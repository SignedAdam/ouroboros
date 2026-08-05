import Foundation

public enum Autonomy: String, Codable, Sendable, CaseIterable {
    case manual

    case assist

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

    public var baseBranch: String?
    public var defaultAgent: String?

    public var verifyCmd: String?
    public var roadmapPath: String?
    public var policy: Policy
    public var createdAt: Date
    public var lastUsed: Date?

    public var favourite: Bool

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

public enum RunKind: String, Codable, Sendable {
    case fix
    case plan
    case freeform
    case cycle
}

public enum RunStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case verifying
    case finishing
    case awaiting
    case succeeded
    case failed
    case abandoned

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

public struct AgentResult: Codable, Sendable, Equatable {
    public var outcome: String
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

    public var note: String?
    public var mergedInto: String?

    public var mergeCommit: String?

    public var acknowledged: Bool
    public var prompt: String?

    public var sessionId: String?

    public var merge: MergeVerdict?

    public var resolveOf: String?

    public var resumeMode: String?

    public init(id: String, projectId: String, projectName: String, kind: RunKind,
                agent: String, title: String, issuePath: String? = nil, cwd: String,
                worktreePath: String? = nil, branch: String? = nil, base: String,
                finish: Finish, status: RunStatus = .queued, queuedAt: Date = Date(),
                startedAt: Date? = nil, endedAt: Date? = nil, pid: Int32? = nil,
                exitCode: Int32? = nil, verify: VerifyOutcome? = nil,
                result: AgentResult? = nil, note: String? = nil, mergedInto: String? = nil,
                mergeCommit: String? = nil, acknowledged: Bool = false, prompt: String? = nil,
                sessionId: String? = nil, merge: MergeVerdict? = nil,
                resolveOf: String? = nil, resumeMode: String? = nil) {
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
        self.resolveOf = resolveOf
        self.resumeMode = resumeMode
    }

    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

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

public struct InboxItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case question
        case failed
        case merged
        case review
        case proposal

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

public struct IssueDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: String
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
