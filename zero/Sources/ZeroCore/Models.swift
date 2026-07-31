import Foundation

// MARK: - Project

public enum Autonomy: String, Codable, Sendable, CaseIterable {
    /// Nothing happens without a click. New projects start here.
    case manual
    /// Fixes run on their own; merging still asks.
    case assist
    /// Fix, verify, merge, tell me after.
    case auto

    public var label: String {
        switch self {
        case .manual: return "manual"
        case .assist: return "assist"
        case .auto:   return "auto"
        }
    }
}

public enum Finish: String, Codable, Sendable, CaseIterable {
    case merge, pr, leave
}

public struct Policy: Codable, Sendable, Equatable {
    public var autonomy: Autonomy
    public var maxParallel: Int
    public var worktreeDefault: Bool
    public var finishDefault: Finish
    /// Paths a supervised agent must not touch — migrations, deploy config,
    /// secrets. Enforced as a post-hoc check on the branch diff, and stated in
    /// the seed prompt so a well-behaved agent never gets there.
    public var protectedPaths: [String]

    public init(autonomy: Autonomy = .manual, maxParallel: Int = 2,
                worktreeDefault: Bool = true, finishDefault: Finish = .merge,
                protectedPaths: [String] = []) {
        self.autonomy = autonomy
        self.maxParallel = maxParallel
        self.worktreeDefault = worktreeDefault
        self.finishDefault = finishDefault
        self.protectedPaths = protectedPaths
    }
}

public struct Project: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    /// nil = auto-detect the repo's current HEAD at dispatch time.
    public var baseBranch: String?
    public var defaultAgent: String?
    /// The single command that decides whether a fix is real. Empty = no gate.
    public var verifyCmd: String?
    public var roadmapPath: String?
    public var policy: Policy
    public var createdAt: Date
    public var lastUsed: Date?
    /// Pinned to the top of the capture panel, however long ago you touched it.
    public var favourite: Bool
    /// Dropped from the panel until Ouroboros is used here again. Cleared by
    /// `Registry.touch` — filing an issue or dispatching a run un-hides a
    /// project, committing to it does not.
    public var hidden: Bool

    public init(id: String, name: String, path: String, baseBranch: String? = nil,
                defaultAgent: String? = nil, verifyCmd: String? = nil,
                roadmapPath: String? = nil, policy: Policy = Policy(),
                createdAt: Date = Date(), lastUsed: Date? = nil,
                favourite: Bool = false, hidden: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.baseBranch = baseBranch
        self.defaultAgent = defaultAgent
        self.verifyCmd = verifyCmd
        self.roadmapPath = roadmapPath
        self.policy = policy
        self.createdAt = createdAt
        self.lastUsed = lastUsed
        self.favourite = favourite
        self.hidden = hidden
    }

    /// Hand-written for the same reason `Config`'s is: synthesised decoding
    /// requires every non-optional key to be present, so adding a field would
    /// make every `projects.json` written before it fail to decode — and a
    /// registry that fails to decode is a registry that silently becomes empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        baseBranch = try c.decodeIfPresent(String.self, forKey: .baseBranch)
        defaultAgent = try c.decodeIfPresent(String.self, forKey: .defaultAgent)
        verifyCmd = try c.decodeIfPresent(String.self, forKey: .verifyCmd)
        roadmapPath = try c.decodeIfPresent(String.self, forKey: .roadmapPath)
        policy = try c.decodeIfPresent(Policy.self, forKey: .policy) ?? Policy()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
        favourite = try c.decodeIfPresent(Bool.self, forKey: .favourite) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

// MARK: - Runs

public enum RunKind: String, Codable, Sendable {
    case fix        // an issue → a branch
    case plan       // draft a roadmap / think, no code
    case freeform   // arbitrary prompt in a project
    case cycle      // one iteration of a build loop
}

public enum RunStatus: String, Codable, Sendable, CaseIterable {
    case queued      // waiting for a scheduler slot
    case running     // agent is live in a terminal
    case verifying   // agent exited; the gate is running
    case finishing   // gate passed; merging / opening the PR
    case awaiting    // agent stopped and asked a question
    case succeeded
    case failed
    case abandoned   // stopped by a human

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .abandoned: return true
        default: return false
        }
    }

    public var isActive: Bool {
        switch self {
        case .queued, .running, .verifying, .finishing: return true
        default: return false
        }
    }
}

/// What the agent itself reports, by writing `result.json` into its run dir.
/// A file, not scraped terminal output: every harness can write a file, and it
/// survives the window closing.
public struct AgentResult: Codable, Sendable, Equatable {
    public var outcome: String            // "done" | "needs-input" | "blocked"
    public var summary: String?
    public var question: String?
    public var filesChanged: [String]?
    public var prUrl: String?

    public init(outcome: String, summary: String? = nil, question: String? = nil,
                filesChanged: [String]? = nil, prUrl: String? = nil) {
        self.outcome = outcome
        self.summary = summary
        self.question = question
        self.filesChanged = filesChanged
        self.prUrl = prUrl
    }
}

public struct VerifyOutcome: Codable, Sendable, Equatable {
    public var command: String
    public var exitCode: Int32
    public var output: String
    public var ranAt: Date
    public var passed: Bool { exitCode == 0 }

    public init(command: String, exitCode: Int32, output: String, ranAt: Date = Date()) {
        self.command = command
        self.exitCode = exitCode
        self.output = output
        self.ranAt = ranAt
    }
}

public struct Run: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var projectId: String
    public var projectName: String
    public var kind: RunKind
    public var agent: String
    public var title: String
    public var issuePath: String?
    public var cwd: String
    public var worktreePath: String?
    public var branch: String?
    public var base: String
    public var finish: Finish
    public var status: RunStatus
    public var queuedAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var pid: Int32?
    public var exitCode: Int32?
    public var verify: VerifyOutcome?
    public var result: AgentResult?
    /// Human-facing explanation of a failure, or of what Zero did at the finish.
    public var note: String?
    public var mergedInto: String?
    /// The merge commit, so "undo this fix" is a `git revert -m 1` away.
    public var mergeCommit: String?
    /// Inbox dismissal. Terminal runs stay on disk; this hides them from the queue.
    public var acknowledged: Bool
    public var prompt: String?
    /// The harness's own conversation id, so the thinking behind a fix can be
    /// reopened instead of re-read. Set at dispatch for harnesses that accept
    /// one, discovered at exit for the ones that don't.
    public var sessionId: String?
    /// Whether this branch still merges into its base, and which two commits
    /// that was decided about. Filled in by the daemon for runs waiting on a
    /// human, so a client can render `review` or `conflicts` without shelling
    /// out to git per row. See `MergeVerdict`.
    public var merge: MergeVerdict?

    public init(id: String, projectId: String, projectName: String, kind: RunKind,
                agent: String, title: String, issuePath: String? = nil, cwd: String,
                worktreePath: String? = nil, branch: String? = nil, base: String,
                finish: Finish, status: RunStatus = .queued, queuedAt: Date = Date(),
                startedAt: Date? = nil, endedAt: Date? = nil, pid: Int32? = nil,
                exitCode: Int32? = nil, verify: VerifyOutcome? = nil,
                result: AgentResult? = nil, note: String? = nil, mergedInto: String? = nil,
                mergeCommit: String? = nil, acknowledged: Bool = false, prompt: String? = nil,
                sessionId: String? = nil, merge: MergeVerdict? = nil) {
        self.id = id
        self.projectId = projectId
        self.projectName = projectName
        self.kind = kind
        self.agent = agent
        self.title = title
        self.issuePath = issuePath
        self.cwd = cwd
        self.worktreePath = worktreePath
        self.branch = branch
        self.base = base
        self.finish = finish
        self.status = status
        self.queuedAt = queuedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pid = pid
        self.exitCode = exitCode
        self.verify = verify
        self.result = result
        self.note = note
        self.mergedInto = mergedInto
        self.mergeCommit = mergeCommit
        self.acknowledged = acknowledged
        self.prompt = prompt
        self.sessionId = sessionId
        self.merge = merge
    }

    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

// MARK: - Ideas

public struct Idea: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var projectId: String?
    public var created: Date
    public var source: String
    public var path: String

    public init(id: String, title: String, body: String, projectId: String? = nil,
                created: Date = Date(), source: String = "human", path: String) {
        self.id = id
        self.title = title
        self.body = body
        self.projectId = projectId
        self.created = created
        self.source = source
        self.path = path
    }
}

// MARK: - Proposals (what an AI operator files instead of a run)

public struct Proposal: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case pending, accepted, dismissed }

    public var id: String
    public var projectId: String?
    public var title: String
    public var body: String
    public var source: String
    public var confidence: Double?
    public var dedupeKey: String
    public var evidence: [String]
    public var state: State
    public var createdAt: Date

    public init(id: String, projectId: String?, title: String, body: String, source: String,
                confidence: Double? = nil, dedupeKey: String, evidence: [String] = [],
                state: State = .pending, createdAt: Date = Date()) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.body = body
        self.source = source
        self.confidence = confidence
        self.dedupeKey = dedupeKey
        self.evidence = evidence
        self.state = state
        self.createdAt = createdAt
    }
}

// MARK: - Inbox

/// The Needs-You queue. Five kinds, decisions only — never status. If an item
/// doesn't need a human, it does not belong here.
public struct InboxItem: Codable, Sendable, Equatable, Identifiable {
    /// The five, in the words a person would use.
    ///
    /// `ready` and `landed` were the first two names and both failed the
    /// read-aloud test: `ready` said nothing about who it was waiting on, and
    /// `landed` was jargon for a thing everyone already calls a merge. What is
    /// waiting on you is `review`; what went in is `merged`.
    public enum Kind: String, Codable, Sendable {
        case question    // an agent stopped and asked
        case failed      // the run or the verification gate went red
        case merged      // a fix merged / a PR is open — read it or undo it
        case review      // verified, waiting for you
        case proposal    // an operator suggests work

        /// Runs on disk and `notifyOn` in config.json were written with the old
        /// words and are not worth breaking someone's inbox over.
        public static func canonical(_ raw: String) -> String {
            switch raw {
            case "landed": return Kind.merged.rawValue
            case "ready":  return Kind.review.rawValue
            default:       return raw
            }
        }

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let kind = Kind(rawValue: Kind.canonical(raw)) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "unknown inbox kind '\(raw)'")
            }
            self = kind
        }
    }

    public var id: String
    public var kind: Kind
    public var projectName: String
    public var title: String
    public var detail: String
    public var createdAt: Date
    public var runId: String?
    public var proposalId: String?
    public var actions: [String]

    public init(id: String, kind: Kind, projectName: String, title: String, detail: String,
                createdAt: Date, runId: String? = nil, proposalId: String? = nil,
                actions: [String] = []) {
        self.id = id
        self.kind = kind
        self.projectName = projectName
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.runId = runId
        self.proposalId = proposalId
        self.actions = actions
    }
}

// MARK: - Events

public struct ZeroEvent: Codable, Sendable {
    public var type: String
    public var at: Date
    public var runId: String?
    public var projectId: String?
    public var status: String?
    public var message: String?

    public init(type: String, at: Date = Date(), runId: String? = nil,
                projectId: String? = nil, status: String? = nil, message: String? = nil) {
        self.type = type
        self.at = at
        self.runId = runId
        self.projectId = projectId
        self.status = status
        self.message = message
    }
}

// MARK: - Wire types

public struct IssueDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: String          // stable: project id + path hash
    public var projectId: String
    public var projectName: String
    public var title: String
    public var slug: String
    public var body: String
    public var status: String
    public var created: Date?
    public var path: String

    public init(id: String, projectId: String, projectName: String, title: String, slug: String,
                body: String, status: String, created: Date?, path: String) {
        self.id = id
        self.projectId = projectId
        self.projectName = projectName
        self.title = title
        self.slug = slug
        self.body = body
        self.status = status
        self.created = created
        self.path = path
    }
}

public struct HealthDTO: Codable, Sendable {
    public var ok: Bool
    public var version: String
    public var pid: Int32
    public var uptime: TimeInterval
    public var projects: Int
    public var activeRuns: Int
    public var queuedRuns: Int
    public var inbox: Int

    public init(ok: Bool, version: String, pid: Int32, uptime: TimeInterval, projects: Int,
                activeRuns: Int, queuedRuns: Int, inbox: Int) {
        self.ok = ok
        self.version = version
        self.pid = pid
        self.uptime = uptime
        self.projects = projects
        self.activeRuns = activeRuns
        self.queuedRuns = queuedRuns
        self.inbox = inbox
    }
}

public struct APIError: Codable, Sendable, Error {
    public var error: String
    public init(_ error: String) { self.error = error }
}

public enum ZeroVersion {
    public static let current = "0.1.0"
}
