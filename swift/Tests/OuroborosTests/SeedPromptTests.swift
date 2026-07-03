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
    func testWorktreeMergeResolvesIssueFile() {
        let p = seedPrompt(issue: issue, baseBranch: "main",
                           options: FixOptions(worktree: true, finish: .mergeIntoBase), branch: "fix/fix-login")
        XCTAssertTrue(p.contains("## Resolution"))
        XCTAssertTrue(p.contains("move it from `.issues/new/` to `.issues/done/` with `git mv`"))
        XCTAssertTrue(p.contains("committed on `main`"))
    }
    func testWorktreePRMentionsGh() {
        let p = seedPrompt(issue: issue, baseBranch: "main",
                           options: FixOptions(worktree: true, finish: .openPR), branch: "fix/fix-login")
        XCTAssertTrue(p.contains("gh pr create"))
        XCTAssertTrue(p.contains("Do not merge"))
    }
    func testWorktreePRAppendsUrlAndLeavesIssueInNew() {
        let p = seedPrompt(issue: issue, baseBranch: "main",
                           options: FixOptions(worktree: true, finish: .openPR), branch: "fix/fix-login")
        XCTAssertTrue(p.contains("Append the PR URL to the issue file"))
        XCTAssertTrue(p.contains("it stays in `.issues/new/` until the PR lands"))
        XCTAssertFalse(p.contains("## Resolution"))
    }
    func testInPlaceMerge() {
        let p = seedPrompt(issue: issue, baseBranch: "main",
                           options: FixOptions(worktree: false, finish: .mergeIntoBase), branch: nil)
        XCTAssertTrue(p.contains("on the current branch"))
        XCTAssertFalse(p.contains("worktree"))
    }
    func testInPlaceMergeResolvesIssueFile() {
        let p = seedPrompt(issue: issue, baseBranch: "main",
                           options: FixOptions(worktree: false, finish: .mergeIntoBase), branch: nil)
        XCTAssertTrue(p.contains("## Resolution"))
        XCTAssertTrue(p.contains("move it from `.issues/new/` to `.issues/done/` with `git mv`"))
        XCTAssertTrue(p.contains("committed with the fix"))
    }
    func testInPlacePRAppendsUrlAndLeavesIssueInNew() {
        let p = seedPrompt(issue: issue, baseBranch: "main",
                           options: FixOptions(worktree: false, finish: .openPR), branch: nil)
        XCTAssertTrue(p.contains("gh pr create"))
        XCTAssertTrue(p.contains("Append the PR URL to the issue file"))
        XCTAssertTrue(p.contains("it stays in `.issues/new/` until the PR lands"))
        XCTAssertFalse(p.contains("## Resolution"))
    }
}
