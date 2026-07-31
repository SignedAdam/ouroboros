import Foundation
import Ouroboros

/// Turns "fix this" into a supervised, reversible, verified piece of work.
///
/// The lifecycle, and who owns each step:
///
///   queued      Zero  — waiting for a scheduler slot
///   running     agent — live in its own terminal, in its own worktree
///   verifying   Zero  — the project's verify command, on the agent's branch
///   finishing   Zero  — merge / PR / leave
///   succeeded | failed | awaiting | abandoned
///
/// The agent never merges and never resolves its own issue. That's the whole
/// point: the branch is evidence, the gate is the judge, and every landed fix
/// is one `git revert` from never having happened.
public final class Supervisor: @unchecked Sendable {
    public let config: Config
    public let registry: Registry
    public let runs: RunStore
    public let issues: IssueService
    public let events: EventBus
    public let notifier: Notifier
    /// Absolute path to the `ouro` binary — the shim is `ouro run-shim`, and a
    /// GUI-launched daemon can't rely on PATH to find it.
    public let ouroPath: String
    public let home: String

    private let work = DispatchQueue(label: "zero.supervisor")
    private let worktrees = WorktreeManager()
    /// Answers to "would this still merge", kept against the pair of shas they
    /// are answers about. See `MergeChecks`.
    private let mergeChecks = MergeChecks()

    public var verifyTimeout: TimeInterval = 900

    public init(config: Config, registry: Registry, runs: RunStore, issues: IssueService,
                events: EventBus, notifier: Notifier, ouroPath: String, home: String = Paths.home) {
        self.config = config
        self.registry = registry
        self.runs = runs
        self.issues = issues
        self.events = events
        self.notifier = notifier
        self.ouroPath = ouroPath
        self.home = home
    }

    // MARK: - Dispatch

    public struct DispatchOptions {
        public var agent: String?
        public var worktree: Bool?
        public var finish: Finish?
        public var extraContext: String?

        public init(agent: String? = nil, worktree: Bool? = nil, finish: Finish? = nil,
                    extraContext: String? = nil) {
            self.agent = agent
            self.worktree = worktree
            self.finish = finish
            self.extraContext = extraContext
        }
    }

    /// The finish a project gets when the caller didn't say. Autonomy is a dial
    /// on *this default*, never an override of an explicit choice — if you asked
    /// for a merge, you get a merge.
    public static func defaultFinish(for project: Project) -> Finish {
        switch project.policy.autonomy {
        case .manual, .assist: return .leave
        case .auto:            return .merge
        }
    }

    @discardableResult
    public func dispatchFix(project: Project, issue: Issue,
                            options: DispatchOptions = DispatchOptions()) -> Run {
        let git = Git(project.path)
        let base = project.baseBranch ?? git.currentBranch ?? "main"
        let run = Run(
            id: Zero.newID("r"),
            projectId: project.id,
            projectName: project.name,
            kind: .fix,
            agent: options.agent ?? project.defaultAgent ?? config.defaultAgent,
            title: issue.title,
            issuePath: issue.path,
            cwd: project.path,
            base: base,
            finish: options.finish ?? Supervisor.defaultFinish(for: project),
            status: .queued
        )
        var stored = run
        stored.note = options.extraContext
        runs.save(stored)
        registry.touch(project.id)
        publish("run.queued", stored)
        work.async { [weak self] in self?.tick() }
        return stored
    }

    @discardableResult
    public func dispatchFreeform(project: Project, title: String, prompt: String,
                                 options: DispatchOptions = DispatchOptions()) -> Run {
        let git = Git(project.path)
        let base = project.baseBranch ?? git.currentBranch ?? "main"
        var run = Run(
            id: Zero.newID("r"),
            projectId: project.id,
            projectName: project.name,
            kind: .freeform,
            agent: options.agent ?? project.defaultAgent ?? config.defaultAgent,
            title: title,
            cwd: project.path,
            base: base,
            finish: options.finish ?? .leave,
            status: .queued
        )
        run.prompt = prompt
        runs.save(run)
        registry.touch(project.id)
        publish("run.queued", run)
        work.async { [weak self] in self?.tick() }
        return run
    }

    /// Answer an agent's question: a fresh run in the SAME worktree and branch,
    /// seeded with the original prompt plus the answer.
    @discardableResult
    public func reply(to runId: String, answer: String, agent: String? = nil) -> Run? {
        guard let previous = runs.get(runId), previous.status == .awaiting else { return nil }
        guard let project = registry.find(previous.projectId) else { return nil }

        var run = Run(
            id: Zero.newID("r"),
            projectId: previous.projectId,
            projectName: previous.projectName,
            kind: previous.kind,
            agent: agent ?? previous.agent,
            title: previous.title,
            issuePath: previous.issuePath,
            cwd: previous.worktreePath ?? project.path,
            worktreePath: previous.worktreePath,
            branch: previous.branch,
            base: previous.base,
            finish: previous.finish,
            status: .queued
        )
        let original = (try? String(contentsOfFile: runs.promptPath(previous.id), encoding: .utf8))
            ?? previous.prompt ?? previous.title
        run.prompt = SupervisedPrompt.reply(
            original: original,
            question: previous.result?.question,
            answer: answer,
            resultPath: runs.resultPath(run.id))
        runs.save(run)
        runs.mutate(previous.id) { $0.acknowledged = true }
        publish("run.queued", run)
        work.async { [weak self] in self?.tick() }
        return run
    }

    // MARK: - Scheduling

    public func slotsAvailable() -> Bool {
        let busy = runs.all().filter { $0.status.isActive && $0.status != .queued }.count
        return busy < max(1, config.maxParallel)
    }

    private func projectSlotsAvailable(_ projectId: String) -> Bool {
        guard let project = registry.find(projectId) else { return false }
        let busy = runs.forProject(projectId)
            .filter { $0.status.isActive && $0.status != .queued }.count
        return busy < max(1, project.policy.maxParallel)
    }

    /// Start whatever the queue allows. Cheap and idempotent — called on a timer
    /// and after every state change.
    public func tick() {
        for run in runs.queued().reversed() {   // oldest first
            guard slotsAvailable(), projectSlotsAvailable(run.projectId) else { return }
            start(run)
        }
    }

    private func start(_ queued: Run) {
        guard let project = registry.find(queued.projectId) else {
            fail(queued.id, note: "project \(queued.projectId) is no longer registered")
            return
        }

        var run = queued
        let wantsWorktree = run.worktreePath == nil && project.policy.worktreeDefault && run.kind != .plan

        if run.worktreePath == nil && wantsWorktree {
            let slug = IssueText.slugify(run.title)
            guard let wt = worktrees.create(repo: project.path, base: run.base, slug: slug) else {
                fail(run.id, note: "could not create a git worktree off \(run.base) — is \(project.path) a clean git repo?")
                return
            }
            run.worktreePath = wt.path
            run.branch = wt.branch
            run.cwd = wt.path
        } else if run.branch == nil {
            run.branch = Git(project.path).currentBranch ?? run.base
            run.cwd = run.worktreePath ?? project.path
        }

        // Seed prompt.
        let prompt: String
        if let existing = run.prompt, !existing.isEmpty {
            prompt = existing
        } else if run.kind == .fix, let issuePath = run.issuePath,
                  let issue = IssueService.store(for: project).read(path: issuePath) {
            prompt = SupervisedPrompt.fix(SupervisedPrompt.Context(
                title: issue.title,
                body: issue.body,
                issuePath: issuePath,
                branch: run.branch ?? run.base,
                base: run.base,
                worktree: run.worktreePath != nil,
                verifyCmd: project.verifyCmd,
                resultPath: runs.resultPath(run.id),
                protectedPaths: project.policy.protectedPaths,
                extraContext: run.note,
                toolsPath: installedToolsPath()))
        } else {
            prompt = SupervisedPrompt.fix(SupervisedPrompt.Context(
                title: run.title,
                body: run.prompt ?? run.title,
                branch: run.branch ?? run.base,
                base: run.base,
                worktree: run.worktreePath != nil,
                verifyCmd: project.verifyCmd,
                resultPath: runs.resultPath(run.id),
                protectedPaths: project.policy.protectedPaths,
                toolsPath: installedToolsPath()))
        }
        try? FileManager.default.createDirectory(atPath: runs.dir(run.id),
                                                 withIntermediateDirectories: true)
        try? prompt.write(toFile: runs.promptPath(run.id), atomically: true, encoding: .utf8)
        run.prompt = prompt
        run.status = .running
        run.startedAt = Date()

        // Wrap the agent in the shim so the run is observable.
        guard let template = config.agentTemplate(run.agent) else {
            runs.save(run)
            fail(run.id, note: "unknown agent '\(run.agent)'")
            return
        }
        // Give the conversation an identity before it starts, so "show me what
        // the agent was actually thinking" is one command away rather than an
        // archaeology exercise. Harnesses that won't be told get asked when
        // they exit — see `captureSession`.
        let harness = Harness.of(agent: run.agent, template: template)
        let sessionId = run.sessionId ?? UUID().uuidString
        if harness.acceptsSessionId { run.sessionId = sessionId }
        runs.save(run)

        // A resolve run continues a conversation rather than opening one. It is
        // not a special kind of run — same shim, same log, same gate — only a
        // different way of handing it the prompt.
        let agentArgv: [String]
        if run.resumeMode == "resumed",
           let resumed = Agents.resumeArgv(harness: harness, template: template,
                                           sessionId: sessionId, prompt: prompt) {
            agentArgv = resumed
        } else {
            agentArgv = Agents.dispatchArgv(template: template, prompt: prompt,
                                            sessionId: sessionId, harness: harness)
        }
        let argv = [ouroPath, "run-shim", run.id, "--home", home, "--"] + agentArgv

        let invocation = AgentInvocation(argv: argv, cwd: run.cwd, label: run.id, title: run.title)
        launcher().launch(invocation)
        publish("run.started", run)
    }

    /// Only mention the toolbelt to agents when it is actually installed —
    /// a prompt that advertises tools the machine does not have is worse than
    /// one that says nothing.
    func installedToolsPath() -> String? {
        let path = (home as NSString).appendingPathComponent("tools")
        let spec = (path as NSString).appendingPathComponent("TOOLS.md")
        return FileManager.default.fileExists(atPath: spec) ? path : nil
    }

    private func launcher() -> TerminalLauncher {
        switch config.terminal {
        case "tmux":   return TerminalLauncher(kind: .ghosttyTmuxTab)
        case "silent": return TerminalLauncher(kind: .custom, customLaunch: { inv, _ in
            // No window at all: detach the shim and let it report over the API.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", inv.argv.map(Shell.quote).joined(separator: " ")]
            process.currentDirectoryURL = URL(fileURLWithPath: inv.cwd)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        })
        case "terminal": return TerminalLauncher(kind: .osDefault)
        default:       return TerminalLauncher(kind: .ghosttyCinemaWindow)
        }
    }

    // MARK: - Shim callbacks

    public func shimStarted(_ id: String, pid: Int32) {
        runs.mutate(id) {
            $0.pid = pid
            if $0.status == .queued { $0.status = .running; $0.startedAt = Date() }
        }
        if let run = runs.get(id) { publish("run.running", run) }
    }

    /// Compare-and-set, not just set. Both the shim and the sweeper can report
    /// the same exit — and a second finalize pass would look at an
    /// already-merged branch, find no commits ahead of base, and declare a
    /// perfectly good fix a failure. `mutate` holds the lock across this check,
    /// so exactly one caller wins.
    public func shimExited(_ id: String, exitCode: Int32) {
        var claimed = false
        guard let run = runs.mutate(id, { run in
            guard run.status == .running || run.status == .queued else { return }
            claimed = true
            run.exitCode = exitCode
            run.endedAt = Date()
            run.status = .verifying
        }), claimed else { return }
        captureSession(run)
        publish("run.verifying", run)
        work.async { [weak self] in self?.finalize(id) }
    }

    /// Ask a harness that would not be told what it called the conversation.
    ///
    /// Runs once, at exit, because a rollout file only identifies itself after
    /// the session has written its first line — and by exit there is exactly
    /// one candidate for this working directory.
    private func captureSession(_ run: Run) {
        guard run.sessionId == nil else { return }
        let harness = Harness.of(agent: run.agent, template: config.agentTemplate(run.agent))
        guard harness == .codex else { return }
        guard let found = Agents.discoverCodexSession(
            cwd: run.worktreePath ?? run.cwd,
            since: run.startedAt ?? run.queuedAt) else { return }
        runs.mutate(run.id) { $0.sessionId = found }
    }

    /// Everything needed to reopen a run's conversation in a terminal, or nil
    /// when this harness has no way back in.
    public func resumeInvocation(_ id: String) -> (argv: [String], cwd: String)? {
        guard let run = runs.get(id), let sessionId = run.sessionId else { return nil }
        let template = config.agentTemplate(run.agent)
        let harness = Harness.of(agent: run.agent, template: template)
        guard let argv = Agents.resumeArgv(harness: harness, template: template,
                                           sessionId: sessionId) else { return nil }
        // The worktree, not the project root: that is where the work happened,
        // and the conversation's file references only resolve there.
        let cwd = run.worktreePath.flatMap {
            FileManager.default.fileExists(atPath: $0) ? $0 : nil
        } ?? run.cwd
        return (argv, cwd)
    }

    /// Reopen the conversation in its own terminal window.
    @discardableResult
    public func resume(_ id: String) -> String? {
        guard let run = runs.get(id) else { return nil }
        guard let (argv, cwd) = resumeInvocation(id) else { return nil }
        TerminalLauncher(kind: .ghosttyWindow).launch(
            AgentInvocation(argv: argv, cwd: cwd, label: "resume-\(run.id)",
                            title: "resume · \(run.title)"))
        return argv.joined(separator: " ")
    }

    // MARK: - Gate + finish

    private func finalize(_ id: String) {
        guard var run = runs.get(id), let project = registry.find(run.projectId) else { return }
        guard run.status == .verifying else { return }   // someone else already landed this

        let result = runs.readResult(id)
        if let result { runs.mutate(id) { $0.result = result } }

        // 1. The agent asked a question — that's a legitimate outcome, not a failure.
        if let result, result.outcome == "needs-input" || result.outcome == "blocked" {
            let run = runs.mutate(id) {
                $0.status = .awaiting
                $0.note = result.question ?? result.summary
            }
            if let run {
                publish("run.awaiting", run)
                emitInbox(run)
            }
            tick()
            return
        }

        let tail = runs.tailLog(id, lines: 40)

        // 2. The harness had forgotten the conversation. That is not a failed
        // run, it is a run that never started, so a fresh agent gets the same
        // brief and the two are told apart on the record.
        //
        // Checked here rather than down with "the agent committed nothing",
        // because a resolve run is handed a branch that already has commits on
        // it — every test below this line would pass while nothing happened.
        if run.resumeMode == "resumed", run.result == nil, (run.exitCode ?? 0) != 0,
           Supervisor.lostTheConversation(tail) {
            runs.mutate(id) {
                $0.status = .abandoned
                $0.endedAt = $0.endedAt ?? Date()
                $0.acknowledged = true
                $0.note = "\($0.agent) could not reopen that conversation — starting fresh"
            }
            if let dead = runs.get(id) { startOver(dead) }
            tick()
            return
        }

        // 3. A non-zero exit with nothing to show for it.
        let git = Git(project.path)
        let branch = run.branch
        let hasWork = branch.map { git.hasCommits(on: $0, notOn: run.base) } ?? false

        if !hasWork {
            var reason = (run.exitCode ?? 0) != 0
                ? "the agent exited \(run.exitCode ?? -1) without committing anything"
                : "the agent finished without committing anything to \(branch ?? "its branch")"
            // Put the agent's own last words in the inbox. Without this, every
            // failure reads the same and you have to go digging through a log to
            // learn something as basic as "your API key is out of credit".
            if let lastWords = Supervisor.lastWords(tail) {
                reason += " — it said: \(lastWords)"
            }
            if let diagnosis = Supervisor.diagnose(tail) {
                reason += "\n\n\(diagnosis)"
            }
            fail(id, note: reason)
            tick()
            return
        }

        // 4. Protected paths.
        if !project.policy.protectedPaths.isEmpty, let branch {
            let touched = git.changedFiles(branch: branch, base: run.base)
            let violations = touched.filter { file in
                project.policy.protectedPaths.contains { file.hasPrefix($0) }
            }
            if !violations.isEmpty {
                fail(id, note: "touched protected paths: \(violations.joined(separator: ", "))")
                tick()
                return
            }
        }

        // 5. The gate. This is the line between "an agent ran" and "a fix landed".
        if let verifyCmd = project.verifyCmd, !verifyCmd.isEmpty {
            let cwd = run.worktreePath ?? project.path
            let outcome = Shell.runLine(verifyCmd, cwd: cwd, timeout: verifyTimeout)
            let verify = VerifyOutcome(command: verifyCmd, exitCode: outcome.status,
                                       output: String(outcome.output.suffix(4000)))
            runs.mutate(id) { $0.verify = verify }
            if !verify.passed {
                fail(id, note: "\(verifyCmd) failed (exit \(verify.exitCode)) — the branch is kept for inspection")
                tick()
                return
            }
        }

        // 6. Green. Land it according to the finish the caller asked for.
        guard let latest = runs.get(id) else { return }
        run = latest
        runs.mutate(id) { $0.status = .finishing }

        switch run.finish {
        case .leave:
            succeed(id, note: "Verified on \(run.branch ?? "its branch"). Nothing merged — finish was 'leave'.")
        case .pr:
            openPR(run, project: project)
        case .merge:
            performMerge(run, project: project)
        }
        tick()
    }

    // MARK: finishing modes

    private func performMerge(_ run: Run, project: Project) {
        guard let branch = run.branch else {
            succeed(run.id, note: "No branch to merge.")
            return
        }
        let git = Git(project.path)

        guard git.currentBranch == run.base else {
            succeed(run.id, note: "Verified, but \(project.name) is on '\(git.currentBranch ?? "?")' not '\(run.base)' — merge \(branch) when you're ready.")
            return
        }
        guard !git.hasUncommittedTrackedChanges() else {
            succeed(run.id, note: "Verified, but you have uncommitted changes to tracked files — merge \(branch) when you're ready.")
            return
        }

        let message = "ouroboros: \(run.title)"
        let merge = git.run(["merge", "--no-ff", branch, "-m", message])
        guard merge.ok else {
            git.run(["merge", "--abort"])
            fail(run.id, note: "merge into \(run.base) conflicted — the branch \(branch) is intact:\n\(merge.output.suffix(600))")
            return
        }
        let sha = git.run(["rev-parse", "HEAD"], timeout: 10).trimmed

        // The worktree has served its purpose; the branch stays as evidence.
        if let worktreePath = run.worktreePath {
            git.run(["worktree", "remove", worktreePath, "--force"], timeout: 60)
        }

        resolveIssue(run, project: project, merged: run.base)

        runs.mutate(run.id) {
            $0.mergedInto = run.base
            $0.mergeCommit = sha.isEmpty ? nil : sha
        }
        succeed(run.id, note: "Merged into \(run.base).")
    }

    private func openPR(_ run: Run, project: Project) {
        guard let branch = run.branch else {
            succeed(run.id, note: "No branch to push."); return
        }
        let git = Git(project.path)
        guard git.hasRemote else {
            succeed(run.id, note: "Verified, but this repo has no remote — nothing to open a PR against.")
            return
        }
        let push = git.run(["push", "-u", "origin", branch], timeout: 180)
        guard push.ok else {
            fail(run.id, note: "git push failed:\n\(push.output.suffix(600))")
            return
        }
        let summary = run.result?.summary ?? "Filed with Ouroboros."
        let create = Shell.run(["gh", "pr", "create", "--base", run.base, "--head", branch,
                                "--title", run.title, "--body", summary],
                               cwd: project.path, login: true, timeout: 120)
        guard create.ok else {
            fail(run.id, note: "gh pr create failed:\n\(create.output.suffix(600))")
            return
        }
        let url = create.output.split(separator: "\n")
            .last(where: { $0.hasPrefix("http") }).map(String.init)
        runs.mutate(run.id) {
            var result = $0.result ?? AgentResult(outcome: "done")
            result.prUrl = url
            $0.result = result
        }
        succeed(run.id, note: url.map { "PR opened: \($0)" } ?? "PR opened.")
    }

    /// Append `## Resolution` and move the issue file to `done/`, then commit
    /// that move. Zero does this rather than the agent so it happens exactly
    /// once, with the real merge outcome in it.
    private func resolveIssue(_ run: Run, project: Project, merged: String?) {
        guard let issuePath = run.issuePath else { return }
        let store = IssueService.store(for: project)
        guard let issue = store.read(path: issuePath) else { return }

        let section = SupervisedPrompt.resolutionSection(
            summary: run.result?.summary, branch: run.branch, merged: merged)
        let updated = store.updateBody(issue, body: issue.body + section) ?? issue
        guard let moved = store.setStatus(updated, .done) else { return }

        // Follow the file: `undo` needs to find it again after it moved.
        if let newPath = moved.path {
            runs.mutate(run.id) { $0.issuePath = newPath }
        }

        let git = Git(project.path)
        git.run(["add", "-A", ".issues"], timeout: 30)
        git.run(["commit", "-m", "ouroboros: resolve \(run.title)"], timeout: 30)
    }

    /// Undo reopens the issue. A reverted fix whose issue still reads "done" is
    /// exactly the kind of quiet drift that makes people stop trusting the tool.
    private func reopenIssue(_ run: Run, project: Project) {
        guard let issuePath = run.issuePath else { return }
        let store = IssueService.store(for: project)
        guard let issue = store.read(path: issuePath), issue.status == .done else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let note = "\n\n_Reverted on \(formatter.string(from: Date())) — reopened._\n"
        let updated = store.updateBody(issue, body: issue.body + note) ?? issue
        guard let moved = store.setStatus(updated, .new) else { return }
        if let newPath = moved.path {
            runs.mutate(run.id) { $0.issuePath = newPath }
        }
        let git = Git(project.path)
        git.run(["add", "-A", ".issues"], timeout: 30)
        git.run(["commit", "-m", "ouroboros: reopen \(run.title)"], timeout: 30)
    }

    // MARK: - Manual actions

    /// Merge a run that was left on its branch (the inbox's "ready" action).
    @discardableResult
    public func mergeNow(_ id: String) -> Run? {
        guard let run = runs.get(id), let project = registry.find(run.projectId) else { return nil }
        guard run.status == .succeeded, run.mergedInto == nil else { return run }
        runs.mutate(id) { $0.acknowledged = false }
        performMerge(run, project: project)
        return runs.get(id)
    }

    /// Revert the merge commit. Undo is what makes autonomy comfortable.
    @discardableResult
    public func undo(_ id: String) -> (Run?, String) {
        guard let run = runs.get(id), let project = registry.find(run.projectId) else {
            return (nil, "no such run")
        }
        guard let sha = run.mergeCommit else { return (run, "this run has nothing merged to undo") }
        let git = Git(project.path)
        guard !git.hasUncommittedTrackedChanges() else {
            return (run, "you have uncommitted changes to tracked files — commit or stash first")
        }
        let revert = git.run(["revert", "--no-edit", "-m", "1", sha], timeout: 60)
        guard revert.ok else { return (run, "git revert failed:\n\(revert.output.suffix(400))") }
        reopenIssue(run, project: project)
        runs.mutate(id) {
            $0.mergedInto = nil
            $0.mergeCommit = nil
            $0.note = "Reverted from \(run.base)."
            $0.acknowledged = true
        }
        return (runs.get(id), "reverted \(String(sha.prefix(8))) from \(run.base)")
    }

    /// Put a run's branch back on top of its base.
    ///
    /// The verb `conflicts` offers instead of a merge the code has already
    /// tested and knows will fail. It runs in the run's own worktree, where the
    /// branch is already checked out, so nothing disturbs what you have open in
    /// the repo. A run whose worktree has gone is rebased in the repo itself,
    /// and only when that repo has nothing uncommitted to lose.
    public func rebase(_ id: String) -> (ok: Bool, message: String) {
        guard let run = runs.get(id), let project = registry.find(run.projectId) else {
            return (false, "no such run")
        }
        guard let branch = run.branch else { return (false, "that run has no branch") }
        let repo: String
        if let worktree = run.worktreePath, FileManager.default.fileExists(atPath: worktree) {
            repo = worktree
        } else {
            guard !Git(project.path).hasUncommittedTrackedChanges() else {
                return (false, "you have uncommitted changes — commit or stash first")
            }
            repo = project.path
        }
        let result = Git(repo).rebase(branch: branch, onto: run.base)
        // The verdict named two commits and one of them has just moved, so the
        // next reader has to ask git again rather than reuse the old answer.
        if result.ok { runs.mutate(id) { $0.merge = nil } }
        return result
    }

    // MARK: - resolve

    /// Send the agent that wrote the branch back in to rebase and fix it.
    ///
    /// Resume, not re-dispatch. The agent that wrote the lines is the only party
    /// that knows why: it is remembering a decision it took an hour ago, where a
    /// fresh agent reading `<<<<<<<` is inferring intent from syntax. Both are
    /// supervised identically — shim, log, gate, inbox — because this is not a
    /// special case, it is a run whose first message is a conflict report.
    ///
    /// It never lands anything. The finish is inherited from the run it is
    /// rescuing, and Ouroboros re-verifies and re-tests the merge afterwards, so
    /// the run comes back `review` if it worked and `conflicts` again if it did
    /// not.
    public func resolve(_ id: String) -> (run: Run?, message: String) {
        guard let previous = runs.get(id), let project = registry.find(previous.projectId) else {
            return (nil, "no such run")
        }
        guard let branch = previous.branch else { return (nil, "that run has no branch") }
        guard let verdict = mergeCheck(id) else {
            return (nil, "that run has no branch to test")
        }
        if let error = verdict.error {
            return (nil, "could not test the merge: \(error)")
        }
        if verdict.spent {
            return (nil, "\(branch) has nothing left to give — \(verdict.staleness?.reason ?? "its work is already on \(previous.base)")")
        }
        guard !verdict.clean else {
            return (nil, "\(branch) already merges into \(previous.base) — nothing to resolve")
        }

        let template = config.agentTemplate(previous.agent)
        let harness = Harness.of(agent: previous.agent, template: template)
        guard harness.canResume else {
            return (nil, "\(previous.agent) cannot reopen a conversation")
        }
        guard let sessionId = previous.sessionId else {
            return (nil, "that run has no recorded conversation — it predates session capture")
        }

        // The branch has to be checked out somewhere the agent can work. Its own
        // worktree is that place; if it has been cleaned away, put it back
        // rather than sending an agent into the repo you are working in.
        guard let worktree = worktree(for: previous, project: project) else {
            return (nil, "could not put \(branch) back in a worktree")
        }

        var run = Run(
            id: Zero.newID("r"),
            projectId: previous.projectId,
            projectName: previous.projectName,
            kind: previous.kind,
            agent: previous.agent,
            title: previous.title,
            issuePath: previous.issuePath,
            cwd: worktree,
            worktreePath: worktree,
            branch: branch,
            base: previous.base,
            finish: previous.finish,
            status: .queued
        )
        run.sessionId = sessionId
        run.resolveOf = previous.id
        run.resumeMode = "resumed"
        run.prompt = SupervisedPrompt.resolve(conflictContext(previous, project: project,
                                                              verdict: verdict,
                                                              resultPath: runs.resultPath(run.id),
                                                              fresh: false))
        run.note = "resolving \(branch) — resumed \(previous.agent) conversation \(sessionId)"
        runs.save(run)
        // The old run's job is done either way: whatever happens next happens on
        // the new one, and leaving both in the inbox asks about one thing twice.
        runs.mutate(previous.id) { $0.acknowledged = true }
        publish("run.queued", run)
        work.async { [weak self] in self?.tick() }
        return (run, "\(previous.agent) is back on \(branch)")
    }

    /// Everything the seed prompt needs about the disagreement.
    private func conflictContext(_ run: Run, project: Project, verdict: MergeVerdict,
                                 resultPath: String, fresh: Bool) -> SupervisedPrompt.ConflictContext {
        // Only a fresh agent is read the issue back. The one being resumed wrote
        // the branch from it and does not need it quoting at itself.
        var issue: String?
        if fresh, let issuePath = run.issuePath,
           let filed = IssueService.store(for: project).read(path: issuePath) {
            issue = "## \(filed.title)\n\n\(filed.body)"
        }
        return SupervisedPrompt.ConflictContext(
            branch: run.branch ?? "its branch",
            base: run.base,
            branchSha: verdict.branchSha,
            baseSha: verdict.baseSha,
            files: verdict.conflicts,
            resultPath: resultPath,
            verifyCmd: project.verifyCmd,
            issue: issue,
            fresh: fresh)
    }

    /// The harness had forgotten the session. Same brief, plus the issue, to an
    /// agent that has never seen this branch — and the run says which it was.
    private func startOver(_ run: Run) {
        guard let project = registry.find(run.projectId), let verdict = run.merge ?? mergeCheck(run.id)
        else { return }
        var fresh = Run(
            id: Zero.newID("r"),
            projectId: run.projectId,
            projectName: run.projectName,
            kind: run.kind,
            agent: run.agent,
            title: run.title,
            issuePath: run.issuePath,
            cwd: run.cwd,
            worktreePath: run.worktreePath,
            branch: run.branch,
            base: run.base,
            finish: run.finish,
            status: .queued
        )
        fresh.resolveOf = run.resolveOf ?? run.id
        fresh.resumeMode = "fresh"
        fresh.prompt = SupervisedPrompt.resolve(
            conflictContext(run, project: project, verdict: verdict,
                            resultPath: runs.resultPath(fresh.id), fresh: true))
        fresh.note = "the \(run.agent) conversation was gone — a new agent is reading the branch cold"
        runs.save(fresh)
        runs.mutate(run.id) { $0.acknowledged = true }
        publish("run.queued", fresh)
        work.async { [weak self] in self?.tick() }
    }

    /// The run's worktree, put back if it has been cleaned away. Nil when the
    /// branch cannot be checked out anywhere of its own.
    private func worktree(for run: Run, project: Project) -> String? {
        let fm = FileManager.default
        if let path = run.worktreePath, fm.fileExists(atPath: path) { return path }
        guard let branch = run.branch else { return nil }
        let path = run.worktreePath ?? (project.path as NSString)
            .appendingPathComponent(".ouroboros/worktrees/\(IssueText.slugify(run.title))")
        let git = Git(project.path)
        // `--force` only overrides git's "already checked out somewhere" guard,
        // which is exactly the state a half-removed worktree leaves behind.
        git.run(["worktree", "prune"], timeout: 30)
        let added = git.run(["worktree", "add", "--force", path, branch], timeout: 120)
        return added.ok ? path : nil
    }

    /// Let a spent branch go: delete it, drop its worktree, close the run.
    ///
    /// Refused unless the branch really is spent. `discard` is the one verb here
    /// that destroys something, so it is not allowed to act on a guess — and the
    /// tip sha goes in the message, because a deleted branch that nobody wrote
    /// down is a deleted branch nobody can get back.
    public func discard(_ id: String) -> (ok: Bool, message: String) {
        guard let run = runs.get(id), let project = registry.find(run.projectId) else {
            return (false, "no such run")
        }
        guard let branch = run.branch else { return (false, "that run has no branch") }
        guard let verdict = mergeCheck(id), verdict.spent else {
            return (false, "\(branch) still has work on it — resolve or rebase it instead")
        }

        let git = Git(project.path)
        let sha = String(verdict.branchSha.prefix(12))
        if let worktreePath = run.worktreePath,
           FileManager.default.fileExists(atPath: worktreePath) {
            git.run(["worktree", "remove", worktreePath, "--force"], timeout: 60)
        }
        git.run(["worktree", "prune"], timeout: 30)
        let deleted = git.run(["branch", "-D", branch], timeout: 30)
        guard deleted.ok else {
            return (false, "could not delete \(branch): \(Supervisor.firstLine(deleted.output))")
        }
        // `abandoned`, not `succeeded`: this run produced nothing that survives.
        // Leaving it succeeded with no branch would flip the row to `review` and
        // offer a merge of nothing, which is the same class of lie as calling an
        // untested branch ready. The note carries the sha, because a deleted
        // branch nobody wrote down is a deleted branch nobody can get back.
        runs.mutate(id) {
            $0.status = .abandoned
            $0.acknowledged = true
            $0.branch = nil
            $0.worktreePath = nil
            $0.merge = nil
            $0.note = "discarded \(branch) at \(sha) — "
                + (verdict.staleness?.reason ?? "its work was already on \(run.base)")
        }
        return (true, "discarded \(branch)  \(sha)")
    }

    static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? "git said nothing"
    }

    @discardableResult
    public func stop(_ id: String) -> Run? {
        guard let run = runs.get(id) else { return nil }
        if let pid = run.pid, pid > 0 { kill(pid, SIGTERM) }
        let updated = runs.mutate(id) {
            $0.status = .abandoned
            $0.endedAt = Date()
            $0.note = "Stopped by you."
        }
        if let updated { publish("run.abandoned", updated) }
        work.async { [weak self] in self?.tick() }
        return updated
    }

    public func diff(_ id: String) -> String {
        guard let run = runs.get(id), let project = registry.find(run.projectId),
              let branch = run.branch else { return "" }
        return Git(project.path).run(["diff", "\(run.base)...\(branch)"], timeout: 60).output
    }

    /// The same work as `diff`, read rather than dumped: commits, files with
    /// their counts, and hunks with a kind per line. One parser, in the daemon,
    /// so no client has to grow a second one.
    public func diffReport(_ id: String) -> DiffReport? {
        guard let run = runs.get(id), let project = registry.find(run.projectId) else { return nil }
        guard let branch = run.branch else {
            // A run with no branch is not an error, it is a run that changed
            // nothing. An empty report says that; a 404 would say the run is
            // missing, which is a different and wrong thing to tell someone.
            return DiffReport(runId: run.id, base: run.base, branch: "")
        }
        return DiffReports.build(runId: run.id, repo: project.path,
                                 base: run.base, branch: branch)
    }

    /// Would this branch actually go in? Tested without performing it, and
    /// answered about two named commits. See `MergeVerdict`.
    public func mergeCheck(_ id: String) -> MergeVerdict? {
        guard let run = runs.get(id), let project = registry.find(run.projectId),
              let branch = run.branch else { return nil }
        return mergeChecks.verdict(repo: project.path, base: run.base, branch: branch)
    }

    /// The verdict for a run that is waiting on a human, and nothing else.
    ///
    /// A queued or running branch has not finished being written, and a merged
    /// one has already gone in — testing either would cost a fork per row per
    /// poll to answer a question nobody asked.
    public func mergeCheckIfPending(_ run: Run) -> MergeVerdict? {
        guard run.status == .succeeded, run.mergedInto == nil,
              run.result?.prUrl == nil, run.branch != nil else { return nil }
        return mergeCheck(run.id)
    }

    public func acknowledge(_ id: String) {
        runs.mutate(id) { $0.acknowledged = true }
    }

    // MARK: - Reconciliation

    /// Runs the daemon believed were live when it stopped. Either the shim left
    /// a report, or the process is simply gone and the run is orphaned.
    public func reconcile() {
        for run in runs.all() where run.status == .running || run.status == .verifying {
            if let report = Zero.readJSON(ShimReport.self, from: runs.shimPath(run.id)),
               report.phase == "exited" {
                shimExited(run.id, exitCode: report.exitCode ?? 0)
                continue
            }
            if let pid = run.pid, pid > 0, kill(pid, 0) == 0 {
                continue   // still alive, adopt it
            }
            if run.status == .verifying {
                work.async { [weak self] in self?.finalize(run.id) }
            } else {
                fail(run.id, note: "the daemon restarted while this run was live and its process is gone")
            }
        }
        tick()
    }

    /// Catch runs whose terminal window was force-closed: the shim never got to
    /// report, so nothing else would ever notice.
    public func sweep() {
        for run in runs.running() {
            // The agent's own result file is proof it finished, and it outranks
            // the shim's bookkeeping. If the shim was killed, or its report never
            // landed, the work is still done — don't strand the run in `running`
            // forever just because the messenger died.
            if FileManager.default.fileExists(atPath: runs.resultPath(run.id)) {
                shimExited(run.id, exitCode: 0)
                continue
            }
            guard let pid = run.pid, pid > 0 else {
                // No pid means the shim's "started" report never arrived. That is
                // NOT evidence the agent is dead: the report can be lost while the
                // agent works away perfectly happily. An earlier version gave up
                // after 180s and killed a run whose agent finished at 184s.
                // Silence is the only real signal, so wait for a lot of it.
                let quietSince = (try? FileManager.default
                    .attributesOfItem(atPath: runs.logPath(run.id))[.modificationDate] as? Date)
                    .flatMap { $0 } ?? run.startedAt ?? run.queuedAt
                if Date().timeIntervalSince(quietSince) > 900 {
                    fail(run.id, note: "no sign of life for 15 minutes — the terminal probably never launched")
                }
                continue
            }
            if kill(pid, 0) != 0 {
                if let report = Zero.readJSON(ShimReport.self, from: runs.shimPath(run.id)),
                   report.phase == "exited" {
                    shimExited(run.id, exitCode: report.exitCode ?? 0)
                } else {
                    shimExited(run.id, exitCode: 130)
                }
            }
        }
        tick()
    }

    // MARK: - Terminal transitions

    private func succeed(_ id: String, note: String) {
        guard let run = runs.mutate(id, {
            $0.status = .succeeded
            $0.endedAt = $0.endedAt ?? Date()
            $0.note = note
        }) else { return }
        publish("run.succeeded", run)
        emitInbox(run)
    }

    private func fail(_ id: String, note: String) {
        guard let run = runs.mutate(id, {
            $0.status = .failed
            $0.endedAt = $0.endedAt ?? Date()
            $0.note = note
        }) else { return }
        publish("run.failed", run)
        emitInbox(run)
    }

    private func emitInbox(_ run: Run) {
        let items = Inbox.build(runs: [run], proposals: [])
        for item in items { notifier.notify(item) }
    }

    /// Turn a handful of failures that are really environment problems into the
    /// sentence that names the actual cause.
    ///
    /// A harness reports what it sees, which is usually a symptom several steps
    /// downstream. "Credit balance is too low" sends you to a billing page when
    /// the real story is that the daemon inherited someone else's key and your
    /// own login was never consulted.
    static func diagnose(_ log: String) -> String? {
        let text = log.lowercased()
        if text.contains("credit balance is too low") || text.contains("insufficient credit") {
            if text.contains("anthropic_api_key") || text.contains("connectors are disabled") {
                return "That key came from the environment the daemon was started in, not from "
                     + "your own login. Restart it from a plain shell (`ouro daemon restart`) "
                     + "and the agent will use your normal credentials."
            }
            return "The account behind the agent's API key is out of credit."
        }
        if text.contains("invalid api key") || text.contains("authentication_error") {
            return "The agent could not authenticate. Check `claude` runs on its own in a "
                 + "terminal, then `ouro daemon restart`."
        }
        if text.contains("command not found") {
            return "The agent's CLI is not on the daemon's PATH. Start the daemon from a login "
                 + "shell, or set an absolute path in ~/.ouroboros/config.json."
        }
        return nil
    }

    /// Has the harness told us it no longer has that conversation?
    ///
    /// The rule this was written to was "a resume that exits non-zero without
    /// output", and that is not what happens. `claude --resume <gone> -p` exits
    /// 1 and says so in a sentence:
    ///
    ///     No conversation found with session ID: 0000…
    ///
    /// Silence is still one of the shapes — a harness can die before printing
    /// anything — so both count. Getting this wrong is not harmless: it puts
    /// "the agent exited 1 without committing anything" in the inbox for a run
    /// that never started, and the fresh-agent fallback never fires.
    static func lostTheConversation(_ log: String) -> Bool {
        let text = log.lowercased()
        for phrase in ["no conversation found with session id",
                       "session not found",
                       "no such session",
                       "could not find session",
                       "no rollout found"] where text.contains(phrase) {
            return true
        }
        return lastWords(log) == nil
    }

    /// The last meaningful line an agent printed, stripped of the ANSI noise a
    /// pty log is full of. Nil when there is nothing worth quoting.
    static func lastWords(_ log: String, limit: Int = 160) -> String? {
        var cleaned: [String] = []
        for rawLine in log.components(separatedBy: .newlines) {
            var line = ""
            var inEscape = false
            for ch in rawLine {
                if ch == "\u{1B}" { inEscape = true; continue }
                if inEscape {
                    if ch.isLetter { inEscape = false }
                    continue
                }
                if ch.isNewline || ch == "\r" { continue }
                if let ascii = ch.asciiValue, ascii < 32 { continue }
                line.append(ch)
            }
            line = line.trimmingCharacters(in: .whitespaces)
            // Box-drawing and spinner frames carry no information.
            let noise = line.allSatisfy { "─│╭╮╯╰┌┐└┘━┃═║·•*…✻✽ ".contains($0) }
            if !line.isEmpty && !noise { cleaned.append(line) }
        }
        guard let last = cleaned.last else { return nil }
        return String(last.prefix(limit))
    }

    private func publish(_ type: String, _ run: Run) {
        events.publish(ZeroEvent(type: type, runId: run.id, projectId: run.projectId,
                                 status: run.status.rawValue, message: run.title))
    }
}
