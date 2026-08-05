import Foundation
import Ouroboros

public struct Pulse: Codable, Sendable, Equatable {
    public var kind: String

    public var text: String
    public var at: Date

    public init(kind: String, text: String, at: Date) {
        self.kind = kind
        self.text = text
        self.at = at
    }
}

public enum WorkState: String, Codable, Sendable, CaseIterable {
    case filed
    case queued
    case running

    case asking

    case review

    case conflicts

    case obsolete
    case merged
    case failed

    case stopped

    public static func canonical(_ raw: String) -> String {
        switch raw {
        case "ready":  return WorkState.review.rawValue
        case "landed": return WorkState.merged.rawValue
        default:       return raw
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let state = WorkState(rawValue: WorkState.canonical(raw)) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "unknown work state '\(raw)'")
        }
        self = state
    }

    public static func of(_ run: Run) -> WorkState {
        switch run.status {
        case .queued:    return .queued
        case .running, .verifying, .finishing: return .running
        case .awaiting:  return .asking
        case .failed:    return .failed
        case .abandoned: return .stopped

        case .succeeded:
            if run.mergedInto != nil || run.result?.prUrl != nil { return .merged }

            if let verdict = run.merge, verdict.spent { return .obsolete }

            if let verdict = run.merge, !verdict.clean, verdict.error == nil { return .conflicts }
            return .review
        }
    }

    public var label: String {
        self == .asking ? "needs you" : rawValue
    }

    public var isLive: Bool {
        self == .queued || self == .running || self == .asking
    }

    public var needsYou: Bool {
        self == .asking || self == .review || self == .conflicts
    }

    public var rank: Int {
        switch self {
        case .asking:    return 0
        case .running:   return 1
        case .queued:    return 2
        case .review:    return 3
        case .conflicts: return 4
        case .failed:    return 5
        case .filed:     return 6
        case .merged:    return 7
        case .obsolete:  return 8
        case .stopped:   return 9
        }
    }
}

public struct IssuePip: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var state: WorkState

    public var at: Date

    public var path: String?
    public var runId: String?
    public var agent: String

    public var canResume: Bool

    public var attempts: Int

    public init(id: String, title: String, state: WorkState, at: Date,
                path: String? = nil, runId: String? = nil, agent: String = "",
                canResume: Bool = false, attempts: Int = 1) {
        self.id = id
        self.title = title
        self.state = state
        self.at = at
        self.path = path
        self.runId = runId
        self.agent = agent
        self.canResume = canResume
        self.attempts = attempts
    }
}

public struct Tally: Codable, Sendable, Equatable {
    public var filed = 0
    public var queued = 0
    public var running = 0
    public var asking = 0
    public var review = 0
    public var conflicts = 0
    public var obsolete = 0
    public var merged = 0
    public var failed = 0
    public var stopped = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filed = try c.decodeIfPresent(Int.self, forKey: .filed) ?? 0
        queued = try c.decodeIfPresent(Int.self, forKey: .queued) ?? 0
        running = try c.decodeIfPresent(Int.self, forKey: .running) ?? 0
        asking = try c.decodeIfPresent(Int.self, forKey: .asking) ?? 0
        review = try c.decodeIfPresent(Int.self, forKey: .review) ?? 0
        conflicts = try c.decodeIfPresent(Int.self, forKey: .conflicts) ?? 0
        obsolete = try c.decodeIfPresent(Int.self, forKey: .obsolete) ?? 0
        merged = try c.decodeIfPresent(Int.self, forKey: .merged) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        stopped = try c.decodeIfPresent(Int.self, forKey: .stopped) ?? 0
    }

    public mutating func add(_ state: WorkState) {
        switch state {
        case .filed:     filed += 1
        case .queued:    queued += 1
        case .running:   running += 1
        case .asking:    asking += 1
        case .review:    review += 1
        case .conflicts: conflicts += 1
        case .obsolete:  obsolete += 1
        case .merged:    merged += 1
        case .failed:    failed += 1
        case .stopped:   stopped += 1
        }
    }

    public func count(of state: WorkState) -> Int {
        switch state {
        case .filed:     return filed
        case .queued:    return queued
        case .running:   return running
        case .asking:    return asking
        case .review:    return review
        case .conflicts: return conflicts
        case .obsolete:  return obsolete
        case .merged:    return merged
        case .failed:    return failed
        case .stopped:   return stopped
        }
    }

    public var open: Int { filed + queued + running + asking + review + conflicts + failed }

    public var total: Int { open + merged + obsolete + stopped }

    public var yours: Int { asking + review + conflicts + failed }

    public var openStates: [(state: WorkState, count: Int)] {
        [WorkState.asking, .failed, .conflicts, .review, .running, .queued, .filed]
            .map { ($0, count(of: $0)) }
            .filter { $0.1 > 0 }
    }
}

public enum ProjectSection: String, Codable, Sendable, CaseIterable {
    case favourite

    case ouroboros

    case git

    public static var ordered: [ProjectSection] { [.favourite, .ouroboros, .git] }

    public var label: String {
        switch self {
        case .favourite: return "pinned"
        case .ouroboros: return "ouroboros"
        case .git:       return "git"
        }
    }
}

public struct ProjectDigest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var path: String

    public var handled: Bool
    public var section: ProjectSection
    public var favourite: Bool
    public var autonomy: Autonomy

    public var agent: String
    public var pulse: Pulse?

    public var issues: [IssuePip]

    public var tally: Tally

    public var openCount: Int
    public var running: Int
    public var fixed: Int
    public var failed: Int

    public var lead: IssuePip? { issues.first }

    public init(id: String, name: String, path: String, handled: Bool,
                section: ProjectSection = .git, favourite: Bool = false,
                autonomy: Autonomy = .manual, agent: String = "",
                pulse: Pulse? = nil, issues: [IssuePip] = [], tally: Tally = Tally(),
                openCount: Int = 0, running: Int = 0, fixed: Int = 0, failed: Int = 0) {
        self.id = id
        self.name = name
        self.path = path
        self.handled = handled
        self.section = section
        self.favourite = favourite
        self.autonomy = autonomy
        self.agent = agent
        self.pulse = pulse
        self.issues = issues
        self.tally = tally
        self.openCount = openCount
        self.running = running
        self.fixed = fixed
        self.failed = failed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        handled = try c.decodeIfPresent(Bool.self, forKey: .handled) ?? false
        section = try c.decodeIfPresent(ProjectSection.self, forKey: .section) ?? .git
        favourite = try c.decodeIfPresent(Bool.self, forKey: .favourite) ?? false
        autonomy = try c.decodeIfPresent(Autonomy.self, forKey: .autonomy) ?? .manual
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        pulse = try c.decodeIfPresent(Pulse.self, forKey: .pulse)
        issues = try c.decodeIfPresent([IssuePip].self, forKey: .issues) ?? []
        tally = try c.decodeIfPresent(Tally.self, forKey: .tally) ?? Tally()
        openCount = try c.decodeIfPresent(Int.self, forKey: .openCount) ?? 0
        running = try c.decodeIfPresent(Int.self, forKey: .running) ?? 0
        fixed = try c.decodeIfPresent(Int.self, forKey: .fixed) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
    }
}

public enum GitLog {
    public static func lastEvent(repo: String) -> Pulse? {
        let head = (repo as NSString).appendingPathComponent(".git/logs/HEAD")
        guard let line = tail(of: head), let tab = line.firstIndex(of: "\t") else { return nil }
        let meta = line[..<tab]
        let message = String(line[line.index(after: tab)...])

        let fields = meta.split(separator: " ")
        guard fields.count >= 2, let seconds = TimeInterval(fields[fields.count - 2]) else {
            return nil
        }
        let (kind, text) = describe(message)
        return Pulse(kind: kind, text: text, at: Date(timeIntervalSince1970: seconds))
    }

    static func describe(_ message: String) -> (kind: String, text: String) {
        let raw = message.trimmingCharacters(in: .whitespaces)
        guard let colon = raw.range(of: ": ") else {
            return (raw.split(separator: " ").first.map(String.init) ?? raw, "")
        }
        let head = String(raw[..<colon.lowerBound])
        let tail = String(raw[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        let verb = head.split(separator: " ").first.map(String.init) ?? head

        switch verb {
        case "commit":
            return ("commit", tail)
        case "merge":
            return ("merge", String(head.dropFirst("merge ".count)))
        case "checkout":
            if let to = tail.range(of: " to ", options: .backwards) {
                return ("checkout", String(tail[to.upperBound...]))
            }
            return ("checkout", tail)
        case "rebase", "pull", "reset", "clone", "branch":
            return (verb, tail)
        default:
            return (verb, tail)
        }
    }

    static func tail(of path: String, window: UInt64 = 4096) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").last.map { String($0) }
    }
}

public final class Digests: @unchecked Sendable {
    struct Filed {
        var title: String
        var path: String
        var at: Date?
        var status: IssueStatus
    }

    private struct Facts {
        var lastIssue: Pulse?

        var issues: [Filed]
        var git: Pulse?
    }

    private let lock = NSLock()
    private var cache: [String: (stamp: String, facts: Facts)] = [:]

    public init() {}

    public func digest(_ project: Project, runs: [Run],
                       defaultAgent: String = "",
                       resumable: (Run) -> Bool = { _ in false }) -> ProjectDigest {
        let facts = facts(for: project)
        let mine = runs.filter { $0.projectId == project.id }

        var byName: [String: Filed] = [:]
        for filed in facts.issues where filed.status != .cancelled {
            let name = (filed.path as NSString).lastPathComponent
            if byName[name] == nil { byName[name] = filed }
        }

        var pips: [IssuePip] = []
        var seen: [String: Int] = [:]
        var covered: Set<String> = []
        for run in mine {
            let name = run.issuePath.map { ($0 as NSString).lastPathComponent }

            if let name, byName[name] == nil { continue }
            let key = name ?? run.id
            if let index = seen[key] {
                pips[index].attempts += 1
                continue
            }
            seen[key] = pips.count
            let filed = name.flatMap { byName[$0] }
            if let filed { covered.insert(filed.path) }
            pips.append(IssuePip(
                id: filed.map { IssueService.id(project: project, path: $0.path) } ?? run.id,
                title: filed?.title ?? run.title,
                state: WorkState.of(run),
                at: run.endedAt ?? run.startedAt ?? run.queuedAt,
                path: filed?.path,
                runId: run.id,
                agent: run.agent,
                canResume: run.sessionId != nil && resumable(run)))
        }

        let waiting = facts.issues.filter { $0.status == .new && !covered.contains($0.path) }
        for filed in waiting {
            pips.append(IssuePip(
                id: IssueService.id(project: project, path: filed.path),
                title: filed.title,
                state: .filed,
                at: filed.at ?? .distantPast,
                path: filed.path))
        }
        pips.sort { a, b in
            a.state.rank != b.state.rank ? a.state.rank < b.state.rank : a.at > b.at
        }

        var tally = Tally()
        for pip in pips { tally.add(pip.state) }

        let handled = project.lastUsed != nil || !mine.isEmpty || facts.lastIssue != nil

        let pulse = (handled ? facts.lastIssue : nil) ?? facts.git ?? facts.lastIssue

        return ProjectDigest(
            id: project.id,
            name: project.name,
            path: project.path,
            handled: handled,
            section: project.favourite ? .favourite : (handled ? .ouroboros : .git),
            favourite: project.favourite,
            autonomy: project.policy.autonomy,
            agent: project.defaultAgent ?? defaultAgent,
            pulse: pulse,

            issues: Array(pips.prefix(6)),
            tally: tally,
            openCount: waiting.count,
            running: mine.filter { $0.status.isActive && $0.status != .queued }.count,
            fixed: mine.filter { $0.status == .succeeded }.count,
            failed: mine.filter { $0.status == .failed }.count)
    }

    private func facts(for project: Project) -> Facts {
        let stamp = stamp(for: project)
        lock.lock()
        if let hit = cache[project.id], hit.stamp == stamp {
            lock.unlock()
            return hit.facts
        }
        lock.unlock()

        let store = IssueStore(rootDir: project.path)
        let issues = store.list()
        let newest = issues.first
        let facts = Facts(
            lastIssue: newest.flatMap { issue in
                issue.created.map { Pulse(kind: "filed", text: issue.title, at: $0) }
            },
            issues: issues.compactMap { issue in
                guard let path = issue.path else { return nil }
                return Filed(title: issue.title, path: path,
                             at: issue.created, status: issue.status)
            },
            git: GitLog.lastEvent(repo: project.path))

        lock.lock()
        cache[project.id] = (stamp, facts)
        lock.unlock()
        return facts
    }

    private func stamp(for project: Project) -> String {
        var parts: [String] = []
        let fm = FileManager.default
        for status in IssueStatus.allCases {
            let dir = (project.path as NSString)
                .appendingPathComponent(".issues/\(status.rawValue)")
            let date = (try? fm.attributesOfItem(atPath: dir))?[.modificationDate] as? Date
            parts.append(date.map { String($0.timeIntervalSince1970) } ?? "-")
        }
        let log = (project.path as NSString).appendingPathComponent(".git/logs/HEAD")
        let logDate = (try? fm.attributesOfItem(atPath: log))?[.modificationDate] as? Date
        parts.append(logDate.map { String($0.timeIntervalSince1970) } ?? "-")
        return parts.joined(separator: "|")
    }
}

public enum Ago {
    public static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)

        if seconds < 45 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        if seconds < 86_400 * 7 { return "\(Int(seconds / 86_400))d" }
        if seconds < 86_400 * 365 { return "\(Int(seconds / (86_400 * 7)))w" }
        return "\(Int(seconds / (86_400 * 365)))y"
    }
}
