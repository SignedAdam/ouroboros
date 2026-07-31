import Foundation

/// The wire contract. Shared by the daemon, the CLI and the app so there is
/// exactly one definition of every request — and so an AI operator reading this
/// file knows the whole surface.
public enum API {

    // MARK: projects

    public struct RegisterProject: Codable, Sendable {
        public var path: String
        public var name: String?
        public var autonomy: String?
        public var verifyCmd: String?
        public init(path: String, name: String? = nil, autonomy: String? = nil,
                    verifyCmd: String? = nil) {
            self.path = path; self.name = name; self.autonomy = autonomy; self.verifyCmd = verifyCmd
        }
    }

    public struct PatchProject: Codable, Sendable {
        public var name: String?
        public var baseBranch: String?
        public var verifyCmd: String?
        public var defaultAgent: String?
        public var autonomy: String?
        public var maxParallel: Int?
        public var worktreeDefault: Bool?
        public var finishDefault: String?
        public var protectedPaths: [String]?
        /// Pin to the top of the capture panel.
        public var favourite: Bool?
        /// Drop out of the capture panel until Ouroboros is used here again.
        public var hidden: Bool?
        public init(name: String? = nil, baseBranch: String? = nil, verifyCmd: String? = nil,
                    defaultAgent: String? = nil, autonomy: String? = nil, maxParallel: Int? = nil,
                    worktreeDefault: Bool? = nil, finishDefault: String? = nil,
                    protectedPaths: [String]? = nil, favourite: Bool? = nil, hidden: Bool? = nil) {
            self.name = name; self.baseBranch = baseBranch; self.verifyCmd = verifyCmd
            self.defaultAgent = defaultAgent; self.autonomy = autonomy; self.maxParallel = maxParallel
            self.worktreeDefault = worktreeDefault; self.finishDefault = finishDefault
            self.protectedPaths = protectedPaths
            self.favourite = favourite; self.hidden = hidden
        }
    }

    /// What a resume produced: the command that ran, and where it ran.
    public struct Resumed: Codable, Sendable {
        public var runId: String
        public var command: String
        public var cwd: String
        public init(runId: String, command: String, cwd: String) {
            self.runId = runId; self.command = command; self.cwd = cwd
        }
    }

    public struct AgentList: Codable, Sendable {
        public var agents: [AgentInfo]
        public var defaultAgent: String
        public init(agents: [AgentInfo], defaultAgent: String) {
            self.agents = agents; self.defaultAgent = defaultAgent
        }
    }

    /// A project's local branches, so the capture panel can offer `base` as a
    /// list to pick from instead of a name you have to spell correctly.
    public struct BranchList: Codable, Sendable {
        public var branches: [String]
        /// What the project dispatches against today.
        public var base: String
        public init(branches: [String], base: String) {
            self.branches = branches; self.base = base
        }
    }

    public struct DiscoverRequest: Codable, Sendable {
        public var root: String
        public init(root: String) { self.root = root }
    }

    public struct DiscoverResponse: Codable, Sendable {
        public var found: [String]
        public var registered: [Project]
        public init(found: [String], registered: [Project]) {
            self.found = found; self.registered = registered
        }
    }

    /// Scaffold a brand new project (directory, git, optional GitHub repo,
    /// optional AI-drafted roadmap). Distinct from `RegisterProject`, which
    /// adopts a directory that already exists.
    public struct CreateProject: Codable, Sendable {
        public var name: String
        /// Defaults to `<projectsRoot>/<name>`.
        public var dir: String?
        public var description: String?
        /// "public" | "private" | nil to skip GitHub entirely.
        public var github: String?
        /// "ai" to spawn a planning run that writes docs/ROADMAP.md, else nil.
        public var roadmap: String?
        public var agent: String?
        public init(name: String, dir: String? = nil, description: String? = nil,
                    github: String? = nil, roadmap: String? = nil, agent: String? = nil) {
            self.name = name; self.dir = dir; self.description = description
            self.github = github; self.roadmap = roadmap; self.agent = agent
        }
    }

    public struct ProjectCreated: Codable, Sendable {
        public var project: Project
        public var run: Run?
        public var message: String
        public init(project: Project, run: Run? = nil, message: String) {
            self.project = project; self.run = run; self.message = message
        }
    }

    /// First-run setup: scan roots, register what's there, report what happened.
    public struct SetupRequest: Codable, Sendable {
        public var roots: [String]?
        public init(roots: [String]? = nil) { self.roots = roots }
    }

    public struct SetupResponse: Codable, Sendable {
        public var scanned: Int
        public var registered: [Project]
        public var agentsAvailable: [String]
        public var message: String
        public init(scanned: Int, registered: [Project], agentsAvailable: [String],
                    message: String) {
            self.scanned = scanned; self.registered = registered
            self.agentsAvailable = agentsAvailable; self.message = message
        }
    }

    /// Self-update from the checkout Ouroboros was built from.
    public struct UpdateResponse: Codable, Sendable {
        public var ok: Bool
        public var fromCommit: String
        public var toCommit: String
        public var message: String
        /// True when binaries changed and the daemon is about to restart.
        public var restarting: Bool
        public init(ok: Bool, fromCommit: String, toCommit: String, message: String,
                    restarting: Bool = false) {
            self.ok = ok; self.fromCommit = fromCommit; self.toCommit = toCommit
            self.message = message; self.restarting = restarting
        }
    }

    // MARK: issues

    public struct CreateIssue: Codable, Sendable {
        /// Project id/name. Omitted → resolved from `cwd`, then from the most
        /// recently used project. This is what makes `ouro i "…"` a one-liner.
        public var project: String?
        public var cwd: String?
        public var title: String?
        public var body: String
        /// Dispatch an agent immediately.
        public var fix: Bool?
        public var agent: String?
        public var worktree: Bool?
        public var finish: String?
        public var screenshotBase64: String?
        public var screenshotNotes: [String]?

        public init(project: String? = nil, cwd: String? = nil, title: String? = nil,
                    body: String, fix: Bool? = nil, agent: String? = nil,
                    worktree: Bool? = nil, finish: String? = nil,
                    screenshotBase64: String? = nil, screenshotNotes: [String]? = nil) {
            self.project = project; self.cwd = cwd; self.title = title; self.body = body
            self.fix = fix; self.agent = agent; self.worktree = worktree; self.finish = finish
            self.screenshotBase64 = screenshotBase64; self.screenshotNotes = screenshotNotes
        }
    }

    public struct IssueCreated: Codable, Sendable {
        public var issue: IssueDTO
        public var run: Run?
        public init(issue: IssueDTO, run: Run? = nil) { self.issue = issue; self.run = run }
    }

    public struct PatchIssue: Codable, Sendable {
        public var body: String?
        public var status: String?
        public init(body: String? = nil, status: String? = nil) {
            self.body = body; self.status = status
        }
    }

    public struct FixRequest: Codable, Sendable {
        public var agent: String?
        public var worktree: Bool?
        public var finish: String?
        public init(agent: String? = nil, worktree: Bool? = nil, finish: String? = nil) {
            self.agent = agent; self.worktree = worktree; self.finish = finish
        }
    }

    // MARK: runs

    public struct Freeform: Codable, Sendable {
        public var project: String?
        public var cwd: String?
        public var title: String?
        public var prompt: String
        public var agent: String?
        public var worktree: Bool?
        public var finish: String?
        public init(project: String? = nil, cwd: String? = nil, title: String? = nil,
                    prompt: String, agent: String? = nil, worktree: Bool? = nil,
                    finish: String? = nil) {
            self.project = project; self.cwd = cwd; self.title = title; self.prompt = prompt
            self.agent = agent; self.worktree = worktree; self.finish = finish
        }
    }

    public struct Reply: Codable, Sendable {
        public var answer: String
        /// Optional harness switch — "you couldn't do it, let codex try".
        public var agent: String?
        public init(answer: String, agent: String? = nil) {
            self.answer = answer; self.agent = agent
        }
    }

    public struct ShimStarted: Codable, Sendable {
        public var pid: Int32
        public init(pid: Int32) { self.pid = pid }
    }

    public struct ShimExited: Codable, Sendable {
        public var exitCode: Int32
        public init(exitCode: Int32) { self.exitCode = exitCode }
    }

    public struct TextResponse: Codable, Sendable {
        public var runId: String
        public var text: String
        public init(runId: String, text: String) { self.runId = runId; self.text = text }
    }

    // MARK: ideas & proposals

    public struct CreateIdea: Codable, Sendable {
        public var title: String?
        public var body: String
        public var project: String?
        public var source: String?
        public init(title: String? = nil, body: String, project: String? = nil,
                    source: String? = nil) {
            self.title = title; self.body = body; self.project = project; self.source = source
        }
    }

    public struct Promote: Codable, Sendable {
        public var project: String?
        public var fix: Bool?
        public init(project: String? = nil, fix: Bool? = nil) {
            self.project = project; self.fix = fix
        }
    }

    public struct CreateProposal: Codable, Sendable {
        public var project: String?
        public var title: String
        public var body: String
        public var source: String
        /// Required in spirit: without it, a screen-watcher fills the inbox with
        /// the same observation forty times. Omitted → derived from project+title.
        public var dedupeKey: String?
        public var confidence: Double?
        public var evidence: [String]?
        public init(project: String? = nil, title: String, body: String, source: String,
                    dedupeKey: String? = nil, confidence: Double? = nil,
                    evidence: [String]? = nil) {
            self.project = project; self.title = title; self.body = body; self.source = source
            self.dedupeKey = dedupeKey; self.confidence = confidence; self.evidence = evidence
        }
    }

    public struct ProposalCreated: Codable, Sendable {
        public var proposal: Proposal
        /// false when an identical pending proposal already existed.
        public var created: Bool
        public init(proposal: Proposal, created: Bool) {
            self.proposal = proposal; self.created = created
        }
    }

    // MARK: misc

    public struct Message: Codable, Sendable {
        public var ok: Bool
        public var message: String
        public init(ok: Bool = true, message: String) { self.ok = ok; self.message = message }
    }

    public struct ProjectList: Codable, Sendable {
        public var projects: [Project]
        public init(projects: [Project]) { self.projects = projects }
    }

    public struct IssueList: Codable, Sendable {
        public var issues: [IssueDTO]
        public init(issues: [IssueDTO]) { self.issues = issues }
    }

    public struct RunList: Codable, Sendable {
        public var runs: [Run]
        public init(runs: [Run]) { self.runs = runs }
    }

    public struct InboxList: Codable, Sendable {
        public var items: [InboxItem]
        public init(items: [InboxItem]) { self.items = items }
    }

    public struct IdeaList: Codable, Sendable {
        public var ideas: [Idea]
        public init(ideas: [Idea]) { self.ideas = ideas }
    }

    public struct ProposalList: Codable, Sendable {
        public var proposals: [Proposal]
        public init(proposals: [Proposal]) { self.proposals = proposals }
    }

    /// The one number the capture panel puts on its footer: how much work
    /// Ouroboros has actually done, and how much is in the air right now.
    ///
    /// Counted from the runs still on disk, which `RunStore.prune` trims after
    /// a month — an honest "lately", not a lifetime tally.
    public struct Stats: Codable, Sendable, Equatable {
        public var handled: Int
        public var fixed: Int
        public var failed: Int
        public var running: Int
        /// Issues filed and never dispatched, across the projects on show.
        public var tasks: Int
        public var projects: Int
        /// The last dozen runs' statuses, oldest first — a tape you can read
        /// at a glance without reading a single word.
        public var tape: [RunStatus]

        public init(handled: Int = 0, fixed: Int = 0, failed: Int = 0, running: Int = 0,
                    tasks: Int = 0, projects: Int = 0, tape: [RunStatus] = []) {
            self.handled = handled; self.fixed = fixed; self.failed = failed
            self.running = running; self.tasks = tasks; self.projects = projects
            self.tape = tape
        }
    }

    /// One call the menu-bar app makes on every open: everything the panel needs.
    public struct Snapshot: Codable, Sendable {
        public var health: HealthDTO
        public var projects: [Project]
        public var inbox: [InboxItem]
        public var activeRuns: [Run]
        public var recentRuns: [Run]
        /// The projects worth offering you, richest first: the ones you have
        /// pointed Ouroboros at, then the ones you have been committing to.
        public var recents: [ProjectDigest]
        public var stats: Stats
        /// The harnesses this machine can dispatch to, so the panel can offer a
        /// choice without probing PATH from inside the app.
        public var agents: [AgentInfo]

        public init(health: HealthDTO, projects: [Project], inbox: [InboxItem],
                    activeRuns: [Run], recentRuns: [Run],
                    recents: [ProjectDigest] = [], stats: Stats = Stats(),
                    agents: [AgentInfo] = []) {
            self.health = health; self.projects = projects; self.inbox = inbox
            self.activeRuns = activeRuns; self.recentRuns = recentRuns
            self.recents = recents; self.stats = stats; self.agents = agents
        }

        // A daemon that has not been restarted since the app was updated is a
        // normal state on a machine where both are built from the same
        // checkout. Decoding what it does send, rather than failing the whole
        // snapshot on a missing key, keeps that mismatch to an empty drawer
        // instead of a panel that says it cannot see the daemon at all.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            health = try c.decode(HealthDTO.self, forKey: .health)
            projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
            inbox = try c.decodeIfPresent([InboxItem].self, forKey: .inbox) ?? []
            activeRuns = try c.decodeIfPresent([Run].self, forKey: .activeRuns) ?? []
            recentRuns = try c.decodeIfPresent([Run].self, forKey: .recentRuns) ?? []
            recents = try c.decodeIfPresent([ProjectDigest].self, forKey: .recents) ?? []
            stats = try c.decodeIfPresent(Stats.self, forKey: .stats) ?? Stats()
            agents = try c.decodeIfPresent([AgentInfo].self, forKey: .agents) ?? []
        }
    }
}
