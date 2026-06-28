import XCTest
@testable import Ouroboros

final class AgentTests: XCTestCase {
    func testClaudeInvocationSubstitutesPrompt() {
        let inv = Agent.claudeCode.invocation(prompt: "do the thing", cwd: "/repo", label: "fix-x")
        XCTAssertEqual(inv.argv, ["claude", "do the thing"])
        XCTAssertEqual(inv.cwd, "/repo")
        XCTAssertEqual(inv.label, "fix-x")
    }
    func testCodexInvocation() {
        let inv = Agent.codex.invocation(prompt: "p", cwd: "/r", label: "l")
        XCTAssertEqual(inv.argv, ["codex", "p"])
    }
    func testCustomAgent() {
        let inv = Agent.custom("my", "cli", "{prompt}").invocation(prompt: "p", cwd: "/r", label: "l")
        XCTAssertEqual(inv.argv, ["my", "cli", "p"])
    }
    func testFixOptionsDefaults() {
        let o = FixOptions()
        XCTAssertTrue(o.worktree)
        XCTAssertEqual(o.finish, .mergeIntoBase)
    }
}
