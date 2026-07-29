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

    private let client = ZeroClient()
    private var timer: Timer?

    var projects: [Project] { snapshot?.projects ?? [] }
    var recents: [ProjectDigest] { snapshot?.recents ?? [] }
    var stats: API.Stats { snapshot?.stats ?? API.Stats() }

    /// Fold state for the capture panel's drawer. A UI preference, so it lives
    /// in UserDefaults rather than config.json, which is the daemon's contract
    /// with every client.
    var recentsExpanded: Bool {
        get {
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
                    self.snapshot = result
                    self.connected = true
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

    func forgetProject(_ id: String) {
        Task.detached { [client] in
            _ = try? client.delete("/v1/projects/\(id)", as: API.Message.self)
            await MainActor.run { [weak self] in self?.refresh() }
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

    func deleteIssue(_ issueId: String) {
        Task.detached { [client] in
            _ = try? client.delete("/v1/issues/\(issueId)", as: API.Message.self)
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

    func openLog(_ runId: String) { RowActions.copy("ouro log \(runId) -f"); status = "copied: ouro log \(runId) -f" }
    func showDiff(_ runId: String) { RowActions.copy("ouro diff \(runId)"); status = "copied: ouro diff \(runId)" }

    func openWorktree(_ runId: String) {
        guard let run = (activeRuns + recentRuns).first(where: { $0.id == runId }),
              let path = run.worktreePath else { return }
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
        NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
    }
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
        case .landed:   return Color(red: 0.49, green: 0.85, blue: 0.34)
        case .ready:    return Color(red: 0.47, green: 0.67, blue: 1.0)
        case .proposal: return Color(red: 1.0, green: 0.48, blue: 0.09)
        }
    }

    var label: String {
        switch kind {
        case .question: return "needs you"
        case .failed:   return "failed"
        case .landed:   return "landed"
        case .ready:    return "ready"
        case .proposal: return "proposal"
        }
    }
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
