import XCTest
@testable import Ouroboros

final class TerminalLauncherTests: XCTestCase {
    private let inv = AgentInvocation(argv: ["claude", "do it"], cwd: "/repo/wt", label: "fix-x")

    private func fakeCapture(sessions: [String], clients: [String]) -> @Sendable ([String]) -> String {
        { argv in
            if argv.contains("list-sessions") { return sessions.joined(separator: "\n") }
            if argv.contains("list-clients") { return clients.joined(separator: "\n") }
            return ""
        }
    }

    func testGhosttyTmuxTabAddsWindowToDedicatedSessionNotTheUsers() {
        final class Box: @unchecked Sendable { var runs: [[String]] = [] }
        let box = Box()
        let launcher = TerminalLauncher(
            kind: .ghosttyTmuxTab,
            run: { box.runs.append($0) },
            capture: fakeCapture(sessions: ["main", "ouroboros"], clients: ["/dev/ttys001"]),
            writeScript: { _ in "/tmp/launch.command" })
        launcher.launch(inv)
        XCTAssertEqual(box.runs.count, 1)
        let first = box.runs[0]
        XCTAssertEqual(first.prefix(3), ["tmux", "new-window", "-t"])
        XCTAssertTrue(first.contains("ouroboros"))
        XCTAssertFalse(first.contains("main"))
        XCTAssertTrue(first.contains("/repo/wt"))
        XCTAssertTrue(first.contains("fix-x"))
    }

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
        XCTAssertEqual(box.runs[1].first, "/Applications/Ghostty.app/Contents/MacOS/ghostty")
        XCTAssertTrue(box.runs[1].contains("attach"))
        XCTAssertTrue(box.runs[1].contains("ouroboros"))
    }

    func testGhosttyTmuxTabCreatesDedicatedSessionOnFirstFix() {
        final class Box: @unchecked Sendable { var runs: [[String]] = [] }
        let box = Box()
        let launcher = TerminalLauncher(
            kind: .ghosttyTmuxTab,
            run: { box.runs.append($0) },
            capture: fakeCapture(sessions: ["main"], clients: []),
            writeScript: { _ in "/tmp/launch.command" })
        launcher.launch(inv)
        let first = box.runs[0]
        XCTAssertEqual(first.prefix(2), ["tmux", "new-session"])
        XCTAssertTrue(first.contains("ouroboros"))
        XCTAssertTrue(first.contains("fix-x"))
        XCTAssertFalse(first.contains("main"))
        XCTAssertEqual(box.runs[1].first, "/Applications/Ghostty.app/Contents/MacOS/ghostty")
        XCTAssertTrue(box.runs[1].contains("attach"))
    }

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

    func testCinemaLaunchesGhosttyBinaryDirectlyWithGeneratedScript() throws {
        final class Box: @unchecked Sendable { var runs: [[String]] = [] }
        let box = Box()
        let launcher = TerminalLauncher(
            kind: .ghosttyCinemaWindow,
            run: { box.runs.append($0) },
            capture: { argv in argv.first == "command" ? "/opt/homebrew/bin/ghostty\n" : "" })
        launcher.launch(inv)
        XCTAssertEqual(box.runs.count, 1)
        let argv = box.runs[0]
        XCTAssertEqual(argv.first, "/opt/homebrew/bin/ghostty")
        XCTAssertFalse(argv.contains("open"))
        XCTAssertTrue(argv.contains("--window-width=110"))
        XCTAssertTrue(argv.contains("--window-height=32"))
        XCTAssertTrue(argv.contains("--quit-after-last-window-closed=true"))
        XCTAssertEqual(argv[argv.count - 2], "zsh")
        let script = argv[argv.count - 1]
        XCTAssertTrue(script.hasSuffix(".command"))
        let content = try String(contentsOfFile: script, encoding: .utf8)
        XCTAssertTrue(content.contains("fixing your issue"))
        XCTAssertFalse(content.contains("tmux"))
        try? FileManager.default.removeItem(atPath: script)
    }

    func testGhosttyBinaryFallsBackToAppBundle() {
        let launcher = TerminalLauncher(kind: .ghosttyCinemaWindow, run: { _ in },
                                        capture: { _ in "" })
        XCTAssertEqual(launcher.ghosttyBinary(),
                       "/Applications/Ghostty.app/Contents/MacOS/ghostty")
    }

    func testCinemaScriptContent() {
        let titled = AgentInvocation(argv: ["claude", "the prompt"], cwd: "/repo/wt",
                                     label: "fix-x", title: "Fix the $HOME 'login'")
        let s = TerminalLauncher.cinemaScript(titled)
        XCTAssertTrue(s.contains("fixing your issue"))
        XCTAssertTrue(s.contains(shquote("Fix the $HOME 'login'")))
        XCTAssertTrue(s.contains("cd /repo/wt"))
        XCTAssertTrue(s.contains("exec claude 'the prompt'"))
        XCTAssertFalse(s.contains("tmux"))
        XCTAssertFalse(s.contains("exec zsh"))
    }

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
