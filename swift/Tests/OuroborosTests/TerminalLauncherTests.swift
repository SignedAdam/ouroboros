import XCTest
@testable import Ouroboros

final class TerminalLauncherTests: XCTestCase {
    private let inv = AgentInvocation(argv: ["claude", "do it"], cwd: "/repo/wt", label: "fix-x")

    func testGhosttyTmuxTabUsesActiveSession() {
        final class Box: @unchecked Sendable { var runs: [[String]] = [] }
        let box = Box()
        let launcher = TerminalLauncher(
            kind: .ghosttyTmuxTab,
            run: { box.runs.append($0) },
            capture: { _ in "100 work\n250 main\n" },           // main is most recent
            writeScript: { _ in "/tmp/launch.command" })
        launcher.launch(inv)
        let first = box.runs.first ?? []
        XCTAssertEqual(first.prefix(3), ["tmux", "new-window", "-t"])
        XCTAssertTrue(first.contains("main"))
        XCTAssertTrue(first.contains("/repo/wt"))
        XCTAssertTrue(first.contains("fix-x"))
    }

    func testGhosttyTmuxTabFallsBackToNewSessionAndGhostty() {
        final class Box: @unchecked Sendable { var runs: [[String]] = [] }
        let box = Box()
        let launcher = TerminalLauncher(
            kind: .ghosttyTmuxTab,
            run: { box.runs.append($0) },
            capture: { _ in "" },                                // no active session
            writeScript: { _ in "/tmp/launch.command" })
        launcher.launch(inv)
        XCTAssertEqual(box.runs[0].prefix(2), ["tmux", "new-session"])
        XCTAssertEqual(box.runs[1].prefix(2), ["open", "-na"])
        XCTAssertTrue(box.runs[1].contains("Ghostty"))
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
