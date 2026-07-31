import Foundation
import ZeroCore

enum Commands {

    // MARK: - overview (bare `ouro`)

    static func overview(_ args: Args) {
        let client = Zero0.connected()
        guard let snapshot = try? client.get("/v1/snapshot", as: API.Snapshot.self) else {
            Out.die("could not read the daemon snapshot")
        }
        Out.banner()

        if snapshot.inbox.isEmpty {
            print("  " + Ansi.dim("inbox clear"))
        } else {
            print("  " + Ansi.bold("needs you"))
            for item in snapshot.inbox.prefix(8) {
                print("    \(Fmt.inboxGlyph(item.kind)) \(Ansi.pad(Fmt.inboxLabel(item.kind), 18)) "
                      + "\(Ansi.dim(item.projectName))  \(Fmt.truncate(item.title, 46))")
            }
            if snapshot.inbox.count > 8 {
                print("    " + Ansi.dim("+\(snapshot.inbox.count - 8) more — ouro inbox"))
            }
        }
        print("")

        let active = snapshot.activeRuns
        if !active.isEmpty {
            print("  " + Ansi.bold("in flight"))
            for run in active {
                print("    \(Fmt.glyph(run.status)) \(Ansi.pad(Fmt.status(run.status), 20)) "
                      + "\(Ansi.dim(run.projectName))  \(Fmt.truncate(run.title, 40))  "
                      + Ansi.dim(Fmt.duration(run.duration)))
            }
            print("")
        }

        print("  " + Ansi.bold("projects"))
        for project in snapshot.projects.prefix(10) {
            let runs = snapshot.activeRuns.filter { $0.projectId == project.id }.count
            let badge = runs > 0 ? Ansi.orange(" ●\(runs)") : ""
            print("    \(Ansi.pad(project.name, 24))\(Ansi.dim(project.policy.autonomy.label))\(badge)")
        }
        if snapshot.projects.isEmpty {
            print("    " + Ansi.dim("none yet — cd into a repo and run: ouro projects add ."))
        }
        print("")
        print("  " + Ansi.dim("ouro i \"what's wrong\"   ·   ouro inbox   ·   ouro runs -w"))
        print("")
    }

    // MARK: - issues

    static func issue(_ args: Args) {
        var body = args.joined
        if body.isEmpty || args.bool("stdin") {
            let piped = readStdin()
            if !piped.isEmpty { body = body.isEmpty ? piped : body + "\n\n" + piped }
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Out.die("say what's wrong: ouro i \"the login button does nothing\"")
        }

        let client = Zero0.connected()
        let request = API.CreateIssue(
            project: args.flag("p", "project"),
            cwd: Zero0.cwd(),
            title: args.flag("t", "title"),
            body: body,
            fix: args.bool("fix", "f"),
            agent: args.flag("a", "agent"),
            worktree: args.has("no-worktree") ? false : nil,
            finish: finishFlag(args))

        do {
            let created: API.IssueCreated = try client.post("/v1/issues", request)
            print("")
            print("  \(Out.mark()) \(Ansi.bold("filed"))  \(Ansi.dim(created.issue.projectName)) · \(created.issue.title)")
            print("    " + Ansi.dim(created.issue.path))
            if let run = created.run {
                print("    " + Ansi.orange("→ ") + "\(run.agent) dispatched"
                      + Ansi.dim("  \(run.id)"))
            } else {
                print("    " + Ansi.dim("fix it with: ouro fix \(created.issue.id)"))
            }
            print("")
        } catch {
            Out.die("\(error)")
        }
    }

    static func issues(_ args: Args) {
        let client = Zero0.connected()
        var path = "/v1/issues"
        var query: [String] = []
        if let project = args.flag("p", "project") { query.append("project=\(escape(project))") }
        if let status = args.flag("status") { query.append("status=\(escape(status))") }
        if !query.isEmpty { path += "?" + query.joined(separator: "&") }

        guard let list = try? client.get(path, as: API.IssueList.self) else {
            Out.die("could not list issues")
        }
        if list.issues.isEmpty { print(Ansi.dim("  no issues")); return }
        print("")
        for issue in list.issues.prefix(args.flag("limit").flatMap(Int.init) ?? 40) {
            let status = issue.status == "new" ? Ansi.orange("new")
                : issue.status == "done" ? Ansi.green("done")
                : Ansi.dim(issue.status)
            print("  \(Ansi.pad(Ansi.dim(issue.id), 32)) \(Ansi.pad(status, 14)) "
                  + "\(Ansi.pad(Ansi.dim(issue.projectName), 22)) \(Fmt.truncate(issue.title, 44))")
        }
        print("")
    }

    static func fix(_ args: Args) {
        let client = Zero0.connected()
        var issueId = args.positional.first

        if issueId == nil {
            // No id: the newest open issue in the project you're standing in.
            let project = args.flag("p", "project")
            var path = "/v1/issues?status=new"
            if let project { path += "&project=\(escape(project))" }
            guard let list = try? client.get(path, as: API.IssueList.self),
                  let newest = list.issues.first else {
                Out.die("no open issues — file one with: ouro i \"…\"")
            }
            issueId = newest.id
            print(Ansi.dim("  → \(newest.projectName) · \(newest.title)"))
        }

        let request = API.FixRequest(
            agent: args.flag("a", "agent"),
            worktree: args.has("no-worktree") ? false : nil,
            finish: finishFlag(args))
        do {
            let run: Run = try client.post("/v1/issues/\(issueId!)/fix", request)
            print("  \(Out.mark()) \(run.agent) dispatched on \(Ansi.bold(run.projectName))"
                  + Ansi.dim("  \(run.id)"))
            if args.bool("watch", "w") { watchRuns(client, once: run.id) }
        } catch {
            Out.die("\(error)")
        }
    }

    /// Confirm a piece of work is really finished: the issue file moves to
    /// `.issues/done` and the run behind it stops asking for attention.
    /// Ouroboros resolves an issue when its own gate goes green; this is a
    /// human saying so, which is not the same claim.
    static func done(_ args: Args) {
        let client = Zero0.connected()
        guard let issueId = args.positional.first else {
            Out.die("which one? ouro done <issue-id>   (ids from `ouro issues`)")
        }
        do {
            let issue: IssueDTO = try client.patch("/v1/issues/\(issueId)",
                                                   API.PatchIssue(status: "done"))
            print("  \(Out.mark()) \(Ansi.bold("done"))  \(Ansi.dim(issue.projectName)) · \(issue.title)")
            // Whatever ran against it is now noise in the inbox. Matched on the
            // file's name, not its path: resolving it just moved the file.
            let name = (issue.path as NSString).lastPathComponent
            if !name.isEmpty,
               let list = try? client.get("/v1/runs?project=\(escape(issue.projectId))",
                                          as: API.RunList.self) {
                for run in list.runs where !run.acknowledged
                    && run.issuePath.map({ ($0 as NSString).lastPathComponent }) == name {
                    _ = try? client.post("/v1/runs/\(run.id)/ack", as: API.Message.self)
                }
            }
        } catch {
            Out.die("\(error)")
        }
    }

    // MARK: - runs

    static func runs(_ args: Args) {
        let client = Zero0.connected()
        if args.bool("w", "watch") { watchRuns(client); return }
        renderRuns(client, args: args)
    }

    private static func renderRuns(_ client: ZeroClient, args: Args) {
        var path = "/v1/runs?limit=\(args.flag("limit").flatMap(Int.init) ?? 25)"
        if !args.bool("all", "a") && args.flag("status") == nil { /* everything recent */ }
        if let status = args.flag("status") { path += "&status=\(escape(status))" }
        if let project = args.flag("p", "project") { path += "&project=\(escape(project))" }

        guard let list = try? client.get(path, as: API.RunList.self) else {
            Out.die("could not list runs")
        }
        if list.runs.isEmpty { print(Ansi.dim("  no runs yet")); return }
        print("")
        print("  " + Ansi.dim(Ansi.pad("run", 20) + Ansi.pad("status", 14)
                              + Ansi.pad("project", 18) + Ansi.pad("title", 40) + "age"))
        for run in list.runs {
            let age = run.status.isActive ? Fmt.duration(run.duration) : Fmt.ago(run.endedAt ?? run.queuedAt)
            print("  \(Ansi.pad(Ansi.dim(run.id), 20))\(Ansi.pad(Fmt.glyph(run.status) + " " + Fmt.status(run.status), 14))"
                  + "\(Ansi.pad(run.projectName, 18))\(Ansi.pad(Fmt.truncate(run.title, 38), 40))"
                  + Ansi.dim(age))
        }
        print("")
    }

    /// Live table. Redraws on a short timer — the point is that ten concurrent
    /// agents feel like a control room rather than ten lost terminals.
    private static func watchRuns(_ client: ZeroClient, once runId: String? = nil) {
        let hideCursor = "\u{1B}[?25l", showCursor = "\u{1B}[?25h", clear = "\u{1B}[H\u{1B}[2J"
        print(hideCursor, terminator: "")
        defer { print(showCursor, terminator: "") }

        signal(SIGINT) { _ in
            print("\u{1B}[?25h")
            exit(0)
        }

        while true {
            guard let snapshot = try? client.get("/v1/snapshot", as: API.Snapshot.self) else {
                Out.die("daemon went away")
            }
            print(clear, terminator: "")
            Out.banner()
            let active = snapshot.activeRuns
            if active.isEmpty {
                print("  " + Ansi.dim("nothing in flight"))
            } else {
                for run in active {
                    print("  \(Fmt.glyph(run.status)) \(Ansi.pad(Fmt.status(run.status), 22))"
                          + "\(Ansi.pad(Ansi.dim(run.projectName), 22))\(Ansi.pad(Fmt.truncate(run.title, 40), 42))"
                          + Ansi.dim(Fmt.duration(run.duration)))
                }
            }
            print("")
            if !snapshot.inbox.isEmpty {
                print("  " + Ansi.bold("needs you"))
                for item in snapshot.inbox.prefix(6) {
                    print("    \(Fmt.inboxGlyph(item.kind)) \(Ansi.pad(Fmt.inboxLabel(item.kind), 18))"
                          + "\(Ansi.dim(item.projectName))  \(Fmt.truncate(item.title, 44))")
                }
                print("")
            }
            print("  " + Ansi.dim("ctrl-c to stop watching"))

            if let runId {
                let known = snapshot.activeRuns + snapshot.recentRuns
                if let run = known.first(where: { $0.id == runId }), run.status.isTerminal {
                    print("")
                    return
                }
            }
            Thread.sleep(forTimeInterval: 1.2)
        }
    }

    static func log(_ args: Args) {
        guard let runId = args.positional.first else { Out.die("usage: ouro log <run-id> [-f]") }
        let client = Zero0.connected()
        let lines = args.flag("n", "lines").flatMap(Int.init) ?? 80
        let follow = args.bool("f", "follow")

        var seen = ""
        repeat {
            guard let response = try? client.get("/v1/runs/\(runId)/log?lines=\(follow ? 4000 : lines)",
                                                 as: API.TextResponse.self) else {
                Out.die("no such run")
            }
            if follow {
                if response.text.count > seen.count {
                    let delta = String(response.text.dropFirst(seen.count))
                    FileHandle.standardOutput.write(Data(delta.utf8))
                    seen = response.text
                }
                if let run = try? client.get("/v1/runs/\(runId)", as: Run.self),
                   run.status.isTerminal { break }
                Thread.sleep(forTimeInterval: 0.8)
            } else {
                print(response.text)
                break
            }
        } while follow
    }

    static func diff(_ args: Args) {
        guard let runId = args.positional.first else { Out.die("usage: ouro diff <run-id>") }
        let client = Zero0.connected()

        // `--json` is the endpoint's own payload, printed. Not re-encoded from
        // a decoded value: what a script sees and what the diff surface reads
        // then cannot drift apart.
        if args.has("json") {
            guard let (status, data) = try? client.sendRaw("GET", "/v1/runs/\(runId)/diff"),
                  (200..<300).contains(status) else { Out.die("no such run") }
            FileHandle.standardOutput.write(data)
            if data.last != 0x0A { print() }
            return
        }

        // The human form is git's own output, unchanged. `?format=text` asks
        // the daemon for exactly that rather than rebuilding a patch from the
        // structure and getting the index lines subtly wrong.
        guard let response = try? client.get("/v1/runs/\(runId)/diff?format=text",
                                             as: API.TextResponse.self) else {
            Out.die("no such run")
        }
        guard !response.text.isEmpty else {
            print(Ansi.dim("  (no changes on that branch)"))
            return
        }
        // One line of shape before the wall of text, from the same structured
        // read the GUI gets. On stderr, deliberately: `ouro diff > patch` has
        // always produced a file git can apply, and a summary line on stdout
        // would quietly stop that being true.
        if let report = try? client.get("/v1/runs/\(runId)/diff", as: DiffReport.self),
           !report.isEmpty {
            FileHandle.standardError.write(Data((Ansi.dim("  " + report.summary) + "\n\n").utf8))
        }
        print(response.text)
    }

    /// Would this branch still go in? The same test the drawer reads off the
    /// snapshot, so the CLI and the panel cannot disagree about a merge.
    static func mergeCheck(_ args: Args) {
        guard let runId = args.positional.first else {
            Out.die("usage: ouro merge-check <run-id>")
        }
        let client = Zero0.connected()
        guard let verdict = try? client.get("/v1/runs/\(runId)/merge-check",
                                            as: MergeVerdict.self) else {
            Out.die("no such run, or it has no branch")
        }
        let pair = Ansi.dim("  \(String(verdict.baseSha.prefix(8)))..\(String(verdict.branchSha.prefix(8)))")
        if let error = verdict.error {
            Out.warn("could not tell: \(error)" + pair)
            return
        }
        if verdict.clean {
            Out.ok("merges into \(verdict.base)" + pair)
            return
        }
        Out.warn("conflicts with \(verdict.base)" + pair)
        for path in verdict.conflicts { print(Ansi.dim("    " + path)) }
        print(Ansi.dim("    ouro fix — or rebase \(verdict.branch) onto \(verdict.base)"))
    }

    static func runAction(_ action: String, _ args: Args) {
        guard let runId = args.positional.first else { Out.die("usage: ouro \(action) <run-id>") }
        let client = Zero0.connected()
        do {
            switch action {
            case "reply":
                let answer = args.positional.dropFirst().joined(separator: " ")
                let text = answer.isEmpty ? readStdin() : answer
                guard !text.isEmpty else { Out.die("usage: ouro reply <run-id> \"your answer\"") }
                let run: Run = try client.post("/v1/runs/\(runId)/reply",
                                               API.Reply(answer: text, agent: args.flag("a", "agent")))
                Out.ok("re-dispatched \(run.agent) with your answer" + Ansi.dim("  \(run.id)"))
            case "stop":
                let run: Run = try client.post("/v1/runs/\(runId)/stop", as: Run.self)
                Out.ok("stopped \(run.id)")
            case "merge":
                let run: Run = try client.post("/v1/runs/\(runId)/merge", as: Run.self)
                if let into = run.mergedInto { Out.ok("merged into \(into)") }
                else { Out.err(run.note ?? "not merged") }
            case "undo":
                let message: API.Message = try client.post("/v1/runs/\(runId)/undo", as: API.Message.self)
                message.ok ? Out.ok(message.message) : Out.err(message.message)
            case "retry":
                let run: Run = try client.post("/v1/runs/\(runId)/retry", as: Run.self)
                Out.ok("retrying" + Ansi.dim("  \(run.id)"))
            case "ok", "drop", "ack":
                _ = try client.post("/v1/runs/\(runId)/ack", as: API.Message.self)
                Out.ok("cleared from the inbox")
            default:
                Out.die("unknown action")
            }
        } catch {
            Out.die("\(error)")
        }
    }

    // MARK: - inbox

    static func inbox(_ args: Args) {
        let client = Zero0.connected()
        guard let list = try? client.get("/v1/inbox", as: API.InboxList.self) else {
            Out.die("could not read the inbox")
        }
        print("")
        if list.items.isEmpty {
            print("  " + Ansi.green("✓") + " " + Ansi.dim("nothing needs you"))
            print("")
            return
        }
        for item in list.items {
            print("  \(Fmt.inboxGlyph(item.kind)) \(Ansi.bold(Fmt.truncate(item.title, 60)))")
            print("    \(Ansi.pad(Fmt.inboxLabel(item.kind), 20))\(Ansi.dim(item.projectName))  "
                  + Ansi.dim(Fmt.ago(item.createdAt)))
            if !item.detail.isEmpty {
                print("    " + Ansi.dim(Fmt.truncate(item.detail, 88)))
            }
            let id = item.runId ?? item.proposalId ?? item.id
            let hints = item.actions.map { action -> String in
                switch action {
                case "reply":  return "ouro reply \(id) \"…\""
                case "log":    return "ouro log \(id)"
                case "diff":   return "ouro diff \(id)"
                case "merge":  return "ouro merge \(id)"
                case "undo":   return "ouro undo \(id)"
                case "retry":  return "ouro retry \(id)"
                case "fix":    return "ouro accept \(id)"
                case "dismiss": return "ouro dismiss \(id)"
                default:       return "ouro ok \(id)"
                }
            }
            print("    " + Ansi.dim(hints.joined(separator: "   ·   ")))
            print("")
        }
    }

    // MARK: - ideas

    static func idea(_ args: Args) {
        var body = args.joined
        if body.isEmpty { body = readStdin() }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Out.die("usage: ouro idea \"a webhook replay tool\"")
        }
        let client = Zero0.connected()
        let request = API.CreateIdea(title: args.flag("t", "title"), body: body,
                                     project: args.flag("p", "project"),
                                     source: args.flag("source"))
        do {
            let idea: Idea = try client.post("/v1/ideas", request)
            print("  \(Out.mark()) \(Ansi.bold("noted"))  \(idea.title)")
            print("    " + Ansi.dim(idea.path))
        } catch {
            Out.die("\(error)")
        }
    }

    static func ideas(_ args: Args) {
        let client = Zero0.connected()

        // `ouro drop` already means "clear this run from the inbox", so dropping
        // an idea lives here as a subcommand rather than fighting for that verb.
        if args.positional.first == "drop", args.positional.count > 1 {
            do {
                let message: API.Message = try client.post(
                    "/v1/ideas/\(args.positional[1])/drop", as: API.Message.self)
                Out.ok(message.message)
            } catch { Out.die("\(error)") }
            return
        }

        let path = args.bool("all") ? "/v1/ideas?all=true" : "/v1/ideas"
        guard let list = try? client.get(path, as: API.IdeaList.self) else {
            Out.die("could not list ideas")
        }
        print("")
        if list.ideas.isEmpty {
            print("  " + Ansi.dim("no ideas yet — ouro idea \"…\""))
            print("")
            return
        }
        for idea in list.ideas {
            print("  \(Ansi.pad(Ansi.dim(idea.id), 16))\(Ansi.pad(Fmt.truncate(idea.title, 52), 54))"
                  + Ansi.dim(idea.projectId ?? "—") + "  " + Ansi.dim(Fmt.ago(idea.created)))
        }
        print("")
        print("  " + Ansi.dim("promote one: ouro promote <id> -p <project> [--fix]"))
        print("  " + Ansi.dim("drop one:    ouro ideas drop <id>"))
        print("")
    }

    /// The panel has `/hotkey`; the CLI has to have it too, or the GUI has a
    /// power the CLI lacks and the whole "one control plane" claim is a lie.
    static func hotkey(_ args: Args) {
        var config = Config.load()
        guard let combo = args.positional.first else {
            print("  " + Ansi.bold(config.hotkey)
                  + Ansi.dim("  (\(HotkeyCombo.describe(config.hotkey)))"))
            print("  " + Ansi.dim("set one: ouro hotkey cmd+shift+space"))
            return
        }
        guard HotkeyCombo.parse(combo) != nil else {
            Out.die("can't read '\(combo)' — try something like opt+space or cmd+shift+k")
        }
        config.hotkey = combo
        guard config.save() else { Out.die("could not write ~/.ouroboros/config.json") }
        Out.ok("capture hotkey is \(HotkeyCombo.describe(combo))")
        print("  " + Ansi.dim("takes effect next time the app launches"))
    }

    static func promote(_ args: Args) {
        guard let ideaId = args.positional.first else {
            Out.die("usage: ouro promote <idea-id> -p <project> [--fix]")
        }
        let client = Zero0.connected()
        do {
            let created: API.IssueCreated = try client.post(
                "/v1/ideas/\(ideaId)/promote",
                API.Promote(project: args.flag("p", "project"), fix: args.bool("fix")))
            Out.ok("promoted into \(created.issue.projectName) · \(created.issue.title)")
            if let run = created.run { print("    " + Ansi.dim("dispatched \(run.agent)  \(run.id)")) }
        } catch {
            Out.die("\(error)")
        }
    }

    // MARK: - projects

    /// Everything known about one run, including the conversation behind it.
    static func show(_ args: Args) {
        guard let id = args.positional.first else { Out.die("usage: ouro show <run>") }
        let client = Zero0.connected()
        guard let run = try? client.get("/v1/runs/\(id)", as: Run.self) else {
            Out.die("no such run")
        }
        print("")
        print("  \(Fmt.glyph(run.status)) \(Ansi.bold(run.title))")
        print("    " + Ansi.dim(Ansi.pad("run", 14)) + run.id)
        print("    " + Ansi.dim(Ansi.pad("project", 14)) + run.projectName)
        print("    " + Ansi.dim(Ansi.pad("agent", 14)) + run.agent)
        print("    " + Ansi.dim(Ansi.pad("status", 14)) + Fmt.status(run.status))
        if let branch = run.branch {
            print("    " + Ansi.dim(Ansi.pad("branch", 14)) + branch + Ansi.dim(" from \(run.base)"))
        }
        if let worktree = run.worktreePath {
            print("    " + Ansi.dim(Ansi.pad("worktree", 14)) + worktree)
        }
        if let session = run.sessionId {
            print("    " + Ansi.dim(Ansi.pad("conversation", 14)) + session)
            print("    " + Ansi.dim(Ansi.pad("", 14) + "reopen it: ouro resume \(run.id)"))
        } else {
            print("    " + Ansi.dim(Ansi.pad("conversation", 14) + "not recorded"))
        }
        if let note = run.note, !note.isEmpty {
            print("    " + Ansi.dim(Ansi.pad("note", 14)) + Fmt.truncate(note, 60))
        }
        print("")
    }

    /// Reopen a run's own conversation in a terminal.
    ///
    /// The daemon does the launching, not this process: the CLI may be running
    /// inside the very window you are trying to leave, and the terminal a run
    /// belongs to is the supervisor's business either way.
    static func resume(_ args: Args) {
        guard let id = args.positional.first else {
            Out.die("usage: ouro resume <run>   (ouro runs to list them)")
        }
        let client = Zero0.connected()
        do {
            let resumed: API.Resumed = try client.post("/v1/runs/\(id)/resume", ZeroClient.Empty())
            Out.ok("reopening \(Ansi.bold(resumed.runId))")
            print("    " + Ansi.dim(resumed.command))
            print("    " + Ansi.dim("in \(resumed.cwd)"))
        } catch { Out.die("\(error)") }
    }

    /// Which harnesses this machine can actually dispatch to, and which of them
    /// can be talked to again afterwards.
    static func agents(_ args: Args) {
        let client = Zero0.connected()
        guard let list = try? client.get("/v1/agents", as: API.AgentList.self) else {
            Out.die("could not read the agent list")
        }
        print("")
        print("  " + Ansi.bold("agents"))
        for agent in list.agents {
            let mark = agent.available ? Ansi.green("●") : Ansi.dim("○")
            var notes: [String] = []
            if agent.isDefault { notes.append("default") }
            if !agent.available { notes.append("not on PATH") }
            if agent.available && agent.canResume { notes.append("conversations can be reopened") }
            print("    \(mark) \(Ansi.pad(agent.name, 12))"
                  + Ansi.dim(notes.joined(separator: " · ")))
        }
        print("")
        print("  " + Ansi.dim("per project: ouro projects agent <id> <agent>   ·   "
                              + "per issue: ouro i \"…\" --fix -a codex"))
        print("")
    }

    static func projects(_ args: Args) {
        let client = Zero0.connected()
        let sub = args.positional.first

        switch sub {
        case "add":
            let raw = args.positional.count > 1 ? args.positional[1] : "."
            let path = Registry.normalize(raw == "." ? Zero0.cwd() : raw)
            do {
                let project: Project = try client.post("/v1/projects", API.RegisterProject(
                    path: path, name: args.flag("name"), autonomy: args.flag("autonomy"),
                    verifyCmd: args.flag("verify")))
                Out.ok("registered \(Ansi.bold(project.name))  \(Ansi.dim(project.path))")
                if let verify = project.verifyCmd {
                    print("    " + Ansi.dim("verify: \(verify)   (ouro projects set \(project.id) --verify \"…\")"))
                } else {
                    print("    " + Ansi.dim("no verify command guessed — set one: ouro projects set \(project.id) --verify \"swift build\""))
                }
            } catch { Out.die("\(error)") }

        case "rm", "remove":
            guard args.positional.count > 1 else { Out.die("usage: ouro projects rm <id>") }
            do {
                let message: API.Message = try client.delete("/v1/projects/\(args.positional[1])",
                                                             as: API.Message.self)
                Out.ok(message.message)
            } catch { Out.die("\(error)") }

        case "set":
            guard args.positional.count > 1 else {
                Out.die("usage: ouro projects set <id> [--verify \"swift build\"] [--autonomy auto] [--base main] [--agent codex]")
            }
            let patch = API.PatchProject(
                name: args.flag("name"), baseBranch: args.flag("base"),
                verifyCmd: args.flag("verify"), defaultAgent: args.flag("a", "agent"),
                autonomy: args.flag("autonomy"),
                maxParallel: args.flag("limit").flatMap(Int.init),
                worktreeDefault: args.has("no-worktree") ? false : nil,
                finishDefault: args.flag("finish"))
            do {
                let project: Project = try client.patch("/v1/projects/\(args.positional[1])", patch)
                Out.ok("updated \(project.name)")
                printProject(project)
            } catch { Out.die("\(error)") }

        // Curation. The capture panel's favourites, hiding and per-project
        // harness are these verbs — its menus are a second face on exactly
        // this, never a private path.
        case "favourite", "favorite", "unfavourite", "unfavorite", "hide", "unhide":
            guard args.positional.count > 1 else {
                Out.die("usage: ouro projects \(sub ?? "favourite") <id>")
            }
            let on = !(sub ?? "").hasPrefix("un")
            let hiding = (sub ?? "").hasSuffix("hide")
            do {
                let project: Project = try client.patch(
                    "/v1/projects/\(args.positional[1])",
                    hiding ? API.PatchProject(hidden: on) : API.PatchProject(favourite: on))
                if hiding {
                    Out.ok(on
                        ? "hid \(project.name) — it comes back the next time you file or fix here"
                        : "\(project.name) is back in the panel")
                } else {
                    Out.ok(on ? "pinned \(project.name)" : "unpinned \(project.name)")
                }
            } catch { Out.die("\(error)") }

        case "agent":
            guard args.positional.count > 2 else {
                Out.die("usage: ouro projects agent <id> <claude|codex|…>   (see: ouro agents)")
            }
            do {
                let project: Project = try client.patch(
                    "/v1/projects/\(args.positional[1])",
                    API.PatchProject(defaultAgent: args.positional[2]))
                Out.ok("\(project.name) now dispatches to \(project.defaultAgent ?? "the default")")
            } catch { Out.die("\(error)") }

        case "discover":
            let root = args.positional.count > 1 ? args.positional[1] : (args.flag("root") ?? "~/dev")
            do {
                let response: API.DiscoverResponse = try client.post(
                    "/v1/projects/discover", API.DiscoverRequest(root: root))
                Out.ok("found \(response.found.count) repos under \(root), registered \(response.registered.count)")
                for project in response.registered.prefix(20) {
                    print("    " + Ansi.dim(project.name))
                }
            } catch { Out.die("\(error)") }

        default:
            guard let list = try? client.get("/v1/projects", as: API.ProjectList.self) else {
                Out.die("could not list projects")
            }
            print("")
            if list.projects.isEmpty {
                print("  " + Ansi.dim("no projects — ouro projects add ."))
                print("")
                return
            }
            for project in list.projects { printProject(project) }
            print("")
        }
    }

    static func rename(_ args: Args) {
        guard args.positional.count >= 2 else {
            Out.die("usage: ouro rename <project> <new-name>")
        }
        let client = Zero0.connected()
        do {
            let project: Project = try client.patch("/v1/projects/\(args.positional[0])",
                                                    API.PatchProject(name: args.positional[1]))
            Out.ok("renamed \(Ansi.dim(args.positional[0])) → \(Ansi.bold(project.name))")
            printProject(project)
        } catch { Out.die("\(error)") }
    }

    private static func printProject(_ project: Project) {
        print("  \(Ansi.pad(Ansi.bold(project.name), 26))\(Ansi.pad(Ansi.dim(project.id), 22))"
              + Ansi.pad(project.policy.autonomy.label, 10)
              + Ansi.dim(project.verifyCmd ?? "no verify command"))
        print("    " + Ansi.dim(project.path))
    }

    // MARK: - setup

    /// The first thing a new user runs. The daemon does the scanning; this only
    /// has to leave the reader knowing what exists now and what to type next.
    static func setup(_ args: Args) {
        let client = Zero0.connected()
        let root = args.positional.first ?? args.flag("root")
        do {
            let response: API.SetupResponse = try client.post(
                "/v1/setup", API.SetupRequest(roots: root.map { [$0] }))
            Out.banner()
            Out.ok(response.message)
            print("")

            if response.registered.isEmpty {
                print("  " + Ansi.dim("nothing new under \(root ?? "your project roots")"
                                      + " — inside a repo, run: ouro projects add ."))
            } else {
                print("  " + Ansi.bold("projects")
                      + Ansi.dim("  \(response.registered.count) registered of \(response.scanned) scanned"))
                let names = response.registered.map(\.name)
                for start in stride(from: 0, to: names.count, by: 3) {
                    let row = names[start..<min(start + 3, names.count)]
                    print("    " + row.map { Ansi.pad(Fmt.truncate($0, 26), 28) }.joined())
                }
            }
            print("")

            if response.agentsAvailable.isEmpty {
                print("  " + Ansi.red("●") + " "
                      + Ansi.dim("no agent CLI on PATH — install claude or codex, then: ouro setup"))
            } else {
                print("  " + Ansi.green("●") + " "
                      + Ansi.pad("agents", 20) + Ansi.dim(response.agentsAvailable.joined(separator: "  ")))
            }
            print("")

            print("  " + Ansi.bold("next"))
            print(Ansi.pad("  ouro i \"the login button does nothing\" --fix", 48)
                  + Ansi.dim("file it and put an agent on it now"))
            print(Ansi.pad("  ouro projects set <id> --verify \"swift build\"", 48)
                  + Ansi.dim("the gate every fix has to pass"))
            print(Ansi.pad("  open -a \"Ouroboros Zero\"", 48)
                  + Ansi.dim("menu bar item + capture panel"))
            print("")
        } catch {
            Out.die("\(error)")
        }
    }

    // MARK: - new project

    /// Scaffolding lives in the daemon — the app's new-project sheet posts to
    /// this same endpoint, so there is one implementation of it rather than two.
    static func newProject(_ args: Args) {
        guard let name = args.positional.first else {
            Out.die("usage: ouro new <name> [--dir ~/dev/name] [--desc \"…\"] [--github private] [--roadmap ai] [--agent claude]")
        }
        let client = Zero0.connected()
        let request = API.CreateProject(
            name: name,
            dir: args.flag("dir"),
            description: args.flag("desc", "description"),
            github: args.flag("github"),
            roadmap: args.flag("roadmap"),
            agent: args.flag("a", "agent"))

        do {
            let created: API.ProjectCreated = try client.post("/v1/projects/create", request)
            Out.ok("created \(Ansi.bold(created.project.name))  \(Ansi.dim(created.project.path))")
            if !created.message.isEmpty { print("    " + Ansi.dim(created.message)) }

            // --verify / --autonomy are policy, not scaffolding, so the create
            // call doesn't carry them; the flags still have to work.
            if args.has("verify", "autonomy") {
                _ = try? client.patch("/v1/projects/\(created.project.id)",
                                      API.PatchProject(verifyCmd: args.flag("verify"),
                                                       autonomy: args.flag("autonomy")),
                                      as: Project.self)
            }
            print("    " + Ansi.dim("registered with ouroboros  \(created.project.id)"))

            if let run = created.run {
                Out.ok("drafting the roadmap with \(run.agent)" + Ansi.dim("  \(run.id)"))
            }
            print("")
            print("  " + Ansi.dim("cd \(created.project.path)"))
            print("  " + Ansi.dim("ouro i \"first thing to build\" --fix"))
            print("")
        } catch {
            Out.die("\(error)")
        }
    }

    // MARK: - daemon

    static func daemon(_ args: Args) {
        let sub = args.positional.first ?? "status"
        let client = Zero0.client()
        switch sub {
        case "start":
            if client.isUp { Out.ok("already running"); return }
            guard Zero0.startDaemon() else { Out.die("could not start ourod") }
            for _ in 0..<50 { if client.isUp { Out.ok("started"); return }; usleep(100_000) }
            Out.die("started but not answering")
        case "stop":
            guard client.isUp else { Out.info("not running"); return }
            _ = try? client.post("/v1/shutdown", as: API.Message.self)
            Out.ok("stopped")
        case "restart":
            if client.isUp { _ = try? client.post("/v1/shutdown", as: API.Message.self) }
            Thread.sleep(forTimeInterval: 0.6)
            _ = Zero0.startDaemon()
            for _ in 0..<50 { if client.isUp { Out.ok("restarted"); return }; usleep(100_000) }
            Out.die("did not come back")
        case "log":
            let path = Zero0.homeOverride.map { ($0 as NSString).appendingPathComponent("ourod.log") }
                ?? Paths.daemonLog
            print((try? String(contentsOfFile: path, encoding: .utf8)) ?? "(no log)")
        default:
            guard let health = try? client.get("/v1/health", as: HealthDTO.self) else {
                print("  " + Ansi.red("●") + " not running")
                return
            }
            print("  " + Ansi.green("●") + " ouroboros \(health.version)  "
                  + Ansi.dim("pid \(health.pid) · up \(Fmt.duration(health.uptime))"))
            print("    " + Ansi.dim("\(health.projects) projects · \(health.activeRuns) active · "
                                    + "\(health.queuedRuns) queued · \(health.inbox) in the inbox"))
        }
    }

    // MARK: - update

    static func update(_ args: Args) {
        let client = Zero0.connected()
        // Read the pid first: a restarted daemon answers on the same socket, so
        // "it replied" proves nothing — only a different pid does.
        let before = try? client.get("/v1/health", as: HealthDTO.self)

        let response: API.UpdateResponse
        do {
            response = try client.post("/v1/update", as: API.UpdateResponse.self)
        } catch {
            Out.die("\(error)")
        }

        let from = String(response.fromCommit.prefix(7))
        let to = String(response.toCommit.prefix(7))
        if response.ok {
            Out.ok(from == to ? "already current" + Ansi.dim("  \(to)")
                              : "updated  \(Ansi.dim(from)) → \(Ansi.bold(to))")
        } else {
            Out.err("update failed" + Ansi.dim("  \(from)"))
        }
        for line in response.message.components(separatedBy: "\n") where !line.isEmpty {
            print("    " + Ansi.dim(line))
        }
        guard response.ok else { exit(1) }

        if response.restarting {
            print("    " + Ansi.dim("the daemon is restarting on the new binaries…"))
            var health: HealthDTO?
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                if let current = try? client.get("/v1/health", as: HealthDTO.self),
                   current.ok, current.pid != before?.pid {
                    health = current
                    break
                }
            }
            if let health {
                Out.ok("back up on ouroboros \(health.version)" + Ansi.dim("  pid \(health.pid)"))
            } else {
                Out.err("it hasn't come back — check: ouro daemon log, then ouro daemon start")
            }
        }
        print("")
    }

    // MARK: - proposals

    static func proposalAction(_ action: String, _ args: Args) {
        guard let id = args.positional.first else { Out.die("usage: ouro \(action) <proposal-id>") }
        let client = Zero0.connected()
        do {
            if action == "accept" {
                let created: API.IssueCreated = try client.post("/v1/proposals/\(id)/accept",
                                                                as: API.IssueCreated.self)
                Out.ok("accepted → \(created.issue.projectName) · \(created.issue.title)")
            } else {
                let message: API.Message = try client.post("/v1/proposals/\(id)/dismiss",
                                                           as: API.Message.self)
                Out.ok(message.message)
            }
        } catch { Out.die("\(error)") }
    }

    // MARK: - helpers

    private static func finishFlag(_ args: Args) -> String? {
        if args.bool("pr") { return "pr" }
        if args.bool("merge") { return "merge" }
        if args.bool("leave") { return "leave" }
        return args.flag("finish")
    }

    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    static func readStdin() -> String {
        guard isatty(0) == 0 else { return "" }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
