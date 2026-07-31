import Foundation

/// Fan-out for live state. The CLI's `ouro runs -w` and the menu-bar app both
/// subscribe here rather than polling — a run that flips to `failed` should
/// reach the eyes watching it in the same second.
public final class EventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: SSEConnection] = [:]
    private var recent: [ZeroEvent] = []
    private let historyLimit = 200

    public init() {}

    public func subscribe(_ connection: SSEConnection) {
        lock.lock()
        subscribers[connection.id] = connection
        lock.unlock()
        connection.comment("ouroboros")
    }

    public func unsubscribe(_ connection: SSEConnection) {
        lock.lock(); subscribers.removeValue(forKey: connection.id); lock.unlock()
    }

    public func history() -> [ZeroEvent] {
        lock.lock(); defer { lock.unlock() }
        return recent
    }

    public func publish(_ event: ZeroEvent) {
        lock.lock()
        recent.append(event)
        if recent.count > historyLimit { recent.removeFirst(recent.count - historyLimit) }
        let targets = Array(subscribers.values)
        lock.unlock()

        let payload = Zero.compactEncoder.encodeSafe(event)
        var dead: [UUID] = []
        for connection in targets where !connection.send(event: event.type, data: payload) {
            dead.append(connection.id)
        }
        if !dead.isEmpty {
            lock.lock()
            for id in dead { subscribers.removeValue(forKey: id) }
            lock.unlock()
        }
    }

    /// Keeps proxies and sleepy sockets from dropping an idle stream.
    public func heartbeat() {
        lock.lock(); let targets = Array(subscribers.values); lock.unlock()
        var dead: [UUID] = []
        for connection in targets where !connection.comment("ping") { dead.append(connection.id) }
        if !dead.isEmpty {
            lock.lock()
            for id in dead { subscribers.removeValue(forKey: id) }
            lock.unlock()
        }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return subscribers.count
    }
}

/// Outbound pings. Mirrors the inbox and nothing else — the design rule is that
/// a notification always corresponds to something that needs a decision, so
/// "run started" is never sent anywhere.
public struct Notifier: Sendable {
    public let webhook: String?
    public let macOS: Bool
    public let enabledKinds: Set<String>

    public init(config: Config) {
        self.webhook = config.discordWebhook
        self.macOS = config.notifyMacOS
        // Through `canonical`, so a config written before the rename still
        // asks for the same notifications.
        self.enabledKinds = Set(config.notifyOn.map(InboxItem.Kind.canonical))
    }

    public func notify(_ item: InboxItem) {
        guard enabledKinds.contains(item.kind.rawValue) else { return }
        discord(item)
        if macOS, item.kind == .question || item.kind == .failed {
            banner(title: "\(item.projectName) — \(Notifier.headline(item.kind))",
                   message: item.title)
        }
    }

    static func headline(_ kind: InboxItem.Kind) -> String {
        switch kind {
        case .question: return "needs you"
        case .failed:   return "failed"
        case .merged:   return "merged"
        case .review:   return "waiting for you"
        case .proposal: return "proposal"
        }
    }

    static func color(_ kind: InboxItem.Kind) -> Int {
        switch kind {
        case .question: return 0xFFBD2E
        case .failed:   return 0xFF5F56
        case .merged:   return 0x7ED957
        case .review:   return 0x78AAFF
        case .proposal: return 0xFF7A18
        }
    }

    public func discord(_ item: InboxItem) {
        guard let webhook, !webhook.isEmpty, let url = URL(string: webhook) else { return }
        let embed: [String: Any] = [
            "title": "\(Notifier.headline(item.kind).uppercased()) · \(item.projectName)",
            "description": item.title,
            "color": Notifier.color(item.kind),
            "fields": item.detail.isEmpty ? [] : [[
                "name": "detail",
                "value": String(item.detail.prefix(1000)),
                "inline": false,
            ]],
            "footer": ["text": "ouroboros zero"],
        ]
        let payload: [String: Any] = ["embeds": [embed]]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10
        // Fire and forget — a Discord outage must never stall a run transition.
        URLSession.shared.dataTask(with: request).resume()
    }

    public func banner(title: String, message: String) {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(escape(message))\" with title \"\(escape(title))\""
        DispatchQueue.global().async {
            Shell.run(["osascript", "-e", script], timeout: 10)
        }
    }
}

/// Derives the Needs-You queue. Pure function of runs + proposals: there is no
/// separate inbox database to drift out of sync, and acknowledging an item is
/// just a flag on the run it came from.
public enum Inbox {
    public static func build(runs: [Run], proposals: [Proposal]) -> [InboxItem] {
        var items: [InboxItem] = []

        for run in runs where !run.acknowledged {
            switch run.status {
            case .awaiting:
                items.append(InboxItem(
                    id: run.id, kind: .question, projectName: run.projectName,
                    title: run.title,
                    detail: run.result?.question ?? run.note ?? "The agent stopped and asked for a decision.",
                    createdAt: run.endedAt ?? run.queuedAt, runId: run.id,
                    actions: ["reply", "drop"]))

            case .failed:
                var detail = run.note ?? "The run failed."
                if let verify = run.verify, !verify.passed {
                    detail = "\(verify.command) failed (exit \(verify.exitCode))"
                }
                items.append(InboxItem(
                    id: run.id, kind: .failed, projectName: run.projectName,
                    title: run.title, detail: detail,
                    createdAt: run.endedAt ?? run.queuedAt, runId: run.id,
                    actions: ["log", "retry", "drop"]))

            case .succeeded:
                if run.mergedInto != nil || run.result?.prUrl != nil {
                    let detail = run.result?.prUrl.map { "PR: \($0)" }
                        ?? run.result?.summary
                        ?? "Merged into \(run.mergedInto ?? "base")."
                    items.append(InboxItem(
                        id: run.id, kind: .merged, projectName: run.projectName,
                        title: run.title, detail: detail,
                        createdAt: run.endedAt ?? run.queuedAt, runId: run.id,
                        actions: ["diff", "undo", "ok"]))
                } else if let verdict = run.merge, !verdict.clean, verdict.error == nil {
                    // Tested, and it will not go in. Offering "merge" here is
                    // how this product came to say `ready` about a branch it had
                    // never tried to merge: an action that is known to fail is
                    // worse than no action, because it reads as a verdict.
                    let files = verdict.conflicts.prefix(3).joined(separator: ", ")
                    let more = verdict.conflicts.count > 3
                        ? " and \(verdict.conflicts.count - 3) more" : ""
                    items.append(InboxItem(
                        id: run.id, kind: .review, projectName: run.projectName,
                        title: run.title,
                        detail: "Verified, but \(run.branch ?? "its branch") no longer merges into "
                            + "\(verdict.base) — conflicts in \(files)\(more). Rebase it, then merge.",
                        createdAt: run.endedAt ?? run.queuedAt, runId: run.id,
                        actions: ["diff", "drop"]))
                } else {
                    items.append(InboxItem(
                        id: run.id, kind: .review, projectName: run.projectName,
                        title: run.title,
                        detail: run.note ?? "Verified on \(run.branch ?? "its branch") — waiting for you to merge.",
                        createdAt: run.endedAt ?? run.queuedAt, runId: run.id,
                        actions: ["merge", "diff", "drop"]))
                }

            default:
                continue
            }
        }

        for proposal in proposals where proposal.state == .pending {
            items.append(InboxItem(
                id: proposal.id, kind: .proposal,
                projectName: proposal.projectId ?? "unassigned",
                title: proposal.title,
                detail: "\(proposal.source): \(proposal.body.prefix(300))",
                createdAt: proposal.createdAt, proposalId: proposal.id,
                actions: ["fix", "dismiss"]))
        }

        // Questions first — they are the only items actively blocking work.
        let rank: [InboxItem.Kind: Int] = [.question: 0, .failed: 1, .review: 2, .proposal: 3, .merged: 4]
        return items.sorted { a, b in
            let ra = rank[a.kind] ?? 9, rb = rank[b.kind] ?? 9
            return ra != rb ? ra < rb : a.createdAt > b.createdAt
        }
    }
}
