import XCTest
@testable import Ouroboros

final class OuroborosFacadeTests: XCTestCase {
    private func tempRepo() -> String {
        let p = (NSTemporaryDirectory() as NSString).appendingPathComponent("ouro-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func testSubmitWritesIssue() {
        let repo = tempRepo()
        let o = Ouroboros(projectDir: repo)
        let issue = o.submit(title: "Fix login", body: "broken")
        XCTAssertEqual(issue?.slug, "fix-login")
        XCTAssertTrue(FileManager.default.fileExists(atPath: issue!.path!))
    }

    func testHandToAgentCreatesWorktreeThenLaunches() {
        final class Box: @unchecked Sendable { var git: [[String]] = []; var launched: [AgentInvocation] = [] }
        let box = Box()
        let repo = tempRepo()
        let worktrees = WorktreeManager(runner: GitRunner { args, _ in box.git.append(args); return (0, "") })
        let terminal = TerminalLauncher(kind: .custom,
                                        customLaunch: { inv, _ in box.launched.append(inv) },
                                        writeScript: { _ in "/tmp/x.command" })
        let o = Ouroboros(projectDir: repo, agent: .claudeCode, terminal: terminal,
                          baseBranch: "main", worktrees: worktrees)
        let issue = Issue(title: "Fix login", slug: "fix-login", body: "broken", path: "\(repo)/.issues/new/Fix login.md")
        let ok = o.handToAgent(issue, options: FixOptions(worktree: true, finish: .mergeIntoBase))
        XCTAssertTrue(ok)
        XCTAssertEqual(box.git.first?.first, "worktree")
        XCTAssertEqual(box.launched.count, 1)
        XCTAssertEqual(box.launched.first?.cwd, "\(repo)/.ouroboros/worktrees/fix-login")
        XCTAssertEqual(box.launched.first?.argv.first, "claude")
        XCTAssertTrue(box.launched.first?.argv.last?.contains("Fix login") == true)
    }

    func testHandToAgentInPlaceUsesProjectDir() {
        final class Box: @unchecked Sendable { var launched: [AgentInvocation] = [] }
        let box = Box()
        let repo = tempRepo()
        let terminal = TerminalLauncher(kind: .custom, customLaunch: { inv, _ in box.launched.append(inv) },
                                        writeScript: { _ in "/tmp/x.command" })
        let o = Ouroboros(projectDir: repo, agent: .codex, terminal: terminal)
        let issue = Issue(title: "X", slug: "x", body: "y")
        _ = o.handToAgent(issue, options: FixOptions(worktree: false, finish: .mergeIntoBase))
        XCTAssertEqual(box.launched.first?.cwd, repo)
    }
}
