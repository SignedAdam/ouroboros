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
    public enum Kind: String, Sendable { case ghosttyTmuxTab, ghosttyCinemaWindow, osDefault, custom }

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
        case .ghosttyCinemaWindow: launchCinema(inv)
        case .osDefault: run(["open", "-a", "Terminal", script])
        case .custom: customLaunch?(inv, script)
        }
    }

    // Cinema mode: a small dedicated Ghostty window per fix — a marquee (banner,
    // issue title, elapsed timer, peek hotkeys) fronts the agent, and the window
    // closes itself when the agent finishes. The whole show is one generated zsh
    // script (per-fix tmux session + embedded Python marquee), so the injectable
    // `writeScript` seam still fakes the path in tests. The .command extension is
    // cosmetic; Ghostty runs it via zsh explicitly.
    private func launchCinema(_ inv: AgentInvocation) {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ouroboros-cinema-\(UUID().uuidString).command")
        let written: String
        if FileManager.default.createFile(
            atPath: path, contents: Data(TerminalLauncher.cinemaScript(inv).utf8),
            attributes: [.posixPermissions: 0o700]) {
            written = path
        } else {
            written = writeScript(inv)   // test seam / degraded fallback: plain agent script
        }
        run(["open", "-na", "Ghostty", "--args",
             "--window-width=80", "--window-height=21", "--title=ouroboros",
             "-e", "zsh", written])
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

    // MARK: cinema script

    /// The self-contained zsh script behind cinema mode: creates a per-fix tmux
    /// session (window "agent" runs the coding agent; window "status" runs an
    /// embedded Python marquee showing the banner, issue title, elapsed timer and
    /// hotkeys), then attaches. When the agent exits, the marquee flashes done and
    /// kills the session — the attach ends and the Ghostty window closes itself.
    /// The issue title crosses the shell layers base64-encoded so quoting in
    /// arbitrary titles can never break the script.
    static func cinemaScript(_ inv: AgentInvocation, sessionPrefix: String = "fix-") -> String {
        let agentCmd = inv.argv.map(shquote).joined(separator: " ")
        let title = inv.title.isEmpty ? inv.label : inv.title
        let titleB64 = Data(title.utf8).base64EncodedString()
        return #"""
        #!/bin/zsh
        set -u
        SESSION=\#(shquote(sessionPrefix + inv.label))-$$
        MARQUEE="${TMPDIR:-/tmp}/ouroboros-marquee-$$.py"
        cat > "$MARQUEE" <<'MARQUEE_PY'
        import base64, select, shutil, subprocess, sys, termios, textwrap, time, tty

        SESSION = sys.argv[1]
        TITLE = base64.b64decode(sys.argv[2]).decode("utf-8", "replace")
        ORANGE, GREEN = "\033[38;2;255;122;24m", "\033[38;2;55;214;122m"
        DIM, BOLD, RESET = "\033[2m", "\033[1m", "\033[0m"
        HIDE, SHOW, CLEAR = "\033[?25l", "\033[?25h", "\033[2J\033[H"
        BANNER = [
            "█▀█ █ █ █▀▄ █▀█ ██▄ █▀█ █▀▄ █▀█ ▄▀▀",
            "█ █ █ █ ██▀ █ █ █▄█ █ █ ██▀ █ █ ▀▀▄",
            "▀▀▀ ▀▀▀ ▀ ▀ ▀▀▀ ▀▀▀ ▀▀▀ ▀ ▀ ▀▀▀ ▀▀ ",
        ]
        SPIN = "◜◠◝◞◡◟"

        def tmux(*args):
            r = subprocess.run(["tmux", *args], capture_output=True, text=True)
            return r.stdout

        def agent_alive():
            return "agent" in tmux("list-windows", "-t", SESSION, "-F", "#W").split()

        def peek_lines(n=10):
            out = tmux("capture-pane", "-p", "-t", SESSION + ":agent")
            lines = [l for l in out.rstrip("\n").split("\n") if l.strip()]
            return lines[-n:]

        def draw(t0, i, peek, cols):
            out = [CLEAR + HIDE, ""]
            for b in BANNER:
                out.append("  " + ORANGE + b + RESET)
            out.append("")
            out.append("  " + DIM + "fixing your issue" + RESET)
            for l in textwrap.wrap(TITLE, max(20, cols - 6)) or [""]:
                out.append("  " + BOLD + l + RESET)
            out.append("")
            el = int(time.time() - t0)
            out.append("  " + ORANGE + SPIN[i % len(SPIN)] + RESET
                       + "  %02d:%02d" % (el // 60, el % 60)
                       + DIM + "  agent working…" + RESET)
            if peek:
                out.append("  " + DIM + "─" * max(10, cols - 4) + RESET)
                for l in peek_lines():
                    out.append("  " + DIM + l[: cols - 4] + RESET)
                out.append("  " + DIM + "─" * max(10, cols - 4) + RESET)
            out.append("")
            out.append("  " + DIM + "[p] peek   [a] watch agent   [q] hide (agent keeps running)" + RESET)
            sys.stdout.write("\n".join(out))
            sys.stdout.flush()

        def main():
            t0, i, peek = time.time(), 0, False
            fd = sys.stdin.fileno()
            old = termios.tcgetattr(fd)
            tty.setcbreak(fd)
            try:
                while True:
                    if not agent_alive():
                        el = int(time.time() - t0)
                        sys.stdout.write(CLEAR + "\n\n  " + GREEN + "✔ done" + RESET
                                         + BOLD + "  %02d:%02d  " % (el // 60, el % 60) + RESET
                                         + DIM + TITLE[:58] + RESET + "\n")
                        sys.stdout.flush()
                        time.sleep(2.5)
                        subprocess.run(["tmux", "kill-session", "-t", SESSION])
                        return
                    cols = shutil.get_terminal_size((80, 21)).columns
                    draw(t0, i, peek, cols)
                    i += 1
                    r, _, _ = select.select([sys.stdin], [], [], 0.5)
                    if r:
                        ch = sys.stdin.read(1)
                        if ch == "p":
                            peek = not peek
                        elif ch == "a":
                            subprocess.run(["tmux", "select-window", "-t", SESSION + ":agent"])
                        elif ch == "q":
                            subprocess.run(["tmux", "detach-client", "-s", SESSION])
            finally:
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
                sys.stdout.write(SHOW)

        main()
        MARQUEE_PY
        tmux new-session -d -s "$SESSION" -c \#(shquote(inv.cwd)) -n agent \#(shquote(agentCmd))
        tmux set-option -t "$SESSION" status off
        tmux new-window -d -t "$SESSION" -n status "python3 \"$MARQUEE\" \"$SESSION\" \#(titleB64)"
        tmux select-window -t "$SESSION:status"
        exec tmux attach -t "$SESSION"
        """#
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
