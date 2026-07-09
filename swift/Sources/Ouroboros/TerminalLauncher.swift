import Foundation

/// Minimal POSIX shell quoting for building the launch script + command strings.
func shquote(_ s: String) -> String {
    if s.isEmpty { return "''" }
    let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./=:,@%+")
    if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public struct TerminalLauncher: Sendable {
    public enum Kind: String, Sendable { case ghosttyTmuxTab, osDefault, custom }

    public let kind: Kind
    /// The dedicated tmux session agents live in. Agents NEVER open windows in the
    /// user's own session — selecting a new window there yanks their current view
    /// ("a terminal spawned on top of mine"). All fixes stack as tabs here instead.
    public let sessionName: String
    let run: @Sendable ([String]) -> Void
    let capture: @Sendable ([String]) -> String
    let customLaunch: (@Sendable (AgentInvocation, String) -> Void)?
    let writeScript: @Sendable (AgentInvocation) -> String

    public init(kind: Kind = .ghosttyTmuxTab,
                sessionName: String = "ouroboros",
                run: (@Sendable ([String]) -> Void)? = nil,
                capture: (@Sendable ([String]) -> String)? = nil,
                customLaunch: (@Sendable (AgentInvocation, String) -> Void)? = nil,
                writeScript: (@Sendable (AgentInvocation) -> String)? = nil) {
        self.kind = kind
        self.sessionName = sessionName
        self.run = run ?? TerminalLauncher.defaultRun
        self.capture = capture ?? TerminalLauncher.defaultCapture
        self.customLaunch = customLaunch
        self.writeScript = writeScript ?? TerminalLauncher.defaultWriteScript
    }

    public func launch(_ inv: AgentInvocation) {
        let script = writeScript(inv)
        switch kind {
        case .ghosttyTmuxTab: launchGhosttyTmuxTab(inv, script)
        case .osDefault: run(["open", "-a", "Terminal", script])
        case .custom: customLaunch?(inv, script)
        }
    }

    private func launchGhosttyTmuxTab(_ inv: AgentInvocation, _ script: String) {
        let runIn = "zsh \(shquote(script))"
        // First fix creates the dedicated session; later fixes add windows (tabs) to it.
        if sessionExists() {
            run(["tmux", "new-window", "-t", sessionName, "-c", inv.cwd, "-n", inv.label, runIn])
        } else {
            run(["tmux", "new-session", "-d", "-s", sessionName, "-n", inv.label,
                 "-c", inv.cwd, runIn])
        }
        // Surface it only when nobody is watching: attach a Ghostty window to the
        // agents' session. If one is already attached, the new tab appears there.
        if !sessionHasClient() {
            run(["open", "-na", "Ghostty", "--args", "-e", "tmux", "attach", "-t", sessionName])
        }
    }

    private func sessionExists() -> Bool {
        capture(["tmux", "list-sessions", "-F", "#{session_name}"])
            .split(separator: "\n").contains { $0 == Substring(sessionName) }
    }

    private func sessionHasClient() -> Bool {
        !capture(["tmux", "list-clients", "-t", sessionName, "-F", "#{client_tty}"])
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: defaults (run via login shell so homebrew PATH resolves from Finder-launched apps)

    static let defaultRun: @Sendable ([String]) -> Void = { argv in
        let cmd = argv.map(shquote).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", cmd]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    static let defaultCapture: @Sendable ([String]) -> String = { argv in
        let cmd = argv.map(shquote).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", cmd]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static let defaultWriteScript: @Sendable (AgentInvocation) -> String = { inv in
        let argv = inv.argv.map(shquote).joined(separator: " ")
        let body = "cd \(shquote(inv.cwd))\n\(argv)\nexec zsh\n"
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ouroboros-launch-\(UUID().uuidString).command")
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }
}
