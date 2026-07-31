import Foundation
import SwiftUI
import ZeroCore

/// The app's entire relationship with the system is this object, and this
/// object's entire relationship with the system is `ZeroClient`. There is no
/// path from a button in the UI to a git command that doesn't go through the
/// same API an AI operator would use.
@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: API.Snapshot?
    @Published var connected = false
    @Published var draft = ""
    @Published var selectedProjectId: String?
    @Published var status: String?
    @Published var busy = false
    /// An explicit harness pick for this capture only. Deliberately not written
    /// back to the project: choosing codex once should not silently retarget
    /// every future dispatch. The context menu changes the project default.
    @Published var agentOverride: String?
    /// The issue just filed, so the confirmation can offer verbs for it.
    @Published var lastFiled: IssueDTO?

    /// The one line of feedback the capture panel shows. See `note(_:bad:)`.
    @Published private(set) var flash: Flash?

    /// Rows acting out their own removal, and rows that have finished.
    ///
    /// Deleting used to be invisible: the row was there, and then a poll came
    /// back up to two seconds later without it. `leaving` says "play the exit";
    /// `vanished` says "don't draw this again", and hands the row back if the
    /// daemon never actually removed it. See `Vanished`.
    @Published private(set) var leaving: Set<String> = []
    @Published private(set) var vanished = Vanished()

    /// The branch a `diff` verb asked for. The capture panel puts it up as a
    /// sheet, so escape lands you back on the drawer with the same project open.
    @Published var showingDiff: DiffReport?

    /// How a row verb asks the capture panel to step aside. Set by the
    /// controller that owns that panel; nil everywhere else, because the
    /// menu-bar popover closes itself and has no window to hide.
    var dismissCapture: (() -> Void)?

    /// The capture panel's options row: worktree, finish, base. Collapsed by
    /// default so the fast path is exactly as long as it was.
    @Published var optionsOpen = false
    /// The branches of the selected project, fetched once when the options row
    /// opens. Empty until then; the menu falls back to the base it already has.
    @Published private(set) var branches: [String] = []

    private let client = ZeroClient()
    private var timer: Timer?
    private var flashToken = 0

    var projects: [Project] { snapshot?.projects ?? [] }
    var recents: [ProjectDigest] { snapshot?.recents ?? [] }
    var stats: API.Stats { snapshot?.stats ?? API.Stats() }

    /// Fold state for the capture panel's drawer. A UI preference, so it lives
    /// in UserDefaults rather than config.json, which is the daemon's contract
    /// with every client.
    var recentsExpanded: Bool {
        get {
            // Open on a machine that has never expressed a preference. A drawer
            // that defaults shut hides the work every time you open the panel,
            // and the fold is one click either way. Whatever you leave it on is
            // what you get next time, which is the only rule that matters here.
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

    /// The ring ⇥ walks in the capture panel, most recent first.
    ///
    /// The drawer's list rather than the whole registry, on purpose: tabbing
    /// through sixty projects when seven are on screen would move a selection
    /// nobody can see. `recents` is empty only before the first snapshot lands
    /// (or against a daemon too old to send them), and the registry is already
    /// sorted by last use, so the fallback is the same order minus the git half.
    var switchOrder: [String] {
        recents.isEmpty ? projects.map(\.id) : recents.map(\.id)
    }

    /// ⇥ forward, ⇧⇥ back. Silent when there is nowhere to go.
    func cycleProject(by steps: Int) {
        guard let next = ProjectCycle.step(from: selectedProject?.id,
                                           in: switchOrder, by: steps) else { return }
        selectedProjectId = next
    }

    func start() {
        refresh()
        // Cheap: a unix-socket round trip against a local process. Polling keeps
        // the panel honest without an SSE reconnect dance in the UI layer.
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
                    // A row cannot act out its own exit while the list under it
                    // is being replaced. The daemon has already deleted the
                    // issue by the time the exit starts, so the very next poll
                    // comes back without it — and dropping the row mid-fold is
                    // exactly the blink this whole change exists to remove.
                    // `vanish` owns those 400ms and refreshes at the end of
                    // them, so no snapshot is lost and nothing can stall here.
                    guard self.leaving.isEmpty else { return }
                    self.snapshot = result
                    self.forgetDeparted()
                    // Terminal runs the app has not announced yet get a toast.
                    ToastCenter.shared.observe(result.recentRuns + result.activeRuns)
                } else {
                    self.connected = false
                }
            }
        }
    }

    /// Bring the daemon up if it isn't. The user should never have to think
    /// about a background process.
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

    // MARK: - what a verb does to the panel

    /// When a row verb last ran. A context menu that closes right after one
    /// closed *because something was chosen from it* — which is not the same
    /// event as clicking away, and the panel must not confuse the two.
    private(set) var lastVerbAt = Date.distantPast

    /// Run a row verb and then do to the panel whatever that verb does to it.
    ///
    /// Every verb in the drawer goes through here, so the decision lives in
    /// `RowVerb` — one table, covered by a test — rather than in whether some
    /// menu item remembered to call `handOff`.
    func perform(_ verb: RowVerb, _ action: () -> Void) {
        lastVerbAt = Date()
        action()
        if verb.handsOff { handOff(after: verb.beat) }
    }

    /// The panel steps aside because another window is about to take the
    /// screen. `beat` is the pause that lets a confirmation be read first.
    func handOff(after beat: Double = 0) {
        guard let dismissCapture else { return }
        guard beat > 0 else { return dismissCapture() }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(beat * 1_000_000_000))
            dismissCapture()
        }
    }

    /// Leave a one-line receipt for a verb that would otherwise leave no mark —
    /// a copy, a merge the daemon does in the background, a delete that failed.
    /// It clears itself: the capture box is not a log.
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

    /// Drop the receipt now — the panel is closing, and a stale line of text
    /// should not be the first thing the next capture says.
    func clearNote() {
        flashToken &+= 1
        flash = nil
    }

    // MARK: - rows leaving

    /// Play a row's exit. Called only once the daemon has said yes, so the
    /// animation reports what happened rather than guessing at it.
    private func vanish(_ id: String) {
        // Deliberately no `withAnimation`: the row owns its own exit, and the
        // timings here only have to outlast it.
        leaving.insert(id)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)   // struck, then folded
            // In one step, so the row is never both finished leaving and still
            // freezing the snapshot: `leaving` holds `refresh` off while the
            // exit plays, and `vanished` keeps the row out of the list after.
            vanished.hide(id)
            leaving.remove(id)
            try? await Task.sleep(nanoseconds: 120_000_000)
            refresh()
        }
    }

    /// Put the hidden rows back in line with what the daemon says exists —
    /// including handing one back if it turns out to still be there.
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

    /// The projects the drawer draws: what the daemon lists, minus anything
    /// whose exit has already finished playing.
    var visibleRecents: [ProjectDigest] { vanished.visible(recents) }

    /// The same, for one project's work.
    func issues(of digest: ProjectDigest) -> [IssuePip] { vanished.visible(digest.issues) }

    /// What an opened project draws, which is its work minus whatever the group
    /// at the top of the drawer has already lifted out of it.
    ///
    /// Lifting a row out means taking it out. Drawing it in both places puts the
    /// same sentence on screen twice, two inches apart, and then the group is
    /// not a summary of anything — it is a duplicate you have to learn to skip.
    func remainingIssues(of digest: ProjectDigest) -> [IssuePip] {
        let lifted = Set(waitingOnYou.map(\.id))
        return issues(of: digest).filter { !lifted.contains($0.id) }
    }

    /// The `n filed` on the project row, dropped by hand for the ones already
    /// deleted — a row that still says 3 over two issues is the same lie the
    /// delayed poll used to tell.
    func openCount(of digest: ProjectDigest) -> Int {
        let gone = digest.issues.filter { $0.state == .filed && vanished.contains($0.id) }
        return max(0, digest.openCount - gone.count)
    }

    // MARK: - what needs you, across every project

    /// One row of the group at the top of the drawer.
    struct Waiting: Identifiable {
        var pip: IssuePip
        var project: String
        var id: String { pip.id }
    }

    /// Every piece of work waiting on a person, across all projects.
    ///
    /// Read off the inbox, which is `Inbox.build` — the same function `ouro
    /// inbox` prints — so the drawer and the CLI cannot come to different
    /// conclusions about what is waiting. The digests supply the row itself,
    /// because an inbox item is a decision and a row is an object you can act
    /// on, and this group has to be both.
    var waitingOnYou: [Waiting] {
        var byRun: [String: Waiting] = [:]
        for digest in visibleRecents {
            for pip in issues(of: digest) {
                guard let runId = pip.runId else { continue }
                byRun[runId] = Waiting(pip: pip, project: digest.name)
            }
        }
        // `merged` is a receipt and `failed` is a pile that never empties;
        // neither is a thing standing between you and a decision. What is left
        // is the question, the review, and the review that will not go in.
        return inbox.compactMap { item -> Waiting? in
            guard item.kind == .question || item.kind == .review else { return nil }
            guard let runId = item.runId else { return nil }
            if let known = byRun[runId] { return known }
            // In the inbox but not in the drawer: the project fell off the
            // recents list, which is a display cap and not a reason to hide
            // something waiting on you. Build the row from the run itself.
            guard let run = run(runId) else { return nil }
            return Waiting(pip: IssuePip(id: run.id, title: run.title,
                                         state: WorkState.of(run),
                                         at: run.endedAt ?? run.queuedAt,
                                         path: run.issuePath, runId: run.id,
                                         agent: run.agent),
                           project: run.projectName)
        }
    }

    // MARK: - actions

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
                    // Filing used to end here, with a line of text and nothing to
                    // do about it. Holding the issue means the confirmation can
                    // offer fix / open / undo on the thing you just made.
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

    /// Delete the issue this capture just wrote. Offered only for that issue and
    /// only while its confirmation is up, so undo can never hit anything else.
    func undoLastFiled() {
        guard let issue = lastFiled else { return }
        lastFiled = nil
        status = "undone"
        deleteIssue(issue.id)
    }

    func runAction(_ action: String, runId: String, answer: String? = nil) {
        busy = true
        Task.detached { [client] in
            switch action {
            case "reply":
                _ = try? client.post("/v1/runs/\(runId)/reply",
                                     API.Reply(answer: answer ?? ""), as: Run.self)
            case "merge":
                _ = try? client.post("/v1/runs/\(runId)/merge", as: Run.self)
            case "undo":
                _ = try? client.post("/v1/runs/\(runId)/undo", as: API.Message.self)
            case "retry":
                _ = try? client.post("/v1/runs/\(runId)/retry", as: Run.self)
            case "stop":
                _ = try? client.post("/v1/runs/\(runId)/stop", as: Run.self)
            default:
                _ = try? client.post("/v1/runs/\(runId)/ack", as: API.Message.self)
            }
            await MainActor.run { [weak self] in
                self?.busy = false
                self?.refresh()
            }
        }
    }

    func proposalAction(_ action: String, id: String) {
        Task.detached { [client] in
            _ = try? client.post("/v1/proposals/\(id)/\(action)", as: API.IssueCreated.self)
            await MainActor.run { [weak self] in self?.refresh() }
        }
    }

    // MARK: - row verbs
    //
    // Every one of these is an HTTP call the CLI could make. The drawer's
    // context menus are a second face on the same API, never a private path.

    /// Only harnesses actually installed. Offering a choice the machine cannot
    /// honour is worse than offering none.
    var availableAgents: [String] {
        let installed = (snapshot?.agents ?? []).filter(\.available).map(\.name)
        return installed.isEmpty ? [snapshot?.health.version != nil ? "claude" : "claude"] : installed
    }

    /// The full run behind a digest's pip. The drawer shows compressed shapes;
    /// its verbs need the real record.
    func run(_ id: String) -> Run? {
        (activeRuns + recentRuns).first { $0.id == id }
    }

    /// The machine-wide default, so a row only calls out a harness when it is
    /// the exception rather than the rule.
    var globalDefaultAgent: String {
        (snapshot?.agents ?? []).first(where: \.isDefault)?.name ?? "claude"
    }

    /// The agent this capture will dispatch to: an explicit pick for this
    /// capture, else the target project's default, else the global default.
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

    /// Hiding and forgetting both take a row off the drawer, so both wait for
    /// the daemon and then let the row leave on screen. A failure says so
    /// instead of playing an exit for something that is still there.
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

    /// The round trip is a unix socket to a process on this machine — a few
    /// milliseconds — so waiting for it costs nothing and buys the difference
    /// between an animation that reports a deletion and one that predicts it.
    func deleteIssue(_ issueId: String) {
        Task { [client] in
            let ok = await Task.detached {
                (try? client.delete("/v1/issues/\(issueId)", as: ZeroClient.Empty.self)) != nil
            }.value
            guard ok else { return note("could not delete that one", bad: true) }
            vanish(issueId)
        }
    }

    /// One verb for "put me in front of this": reopen the conversation an agent
    /// already had about it, or start one if it never had. Naming a harness
    /// always means "start a fresh one with that harness".
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

    /// Confirmed done: the issue moves to `.issues/done` and the run behind it
    /// leaves the inbox. Two calls because they are two separate facts, and the
    /// same pair `ouro done` makes.
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

    /// The log and the diff-as-text are commands to paste, not windows to open —
    /// which is exactly why they leave the panel up and say what they did.
    private func copyCommand(_ command: String) {
        RowActions.copy(command)
        status = "copied: \(command)"
        note("copied: \(command)")
    }

    /// The run's log, live, in a terminal of its own — `ouro log <run> -f`, the
    /// product's own verb rather than anything this app knows how to do.
    func watchRun(_ runId: String) {
        Task.detached {
            Shell.run(["/Applications/Ghostty.app/Contents/MacOS/ghostty",
                       "--title=ouro log", "-e", "zsh", "-lc",
                       "ouro log \(Shell.quote(runId)) -f"], login: true)
        }
    }

    /// Answering is a sentence, and there is a field for sentences right here.
    /// The verb loads `/reply <run>` into it rather than opening a second box
    /// to type in, so ⏎ sends it down the same slash-command path the CLI uses.
    func startReply(to runId: String) {
        draft = "/reply \(runId) "
        note("type the answer, then ⏎")
    }

    /// Put the branch back on top of its base, so a run whose verdict came back
    /// `conflicts` has somewhere to go that is not a merge known to fail.
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

    /// Send the agent that wrote the branch back to it, with the conflict as
    /// its first message. `POST /v1/runs/:id/resolve` and nothing else — the
    /// panel has no idea how to resume a conversation, and must not learn.
    func resolveRun(_ runId: String) {
        note("sending it back…")
        Task { [client] in
            let next = await Task.detached {
                try? client.post("/v1/runs/\(runId)/resolve", as: Run.self)
            }.value
            // The daemon refuses with the reason — nothing to resolve, no
            // conversation to reopen — so a silent nil is the only case left.
            guard let next else { return note("could not send that one back", bad: true) }
            note(next.resumeMode == "fresh"
                 ? "a fresh \(next.agent) is reading the branch"
                 : "\(next.agent) is back on \(next.branch ?? "its branch")")
            refresh()
        }
    }

    /// Let a spent branch go. The daemon refuses unless it has checked there is
    /// nothing on it, so this button cannot throw work away.
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

    /// What the agent actually did, as data. Presented as a sheet on the
    /// capture panel, so escape puts the drawer back exactly as it was.
    func openDiff(_ runId: String) {
        Task { [client] in
            let report = await Task.detached {
                try? client.get("/v1/runs/\(runId)/diff", as: DiffReport.self)
            }.value
            guard let report else { return note("no diff for that one", bad: true) }
            showingDiff = report
        }
    }

    // MARK: - dispatch options

    /// Read the branches of the project the capture is aimed at, once, when the
    /// options row opens. Cheap, and it means `base` is a list to pick from
    /// rather than a name you have to spell.
    func loadBranches() {
        guard let project = selectedProject else { return }
        Task { [client] in
            let list = await Task.detached {
                try? client.get("/v1/projects/\(project.id)/branches", as: API.BranchList.self)
            }.value
            branches = list?.branches ?? []
        }
    }

    /// The options are the project's own defaults, so they are remembered where
    /// every other face of the product can already read them: on the project.
    /// The next capture into it inherits the answer, which is the point — this
    /// is a property of the project, not of the moment.
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

    /// Hand a path to whatever app owns it. Paired with `RowVerb.handsOff`,
    /// which is what gets the panel out of that app's way.
    func open(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openTerminal(at path: String) {
        Task.detached {
            Shell.run(["open", "-a", "Ghostty", path], login: true)
        }
    }

    /// `claude agents` is a fleet view of your OWN background sessions in a
    /// repo. Ouroboros owns its supervised runs and does not hand them over, so
    /// this is offered per project rather than per run.
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

/// One line of feedback in the capture panel: what a verb did, or why it
/// couldn't. See `AppModel.note(_:bad:)`.
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
    /// Colour carries urgency, not category: orange is moving, blue is waiting
    /// on you, red went wrong, green landed. Everything else stays grey so the
    /// three that matter are the three you see.
    var tint: Color {
        switch self {
        case .filed, .stopped: return .secondary
        case .queued:   return Color.secondary
        case .running:  return Color(red: 1.0, green: 0.48, blue: 0.09)
        case .asking:   return Color(red: 1.0, green: 0.74, blue: 0.18)
        case .review:   return Color(red: 0.47, green: 0.67, blue: 1.0)
        case .merged:   return Color(red: 0.49, green: 0.85, blue: 0.34)
        // Nothing went wrong: the work arrived by another road. Grey, because a
        // colour here would be the panel raising its voice about housekeeping.
        case .obsolete: return .secondary
        // Tinted like the failure it is. A branch that will not go in is not a
        // milder kind of review, it is work that has to be done again.
        case .conflicts, .failed: return Color(red: 1.0, green: 0.37, blue: 0.34)
        }
    }

    /// Filed is the one state that is an absence of work rather than a kind of
    /// it, so it is the one drawn hollow. `obsolete` joins it: the branch is
    /// still there, but there is nothing inside it.
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
