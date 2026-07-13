import XCTest
@testable import Ouroboros

final class TerminalLauncherTests: XCTestCase {
    private let inv = AgentInvocation(argv: ["claude", "do it"], cwd: "/repo/wt", label: "fix-x")

    // A capture fake that answers tmux queries about the dedicated session.
    private func fakeCapture(sessions: [String], clients: [String]) -> @Sendable ([String]) -> String {
        { argv in
            if argv.contains("list-sessions") { return sessions.joined(separator: "\n") }
            if argv.contains("list-clients") { return clients.joined(separator: "\n") }
            return ""
        }
    }

    // Agents NEVER touch the user's own tmux session: even with a user session
    // present, the fix goes into the dedicated "ouroboros" session as a new tab.
    func testGhosttyTmuxTabAddsWindowToDedicatedSessionNotTheUsers() {
        final class Box: @unchecked Sendable { var runs: [[String]] = [] }
        let box = Box()
        let launcher = TerminalLauncher(
            kind: .ghosttyTmuxTab,
            run: { box.runs.append($0) },
            capture: fakeCapture(sessions: ["main", "ouroboros"], clients: ["/dev/ttys001"]),
            writeScript: { _ in "/tmp/launch.command" })
        launcher.launch(inv)
        XCTAssertEqual(box.runs.count, 1)                    // attached → no Ghostty open
        let first = box.runs[0]
        XCTAssertEqual(first.prefix(3), ["tmux", "new-window", "-t"])
        XCTAssertTrue(first.contains("ouroboros"))
        XCTAssertFalse(first.contains("main"))
        XCTAssertTrue(first.contains("/repo/wt"))
        XCTAssertTrue(first.contains("fix-x"))
    }

    // Session exists but nobody is watching it → also open a Ghostty window attached to it.
    func testGhosttyTmuxTabAttachesGhosttyWhenUnwatched() {
        final class Box: @unchecked Sendable { var runs: [[String]] = [] }
        let box = Box()
        let launcher = TerminalLauncher(
            kind: .ghosttyTmuxTab,
            run: { box.runs.append($0) },
            capture: fakeCapture(sessions: ["ouroboros"], clients: []),
            writeScript: { _ in "/tmp/launch.command" })
        launcher.launch(inv)
        XCTAssertEqual(box.runs[0].prefix(2), ["tmux", "new-window"])
        XCTAssertEqual(box.runs[1].prefix(2), ["open", "-na"])
        XCTAssertTrue(box.runs[1].contains("Ghostty"))
        XCTAssertTrue(box.runs[1].contains("ouroboros"))
    }

    // No dedicated session yet → create it detached (named window) + attach Ghostty.
    func testGhosttyTmuxTabCreatesDedicatedSessionOnFirstFix() {
        final class Box: @unchecked Sendable { var runs: [[String]] = [] }
        let box = Box()
        let launcher = TerminalLauncher(
            kind: .ghosttyTmuxTab,
            run: { box.runs.append($0) },
            capture: fakeCapture(sessions: ["main"], clients: []),   // user session only
            writeScript: { _ in "/tmp/launch.command" })
        launcher.launch(inv)
        let first = box.runs[0]
        XCTAssertEqual(first.prefix(2), ["tmux", "new-session"])
        XCTAssertTrue(first.contains("ouroboros"))
        XCTAssertTrue(first.contains("fix-x"))
        XCTAssertFalse(first.contains("main"))
        XCTAssertEqual(box.runs[1].prefix(2), ["open", "-na"])
        XCTAssertTrue(box.runs[1].contains("Ghostty"))
    }

    // The dedicated session name is configurable.
    func testCustomSessionName() {
        final class Box: @unchecked Sendable { var runs: [[String]] = [] }
        let box = Box()
        let launcher = TerminalLauncher(
            kind: .ghosttyTmuxTab, sessionName: "fixers",
            run: { box.runs.append($0) },
            capture: fakeCapture(sessions: [], clients: []),
            writeScript: { _ in "/tmp/launch.command" })
        launcher.launch(inv)
        XCTAssertTrue(box.runs[0].contains("fixers"))
    }

    // Cinema mode: one Ghostty window running the generated splash+agent script.
    // No tmux anywhere — the agent owns the window's TTY directly.
    func testCinemaOpensGhosttyWindowWithGeneratedScript() throws {
        final class Box: @unchecked Sendable { var runs: [[String]] = [] }
        let box = Box()
        let launcher = TerminalLauncher(kind: .ghosttyCinemaWindow, run: { box.runs.append($0) })
        launcher.launch(inv)
        XCTAssertEqual(box.runs.count, 1)
        let argv = box.runs[0]
        XCTAssertEqual(Array(argv.prefix(4)), ["open", "-na", "Ghostty", "--args"])
        XCTAssertTrue(argv.contains("--window-width=110"))
        XCTAssertTrue(argv.contains("--window-height=32"))
        XCTAssertEqual(argv[argv.count - 2], "zsh")
        let script = argv[argv.count - 1]
        XCTAssertTrue(script.hasSuffix(".command"))
        let content = try String(contentsOfFile: script, encoding: .utf8)
        XCTAssertTrue(content.contains("fixing your issue"))
        XCTAssertFalse(content.contains("tmux"))
        try? FileManager.default.removeItem(atPath: script)
    }

    // The splash script: banner + title, then exec the agent in place (so the
    // window closes when the agent exits). Never touches tmux or the user's rc.
    func testCinemaScriptContent() {
        let titled = AgentInvocation(argv: ["claude", "the prompt"], cwd: "/repo/wt",
                                     label: "fix-x", title: "Fix the $HOME 'login'")
        let s = TerminalLauncher.cinemaScript(titled)
        XCTAssertTrue(s.contains("fixing your issue"))
        XCTAssertTrue(s.contains(shquote("Fix the $HOME 'login'")))   // title shell-quoted
        XCTAssertTrue(s.contains("cd /repo/wt"))
        XCTAssertTrue(s.contains("exec claude 'the prompt'"))          // agent replaces the shell
        XCTAssertFalse(s.contains("tmux"))
        XCTAssertFalse(s.contains("exec zsh"))                         // no trailing shell → window closes
    }

    // Tab-mode launch script keeps a shell after the agent but MUST skip rc files
    // (a .zshrc session picker would hijack the finished tab).
    func testDefaultScriptTrailingShellSkipsRcFiles() throws {
        let path = TerminalLauncher.defaultWriteScript(inv)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.contains("exec zsh -f"))
    }

    func testOsDefaultOpensScriptInTerminal() {
        final class Box: @unchecked Sendable { var runs: [[String]] = [] }
        let box = Box()
        let launcher = TerminalLauncher(kind: .osDefault, run: { box.runs.append($0) },
                                        writeScript: { _ in "/tmp/launch.command" })
        launcher.launch(inv)
        XCTAssertEqual(box.runs.first, ["open", "-a", "Terminal", "/tmp/launch.command"])
    }
}
