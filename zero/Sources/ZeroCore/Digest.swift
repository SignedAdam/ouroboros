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

/// Where one piece of work has got to, from a sentence you typed to a merge.
///
/// One vocabulary for issues and runs together. The drawer used to keep two
/// lists — TASKS for issues nobody had dispatched, JOBS for runs — and the split
/// was invisible from outside: the same sentence appeared under a different
/// heading depending on whether an agent had been started, and neither heading
/// said so.
/// The words changed once and both renames were the same fix: a state has to
/// say who it is waiting on. `ready` never said "waiting on you", and `landed`
/// was jargon for the thing everyone already calls a merge. `Kind.canonical`
/// in `InboxItem` translates the old spellings on the wire; this enum does the
/// same for anything a daemon or a run file wrote before the rename.
public enum WorkState: String, Codable, Sendable, CaseIterable {
    /// Written down and never handed to anyone. These are the ones that rot.
    case filed
    case queued
    case running
    /// The agent stopped and asked something.
    case asking
    /// Verified, sitting on its branch, and it still merges.
    case review
    /// Verified, and its branch no longer goes into its base. Its own state,
    /// because offering `merge` on it would be a verdict the code has checked
    /// and contradicted.
    case conflicts
    case merged
    case failed
    /// Stopped by a human.
    case stopped

    /// The two words that were renamed, read leniently. Anything else is still
    /// an error: forgiving two renames is not forgiving typos.
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
        // The same test the inbox uses, so the drawer and `ouro inbox` can never
        // disagree about whether a fix actually landed.
        case .succeeded:
            if run.mergedInto != nil || run.result?.prUrl != nil { return .merged }
            // Only a verdict the code actually took. `error != nil` is "we could
            // not tell", and that must never render as "it will not go in".
            if let verdict = run.merge, !verdict.clean, verdict.error == nil { return .conflicts }
            return .review
        }
    }

    public var label: String {
        self == .asking ? "needs you" : rawValue
    }

    /// Moving right now, as opposed to waiting for someone.
    public var isLive: Bool {
        self == .queued || self == .running || self == .asking
    }

    /// Waiting on a person, and on this person. What the drawer lifts to the top
    /// and what `ouro inbox` prints.
    public var needsYou: Bool {
        self == .asking || self == .review || self == .conflicts
    }

    /// Order within a project: what is moving, then what is waiting on you,
    /// then what was only ever written down, then what is finished with.
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
        case .stopped:   return 8
        }
    }
}

/// One piece of work on one line, and everything a row needs to act on it.
public struct IssuePip: Codable, Sendable, Equatable, Identifiable {
    /// The issue's id where there is an issue file, else the run's. Either way
    /// it is what the API takes.
    public var id: String
    public var title: String
    public var state: WorkState
    /// Filed at, or the run's last move.
    public var at: Date
    /// The issue file. Absent for a freeform run, which was never an issue.
    public var path: String?
    public var runId: String?
    public var agent: String
    /// The harness kept a conversation id and can be told to reopen it.
    public var canResume: Bool
    /// Attempts at this one issue. `state` describes the newest.
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

/// How much work a project is carrying, by state.
///
/// Counted over every piece of work in the project, not over the rows the
/// drawer draws: `ProjectDigest.issues` is capped at six for display, so
/// counting rows would under-report exactly the projects most worth reporting.
public struct Tally: Codable, Sendable, Equatable {
    public var filed = 0
    public var queued = 0
    public var running = 0
    public var asking = 0
    public var review = 0
    public var conflicts = 0
    public var merged = 0
    public var failed = 0
    public var stopped = 0

    public init() {}

    /// Every field defaulted and decoded leniently: a daemon older than this
    /// type sends no tally at all, and a project rendering with zeroes beats a
    /// snapshot that fails to decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filed = try c.decodeIfPresent(Int.self, forKey: .filed) ?? 0
        queued = try c.decodeIfPresent(Int.self, forKey: .queued) ?? 0
        running = try c.decodeIfPresent(Int.self, forKey: .running) ?? 0
        asking = try c.decodeIfPresent(Int.self, forKey: .asking) ?? 0
        review = try c.decodeIfPresent(Int.self, forKey: .review) ?? 0
        conflicts = try c.decodeIfPresent(Int.self, forKey: .conflicts) ?? 0
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
        case .merged:    return merged
        case .failed:    return failed
        case .stopped:   return stopped
        }
    }

    /// Still wants something from someone. A merged fix and an abandoned run
    /// are finished with, and a backlog that counts them is a backlog that only
    /// ever grows.
    public var open: Int { filed + queued + running + asking + review + conflicts + failed }

    public var total: Int { open + merged + stopped }

    /// Waiting on *you* specifically — a question, a review, a branch that no
    /// longer merges, a failure. The states worth interrupting someone for.
    public var yours: Int { asking + review + conflicts + failed }

    /// Open states with something in them, most urgent first. What a bar draws
    /// and what a summary reads.
    public var openStates: [(state: WorkState, count: Int)] {
        [WorkState.asking, .failed, .conflicts, .review, .running, .queued, .filed]
            .map { ($0, count(of: $0)) }
            .filter { $0.1 > 0 }
    }
}

/// Why a project is in the drawer at all. Assigned by the daemon so the app
/// never has to re-derive it and get a different answer.
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
        case .favourite: return "pinned"
        case .ouroboros: return "ouroboros"
        case .git:       return "git"
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
    /// The work in this project, most urgent first. Issues and runs in one
    /// list, because to the person who typed the sentence they are one thing.
    public var issues: [IssuePip]
    /// Every piece of work here, by state — including the ones `issues` had to
    /// leave out.
    public var tally: Tally
    /// Filed and never dispatched. The count the drawer puts a noun on.
    public var openCount: Int
    public var running: Int
    public var fixed: Int
    public var failed: Int

    /// The one fact the row's right-hand side carries: what happened to this
    /// project last, in the language of whatever happened.
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

    /// A daemon older than this field sends no `issues`; render the project
    /// rather than failing the whole snapshot on one missing key.
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
    /// An issue file as the drawer needs it: what it says, where it is, and
    /// which status folder it is sitting in.
    struct Filed {
        var title: String
        var path: String
        var at: Date?
        var status: IssueStatus
    }

    private struct Facts {
        var lastIssue: Pulse?
        /// Every issue file in the project, newest first.
        var issues: [Filed]
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

        // Resolving an issue MOVES its file into another status folder, so the
        // path a run recorded at dispatch goes stale the moment a fix lands.
        // The basename survives the move, and is what still ties a finished run
        // back to the issue it is about.
        //
        // `cancelled` is left out on purpose. It is a state for a run somebody
        // stopped, never for an issue, and the drawer does not draw it: an issue
        // parked there before delete learned to remove is not work, and a row
        // that keeps showing it is the bug this rule exists to close.
        var byName: [String: Filed] = [:]
        for filed in facts.issues where filed.status != .cancelled {
            let name = (filed.path as NSString).lastPathComponent
            if byName[name] == nil { byName[name] = filed }
        }

        // One line per piece of work, not per attempt. Retrying an issue three
        // times is one story with three chapters; showing it as three identical
        // titles stacked reads as a rendering bug, which is how it was reported.
        var pips: [IssuePip] = []
        var seen: [String: Int] = [:]
        var covered: Set<String> = []
        for run in mine {
            let name = run.issuePath.map { ($0 as NSString).lastPathComponent }
            // The issue this run is about has been erased. Delete removes, so
            // the row goes with it — otherwise deleting an issue that had ever
            // been dispatched left the run behind, still drawing the sentence
            // you had just thrown away. A freeform run has no issue file and is
            // never caught by this.
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

        // "Filed and never launched": described, and handed to nobody. Distinct
        // from a run that failed, which was at least attempted.
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

        // Counted here, over everything, because six lines down `pips` becomes
        // the first six rows and the tally would start lying about any project
        // with a seventh.
        var tally = Tally()
        for pip in pips { tally.add(pip.state) }

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
            // Six is what an open project can show without the drawer becoming
            // the issue tracker. `ouro issues` is the issue tracker.
            issues: Array(pips.prefix(6)),
            tally: tally,
            openCount: waiting.count,
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
