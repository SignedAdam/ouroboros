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

    private let client = ZeroClient()
    private var timer: Timer?

    var projects: [Project] { snapshot?.projects ?? [] }
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
        let request = API.CreateIssue(project: project.id, title: nil, body: body, fix: fix)
        Task.detached { [client] in
            let created = try? client.post("/v1/issues", request, as: API.IssueCreated.self)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy = false
                if let created {
                    self.draft = ""
                    self.status = created.run != nil
                        ? "dispatched \(created.run!.agent) · \(created.issue.title)"
                        : "filed · \(created.issue.title)"
                } else {
                    self.status = "could not file that"
                }
                self.refresh()
            }
        }
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
