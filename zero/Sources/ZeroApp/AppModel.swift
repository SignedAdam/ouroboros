import Foundation
import SwiftUI
import ZeroCore

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: API.Snapshot?
    @Published var connected = false
    @Published var draft = ""
    @Published var selectedProjectId: String?
    @Published var status: String?
    @Published var busy = false

    @Published var agentOverride: String?

    @Published var lastFiled: IssueDTO?

    @Published private(set) var flash: Flash?

    @Published private(set) var leaving: Set<String> = []
    @Published private(set) var vanished = Vanished()

    @Published var showingDiff: DiffReport?

    var dismissCapture: (() -> Void)?

    @Published var optionsOpen = false

    @Published private(set) var branches: [String] = []

    private let client = ZeroClient()
    private var timer: Timer?
    private var flashToken = 0

    var projects: [Project] { snapshot?.projects ?? [] }
    var recents: [ProjectDigest] { snapshot?.recents ?? [] }
    var stats: API.Stats { snapshot?.stats ?? API.Stats() }

    var recentsExpanded: Bool {
        get {
            UserDefaults.standard.object(forKey: "recentsExpanded") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "recentsExpanded")
            objectWillChange.send()
        }
    }
    var inbox: [InboxItem] { snapshot?.inbox ?? [] }
    var activeRuns: [Run] { snapshot?.activeRuns ?? [] }
    var recentRuns: [Run] { snapshot?.recentRuns ?? [] }

    var selectedProject: Project? {
        if let selectedProjectId, let match = projects.first(where: { $0.id == selectedProjectId }) {
            return match
        }
        return projects.first
    }

    var runningCount: Int {
        activeRuns.filter { $0.status != .queued }.count
    }

    var switchOrder: [String] {
        recents.isEmpty ? projects.map(\.id) : recents.map(\.id)
    }

    func cycleProject(by steps: Int) {
        guard let next = ProjectCycle.step(from: selectedProject?.id,
                                           in: switchOrder, by: steps) else { return }
        selectedProjectId = next
    }

    func start() {
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        Task.detached { [client] in
            let result = try? client.get("/v1/snapshot", as: API.Snapshot.self)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let result {
                    self.connected = true

                    guard self.leaving.isEmpty else { return }
                    self.snapshot = result
                    self.forgetDeparted()

                    ToastCenter.shared.observe(result.recentRuns + result.activeRuns)
                } else {
                    self.connected = false
                }
            }
        }
    }

    func ensureDaemon() {
        guard !connected else { return }
        Task.detached { [client] in
            guard !client.isUp else { return }
            let binary = AppModel.daemonBinary()
            guard let binary else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            for _ in 0..<40 {
                if client.isUp { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            await MainActor.run { [weak self] in self?.refresh() }
        }
    }

    nonisolated static func daemonBinary() -> String? {
        let argv0 = CommandLine.arguments.first ?? ""
        let resolved = (argv0 as NSString).isAbsolutePath
            ? argv0
            : FileManager.default.currentDirectoryPath + "/" + argv0
        let sibling = ((resolved as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("ourod")
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        return Shell.which("ourod")
    }

    private(set) var lastVerbAt = Date.distantPast

    func perform(_ verb: RowVerb, _ action: () -> Void) {
        lastVerbAt = Date()
        action()
        if verb.handsOff { handOff(after: verb.beat) }
    }

    func handOff(after beat: Double = 0) {
        guard let dismissCapture else { return }
        guard beat > 0 else { return dismissCapture() }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(beat * 1_000_000_000))
            dismissCapture()
        }
    }

    func note(_ text: String, bad: Bool = false) {
        flashToken &+= 1
        let mine = flashToken
        flash = Flash(text: text, bad: bad)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard flashToken == mine else { return }
            flash = nil
        }
    }

    func clearNote() {
        flashToken &+= 1
        flash = nil
    }

    private func vanish(_ id: String) {
        leaving.insert(id)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)

            vanished.hide(id)
            leaving.remove(id)
            try? await Task.sleep(nanoseconds: 120_000_000)
            refresh()
        }
    }

    private func forgetDeparted() {
        guard !vanished.isEmpty else { return }
        var live = Set(projects.map(\.id))
        for digest in recents {
            live.insert(digest.id)
            live.formUnion(digest.issues.map(\.id))
        }
        vanished.reconcile(live: live)
    }

    func isLeaving(_ id: String) -> Bool { leaving.contains(id) }

    var visibleRecents: [ProjectDigest] { vanished.visible(recents) }

    func issues(of digest: ProjectDigest) -> [IssuePip] { vanished.visible(digest.issues) }

    func remainingIssues(of digest: ProjectDigest) -> [IssuePip] {
        let lifted = Set(waitingOnYou.map(\.id))
        return issues(of: digest).filter { !lifted.contains($0.id) }
    }

    func openCount(of digest: ProjectDigest) -> Int {
        let gone = digest.issues.filter { $0.state == .filed && vanished.contains($0.id) }
        return max(0, digest.openCount - gone.count)
    }

    struct Waiting: Identifiable {
        var pip: IssuePip
        var project: String
        var id: String { pip.id }
    }

    var waitingOnYou: [Waiting] {
        var byRun: [String: Waiting] = [:]
        for digest in visibleRecents {
            for pip in issues(of: digest) {
                guard let runId = pip.runId else { continue }
                byRun[runId] = Waiting(pip: pip, project: digest.name)
            }
        }

        return inbox.compactMap { item -> Waiting? in
            guard item.kind == .question || item.kind == .review else { return nil }
            guard let runId = item.runId else { return nil }
            if let known = byRun[runId] { return known }

            guard let run = run(runId) else { return nil }
            return Waiting(pip: IssuePip(id: run.id, title: run.title,
                                         state: WorkState.of(run),
                                         at: run.endedAt ?? run.queuedAt,
                                         path: run.issuePath, runId: run.id,
                                         agent: run.agent),
                           project: run.projectName)
        }
    }

    func file(fix: Bool) {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        guard let project = selectedProject else {
            status = "no project registered yet"
            return
        }
        busy = true
        let request = API.CreateIssue(project: project.id, title: nil, body: body,
                                      fix: fix, agent: fix ? effectiveAgent : nil)
        Task.detached { [client] in
            let created = try? client.post("/v1/issues", request, as: API.IssueCreated.self)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy = false
                if let created {
                    self.draft = ""

                    self.lastFiled = created.run == nil ? created.issue : nil
                    self.status = created.run != nil
                        ? "\(created.run!.agent) is on it · \(created.issue.title)"
                        : "filed · \(created.issue.title)"
                } else {
                    self.status = "could not file that"
                }
                self.refresh()
            }
        }
    }

    func undoLastFiled() {
        guard let issue = lastFiled else { return }
        lastFiled = nil
        status = "undone"
        deleteIssue(issue.id)
    }

    func runAction(_ action: String, runId: String, answer: String? = nil) {
        busy = true
        Task.detached { [client] in
            var refused: String?
            do {
                switch action {
                case "reply":
                    _ = try client.post("/v1/runs/\(runId)/reply",
                                        API.Reply(answer: answer ?? ""), as: Run.self)
                case "merge":
                    _ = try client.post("/v1/runs/\(runId)/merge", as: Run.self)
                case "undo":
                    _ = try client.post("/v1/runs/\(runId)/undo", as: API.Message.self)
                case "retry":
                    _ = try client.post("/v1/runs/\(runId)/retry", as: Run.self)
                case "stop":
                    _ = try client.post("/v1/runs/\(runId)/stop", as: Run.self)
                default:
                    _ = try client.post("/v1/runs/\(runId)/ack", as: API.Message.self)
                }
            } catch {
                refused = AppModel.refusal(error)
            }
            await MainActor.run { [weak self] in
                self?.busy = false
                if let refused { self?.note(refused, bad: true) }
                self?.refresh()
            }
        }
    }

    nonisolated static func refusal(_ error: Error) -> String {
        guard let client = error as? ZeroClient.ClientError else { return "\(error)" }
        switch client {
        case .http(_, let message): return message
        case .daemonDown:           return "daemon is not running"
        case .transport, .decode:   return client.description
        }
    }

    func proposalAction(_ action: String, id: String) {
        Task.detached { [client] in
            _ = try? client.post("/v1/proposals/\(id)/\(action)", as: API.IssueCreated.self)
            await MainActor.run { [weak self] in self?.refresh() }
        }
    }

    var availableAgents: [String] {
        let installed = (snapshot?.agents ?? []).filter(\.available).map(\.name)
        return installed.isEmpty ? [snapshot?.health.version != nil ? "claude" : "claude"] : installed
    }

    func run(_ id: String) -> Run? {
        (activeRuns + recentRuns).first { $0.id == id }
    }

    var globalDefaultAgent: String {
        (snapshot?.agents ?? []).first(where: \.isDefault)?.name ?? "claude"
    }

    var effectiveAgent: String {
        agentOverride
            ?? selectedProject?.defaultAgent
            ?? (snapshot?.agents ?? []).first(where: \.isDefault)?.name
            ?? availableAgents.first
            ?? "claude"
    }

    func patchProject(_ id: String, _ patch: API.PatchProject) {
        Task.detached { [client] in
            _ = try? client.patch("/v1/projects/\(id)", patch, as: Project.self)
            await MainActor.run { [weak self] in self?.refresh() }
        }
    }

    func hideProject(_ id: String) {
        Task { [client] in
            let ok = await Task.detached {
                (try? client.patch("/v1/projects/\(id)", API.PatchProject(hidden: true),
                                   as: ZeroClient.Empty.self)) != nil
            }.value
            guard ok else { return note("could not hide that one", bad: true) }
            note("hidden until it's active again")
            vanish(id)
        }
    }

    func forgetProject(_ id: String) {
        Task { [client] in
            let ok = await Task.detached {
                (try? client.delete("/v1/projects/\(id)", as: ZeroClient.Empty.self)) != nil
            }.value
            guard ok else { return note("could not remove that one", bad: true) }
            note("removed from Ouroboros")
            vanish(id)
        }
    }

    func fixIssue(_ issueId: String, agent: String? = nil) {
        status = "dispatching…"
        Task.detached { [client] in
            let run = try? client.post("/v1/issues/\(issueId)/fix",
                                       API.FixRequest(agent: agent), as: Run.self)
            await MainActor.run { [weak self] in
                self?.status = run.map { "\($0.agent) is on it" } ?? "could not dispatch"
                self?.refresh()
            }
        }
    }

    func deleteIssue(_ issueId: String) {
        Task { [client] in
            let ok = await Task.detached {
                (try? client.delete("/v1/issues/\(issueId)", as: ZeroClient.Empty.self)) != nil
            }.value
            guard ok else { return note("could not delete that one", bad: true) }
            vanish(issueId)
        }
    }

    func open(_ pip: IssuePip, agent: String? = nil) {
        if agent == nil, pip.canResume, let runId = pip.runId {
            resumeRun(runId)
            return
        }
        guard pip.path != nil else {
            status = "no issue file behind that one"
            return
        }
        fixIssue(pip.id, agent: agent)
    }

    func markDone(_ pip: IssuePip) {
        status = "done · \(pip.title)"
        let runId = pip.runId
        Task.detached { [client] in
            _ = try? client.patch("/v1/issues/\(pip.id)", API.PatchIssue(status: "done"),
                                  as: IssueDTO.self)
            if let runId {
                _ = try? client.post("/v1/runs/\(runId)/ack", as: API.Message.self)
            }
            await MainActor.run { [weak self] in self?.refresh() }
        }
    }

    func resumeRun(_ runId: String) {
        status = "reopening the conversation…"
        Task.detached { [client] in
            let reply = try? client.post("/v1/runs/\(runId)/resume", as: API.Message.self)
            await MainActor.run { [weak self] in
                self?.status = reply?.message ?? "could not resume that one"
            }
        }
    }

    func openLog(_ runId: String) { copyCommand("ouro log \(runId) -f") }
    func showDiff(_ runId: String) { copyCommand("ouro diff \(runId)") }

    private func copyCommand(_ command: String) {
        RowActions.copy(command)
        status = "copied: \(command)"
        note("copied: \(command)")
    }

    func watchRun(_ runId: String) {
        Task.detached {
            Shell.run(["/Applications/Ghostty.app/Contents/MacOS/ghostty",
                       "--title=ouro log", "-e", "zsh", "-lc",
                       "ouro log \(Shell.quote(runId)) -f"], login: true)
        }
    }

    func startReply(to runId: String) {
        draft = "/reply \(runId) "
        note("type the answer, then ⏎")
    }

    func rebaseRun(_ runId: String) {
        note("rebasing…")
        Task { [client] in
            let reply = await Task.detached {
                try? client.post("/v1/runs/\(runId)/rebase", as: API.Message.self)
            }.value
            guard let reply else { return note("could not rebase that one", bad: true) }
            note(reply.message, bad: !reply.ok)
            refresh()
        }
    }

    func resolveRun(_ runId: String) {
        note("sending it back…")
        Task { [client] in
            let next = await Task.detached {
                try? client.post("/v1/runs/\(runId)/resolve", as: Run.self)
            }.value

            guard let next else { return note("could not send that one back", bad: true) }
            note(next.resumeMode == "fresh"
                 ? "a fresh \(next.agent) is reading the branch"
                 : "\(next.agent) is back on \(next.branch ?? "its branch")")
            refresh()
        }
    }

    func discardRun(_ runId: String) {
        note("letting it go…")
        Task { [client] in
            let reply = await Task.detached {
                try? client.post("/v1/runs/\(runId)/discard", as: API.Message.self)
            }.value
            guard let reply, reply.ok else {
                return note("could not discard that one", bad: true)
            }
            note(reply.message)
            refresh()
        }
    }

    func openDiff(_ runId: String) {
        Task { [client] in
            let report = await Task.detached {
                try? client.get("/v1/runs/\(runId)/diff", as: DiffReport.self)
            }.value
            guard let report else { return note("no diff for that one", bad: true) }
            showingDiff = report
        }
    }

    func loadBranches() {
        guard let project = selectedProject else { return }
        Task { [client] in
            let list = await Task.detached {
                try? client.get("/v1/projects/\(project.id)/branches", as: API.BranchList.self)
            }.value
            branches = list?.branches ?? []
        }
    }

    func setOption(_ patch: API.PatchProject, note text: String) {
        guard let project = selectedProject else { return }
        patchProject(project.id, patch)
        note(text)
    }

    func openWorktree(_ runId: String) {
        guard let run = (activeRuns + recentRuns).first(where: { $0.id == runId }),
              let path = run.worktreePath else { return }
        open(path: path)
    }

    func open(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openTerminal(at path: String) {
        Task.detached {
            Shell.run(["open", "-a", "Ghostty", path], login: true)
        }
    }

    func openAgentView(_ project: Project) {
        Task.detached {
            let script = "cd \(Shell.quote(project.path)) && claude agents --cwd \(Shell.quote(project.path))"
            Shell.run(["/Applications/Ghostty.app/Contents/MacOS/ghostty",
                       "--title=agent view", "-e", "zsh", "-lc", script], login: true)
        }
    }

    func openInFinder(_ project: Project) {
        open(path: project.path)
    }
}

struct Flash: Equatable {
    var text: String
    var bad = false
}

extension Run {
    var elapsedLabel: String {
        guard let duration else { return "" }
        let seconds = Int(duration)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

extension InboxItem {
    var tint: Color {
        switch kind {
        case .question: return Color(red: 1.0, green: 0.74, blue: 0.18)
        case .failed:   return Color(red: 1.0, green: 0.37, blue: 0.34)
        case .merged:   return Color(red: 0.49, green: 0.85, blue: 0.34)
        case .review:   return Color(red: 0.47, green: 0.67, blue: 1.0)
        case .proposal: return Color(red: 1.0, green: 0.48, blue: 0.09)
        }
    }

    var label: String {
        switch kind {
        case .question: return "needs you"
        case .failed:   return "failed"
        case .merged:   return "merged"
        case .review:   return "review"
        case .proposal: return "proposal"
        }
    }
}

extension WorkState {
    var tint: Color {
        switch self {
        case .filed, .stopped: return .secondary
        case .queued:   return Color.secondary
        case .running:  return Color(red: 1.0, green: 0.48, blue: 0.09)
        case .asking:   return Color(red: 1.0, green: 0.74, blue: 0.18)
        case .review:   return Color(red: 0.47, green: 0.67, blue: 1.0)
        case .merged:   return Color(red: 0.49, green: 0.85, blue: 0.34)

        case .obsolete: return .secondary

        case .conflicts, .failed: return Color(red: 1.0, green: 0.37, blue: 0.34)
        }
    }

    var isHollow: Bool { self == .filed || self == .stopped || self == .obsolete }
}

extension RunStatus {
    var tint: Color {
        switch self {
        case .queued:    return .secondary
        case .running:   return Color(red: 1.0, green: 0.48, blue: 0.09)
        case .verifying, .finishing: return Color(red: 0.47, green: 0.67, blue: 1.0)
        case .awaiting:  return Color(red: 1.0, green: 0.74, blue: 0.18)
        case .succeeded: return Color(red: 0.49, green: 0.85, blue: 0.34)
        case .failed:    return Color(red: 1.0, green: 0.37, blue: 0.34)
        case .abandoned: return .secondary
        }
    }

    var label: String {
        switch self {
        case .awaiting: return "needs you"
        default: return rawValue
        }
    }
}
