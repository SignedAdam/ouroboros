import XCTest
@testable import ZeroCore

final class ToolbeltInPromptTests: XCTestCase {
    private var context: SupervisedPrompt.Context {
        SupervisedPrompt.Context(
            title: "Login button dead", body: "clicking it does nothing",
            issuePath: "/repo/.issues/new/x.md", branch: "fix/login", base: "main",
            worktree: true, verifyCmd: "swift build",
            resultPath: "/runs/r-1/result.json")
    }

    func testAProjectWithoutAScreenIsNotToldAboutTheToolbelt() {
        let prompt = SupervisedPrompt.fix(context)

        XCTAssertFalse(prompt.contains("toolbelt"))
        XCTAssertFalse(prompt.contains("take-screenshot"))
        XCTAssertFalse(prompt.contains("list-windows"))
    }

    func testAProjectWithAScreenGetsTheToolbeltAndTheReasonForIt() {
        var ctx = context
        ctx.toolsPath = "/Users/x/.ouroboros/tools"
        let prompt = SupervisedPrompt.fix(ctx)

        XCTAssertTrue(prompt.contains("take-screenshot"))
        XCTAssertTrue(prompt.contains("a diff does not prove the fix"))
        XCTAssertTrue(prompt.contains("/Users/x/.ouroboros/tools/TOOLS.md"))
    }
}

final class PolicyDecodingTests: XCTestCase {
    private func policy(_ json: String) throws -> Policy {
        try JSONDecoder().decode(Policy.self, from: Data(json.utf8))
    }

    func testGuiIsOffUntilAskedFor() throws {
        XCTAssertFalse(try policy("{}").gui)
        XCTAssertTrue(try policy(#"{"gui":true}"#).gui)
    }

    func testAPolicyFromAnOlderBuildStillDecodes() throws {
        let old = #"{"autonomy":"auto","maxParallel":4,"worktreeDefault":false,"finishDefault":"pr","protectedPaths":["db/"]}"#
        let p = try policy(old)

        XCTAssertEqual(p.autonomy, .auto)
        XCTAssertEqual(p.maxParallel, 4)
        XCTAssertFalse(p.worktreeDefault)
        XCTAssertEqual(p.finishDefault, .pr)
        XCTAssertEqual(p.protectedPaths, ["db/"])
        XCTAssertFalse(p.gui)
    }

    func testAnEmptyPolicyFallsBackToTheDefaults() throws {
        let p = try policy("{}")

        XCTAssertEqual(p.autonomy, .manual)
        XCTAssertEqual(p.maxParallel, 2)
        XCTAssertTrue(p.worktreeDefault)
        XCTAssertEqual(p.finishDefault, .merge)
        XCTAssertEqual(p.protectedPaths, [])
    }

    func testGuiSurvivesARoundTrip() throws {
        var p = Policy()
        p.gui = true
        let data = try JSONEncoder().encode(p)

        XCTAssertTrue(try JSONDecoder().decode(Policy.self, from: data).gui)
    }
}
