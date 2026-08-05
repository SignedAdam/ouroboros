import XCTest
@testable import ZeroCore

final class MergeCheckTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "ouro-merge-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let git = Git(root)
        git.run(["init", "-q", "-b", "main"])
        git.run(["config", "user.email", "test@ouroboros.local"])
        git.run(["config", "user.name", "Ouroboros Test"])
        git.run(["config", "commit.gpgsign", "false"])
        write("shared.txt", "one\ntwo\nthree\n")
        write("other.txt", "untouched\n")
        git.run(["add", "-A"])
        git.run(["commit", "-q", "-m", "base"])
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    private func write(_ name: String, _ body: String) {
        try? body.write(toFile: root + "/" + name, atomically: true, encoding: .utf8)
    }

    private func commit(_ message: String) {
        let git = Git(root)
        git.run(["add", "-A"])
        git.run(["commit", "-q", "-m", message])
    }

    private func branch(_ name: String) { Git(root).run(["checkout", "-q", "-b", name]) }
    private func checkout(_ name: String) { Git(root).run(["checkout", "-q", name]) }

    func testACleanBranchMerges() {
        branch("fix/clean")
        write("new.txt", "added by the branch\n")
        commit("add a file")
        checkout("main")

        let verdict = MergeChecks().verdict(repo: root, base: "main", branch: "fix/clean")
        XCTAssertTrue(verdict.clean)
        XCTAssertTrue(verdict.conflicts.isEmpty)
        XCTAssertNil(verdict.error)
        XCTAssertEqual(verdict.state, "review")
        XCTAssertFalse(verdict.baseSha.isEmpty)
        XCTAssertFalse(verdict.branchSha.isEmpty)
        XCTAssertNotEqual(verdict.baseSha, verdict.branchSha)
    }

    func testABranchThatConflictsNamesTheFiles() {
        branch("fix/conflict")
        write("shared.txt", "one\nBRANCH\nthree\n")
        commit("branch edits the middle")
        checkout("main")
        write("shared.txt", "one\nMAIN\nthree\n")
        commit("main edits the middle")

        let verdict = MergeChecks().verdict(repo: root, base: "main", branch: "fix/conflict")
        XCTAssertFalse(verdict.clean)
        XCTAssertEqual(verdict.conflicts, ["shared.txt"])
        XCTAssertNil(verdict.error)
        XCTAssertEqual(verdict.state, "conflicts")
    }

    func testOnlyTheConflictedFilesAreListed() {
        branch("fix/mixed")
        write("shared.txt", "one\nBRANCH\nthree\n")
        write("branch-only.txt", "mine\n")
        commit("branch")
        checkout("main")
        write("shared.txt", "one\nMAIN\nthree\n")
        commit("main")

        let verdict = MergeChecks().verdict(repo: root, base: "main", branch: "fix/mixed")
        XCTAssertEqual(verdict.conflicts, ["shared.txt"])
        XCTAssertFalse(verdict.conflicts.contains("branch-only.txt"))
        XCTAssertFalse(verdict.conflicts.contains("other.txt"))
    }

    func testDisjointEditsToOneFileStillMerge() {
        write("long.txt", (1...40).map(String.init).joined(separator: "\n") + "\n")
        commit("a long file")

        branch("fix/top")
        write("long.txt", (["TOP"] + (2...40).map(String.init)).joined(separator: "\n") + "\n")
        commit("branch edits the top")
        checkout("main")
        var lines = (1...40).map(String.init)
        lines[39] = "BOTTOM"
        write("long.txt", lines.joined(separator: "\n") + "\n")
        commit("main edits the bottom")

        let verdict = MergeChecks().verdict(repo: root, base: "main", branch: "fix/top")
        XCTAssertTrue(verdict.clean, "disjoint edits to one file are not a conflict")
    }

    func testABranchAlreadyInTheBaseIsClean() {
        branch("fix/landed")
        write("new.txt", "x\n")
        commit("work")
        checkout("main")
        Git(root).run(["merge", "-q", "--no-ff", "-m", "merge", "fix/landed"])

        let verdict = MergeChecks().verdict(repo: root, base: "main", branch: "fix/landed")
        XCTAssertTrue(verdict.clean)
        XCTAssertNil(verdict.error)
    }

    func testAMissingBranchIsUnknownRatherThanClean() {
        let verdict = MergeChecks().verdict(repo: root, base: "main", branch: "fix/does-not-exist")
        XCTAssertNotNil(verdict.error)
        XCTAssertFalse(verdict.clean)
        XCTAssertEqual(verdict.state, "unknown")
    }

    func testAVerdictOnlyDescribesThePairItTested() {
        branch("fix/pair")
        write("new.txt", "x\n")
        commit("work")
        checkout("main")

        let checks = MergeChecks()
        let first = checks.verdict(repo: root, base: "main", branch: "fix/pair")
        XCTAssertTrue(first.describes(baseSha: first.baseSha, branchSha: first.branchSha))

        write("other.txt", "moved on\n")
        commit("main moves")
        let second = checks.verdict(repo: root, base: "main", branch: "fix/pair")
        XCTAssertNotEqual(first.baseSha, second.baseSha)
        XCTAssertFalse(first.describes(baseSha: second.baseSha, branchSha: second.branchSha))
        XCTAssertNotEqual(first.key, second.key)
    }

    func testTheSamePairIsAnsweredFromCache() {
        branch("fix/cached")
        write("new.txt", "x\n")
        commit("work")
        checkout("main")

        let checks = MergeChecks()
        let first = checks.verdict(repo: root, base: "main", branch: "fix/cached")
        let second = checks.verdict(repo: root, base: "main", branch: "fix/cached")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.checkedAt, second.checkedAt, "a cache hit does not re-run git")
    }

    func testRoundTrip() throws {
        let verdict = MergeVerdict(base: "main", branch: "fix/x", baseSha: "aa", branchSha: "bb",
                                   clean: false, conflicts: ["a.swift", "b.swift"])
        let data = try JSONEncoder().encode(verdict)
        let back = try JSONDecoder().decode(MergeVerdict.self, from: data)
        XCTAssertEqual(back.conflicts, ["a.swift", "b.swift"])
        XCTAssertEqual(back.state, "conflicts")
    }
}

final class MergeCheckParsingTests: XCTestCase {
    func testConflictsStopAtTheBlankLine() {
        let output = """
        3d8a4c7b2d876fb9a96c6b4cb819762538434c7f
        zero/Sources/ZeroApp/ProjectsDrawer.swift
        zero/Sources/ZeroApp/QuickCapture.swift

        Auto-merging zero/Sources/ZeroApp/AppModel.swift
        CONFLICT (content): Merge conflict in zero/Sources/ZeroApp/ProjectsDrawer.swift
        """
        XCTAssertEqual(MergeChecks.conflicts(in: output),
                       ["zero/Sources/ZeroApp/ProjectsDrawer.swift",
                        "zero/Sources/ZeroApp/QuickCapture.swift"])
    }

    func testACleanRunListsNothing() {
        XCTAssertTrue(MergeChecks.conflicts(in: "fd6e82bf59748675b71b44eb9caa2513d66d4950\n").isEmpty)
    }

    func testAFailureExplainsItselfInOneLine() {
        let reason = MergeChecks.reason("fatal: not a git repository\nsome more noise\n")
        XCTAssertEqual(reason, "fatal: not a git repository")
    }

    func testASilentFailureStillSaysSomething() {
        XCTAssertEqual(MergeChecks.reason("   \n\n"), "could not test the merge")
    }
}
