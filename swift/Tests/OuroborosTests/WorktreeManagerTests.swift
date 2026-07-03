import XCTest
@testable import Ouroboros

final class WorktreeManagerTests: XCTestCase {
    func testCreateRunsGitWorktreeAddAndReturnsPath() {
        final class Box: @unchecked Sendable { var calls: [[String]] = [] }
        let box = Box()
        let runner = GitRunner { args, _ in box.calls.append(args); return (0, "") }
        let wt = WorktreeManager(runner: runner).create(repo: "/repo", base: "main", slug: "fix-login")
        XCTAssertEqual(wt?.branch, "fix/fix-login")
        XCTAssertEqual(wt?.path, "/repo/.ouroboros/worktrees/fix-login")
        XCTAssertEqual(box.calls.first?.first, "worktree")
        XCTAssertTrue(box.calls.first?.contains("fix/fix-login") == true)
        XCTAssertTrue(box.calls.first?.contains("/repo/.ouroboros/worktrees/fix-login") == true)
        XCTAssertTrue(box.calls.first?.contains("main") == true)
    }
    func testCreateRetriesSuffixWhenBranchExists() {
        final class Box: @unchecked Sendable { var n = 0 }
        let box = Box()
        let runner = GitRunner { _, _ in
            box.n += 1
            return box.n == 1 ? (128, "fatal: a branch named 'fix/x' already exists") : (0, "")
        }
        let wt = WorktreeManager(runner: runner).create(repo: "/repo", base: "main", slug: "x")
        XCTAssertEqual(wt?.branch, "fix/x-2")
    }
    func testCreateReturnsNilOnHardFailure() {
        let runner = GitRunner { _, _ in (1, "fatal: not a git repository") }
        XCTAssertNil(WorktreeManager(runner: runner).create(repo: "/repo", base: "main", slug: "x"))
    }
}
