import XCTest
@testable import Ouroboros

final class SeedPromptTests: XCTestCase {
    private let issue = Issue(title: "Fix login", slug: "fix-login",
                              body: "button does nothing", path: "/repo/.issues/new/Fix login.md")

    func testAlwaysIncludesIssueAndBlockedClause() {
        let p = seedPrompt(issue: issue, baseBranch: "main",
                           options: FixOptions(worktree: true, finish: .mergeIntoBase), branch: "fix/fix-login")
        XCTAssertTrue(p.contains("## Fix login"))
        XCTAssertTrue(p.contains("button does nothing"))
        XCTAssertTrue(p.contains("/repo/.issues/new/Fix login.md"))
        XCTAssertTrue(p.contains("leave it blocked"))
    }
    func testWorktreeMergeMentionsBranchAndMerge() {
        let p = seedPrompt(issue: issue, baseBranch: "main",
                           options: FixOptions(worktree: true, finish: .mergeIntoBase), branch: "fix/fix-login")
        XCTAssertTrue(p.contains("worktree on branch `fix/fix-login`"))
        XCTAssertTrue(p.contains("merge back into `main`"))
    }
    func testWorktreePRMentionsGh() {
        let p = seedPrompt(issue: issue, baseBranch: "main",
                           options: FixOptions(worktree: true, finish: .openPR), branch: "fix/fix-login")
        XCTAssertTrue(p.contains("gh pr create"))
        XCTAssertTrue(p.contains("Do not merge"))
    }
    func testInPlaceMerge() {
        let p = seedPrompt(issue: issue, baseBranch: "main",
                           options: FixOptions(worktree: false, finish: .mergeIntoBase), branch: nil)
        XCTAssertTrue(p.contains("on the current branch"))
        XCTAssertFalse(p.contains("worktree"))
    }
}
