import SwiftUI
import AppKit
import ZeroCore

struct WizardRequest: Identifiable {
    enum Kind { case add, new }
    let id = UUID()
    let kind: Kind
    let prefill: String?
}

@MainActor
final class SlashRunner: ObservableObject {
    @Published var status: String?

    @Published var wizard: WizardRequest?

    @Published var working = false

    @Published var startedAt: Date?

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func run(_ input: String) async -> Bool {
        guard let parsed = SlashCommands.parse(input) else { return false }
        working = true
        startedAt = Date()
        defer { working = false; startedAt = nil }
        await execute(parsed.command, args: parsed.args)
        return true
    }

    private func execute(_ command: SlashCommand, args: [String]) async {
        let rest = args.joined(separator: " ")

        switch command.name {
        case "add":      await addProject(rest)
        case "new":      await newProject(args)
        case "project":  selectProject(rest)
        case "open":     openProject(rest)

        case "fix":      await dispatchFix(rest)
        case "idea":     await parkIdea(rest)
        case "promote":  await promoteIdea(rest)
        case "task":     await dispatchTask(rest)

        case "issues":   await listIssues(rest)
        case "inbox":    await showInbox()
        case "runs":     await showRuns()

        case "reply":    await replyToRun(args)
        case "merge":    await mergeRun(rest)
        case "retry":    await retryRun(rest)
        case "undo":     await undoRun(rest)
        case "stop":     await stopRun(rest)

        case "rename":   await renameProject(args)
        case "verify":   await setVerify(rest)
        case "autonomy": await setAutonomy(rest)
        case "agent":    await setAgent(rest)
        case "finish":   await setFinish(rest)
        case "discover": await discover(rest)
        case "forget":   await forgetProject(rest)

        case "setup":    await setup(args)
        case "update":   await selfUpdate()
        case "rebuild":  await rebuildFromSource()
        case "hotkey":   await setHotkey(rest)
        case "health":   await showHealth()
        case "help":     showHelp()
        case "quit":     NSApplication.shared.terminate(nil)

        default:         report("\(command.name) isn't wired up yet")
        }
    }

    private func addProject(_ rawPath: String) async {
        guard !rawPath.isEmpty else {
            wizard = WizardRequest(kind: .add, prefill: nil)
            return
        }
        let expanded = (rawPath as NSString).expandingTildeInPath

        let name = SlashCommands.projectName(forPath: expanded)
        let path = Registry.normalize(expanded)
        guard isDirectory(path) else {
            report("no directory at \(tildeify(path)) — /new scaffolds a new one")
            return
        }
        let reply = await Wire.post("/v1/projects",
                                    API.RegisterProject(path: path, name: name),
                                    as: Project.self)
        guard let project = reply.value else { report(reply.text); return }
        adopt(project, saying: "registered \(project.name) · \(tildeify(project.path))")
    }

    private func newProject(_ args: [String]) async {
        guard let name = args.first, !name.isEmpty else {
            wizard = WizardRequest(kind: .new, prefill: nil)
            return
        }

        let description = args.dropFirst().joined(separator: " ")
        report("scaffolding \(name)…")
        let reply = await Wire.post("/v1/projects/create",
                                    API.CreateProject(name: name,
                                                      description: description.isEmpty ? nil : description),
                                    as: API.ProjectCreated.self)
        guard let created = reply.value else { report(reply.text); return }
        adopt(created.project, saying: created.message)
    }

    private func selectProject(_ needle: String) {
        guard !needle.isEmpty else {
            report(model.projects.isEmpty
                   ? "no projects yet — /add <path> or /setup"
                   : "projects: " + model.projects.map(\.name).joined(separator: " "))
            return
        }
        guard let project = resolve(needle) else { report(noMatch(needle)); return }
        model.selectedProjectId = project.id
        report("capturing into \(project.name)")
    }

    private func openProject(_ needle: String) {
        let project = needle.isEmpty ? model.selectedProject : resolve(needle)
        guard let project else { report(needle.isEmpty ? "no project selected" : noMatch(needle)); return }
        model.openInFinder(project)
        report("opened \(tildeify(project.path))")
    }

    private func renameProject(_ args: [String]) async {
        guard args.count >= 2 else { report("usage: /rename <old> <new>"); return }
        guard let project = resolve(args[0]) else { report(noMatch(args[0])); return }
        let newName = args.dropFirst().joined(separator: " ")
        guard let updated = await patch(project, API.PatchProject(name: newName)) else { return }
        report("renamed \(project.name) → \(updated.name)")
    }

    private func forgetProject(_ needle: String) async {
        guard !needle.isEmpty else { report("usage: /forget <project>"); return }
        guard let project = resolve(needle) else { report(noMatch(needle)); return }
        let reply = await Wire.delete("/v1/projects/\(project.id)", as: API.Message.self)
        guard let message = reply.value else { report(reply.text); return }
        if model.selectedProjectId == project.id { model.selectedProjectId = nil }
        report(message.message)
        model.refresh()
    }

    private func discover(_ rawRoot: String) async {
        let root = rawRoot.isEmpty ? await Wire.offMain({ Config.load().projectsRoot }) : rawRoot
        report("scanning \(root)…")
        let reply = await Wire.post("/v1/projects/discover", API.DiscoverRequest(root: root),
                                    as: API.DiscoverResponse.self)
        guard let response = reply.value else { report(reply.text); return }
        report("found \(response.found.count) repos under \(root) · registered \(response.registered.count)")
        model.refresh()
    }

    private func setVerify(_ command: String) async {
        guard let project = requireProject() else { return }
        guard !command.isEmpty else {
            report(project.verifyCmd.map { "\(project.name) verifies with: \($0)" }
                   ?? "\(project.name) has no verify command — nothing gates a merge")
            return
        }
        guard let updated = await patch(project, API.PatchProject(verifyCmd: command)) else { return }
        report("\(updated.name) verifies with: \(command)")
    }

    private func setAutonomy(_ raw: String) async {
        guard let project = requireProject() else { return }
        guard !raw.isEmpty else {
            report("\(project.name) is on \(project.policy.autonomy.label)")
            return
        }
        guard Autonomy(rawValue: raw.lowercased()) != nil else {
            report("autonomy is manual, assist or auto")
            return
        }
        guard let updated = await patch(project, API.PatchProject(autonomy: raw.lowercased())) else { return }
        report("\(updated.name) → \(updated.policy.autonomy.label)")
    }

    private func setAgent(_ name: String) async {
        guard let project = requireProject() else { return }
        guard !name.isEmpty else {
            report("\(project.name) uses \(project.defaultAgent ?? "the default harness")")
            return
        }
        guard let updated = await patch(project, API.PatchProject(defaultAgent: name)) else { return }
        report("\(updated.name) → \(name)")
    }

    private func setFinish(_ raw: String) async {
        guard let project = requireProject() else { return }
        guard !raw.isEmpty else {
            report("\(project.name) finishes with \(project.policy.finishDefault.rawValue)")
            return
        }
        guard Finish(rawValue: raw.lowercased()) != nil else {
            report("finish is merge, pr or leave")
            return
        }
        guard let updated = await patch(project, API.PatchProject(finishDefault: raw.lowercased())) else { return }
        report("\(updated.name) finishes with \(updated.policy.finishDefault.rawValue)")
    }

    private func dispatchFix(_ rawId: String) async {
        var issueId = rawId
        if issueId.isEmpty {
            guard let project = requireProject() else { return }
            let reply = await Wire.get("/v1/issues?status=new&project=\(escape(project.id))",
                                       as: API.IssueList.self)
            let open = (reply.value?.issues ?? []).sorted {
                ($0.created ?? .distantPast) > ($1.created ?? .distantPast)
            }
            guard let newest = open.first else {
                report("no open issues in \(project.name) — describe one instead")
                return
            }
            issueId = newest.id
        }
        let reply = await Wire.post("/v1/issues/\(issueId)/fix", API.FixRequest(), as: Run.self)
        guard let run = reply.value else { report(reply.text); return }
        report("dispatched \(run.agent) · \(run.title)")
        model.refresh()
    }

    private func dispatchTask(_ prompt: String) async {
        guard let project = requireProject() else { return }
        guard !prompt.isEmpty else { report("usage: /task <what the agent should do>"); return }
        let reply = await Wire.post("/v1/runs", API.Freeform(project: project.id, prompt: prompt),
                                    as: Run.self)
        guard let run = reply.value else { report(reply.text); return }
        report("dispatched \(run.agent) · \(run.title)")
        model.refresh()
    }

    private func parkIdea(_ text: String) async {
        guard !text.isEmpty else {
            let reply = await Wire.get("/v1/ideas", as: API.IdeaList.self)
            guard let ideas = reply.value?.ideas else { report(reply.text); return }
            report(ideas.isEmpty
                   ? "nothing parked — /idea <text>"
                   : "\(ideas.count) parked · " + ideas.prefix(3).map(\.title).joined(separator: " · "))
            return
        }
        let reply = await Wire.post("/v1/ideas",
                                    API.CreateIdea(body: text, project: model.selectedProject?.id),
                                    as: Idea.self)
        guard let idea = reply.value else { report(reply.text); return }
        report("noted · \(idea.title)")
    }

    private func promoteIdea(_ rawId: String) async {
        var ideaId = rawId
        if ideaId.isEmpty {
            let reply = await Wire.get("/v1/ideas", as: API.IdeaList.self)
            guard let newest = reply.value?.ideas.first else { report("nothing parked to promote"); return }
            ideaId = newest.id
        }
        let reply = await Wire.post("/v1/ideas/\(ideaId)/promote",
                                    API.Promote(project: model.selectedProject?.id),
                                    as: API.IssueCreated.self)
        guard let created = reply.value else { report(reply.text); return }
        report("promoted into \(created.issue.projectName) · \(created.issue.title)")
        model.refresh()
    }

    private func replyToRun(_ args: [String]) async {
        var runId = ""
        var words = args

        if let first = args.first, first.hasPrefix("r-") {
            runId = first
            words = Array(args.dropFirst())
        }
        let answer = words.joined(separator: " ")
        guard !answer.isEmpty else { report("usage: /reply [run] <your answer>"); return }
        guard let id = await resolveRun(runId, kind: .question) else {
            report("no agent is waiting on a question")
            return
        }
        let reply = await Wire.post("/v1/runs/\(id)/reply", API.Reply(answer: answer), as: Run.self)
        guard let run = reply.value else { report(reply.text); return }
        report("answered · \(run.agent) picked it back up")
        model.refresh()
    }

    private func mergeRun(_ rawId: String) async {
        guard let id = await resolveRun(rawId, kind: .review) else {
            report("nothing is verified and waiting to merge")
            return
        }
        let reply = await Wire.post("/v1/runs/\(id)/merge", as: Run.self)
        guard let run = reply.value else { report(reply.text); return }
        report("merged · \(run.title)")
        model.refresh()
    }

    private func retryRun(_ rawId: String) async {
        guard let id = await resolveRun(rawId, kind: .failed) else {
            report("nothing failed to retry")
            return
        }
        let reply = await Wire.post("/v1/runs/\(id)/retry", as: Run.self)
        guard let run = reply.value else { report(reply.text); return }
        report("retrying with \(run.agent) · \(run.title)")
        model.refresh()
    }

    private func undoRun(_ rawId: String) async {
        guard let id = await resolveRun(rawId, kind: .merged) else {
            report("nothing merged recently to undo")
            return
        }
        let reply = await Wire.post("/v1/runs/\(id)/undo", as: API.Message.self)
        guard let message = reply.value else { report(reply.text); return }
        report(message.message)
        model.refresh()
    }

    private func stopRun(_ rawId: String) async {
        let id = rawId.isEmpty ? model.activeRuns.first?.id : rawId
        guard let id else { report("nothing in flight"); return }
        let reply = await Wire.post("/v1/runs/\(id)/stop", as: Run.self)
        guard let run = reply.value else { report(reply.text); return }
        report("stopped · \(run.title)")
        model.refresh()
    }

    private func listIssues(_ needle: String) async {
        let project = needle.isEmpty ? model.selectedProject : resolve(needle)
        if !needle.isEmpty && project == nil { report(noMatch(needle)); return }
        var path = "/v1/issues?status=new"
        if let project { path += "&project=\(escape(project.id))" }
        let reply = await Wire.get(path, as: API.IssueList.self)
        guard let issues = reply.value?.issues else { report(reply.text); return }
        let scope = project.map { " in \($0.name)" } ?? ""
        guard !issues.isEmpty else { report("no open issues\(scope)"); return }
        let newest = issues.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        report("\(issues.count) open\(scope) · "
               + newest.prefix(3).map(\.title).joined(separator: " · "))
    }

    private func showInbox() async {
        let reply = await Wire.get("/v1/inbox", as: API.InboxList.self)
        guard let items = reply.value?.items else { report(reply.text); return }
        guard !items.isEmpty else { report("inbox is empty"); return }
        let head = items.prefix(3).map { "\($0.label) \($0.title)" }.joined(separator: " · ")
        report("\(items.count) needs you · \(head)")
    }

    private func showRuns() async {
        let reply = await Wire.get("/v1/runs?status=active&limit=20", as: API.RunList.self)
        guard let runs = reply.value?.runs else { report(reply.text); return }
        guard !runs.isEmpty else { report("nothing in flight"); return }
        let head = runs.prefix(3).map { "\($0.status.label) \($0.projectName)/\($0.title)" }
            .joined(separator: " · ")
        report("\(runs.count) in flight · \(head)")
    }

    private func showHealth() async {
        let reply = await Wire.get("/v1/health", as: HealthDTO.self)
        guard let health = reply.value else { report(reply.text); return }
        report("ourod \(health.version) · \(health.projects) projects · \(health.activeRuns) running"
               + " · \(health.queuedRuns) queued · \(health.inbox) needs you")
    }

    private func showHelp() {
        report("\(SlashCommands.all.count) commands · type / to browse them · "
               + SlashCommands.all.map { "/" + $0.name }.joined(separator: " "))
    }

    private func setup(_ roots: [String]) async {
        report("scanning for projects…")
        let reply = await Wire.post("/v1/setup", API.SetupRequest(roots: roots.isEmpty ? nil : roots),
                                    as: API.SetupResponse.self)
        guard let response = reply.value else { report(reply.text); return }
        report(response.message)
        model.refresh()
    }

    private func selfUpdate() async {
        report("pulling and rebuilding — this takes a minute…")
        let reply = await Wire.post("/v1/update", as: API.UpdateResponse.self)
        guard let response = reply.value else { report(reply.text); return }
        guard response.restarting else {
            report(response.message)
            model.refresh()
            return
        }

        report("\(response.message) — restarting the app…")
        try? await Task.sleep(nanoseconds: 700_000_000)
        SlashRunner.relaunchApp()
    }

    static func relaunchApp() {
        guard let repo = Config.load().repoPath ?? Registry().find("ouroboros")?.path else {
            NSApplication.shared.terminate(nil)
            return
        }
        let app = ((repo as NSString).appendingPathComponent("zero") as NSString)
            .appendingPathComponent("build/Ouroboros Zero.app")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "sleep 1; open -g \(Shell.quote(app))"]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    private func rebuildFromSource() async {
        report("rebuilding from source…")
        let ok = await Wire.offMain({ () -> Bool in
            guard let repo = Config.load().repoPath
                ?? Registry().find("ouroboros")?.path else { return false }
            let zero = (repo as NSString).appendingPathComponent("zero")
            let build = Shell.runLine("make install", cwd: zero, timeout: 900)
            guard build.ok else { return false }

            let app = (zero as NSString).appendingPathComponent("build/Ouroboros Zero.app")
            let relaunch = "sleep 1; open -g \(Shell.quote(app))"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", relaunch]
            try? process.run()
            return true
        })

        guard ok else {
            report("rebuild failed — run `make install` in zero/ to see why")
            return
        }
        report("rebuilt. restarting into it…")
        try? await Task.sleep(nanoseconds: 900_000_000)
        NSApplication.shared.terminate(nil)
    }

    private func setHotkey(_ raw: String) async {
        let combo = raw.lowercased().replacingOccurrences(of: " ", with: "")
        guard !combo.isEmpty else {
            let current = await Wire.offMain({ Config.load().hotkey })
            report("capture hotkey is \(current) — /hotkey cmd+shift+space to change it")
            return
        }

        let saved = await Wire.offMain({ () -> Bool in
            var config = Config.load()
            config.hotkey = combo
            return config.save()
        })
        report(saved
               ? "hotkey set to \(combo) — it takes effect the next time the app launches"
               : "could not write ~/.ouroboros/config.json")
    }

    private func report(_ text: String) {
        status = text
        model.status = text
    }

    private func adopt(_ project: Project, saying text: String) {
        model.selectedProjectId = project.id
        report(text)
        model.refresh()
    }

    private func requireProject() -> Project? {
        guard let project = model.selectedProject else {
            report("no project yet — /add <path> or /setup")
            return nil
        }
        return project
    }

    private func patch(_ project: Project, _ body: API.PatchProject) async -> Project? {
        let reply = await Wire.patch("/v1/projects/\(project.id)", body, as: Project.self)
        guard let updated = reply.value else { report(reply.text); return nil }
        model.refresh()
        return updated
    }

    private func resolveRun(_ rawId: String, kind: InboxItem.Kind) async -> String? {
        guard rawId.isEmpty else { return rawId }
        let reply = await Wire.get("/v1/inbox", as: API.InboxList.self)
        let items = reply.value?.items ?? []
        return items.first(where: { $0.kind == kind && $0.runId != nil })?.runId
    }

    private func resolve(_ needle: String) -> Project? {
        let key = needle.lowercased()
        let projects = model.projects
        if let exact = projects.first(where: { $0.id.lowercased() == key }) { return exact }
        if let byName = projects.first(where: { $0.name.lowercased() == key }) { return byName }
        let matches = projects.filter {
            $0.id.lowercased().hasPrefix(key) || $0.name.lowercased().hasPrefix(key)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func noMatch(_ needle: String) -> String {
        "no project matching \(needle)"
    }
}

struct SlashPalette: View {
    let matches: [SlashCommand]
    let selection: Int

    init(matches: [SlashCommand], selection: Int) {
        self.matches = matches
        self.selection = selection
    }

    private static let visible = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.prefix(SlashPalette.visible).enumerated()), id: \.element.name) { index, command in
                row(command, selected: index == selection)
            }
            if matches.count > SlashPalette.visible {
                Text("+\(matches.count - SlashPalette.visible) more")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 6)
            }
        }
        .padding(.vertical, 4)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(ouroOrange.opacity(0.22), lineWidth: 1))
    }

    private func row(_ command: SlashCommand, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Text("/" + command.name)
                .font(.system(size: 12, weight: selected ? .semibold : .regular, design: .rounded))
                .foregroundStyle(selected ? ouroOrange : Color.primary)
            if !command.argHint.isEmpty {
                Text(command.argHint)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 14)
            Text(command.summary)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(selected ? ouroOrange.opacity(0.14) : Color.clear)
    }
}

struct ProjectWizardSheet: View {
    let request: WizardRequest
    @ObservedObject var model: AppModel
    var onClose: () -> Void

    @State private var name = ""
    @State private var directory = ""
    @State private var desc = ""
    @State private var github = "none"
    @State private var roadmap = false
    @State private var projectsRoot = "~/dev"

    @State private var nameEdited = false
    @State private var dirEdited = false
    @State private var working = false
    @State private var problem: String?

    init(request: WizardRequest, model: AppModel, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _model = ObservedObject(wrappedValue: model)
        _name = State(initialValue: request.kind == .new ? (request.prefill ?? "") : "")
        _directory = State(initialValue: request.kind == .add ? (request.prefill ?? "") : "")
    }

    private var isAdd: Bool { request.kind == .add }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isAdd ? "Add a project" : "New project")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(isAdd
                     ? "adopt a directory that already exists"
                     : "scaffold a directory that doesn't exist yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if isAdd { addFields } else { newFields }

            if let problem {
                Text(problem)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 1.0, green: 0.37, blue: 0.34))
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(working ? "Working…" : (isAdd ? "Add project" : "Create project")) {
                    Task { await submit() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(ouroOrange)
                .disabled(working || primaryFieldIsEmpty)
            }
            .font(.system(size: 11))
        }
        .padding(18)
        .frame(width: 460)
        .background(.regularMaterial)

        .task {
            let root = await Wire.offMain({ Config.load().projectsRoot })
            await MainActor.run {
                projectsRoot = root
                if !isAdd && !dirEdited { directory = suggestedDir(for: name) }
            }
        }
    }

    private var primaryFieldIsEmpty: Bool {
        isAdd
            ? directory.trimmingCharacters(in: .whitespaces).isEmpty
            : name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var addFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Directory") {
                HStack(spacing: 6) {
                    TextField("~/dev/acme", text: directoryBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button("Choose…") { choose() }
                        .font(.system(size: 11))
                }
            }
            field("Name") {
                TextField("Acme", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
    }

    private var newFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Name") {
                TextField("acme", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            field("Directory") {
                HStack(spacing: 6) {
                    TextField(suggestedDir(for: "name"), text: directoryBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button("Choose…") { choose() }
                        .font(.system(size: 11))
                }
            }
            field("What it is") {
                TextField("a semantic search engine for…", text: $desc)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            field("GitHub") {
                Picker("", selection: $github) {
                    Text("none").tag("none")
                    Text("public").tag("public")
                    Text("private").tag("private")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .font(.system(size: 11))
            }
            field("Roadmap") {
                Toggle(isOn: $roadmap) {
                    Text("AI-drafted roadmap")
                        .font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
            content()
        }
    }

    private var directoryBinding: Binding<String> {
        Binding(get: { directory },
                set: { typed in
                    if typed != directory && !isAdd { dirEdited = true }
                    directory = typed
                    if isAdd && !nameEdited {
                        name = SlashCommands.projectName(
                            forPath: (typed as NSString).expandingTildeInPath)
                    }
                })
    }

    private var nameBinding: Binding<String> {
        Binding(get: { name },
                set: { typed in
                    if typed != name { nameEdited = true }
                    name = typed
                    if !isAdd && !dirEdited { directory = suggestedDir(for: typed) }
                })
    }

    private func suggestedDir(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (projectsRoot as NSString).appendingPathComponent(trimmed)
    }

    @MainActor
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = !isAdd
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directoryBinding.wrappedValue = url.path
    }

    @MainActor
    private func submit() async {
        problem = nil
        working = true
        defer { working = false }
        if isAdd { await addExisting() } else { await createNew() }
    }

    @MainActor
    private func addExisting() async {
        let raw = (directory.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        let path = Registry.normalize(raw)
        guard isDirectory(path) else {
            problem = "there is no directory at \(tildeify(path)) — use /new to scaffold one"
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let reply = await Wire.post("/v1/projects",
                                    API.RegisterProject(path: path,
                                                        name: trimmed.isEmpty ? nil : trimmed),
                                    as: Project.self)
        guard let project = reply.value else { problem = reply.text; return }
        finish(project, saying: "registered \(project.name) · \(tildeify(project.path))")
    }

    @MainActor
    private func createNew() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let dir = directory.trimmingCharacters(in: .whitespaces)
        let body = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = await Wire.post("/v1/projects/create",
                                    API.CreateProject(name: trimmed,
                                                      dir: dir.isEmpty ? nil : dir,
                                                      description: body.isEmpty ? nil : body,
                                                      github: github == "none" ? nil : github,
                                                      roadmap: roadmap ? "ai" : nil),
                                    as: API.ProjectCreated.self)
        guard let created = reply.value else { problem = reply.text; return }
        finish(created.project, saying: created.message)
    }

    @MainActor
    private func finish(_ project: Project, saying text: String) {
        model.selectedProjectId = project.id
        model.status = text
        model.refresh()
        onClose()
    }
}

private enum Wire {
    static let client = ZeroClient()

    static func get<R: Decodable & Sendable>(_ path: String, as type: R.Type) async -> Reply<R> {
        await perform { try $0.get(path, as: R.self) }
    }

    static func post<B: Encodable & Sendable, R: Decodable & Sendable>(
        _ path: String, _ body: B, as type: R.Type) async -> Reply<R> {
        await perform { try $0.post(path, body, as: R.self) }
    }

    static func post<R: Decodable & Sendable>(_ path: String, as type: R.Type) async -> Reply<R> {
        await perform { try $0.post(path, as: R.self) }
    }

    static func patch<B: Encodable & Sendable, R: Decodable & Sendable>(
        _ path: String, _ body: B, as type: R.Type) async -> Reply<R> {
        await perform { try $0.patch(path, body, as: R.self) }
    }

    static func delete<R: Decodable & Sendable>(_ path: String, as type: R.Type) async -> Reply<R> {
        await perform { try $0.delete(path, as: R.self) }
    }

    static func offMain<R: Sendable>(_ work: @escaping @Sendable () -> R) async -> R {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    private static func perform<R: Sendable>(
        _ work: @escaping @Sendable (ZeroClient) throws -> R) async -> Reply<R> {
        await Task.detached(priority: .userInitiated) { () -> Reply<R> in
            do {
                let value = try work(Wire.client)
                return Reply(value: value, error: nil)
            } catch {
                return Reply(value: nil, error: "\(error)")
            }
        }.value
    }
}

private struct Reply<R: Sendable>: Sendable {
    let value: R?
    let error: String?
    var text: String { error ?? "the daemon said nothing" }
}

private func escape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
}

private func isDirectory(_ path: String) -> Bool {
    var directory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
    return exists && directory.boolValue
}

private func tildeify(_ path: String) -> String {
    let home = NSHomeDirectory()
    guard path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + String(path.dropFirst(home.count))
}
