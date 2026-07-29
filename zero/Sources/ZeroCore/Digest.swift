import Foundation
import Ouroboros

// MARK: - what a project looks like from the outside

/// The last thing that happened in a project, in the language of whatever
/// happened: an issue you filed, or a commit you made. One line, because the
/// capture panel has room for one line.
public struct Pulse: Codable, Sendable, Equatable {
    /// "filed", "commit", "merge", "checkout", … — rendered as the label.
    public var kind: String
    /// The issue title, the commit subject, the branch switched to. May be empty
    /// for events that are entirely described by their kind ("pull").
    public var text: String
    public var at: Date

    public init(kind: String, text: String, at: Date) {
        self.kind = kind
        self.text = text
        self.at = at
    }
}

/// A run, reduced to what fits on one line of the drawer — and to what you can
/// do with it from there.
public struct RunPip: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var status: RunStatus
    public var title: String
    public var at: Date
    public var seconds: Int?
    public var agent: String
    /// The harness's conversation id, when it has one. Absent means "reopening
    /// this is not on the menu", which is different from "it failed".
    public var sessionId: String?
    public var canResume: Bool
    public var worktreePath: String?
    public var branch: String?

    public init(id: String, status: RunStatus, title: String, at: Date, seconds: Int? = nil,
                agent: String = "", sessionId: String? = nil, canResume: Bool = false,
                worktreePath: String? = nil, branch: String? = nil) {
        self.id = id
        self.status = status
        self.title = title
        self.at = at
        self.seconds = seconds
        self.agent = agent
        self.sessionId = sessionId
        self.canResume = canResume
        self.worktreePath = worktreePath
        self.branch = branch
    }
}

/// An issue nobody has been dispatched for — and everything needed to change
/// that from a right-click.
public struct TaskPip: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var path: String
    public var at: Date?

    public init(id: String, title: String, path: String, at: Date? = nil) {
        self.id = id
        self.title = title
        self.path = path
        self.at = at
    }
}

/// Which of the drawer's three lists a project belongs to. Assigned by the
/// daemon so the app never has to re-derive it and get a different answer.
public enum ProjectSection: String, Codable, Sendable, CaseIterable {
    /// Pinned by hand. Always shown, however cold.
    case favourite
    /// Ouroboros has been used here — issues filed, agents run.
    case ouroboros
    /// Only git says anything happened. Never filed against.
    case git

    /// Top to bottom, most deliberate first.
    public static var ordered: [ProjectSection] { [.favourite, .ouroboros, .git] }

    public var label: String {
        switch self {
        case .favourite: return "FAVOURITES"
        case .ouroboros: return "IN OUROBOROS"
        case .git:       return "GIT ACTIVITY"
        }
    }

    public var glyph: String {
        switch self {
        case .favourite: return "star.fill"
        case .ouroboros: return "circle.hexagonpath"
        case .git:       return "arrow.triangle.branch"
        }
    }

    public var explanation: String {
        switch self {
        case .favourite:
            return "Pinned by you. These stay here however long it has been."
        case .ouroboros:
            return "You have filed or fixed something here through Ouroboros."
        case .git:
            return "You have been committing here, but Ouroboros has never run in it."
        }
    }
}

/// One project, as the capture panel needs it: what happened here last, what
/// Ouroboros has run, and what is still waiting for a run.
///
/// Assembled by the daemon rather than the app, for the usual reason — the app
/// has no powers of its own — and because reading sixty repos' issue folders is
/// work that wants a cache, and the daemon is the thing that gets to keep one.
public struct ProjectDigest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    /// Ouroboros has actually been used here: filed an issue, or run an agent.
    /// False means this project is only in the list because you committed to it.
    public var handled: Bool
    public var section: ProjectSection
    public var favourite: Bool
    public var autonomy: Autonomy
    /// The harness this project dispatches to, resolved: its own default, or
    /// the global one.
    public var agent: String
    public var pulse: Pulse?
    /// Issues filed and never dispatched — the work you have described but not
    /// yet handed to anyone.
    public var tasks: [TaskPip]
    public var taskCount: Int
    /// Newest first.
    public var jobs: [RunPip]
    public var running: Int
    public var fixed: Int
    public var failed: Int

    public init(id: String, name: String, path: String, handled: Bool,
                section: ProjectSection = .git, favourite: Bool = false,
                autonomy: Autonomy = .manual, agent: String = "",
                pulse: Pulse? = nil, tasks: [TaskPip] = [], taskCount: Int = 0,
                jobs: [RunPip] = [], running: Int = 0, fixed: Int = 0, failed: Int = 0) {
        self.id = id
        self.name = name
        self.path = path
        self.handled = handled
        self.section = section
        self.favourite = favourite
        self.autonomy = autonomy
        self.agent = agent
        self.pulse = pulse
        self.tasks = tasks
        self.taskCount = taskCount
        self.jobs = jobs
        self.running = running
        self.fixed = fixed
        self.failed = failed
    }
}

// MARK: - the reflog as an activity feed

/// `.git/logs/HEAD` is a free activity log every repo already keeps: one line
/// per commit, merge, checkout, pull or reset, with a timestamp and a message.
///
/// Reading it beats shelling out to `git log`: with sixty registered projects
/// the subprocess version costs seconds, and the capture panel has to open
/// instantly. It is also more truthful than the file's mtime — a reflog line
/// says *what* happened, not just that something did.
public enum GitLog {
    public static func lastEvent(repo: String) -> Pulse? {
        let head = (repo as NSString).appendingPathComponent(".git/logs/HEAD")
        guard let line = tail(of: head), let tab = line.firstIndex(of: "\t") else { return nil }
        let meta = line[..<tab]
        let message = String(line[line.index(after: tab)...])

        // "<old> <new> <name> <email> <unix seconds> <tz>" — counted from the
        // right, because a person's name is any number of words.
        let fields = meta.split(separator: " ")
        guard fields.count >= 2, let seconds = TimeInterval(fields[fields.count - 2]) else {
            return nil
        }
        let (kind, text) = describe(message)
        return Pulse(kind: kind, text: text, at: Date(timeIntervalSince1970: seconds))
    }

    /// Reflog messages are terse but structured. Turn each into a label and the
    /// one piece of it worth reading.
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
            // "commit", "commit (amend)", "commit (initial)" — all commits.
            return ("commit", tail)
        case "merge":
            // "merge feat/x: Fast-forward" — the branch is the interesting half.
            return ("merge", String(head.dropFirst("merge ".count)))
        case "checkout":
            // "checkout: moving from a to b" — where you ended up.
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

    /// The last line, read from the end of the file. Reflogs grow forever and
    /// only the final line matters.
    static func tail(of path: String, window: UInt64 = 4096) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        // Lossy on purpose: a fixed-size window can land mid-character, and the
        // damage is confined to a line we are about to throw away anyway.
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").last.map { String($0) }
    }
}

// MARK: - digests

/// Builds `ProjectDigest`s, and remembers what it read.
///
/// The panel polls twice a second-ish; parsing every issue file in eight repos
/// at that rate would be silly. Everything that comes off disk is cached
/// against the modification times of the directories it came from, so a poll
/// that changes nothing costs a handful of `stat` calls.
public final class Digests: @unchecked Sendable {
    private struct Facts {
        var lastIssue: Pulse?
        /// Issues still sitting in `.issues/new`, newest first.
        var open: [(title: String, path: String, at: Date?)]
        var git: Pulse?
    }

    private let lock = NSLock()
    private var cache: [String: (stamp: String, facts: Facts)] = [:]

    public init() {}

    /// `runs` is every known run — passed in rather than fetched so the caller
    /// reads the store once for the whole snapshot.
    public func digest(_ project: Project, runs: [Run],
                       defaultAgent: String = "",
                       resumable: (Run) -> Bool = { _ in false }) -> ProjectDigest {
        let facts = facts(for: project)
        let mine = runs.filter { $0.projectId == project.id }

        // "Defined but not launched": an issue nobody has dispatched an agent
        // for. Runs remember the issue file they came from, so this is exact
        // rather than a guess from titles.
        let dispatched = Set(mine.compactMap { $0.issuePath.map(Registry.normalize) })
        let waiting = facts.open.filter { !dispatched.contains(Registry.normalize($0.path)) }

        let jobs = mine.prefix(4).map { run in
            RunPip(id: run.id, status: run.status, title: run.title,
                   at: run.endedAt ?? run.startedAt ?? run.queuedAt,
                   seconds: run.duration.map { Int($0) },
                   agent: run.agent,
                   sessionId: run.sessionId,
                   canResume: run.sessionId != nil && resumable(run),
                   worktreePath: run.worktreePath,
                   branch: run.branch)
        }

        let handled = project.lastUsed != nil || !mine.isEmpty || facts.lastIssue != nil
        // What the panel shows as "the last thing that happened here": for a
        // project Ouroboros knows, that is the issue you filed; for one it only
        // knows from the outside, the repo's own last move.
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
            tasks: waiting.prefix(4).map {
                TaskPip(id: IssueService.id(project: project, path: $0.path),
                        title: $0.title, path: $0.path, at: $0.at)
            },
            taskCount: waiting.count,
            jobs: Array(jobs),
            running: mine.filter { $0.status.isActive && $0.status != .queued }.count,
            fixed: mine.filter { $0.status == .succeeded }.count,
            failed: mine.filter { $0.status == .failed }.count)
    }

    // MARK: cache

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
            open: issues.filter { $0.status == .new }.map { ($0.title, $0.path ?? "", $0.created) },
            git: GitLog.lastEvent(repo: project.path))

        lock.lock()
        cache[project.id] = (stamp, facts)
        lock.unlock()
        return facts
    }

    /// Cheap proof that nothing we read has changed: the mtimes of the issue
    /// folders and of the reflog. A folder's mtime moves when an issue is
    /// added, removed or moved between statuses, which is every transition the
    /// drawer can see.
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

// MARK: - time, in as few characters as possible

/// "now", "4m", "3h", "6d", "2w". The drawer has room for two characters and a
/// unit, and a relative age is the only form of a timestamp anyone reads here.
public enum Ago {
    public static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        // Future dates happen (clock skew, a file written a moment ago on a
        // machine with a fast clock) and "in 3 seconds" is never useful here.
        if seconds < 45 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        if seconds < 86_400 * 7 { return "\(Int(seconds / 86_400))d" }
        if seconds < 86_400 * 365 { return "\(Int(seconds / (86_400 * 7)))w" }
        return "\(Int(seconds / (86_400 * 365)))y"
    }
}
