import Foundation
import ZeroCore
import Ouroboros

/// `ourod` — the only writer of run state, the only thing that spawns agents,
/// and the single implementation behind every face. The CLI and the menu-bar
/// app are HTTP clients of this file and have no other powers.
final class Daemon: @unchecked Sendable {
    let config: Config
    let registry: Registry
    let runs: RunStore
    let issues: IssueService
    let ideas: IdeaStore
    let proposals: ProposalStore
    let events = EventBus()
    let notifier: Notifier
    let supervisor: Supervisor
    let digests = Digests()
    let startedAt = Date()

    private var server: HTTPServer?
    private var timer: DispatchSourceTimer?

    init() {
        Paths.ensure()
        let config = Config.load()
        self.config = config
        self.registry = Registry()
        self.runs = RunStore()
        self.issues = IssueService(registry: registry)
        self.ideas = IdeaStore()
        self.proposals = ProposalStore()
        self.notifier = Notifier(config: config)
        self.supervisor = Supervisor(
            config: config, registry: registry, runs: runs, issues: issues,
            events: events, notifier: notifier, ouroPath: Daemon.locateOuro(), home: Paths.home)
    }

    /// The shim is `ouro run-shim`, spawned from a terminal that may not have
    /// the user's PATH. Prefer the sibling of this binary.
    static func locateOuro() -> String {
        let argv0 = CommandLine.arguments.first ?? "ourod"
        let resolved = (argv0 as NSString).isAbsolutePath
            ? argv0
            : FileManager.default.currentDirectoryPath + "/" + argv0
        let sibling = ((resolved as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("ouro")
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        return Shell.which("ouro") ?? "ouro"
    }

    // MARK: - lifecycle

    func start() throws {
        writePidFile()
        let server = HTTPServer(token: nil) { [weak self] request in
            guard let self else { return .error("daemon shutting down", status: 500) }
            return self.route(request)
        }
        try server.listenUnix(path: Paths.socket)
        if let port = config.httpPort {
            // Loopback listener is token-gated in the client; the socket is the
            // trusted local path.
            try? server.listenLoopback(port: port)
        }
        server.start()
        self.server = server

        supervisor.reconcile()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "zero.tick"))
        timer.schedule(deadline: .now() + 2, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.supervisor.sweep()
            self?.events.heartbeat()
        }
        timer.resume()
        self.timer = timer

        log("ouroboros zero \(ZeroVersion.current) listening on \(Paths.socket)")
        log("projects: \(registry.all().count)  runs: \(runs.all().count)")
    }

    func stop() {
        server?.stop()
        timer?.cancel()
        try? FileManager.default.removeItem(atPath: Paths.pidFile)
        unlink(Paths.socket)
    }

    private func writePidFile() {
        let pid = ProcessInfo.processInfo.processIdentifier
        try? String(pid).write(toFile: Paths.pidFile, atomically: true, encoding: .utf8)
    }

    func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    // MARK: - resolution helpers

    /// Project resolution, in order: explicit name → the repo containing `cwd`
    /// → most recently used. An unregistered git repo under `cwd` registers
    /// itself, so `ouro i` works the first time you use it in a new project.
    func resolveProject(_ name: String?, cwd: String?) -> Project? {
        if let name, !name.isEmpty {
            return registry.find(name)
        }
        if let cwd, !cwd.isEmpty {
            if let existing = registry.containing(cwd) { return existing }
            if let root = Git.repoRoot(containing: cwd) {
                return registry.register(path: root)
            }
        }
        return registry.all().first
    }

    func finish(_ raw: String?) -> Finish? {
        guard let raw else { return nil }
        return Finish(rawValue: raw)
    }

    // MARK: - router

    func route(_ request: HTTPRequest) -> HTTPResponse {
        let segments = request.path.split(separator: "/").map(String.init)
        guard segments.first == "v1" else {
            return .error("unknown API root — everything lives under /v1", status: 404)
        }
        let path = Array(segments.dropFirst())
        let method = request.method

        switch (method, path.first) {
        case ("GET", "health"):    return .json(health())
        case ("GET", "snapshot"):  return .json(snapshot())
        case ("GET", "events"):    return eventStream()
        case ("GET", "config"):    return .json(config)
        case ("GET", "agents"):
            return .json(API.AgentList(agents: agentList(), defaultAgent: config.defaultAgent))
        case ("POST", "setup"):    return setup(request)
        case ("POST", "update"):   return selfUpdate()
        case ("POST", "shutdown"):
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { self.stop(); exit(0) }
            return .json(API.Message(message: "shutting down"))

        case (_, "projects"):  return routeProjects(method, path, request)
        case (_, "issues"):    return routeIssues(method, path, request)
        case (_, "runs"):      return routeRuns(method, path, request)
        case (_, "ideas"):     return routeIdeas(method, path, request)
        case (_, "proposals"): return routeProposals(method, path, request)
        case ("GET", "inbox"): return .json(API.InboxList(items: inbox()))

        default:
            return .error("no route for \(method) \(request.path)", status: 404)
        }
    }

    // MARK: projects

    private func routeProjects(_ method: String, _ path: [String],
                               _ request: HTTPRequest) -> HTTPResponse {
        switch (method, path.count) {
        case ("GET", 1):
            return .json(API.ProjectList(projects: registry.all()))

        case ("POST", 1):
            guard let body = request.decode(API.RegisterProject.self) else {
                return .error("expected {\"path\": \"...\"}")
            }
            var policy = Policy()
            if let autonomy = body.autonomy, let parsed = Autonomy(rawValue: autonomy) {
                policy.autonomy = parsed
            }
            guard var project = registry.register(path: body.path, name: body.name, policy: policy)
            else { return .error("not a directory: \(body.path)") }
            if let verifyCmd = body.verifyCmd {
                project.verifyCmd = verifyCmd
                registry.upsert(project)
            }
            return .json(project, status: 201)

        case ("POST", 2) where path[1] == "discover":
            guard let body = request.decode(API.DiscoverRequest.self) else {
                return .error("expected {\"root\": \"...\"}")
            }
            let found = Registry.discover(in: (body.root as NSString).expandingTildeInPath)
            let registered = found.compactMap { registry.register(path: $0) }
            return .json(API.DiscoverResponse(found: found, registered: registered))

        case ("POST", 2) where path[1] == "create":
            guard let body = request.decode(API.CreateProject.self),
                  !body.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error("expected {\"name\": \"...\"}")
            }
            return createProject(body)

        case ("GET", 2):
            guard let project = registry.find(path[1]) else { return .error("no such project", status: 404) }
            return .json(project)

        case ("PATCH", 2):
            guard var project = registry.find(path[1]) else { return .error("no such project", status: 404) }
            guard let body = request.decode(API.PatchProject.self) else { return .error("bad body") }
            if let v = body.name { project.name = v }
            if let v = body.baseBranch { project.baseBranch = v.isEmpty ? nil : v }
            if let v = body.verifyCmd { project.verifyCmd = v.isEmpty ? nil : v }
            if let v = body.defaultAgent { project.defaultAgent = v.isEmpty ? nil : v }
            if let v = body.autonomy, let parsed = Autonomy(rawValue: v) { project.policy.autonomy = parsed }
            if let v = body.maxParallel { project.policy.maxParallel = max(1, v) }
            if let v = body.worktreeDefault { project.policy.worktreeDefault = v }
            if let v = body.finishDefault, let parsed = Finish(rawValue: v) { project.policy.finishDefault = parsed }
            if let v = body.protectedPaths { project.policy.protectedPaths = v }
            if let v = body.favourite {
                project.favourite = v
                // Pinning something you had hidden is a change of mind, and
                // leaving it hidden would make the pin do nothing.
                if v { project.hidden = false }
            }
            if let v = body.hidden { project.hidden = v }
            registry.upsert(project)
            return .json(project)

        case ("DELETE", 2):
            guard let project = registry.find(path[1]) else { return .error("no such project", status: 404) }
            registry.remove(project.id)
            return .json(API.Message(message: "removed \(project.name) (the directory is untouched)"))

        case ("GET", 3) where path[2] == "issues":
            guard let project = registry.find(path[1]) else { return .error("no such project", status: 404) }
            return .json(API.IssueList(issues: issues.list(project: project)))

        default:
            return .error("no route", status: 404)
        }
    }

    /// Scaffold a project that does not exist yet — directory, README, git,
    /// optionally a GitHub repo and an AI-drafted roadmap. `POST /v1/projects`
    /// adopts a directory; this one brings it into being, so the menu-bar app
    /// gets `ouro new` without reimplementing any of it.
    private func createProject(_ body: API.CreateProject) -> HTTPResponse {
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = Registry.normalize(
            body.dir ?? (config.projectsRoot as NSString).appendingPathComponent(name))
        let fm = FileManager.default

        guard !fm.fileExists(atPath: dir) else {
            return .error("\(dir) already exists — adopt it with POST /v1/projects instead",
                          status: 409)
        }
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return .error("could not create \(dir): \(error)")
        }

        let description = body.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let readme = "# \(name)\n\n\(description.isEmpty ? "TODO: describe this project." : description)\n"
        try? readme.write(toFile: (dir as NSString).appendingPathComponent("README.md"),
                          atomically: true, encoding: .utf8)
        try? ".ouroboros/\n.DS_Store\n".write(
            toFile: (dir as NSString).appendingPathComponent(".gitignore"),
            atomically: true, encoding: .utf8)

        let git = Git(dir)
        git.run(["init", "-b", "main"])
        git.run(["add", "-A"])
        git.run(["commit", "-m", "initial commit"])

        var said = ["created \(name) at \(dir)"]

        if let visibility = body.github, visibility == "public" || visibility == "private" {
            // A missing or unauthenticated `gh` must not cost you the project you
            // just scaffolded: the directory and its history are already real, and
            // `gh repo create --source .` works just as well tomorrow.
            let created = Shell.run(["gh", "repo", "create", name, "--\(visibility)",
                                     "--source", ".", "--push"],
                                    cwd: dir, login: true, timeout: 120)
            said.append(created.ok
                ? "pushed to a \(visibility) github repo"
                : "github skipped — gh repo create failed: \(Daemon.oneLine(created.trimmed))")
        }

        guard let project = registry.register(path: dir, name: name) else {
            return .error("created \(dir) but could not register it", status: 500)
        }
        said.append("registered as \(project.id)")

        var run: Run?
        if body.roadmap == "ai" {
            let planning = supervisor.dispatchFreeform(
                project: project, title: "draft the roadmap",
                prompt: Daemon.roadmapPrompt(name: name, description: description),
                options: .init(agent: body.agent, worktree: false, finish: .leave))
            run = planning
            said.append("drafting the roadmap with \(planning.agent) (\(planning.id))")
        }

        let message = said.joined(separator: ", ")
        log("new project: \(message)")
        return .json(API.ProjectCreated(project: project, run: run, message: message), status: 201)
    }

    /// The brief `ouro new --roadmap ai` sends. The schema is not decoration —
    /// an autonomous loop reads these task blocks back out of the file.
    static func roadmapPrompt(name: String, description: String) -> String {
        """
        Draft the development roadmap for a new project called "\(name)".

        \(description.isEmpty ? "" : "What it is: \(description)\n")
        Write it to docs/ROADMAP.md using this exact schema, which an autonomous loop reads:

        ## Phase 1 — <title>

        **Goal:** <one paragraph>

        ### Tasks

        - id: P1.T01
          title: "<concrete task — what gets built>"
          status: queued
          notes: "<hints, decisions, gotchas for the next cycle>"

        Rules:
        · Phase 1 is always repository layout and skeleton for the chosen stack.
        · Decompose only the first 3-4 phases into tasks of <= 30 minutes each.
        · List every later phase as a one-line stub under a final
          "## Decomposition queue" heading — they get expanded when their turn comes,
          against the code as it actually is then.
        · Pick the stack yourself from the description and say why in Phase 1's goal.

        Commit the roadmap. Do not write any application code in this run.
        """
    }

    // MARK: issues

    private func routeIssues(_ method: String, _ path: [String],
                             _ request: HTTPRequest) -> HTTPResponse {
        switch (method, path.count) {
        case ("GET", 1):
            if let projectName = request.q("project") {
                guard let project = registry.find(projectName) else {
                    return .error("no such project", status: 404)
                }
                var list = issues.list(project: project)
                if let status = request.q("status") { list = list.filter { $0.status == status } }
                return .json(API.IssueList(issues: list))
            }
            return .json(API.IssueList(issues: issues.listAll(status: request.q("status"))))

        case ("POST", 1):
            guard let body = request.decode(API.CreateIssue.self),
                  !body.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error("expected {\"body\": \"...\"}")
            }
            guard let project = resolveProject(body.project, cwd: body.cwd) else {
                return .error("no project — register one with `ouro projects add <path>`")
            }
            var screenshot: IssueScreenshot?
            if let encoded = body.screenshotBase64, let data = Data(base64Encoded: encoded) {
                screenshot = IssueScreenshot(pngData: data,
                                             textNotes: body.screenshotNotes ?? [],
                                             hasPenMarks: false)
            }
            guard let dto = issues.create(project: project, title: body.title ?? "",
                                          body: body.body, screenshot: screenshot) else {
                return .error("could not write the issue file into \(project.path)")
            }
            events.publish(ZeroEvent(type: "issue.created", projectId: project.id, message: dto.title))

            var run: Run?
            if body.fix == true, let (_, issue) = issues.find(dto.id) {
                run = supervisor.dispatchFix(project: project, issue: issue, options: .init(
                    agent: body.agent, worktree: body.worktree, finish: finish(body.finish)))
            }
            return .json(API.IssueCreated(issue: dto, run: run), status: 201)

        case ("GET", 2):
            guard let (project, issue) = issues.find(path[1]) else {
                return .error("no such issue", status: 404)
            }
            return .json(IssueService.dto(issue, project: project))

        case ("PATCH", 2):
            guard let (project, issue) = issues.find(path[1]) else {
                return .error("no such issue", status: 404)
            }
            guard let body = request.decode(API.PatchIssue.self) else { return .error("bad body") }
            var current = issue
            if let text = body.body, !text.isEmpty {
                if let updated = issues.updateBody(project: project, issue: current, body: text),
                   let reread = IssueService.store(for: project).read(path: updated.path) {
                    current = reread
                }
            }
            if let statusRaw = body.status, let status = IssueStatus(rawValue: statusRaw) {
                if let moved = issues.setStatus(project: project, issue: current, status: status),
                   let reread = IssueService.store(for: project).read(path: moved.path) {
                    current = reread
                }
            }
            return .json(IssueService.dto(current, project: project))

        case ("POST", 3) where path[2] == "fix":
            guard let (project, issue) = issues.find(path[1]) else {
                return .error("no such issue", status: 404)
            }
            let body = request.decode(API.FixRequest.self) ?? API.FixRequest()
            let run = supervisor.dispatchFix(project: project, issue: issue, options: .init(
                agent: body.agent, worktree: body.worktree, finish: finish(body.finish)))
            return .json(run, status: 201)

        case ("DELETE", 2):
            guard let (project, issue) = issues.find(path[1]) else {
                return .error("no such issue", status: 404)
            }
            // Cancelled, not erased: the trail from "half a thought at midnight"
            // to "never mind" is worth as much as the one that ends in a fix.
            // `?purge=1` is the one that really deletes the file.
            if request.q("purge") == "1" {
                guard let file = issue.path else { return .error("issue has no file") }
                try? FileManager.default.removeItem(atPath: file)
                return .json(API.Message(message: "deleted \(issue.title)"))
            }
            guard let moved = issues.setStatus(project: project, issue: issue, status: .cancelled)
            else { return .error("could not cancel that issue") }
            return .json(moved)

        default:
            return .error("no route", status: 404)
        }
    }

    // MARK: runs

    private func routeRuns(_ method: String, _ path: [String],
                           _ request: HTTPRequest) -> HTTPResponse {
        switch (method, path.count) {
        case ("GET", 1):
            var list = runs.all()
            if let status = request.q("status") {
                if status == "active" { list = list.filter { $0.status.isActive } }
                else { list = list.filter { $0.status.rawValue == status } }
            }
            if let projectName = request.q("project"), let project = registry.find(projectName) {
                list = list.filter { $0.projectId == project.id }
            }
            if let limit = request.q("limit").flatMap(Int.init) { list = Array(list.prefix(limit)) }
            return .json(API.RunList(runs: list))

        case ("POST", 1):
            guard let body = request.decode(API.Freeform.self),
                  !body.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error("expected {\"prompt\": \"...\"}")
            }
            guard let project = resolveProject(body.project, cwd: body.cwd) else {
                return .error("no project")
            }
            let title = body.title ?? IssueText.suggestTitle(body.prompt)
            let run = supervisor.dispatchFreeform(
                project: project, title: title.isEmpty ? "freeform run" : title,
                prompt: body.prompt,
                options: .init(agent: body.agent, worktree: body.worktree,
                               finish: finish(body.finish)))
            return .json(run, status: 201)

        case ("GET", 2):
            guard let run = runs.get(path[1]) else { return .error("no such run", status: 404) }
            return .json(run)

        case ("GET", 3) where path[2] == "log":
            guard let run = runs.get(path[1]) else { return .error("no such run", status: 404) }
            let lines = request.q("lines").flatMap(Int.init) ?? 80
            return .json(API.TextResponse(runId: run.id, text: runs.tailLog(run.id, lines: lines)))

        case ("GET", 3) where path[2] == "diff":
            guard let run = runs.get(path[1]) else { return .error("no such run", status: 404) }
            return .json(API.TextResponse(runId: run.id, text: supervisor.diff(run.id)))

        case ("GET", 3) where path[2] == "prompt":
            guard let run = runs.get(path[1]) else { return .error("no such run", status: 404) }
            let text = (try? String(contentsOfFile: runs.promptPath(run.id), encoding: .utf8)) ?? ""
            return .json(API.TextResponse(runId: run.id, text: text))

        case ("POST", 3):
            guard let run = runs.get(path[1]) else { return .error("no such run", status: 404) }
            switch path[2] {
            case "stop":
                guard let stopped = supervisor.stop(run.id) else { return .error("could not stop") }
                return .json(stopped)
            case "ack":
                supervisor.acknowledge(run.id)
                return .json(API.Message(message: "acknowledged"))
            case "merge":
                guard let merged = supervisor.mergeNow(run.id) else { return .error("could not merge") }
                return .json(merged)
            case "undo":
                let (updated, message) = supervisor.undo(run.id)
                guard let updated else { return .error(message) }
                return .json(API.Message(ok: updated.mergeCommit == nil, message: message))
            case "reply":
                guard let body = request.decode(API.Reply.self), !body.answer.isEmpty else {
                    return .error("expected {\"answer\": \"...\"}")
                }
                guard let next = supervisor.reply(to: run.id, answer: body.answer,
                                                  agent: body.agent) else {
                    return .error("that run is not waiting on a question")
                }
                return .json(next, status: 201)
            case "retry":
                guard let project = registry.find(run.projectId) else { return .error("no project") }
                if let issuePath = run.issuePath,
                   let issue = IssueService.store(for: project).read(path: issuePath) {
                    supervisor.acknowledge(run.id)
                    return .json(supervisor.dispatchFix(project: project, issue: issue,
                                                        options: .init(agent: run.agent)), status: 201)
                }
                supervisor.acknowledge(run.id)
                return .json(supervisor.dispatchFreeform(project: project, title: run.title,
                                                         prompt: run.prompt ?? run.title,
                                                         options: .init(agent: run.agent)), status: 201)
            case "resume":
                // Reopen the agent's own conversation in a terminal. Refused
                // rather than faked when there is nothing to reopen: a window
                // that opens onto an error is worse than a menu item that
                // never appeared.
                guard let (argv, cwd) = supervisor.resumeInvocation(run.id) else {
                    let harness = Harness.of(agent: run.agent,
                                             template: config.agentTemplate(run.agent))
                    return .error(run.sessionId == nil
                        ? "this run has no recorded conversation — it predates session capture"
                        : "\(run.agent): \(harness.resumeHint)")
                }
                supervisor.resume(run.id)
                return .json(API.Resumed(runId: run.id,
                                         command: argv.joined(separator: " "), cwd: cwd))
            default:
                return .error("no route", status: 404)
            }

        case ("POST", 4) where path[2] == "shim":
            // Internal: the shim reporting from inside the terminal.
            guard runs.get(path[1]) != nil else { return .error("no such run", status: 404) }
            if path[3] == "started", let body = request.decode(API.ShimStarted.self) {
                supervisor.shimStarted(path[1], pid: body.pid)
                return .json(API.Message(message: "ok"))
            }
            if path[3] == "exited", let body = request.decode(API.ShimExited.self) {
                supervisor.shimExited(path[1], exitCode: body.exitCode)
                return .json(API.Message(message: "ok"))
            }
            return .error("bad shim report")

        default:
            return .error("no route", status: 404)
        }
    }

    // MARK: ideas

    private func routeIdeas(_ method: String, _ path: [String],
                            _ request: HTTPRequest) -> HTTPResponse {
        switch (method, path.count) {
        case ("GET", 1):
            let includeDone = request.flag("all") ?? false
            return .json(API.IdeaList(ideas: ideas.list(includeDone: includeDone)))

        case ("POST", 1):
            guard let body = request.decode(API.CreateIdea.self),
                  !body.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error("expected {\"body\": \"...\"}")
            }
            let projectId = body.project.flatMap { registry.find($0)?.id }
            guard let idea = ideas.create(title: body.title, body: body.body,
                                          projectId: projectId,
                                          source: body.source ?? "human") else {
                return .error("could not write the idea")
            }
            notifier.notify(InboxItem(
                id: idea.id, kind: .proposal, projectName: projectId ?? "ideas",
                title: idea.title, detail: String(idea.body.prefix(400)),
                createdAt: idea.created))
            events.publish(ZeroEvent(type: "idea.created", message: idea.title))
            return .json(idea, status: 201)

        case ("POST", 3) where path[2] == "promote":
            guard let (idea, issue) = ideas.find(path[1]) else {
                return .error("no such idea", status: 404)
            }
            let body = request.decode(API.Promote.self) ?? API.Promote()
            guard let project = resolveProject(body.project ?? idea.projectId, cwd: nil) else {
                return .error("say which project: --project <name>")
            }
            guard let dto = issues.create(project: project, title: idea.title, body: idea.body) else {
                return .error("could not write the issue")
            }
            ideas.retire(issue)
            var run: Run?
            if body.fix == true, let (_, created) = issues.find(dto.id) {
                run = supervisor.dispatchFix(project: project, issue: created)
            }
            return .json(API.IssueCreated(issue: dto, run: run), status: 201)

        case ("POST", 3) where path[2] == "drop":
            guard let (_, issue) = ideas.find(path[1]) else {
                return .error("no such idea", status: 404)
            }
            ideas.drop(issue)
            return .json(API.Message(message: "dropped"))

        default:
            return .error("no route", status: 404)
        }
    }

    // MARK: proposals

    private func routeProposals(_ method: String, _ path: [String],
                                _ request: HTTPRequest) -> HTTPResponse {
        switch (method, path.count) {
        case ("GET", 1):
            let all = request.flag("all") ?? false
            return .json(API.ProposalList(proposals: all ? proposals.all() : proposals.pending()))

        case ("POST", 1):
            guard let body = request.decode(API.CreateProposal.self), !body.title.isEmpty else {
                return .error("expected {\"title\": …, \"body\": …, \"source\": …}")
            }
            let projectId = body.project.flatMap { registry.find($0)?.id }
            let key = body.dedupeKey ?? "\(projectId ?? "-"):\(body.title.lowercased())"
            let proposal = Proposal(
                id: Zero.newID("p"), projectId: projectId, title: body.title, body: body.body,
                source: body.source, confidence: body.confidence, dedupeKey: key,
                evidence: body.evidence ?? [])
            let (stored, created) = proposals.upsert(proposal)
            if created {
                events.publish(ZeroEvent(type: "proposal.created", projectId: projectId,
                                         message: stored.title))
                notifier.notify(InboxItem(
                    id: stored.id, kind: .proposal, projectName: projectId ?? "unassigned",
                    title: stored.title, detail: "\(stored.source): \(stored.body.prefix(300))",
                    createdAt: stored.createdAt))
            }
            return .json(API.ProposalCreated(proposal: stored, created: created),
                         status: created ? 201 : 200)

        case ("POST", 3) where path[2] == "accept":
            guard let proposal = proposals.get(path[1]) else {
                return .error("no such proposal", status: 404)
            }
            guard let projectId = proposal.projectId, let project = registry.find(projectId) else {
                return .error("this proposal has no project — promote it with a project instead")
            }
            guard let dto = issues.create(project: project, title: proposal.title,
                                          body: proposal.body + "\n\n_Proposed by \(proposal.source)._") else {
                return .error("could not write the issue")
            }
            proposals.setState(proposal.id, .accepted)
            var run: Run?
            if let (_, issue) = issues.find(dto.id) {
                run = supervisor.dispatchFix(project: project, issue: issue)
            }
            return .json(API.IssueCreated(issue: dto, run: run), status: 201)

        case ("POST", 3) where path[2] == "dismiss":
            guard proposals.setState(path[1], .dismissed) != nil else {
                return .error("no such proposal", status: 404)
            }
            return .json(API.Message(message: "dismissed"))

        default:
            return .error("no route", status: 404)
        }
    }

    // MARK: setup & self-update

    /// First run, in one call: scan the roots, adopt every repo under them, and
    /// say which harnesses are actually installed — the two things that decide
    /// whether the next command the user types works.
    private func setup(_ request: HTTPRequest) -> HTTPResponse {
        let body = request.decode(API.SetupRequest.self) ?? API.SetupRequest()
        var roots = body.roots ?? config.autoDiscoverRoots
        if roots.isEmpty { roots = [config.projectsRoot] }

        var scanned = 0
        var registered: [Project] = []
        var seen = Set<String>()
        for root in roots {
            let found = Registry.discover(in: Registry.normalize(root))
            scanned += found.count
            for repo in found where seen.insert(Registry.normalize(repo)).inserted {
                // Count only what this call added. `register` happily returns an
                // already-adopted project, and reporting those as new makes the
                // number lie every time setup is run twice.
                guard registry.byPath(repo) == nil else { continue }
                if let project = registry.register(path: repo) { registered.append(project) }
            }
        }

        let agents = config.availableAgents()
        let rootList = roots.map { Daemon.tildeify(Registry.normalize($0)) }.joined(separator: ", ")
        let message = "scanned \(scanned) repos under \(rootList), registered \(registered.count); "
            + (agents.isEmpty
               ? "no agent CLI on PATH — install claude or codex"
               : "agents: \(agents.joined(separator: ", "))")
        log(message)
        return .json(API.SetupResponse(scanned: scanned, registered: registered,
                                       agentsAvailable: agents, message: message))
    }

    /// Pull the checkout Zero was built from and reinstall it.
    ///
    /// `make install` does the replacement, and it must: it removes each binary
    /// before copying the new one. Overwriting a running, code-signed Mach-O in
    /// place invalidates the signature and macOS SIGKILLs the next exec — which
    /// surfaces as agents that launch and vanish with an empty log, nothing that
    /// looks remotely like a signing problem. Never reimplement that copy here.
    private func selfUpdate() -> HTTPResponse {
        func no(_ message: String, from: String = "", to: String = "") -> HTTPResponse {
            .json(API.UpdateResponse(ok: false, fromCommit: from, toCommit: to, message: message))
        }
        guard let repo = updateRepo() else {
            return no("no checkout to update from — set \"repoPath\" in ~/.ouroboros/config.json "
                      + "to your ouroboros clone, or register it as a project named 'ouroboros'")
        }
        let git = Git(repo)
        guard git.isRepo else { return no("\(repo) is not a git checkout — fix \"repoPath\"") }

        let from = git.run(["rev-parse", "--short", "HEAD"], timeout: 15).trimmed
        let pull = git.run(["pull", "--ff-only"], timeout: 300)
        guard pull.ok else {
            // Dirty tree, diverged history, no network. Building an unknown state
            // is worse than not updating, so stop here with git's own words.
            return no("git pull --ff-only failed in \(repo):\n\(pull.trimmed.suffix(800))",
                      from: from, to: from)
        }
        let to = git.run(["rev-parse", "--short", "HEAD"], timeout: 15).trimmed
        guard to != from else {
            return .json(API.UpdateResponse(ok: true, fromCommit: from, toCommit: to,
                                            message: "already up to date at \(from)"))
        }

        let build = Shell.runLine("make install", cwd: Daemon.packageDir(repo), timeout: 600)
        guard build.ok else {
            return no("pulled \(from) → \(to), but `make install` failed:\n"
                      + "\(build.trimmed.suffix(1500))", from: from, to: to)
        }

        log("updated \(from) → \(to) — exiting so the launcher starts the new binary")
        // Exit only after the response is on the wire: the caller has to learn it
        // is coming back before the socket dies with the process.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { self.stop(); exit(0) }
        return .json(API.UpdateResponse(ok: true, fromCommit: from, toCommit: to,
                                        message: "updated \(from) → \(to), restarting",
                                        restarting: true))
    }

    private func updateRepo() -> String? {
        if let configured = config.repoPath, !configured.isEmpty {
            return Registry.normalize(configured)
        }
        let project = registry.all().first {
            $0.name.lowercased() == "ouroboros" || $0.id.lowercased() == "ouroboros"
        }
        return project.map { Registry.normalize($0.path) }
    }

    /// The SPM package lives in `<repo>/zero`, but `repoPath` may already point
    /// at the package itself — both are things a person would reasonably set.
    static func packageDir(_ repo: String) -> String {
        let nested = (repo as NSString).appendingPathComponent("zero")
        let makefile = (nested as NSString).appendingPathComponent("Makefile")
        return FileManager.default.fileExists(atPath: makefile) ? nested : repo
    }

    /// `~/dev` reads better than `/Users/you/dev` in a one-line summary.
    static func tildeify(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    /// git and gh answer in paragraphs; a `message` is one line.
    static func oneLine(_ text: String, limit: Int = 160) -> String {
        let flat = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(flat.prefix(limit))
    }

    // MARK: composed reads

    func inbox() -> [InboxItem] {
        Inbox.build(runs: runs.all(), proposals: proposals.all())
    }

    func health() -> HealthDTO {
        HealthDTO(ok: true, version: ZeroVersion.current,
                  pid: ProcessInfo.processInfo.processIdentifier,
                  uptime: Date().timeIntervalSince(startedAt),
                  projects: registry.all().count,
                  activeRuns: runs.active().filter { $0.status != .queued }.count,
                  queuedRuns: runs.queued().count,
                  inbox: inbox().count)
    }

    func snapshot() -> API.Snapshot {
        let all = runs.all()
        let recents = recentProjects().map { project in
            digests.digest(project, runs: all, defaultAgent: config.defaultAgent) { run in
                Harness.of(agent: run.agent,
                           template: self.config.agentTemplate(run.agent)).canResume
            }
        }
        return API.Snapshot(
            health: health(),
            projects: registry.all(),
            inbox: inbox(),
            activeRuns: all.filter { $0.status.isActive },
            recentRuns: Array(all.filter { $0.status.isTerminal }.prefix(12)),
            recents: recents,
            stats: API.Stats(
                handled: all.count,
                fixed: all.filter { $0.status == .succeeded }.count,
                failed: all.filter { $0.status == .failed }.count,
                running: all.filter { $0.status.isActive && $0.status != .queued }.count,
                tasks: recents.reduce(0) { $0 + $1.openCount },
                projects: registry.all().count,
                // Oldest first: a tape is read left to right, and the newest
                // run belongs at the end where the eye lands.
                tape: Array(all.prefix(12)).reversed().map(\.status)),
            agents: agentList())
    }

    /// Three kinds of recent, in one ordered list, each project appearing once
    /// in the highest section that claims it:
    ///
    ///   favourites — pinned by hand, shown however cold they are
    ///   ouroboros  — you have filed or run something here
    ///   git        — you have only committed here; Ouroboros has never been used
    ///
    /// Hidden projects are dropped until `Registry.touch` clears the flag, and
    /// so are directories that no longer exist: a recents list is a set of
    /// offers, and offering something that isn't there is a bug.
    private func recentProjects() -> [Project] {
        let fm = FileManager.default
        func live(_ projects: [Project]) -> [Project] {
            projects.filter { !$0.hidden && fm.fileExists(atPath: $0.path) }
        }
        let favourites = live(registry.all().filter(\.favourite))
        let taken = Set(favourites.map(\.id))
        let used = live(registry.recentlyUsed(limit: 8))
            .filter { !taken.contains($0.id) }
            .prefix(4)
        let byGit = live(registry.recentlyTouchedByGit(
                limit: 8, excluding: taken.union(used.map(\.id))))
            .prefix(3)
        return favourites + Array(used) + Array(byGit)
    }

    /// The harnesses that could actually be dispatched to right now. Anything
    /// whose CLI is missing is reported unavailable rather than hidden, so
    /// "there is no codex here" is a visible fact instead of a silent absence.
    func agentList() -> [AgentInfo] {
        let names = Set(config.agents.keys).union(Config.defaultAgents.keys).sorted()
        return names.map { name in
            let template = config.agentTemplate(name)
            let harness = Harness.of(agent: name, template: template)
            return AgentInfo(
                name: name,
                available: (template?.first).flatMap { Shell.which($0) } != nil,
                isDefault: name == config.defaultAgent,
                canResume: harness.canResume)
        }
    }

    private func eventStream() -> HTTPResponse {
        HTTPResponse(stream: { [weak self] connection in
            self?.events.subscribe(connection)
        })
    }
}
