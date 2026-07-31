import XCTest
@testable import ZeroCore

/// "This branch conflicts" and "this branch is finished with" look identical
/// from outside, and asking the wrong one of the two sends somebody to resolve
/// work that has already shipped. Real repositories and real git, for the same
/// reason `MergeCheckTests` uses them: a staleness check that is itself a guess
/// would be the bug this whole state exists to close.
final class StalenessTests: XCTestCase {

    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "ouro-stale-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let git = Git(root)
        git.run(["init", "-q", "-b", "main"])
        git.run(["config", "user.email", "test@ouroboros.local"])
        git.run(["config", "user.name", "Ouroboros Test"])
        git.run(["config", "commit.gpgsign", "false"])
        write("shared.txt", "one\ntwo\nthree\n")
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

    // MARK: the patch-id half

    /// The clean case: somebody cherry-picked the branch's commit onto the base
    /// rather than merging it. `git cherry` finds the patch upstream, so nothing
    /// has to be measured.
    func testACherryPickedCommitIsSpent() {
        branch("fix/picked")
        write("picked.txt", "the work\n")
        commit("do the work")
        let sha = Git(root).run(["rev-parse", "HEAD"], timeout: 10).trimmed
        checkout("main")
        // The base moves first, so the cherry-pick lands on a different parent
        // and is a genuinely different commit. Onto an unchanged parent git
        // reuses the object outright and the branch is simply an ancestor.
        write("shared.txt", "one\nMAIN\nthree\n")
        commit("main moves on")
        Git(root).run(["cherry-pick", sha], timeout: 30)

        let verdict = MergeChecks().verdict(repo: root, base: "main", branch: "fix/picked")
        let staleness = try! XCTUnwrap(verdict.staleness)
        XCTAssertEqual(staleness.commits, 1)
        XCTAssertEqual(staleness.commitsUpstream, 1)
        XCTAssertTrue(staleness.spent)
        XCTAssertEqual(staleness.reason, "its commit is already on the base")
        XCTAssertTrue(verdict.spent)
        XCTAssertEqual(verdict.state, "obsolete")
    }

    /// Ordinary work. Nothing of it is upstream, and it must not be thrown away.
    func testALiveBranchIsNotSpent() {
        branch("fix/live")
        write("mine.txt", "brand new work nobody has\nsecond line of it\n")
        commit("work")
        checkout("main")
        write("shared.txt", "one\nMAIN\nthree\n")
        commit("main moves on")

        let verdict = MergeChecks().verdict(repo: root, base: "main", branch: "fix/live")
        let staleness = try! XCTUnwrap(verdict.staleness)
        XCTAssertEqual(staleness.commitsUpstream, 0)
        XCTAssertFalse(staleness.spent)
        XCTAssertFalse(verdict.spent)
    }

    // MARK: the content half

    /// The case this state was actually built for, and the one `git cherry`
    /// cannot see: somebody read the branch and wrote the same thing again,
    /// because the base had moved too far to replay it. No patch-id survives
    /// that. The content does.
    func testWorkReAppliedByHandIsSpent() {
        let body = (1...30).map { "line \($0) of the fix" }.joined(separator: "\n") + "\n"
        branch("fix/reapplied")
        write("feature.txt", body)
        commit("the fix")
        checkout("main")
        // Same content, written independently — a different commit, a different
        // patch-id, and one extra line the base has gone on to add.
        write("feature.txt", body + "line 31, added later on the base\n")
        commit("the same fix, re-applied by hand")
        write("shared.txt", "one\nMAIN\nthree\n")
        commit("main moves on")

        let verdict = MergeChecks().verdict(repo: root, base: "main", branch: "fix/reapplied")
        let staleness = try! XCTUnwrap(verdict.staleness)
        XCTAssertEqual(staleness.commitsUpstream, 0, "git cherry cannot see this one")
        XCTAssertEqual(staleness.added, 30)
        XCTAssertEqual(staleness.addedUpstream, 30)
        XCTAssertTrue(staleness.spent)
        XCTAssertEqual(staleness.reason, "30 of 30 lines are already on the base")
    }

    /// The base took most of it and the branch still holds something. Not spent:
    /// the remainder is exactly what a `resolve` run exists to rescue.
    func testABranchStillHoldingSomethingIsNotSpent() {
        let shared = (1...30).map { "line \($0) of the fix" }.joined(separator: "\n") + "\n"
        branch("fix/partial")
        write("feature.txt", shared + (1...10).map { "only on the branch \($0)" }
            .joined(separator: "\n") + "\n")
        commit("the fix, plus more")
        checkout("main")
        write("feature.txt", shared)
        commit("part of it, re-applied")

        let verdict = MergeChecks().verdict(repo: root, base: "main", branch: "fix/partial")
        let staleness = try! XCTUnwrap(verdict.staleness)
        XCTAssertEqual(staleness.addedUpstream, 30)
        XCTAssertEqual(staleness.added, 40)
        XCTAssertFalse(staleness.spent, "a quarter of it is still only on the branch")
    }

    /// The guard that keeps a measurement from deleting somebody's work: one
    /// file the base has never seen and the branch is not spent, whatever the
    /// line counts say.
    func testAFileTheBaseHasNeverSeenIsNeverSpent() {
        let body = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        branch("fix/newfile")
        write("feature.txt", body)
        write("brand-new.txt", "line 1\n")   // one line, and the base has no such file
        commit("the fix and a new file")
        checkout("main")
        write("feature.txt", body)
        commit("the fix, re-applied")

        let verdict = MergeChecks().verdict(repo: root, base: "main", branch: "fix/newfile")
        let staleness = try! XCTUnwrap(verdict.staleness)
        XCTAssertEqual(staleness.newFiles, 1)
        XCTAssertFalse(staleness.spent, "it still brings a file nobody else has")
    }

    /// A branch already merged in is answered before any of this runs, and
    /// `clean` is the right word for it: it went in.
    func testAMergedBranchIsCleanRatherThanSpent() {
        branch("fix/merged")
        write("new.txt", "x\n")
        commit("work")
        checkout("main")
        Git(root).run(["merge", "-q", "--no-ff", "-m", "merge", "fix/merged"])

        let verdict = MergeChecks().verdict(repo: root, base: "main", branch: "fix/merged")
        XCTAssertTrue(verdict.clean)
        XCTAssertFalse(verdict.spent)
        XCTAssertEqual(verdict.state, "review")
    }

    /// "We could not tell" must never become "throw the branch away". `discard`
    /// deletes something, and it may only ever act on a real answer.
    func testAnUnaskableQuestionIsNotAnObsoleteBranch() {
        let verdict = MergeChecks().verdict(repo: root, base: "main", branch: "fix/nope")
        XCTAssertNotNil(verdict.error)
        XCTAssertFalse(verdict.spent)
        XCTAssertEqual(verdict.state, "unknown")
    }
}

/// The rule itself, without git: what counts as spent and what does not.
final class StalenessRuleTests: XCTestCase {

    func testNothingOnTheBranchIsNotSpent() {
        XCTAssertFalse(Staleness().spent)
        XCTAssertFalse(Staleness(commits: 0, commitsUpstream: 0, added: 0, addedUpstream: 0).spent)
    }

    func testEveryCommitUpstreamIsEnoughOnItsOwn() {
        XCTAssertTrue(Staleness(commits: 3, commitsUpstream: 3).spent)
        XCTAssertFalse(Staleness(commits: 3, commitsUpstream: 2).spent)
    }

    /// The bar, stated: at most one added line in ten may still be missing.
    func testTheContentBar() {
        XCTAssertTrue(Staleness(commits: 1, added: 100, addedUpstream: 90).spent)
        XCTAssertFalse(Staleness(commits: 1, added: 100, addedUpstream: 89).spent)
    }

    /// A new file outranks every count on the struct.
    func testANewFileOutranksTheCounts() {
        XCTAssertFalse(Staleness(commits: 1, commitsUpstream: 1, newFiles: 1).spent)
        XCTAssertFalse(Staleness(commits: 1, added: 100, addedUpstream: 100, newFiles: 1).spent)
    }

    /// It says why, in both shapes, because `obsolete` is a claim about
    /// somebody's work and it has to show its working.
    func testItSaysWhy() {
        XCTAssertEqual(Staleness(commits: 1, commitsUpstream: 1).reason,
                       "its commit is already on the base")
        XCTAssertEqual(Staleness(commits: 4, commitsUpstream: 4).reason,
                       "all 4 commits are already on the base")
        XCTAssertEqual(Staleness(commits: 1, added: 590, addedUpstream: 551).reason,
                       "551 of 590 lines are already on the base")
    }

    /// A daemon older than this type sends no staleness at all, and a verdict
    /// without one is a verdict that simply did not ask.
    func testAVerdictWithoutStalenessIsNotSpent() throws {
        let json = #"{"base":"main","branch":"fix/x","baseSha":"aa","branchSha":"bb","clean":false}"#
        let verdict = try JSONDecoder().decode(MergeVerdict.self, from: Data(json.utf8))
        XCTAssertNil(verdict.staleness)
        XCTAssertFalse(verdict.spent)
        XCTAssertEqual(verdict.state, "conflicts")
    }

    func testStalenessSurvivesTheWire() throws {
        let verdict = MergeVerdict(base: "main", branch: "fix/x", baseSha: "aa", branchSha: "bb",
                                   clean: false, conflicts: ["a.swift"],
                                   staleness: Staleness(commits: 1, added: 10, addedUpstream: 10))
        let back = try JSONDecoder().decode(MergeVerdict.self,
                                            from: try JSONEncoder().encode(verdict))
        XCTAssertEqual(back.staleness, verdict.staleness)
        XCTAssertTrue(back.spent)
        XCTAssertEqual(back.state, "obsolete")
    }
}

/// When a resume dies because the harness has forgotten the conversation, that
/// is not a failed run — it is a run that never started, and a fresh agent gets
/// the same brief instead.
final class LostConversationTests: XCTestCase {

    /// What `claude --resume <gone> -p` actually prints. The brief for this
    /// said "exits non-zero without output"; it exits 1 and says so in a
    /// sentence, and reading only for silence would have meant the fallback
    /// never fired once.
    func testClaudeSaysSoInASentence() {
        let log = """
        \u{1B}[33mWarning: no stdin data received in 3s, proceeding without it.\u{1B}[39m
        No conversation found with session ID: 00000000-1111-2222-3333-444444444444
        """
        XCTAssertTrue(Supervisor.lostTheConversation(log))
        XCTAssertNotNil(Supervisor.lastWords(log), "it is not silent, which is the point")
    }

    /// And silence still counts: a harness can die before printing anything.
    func testSilenceCountsToo() {
        XCTAssertTrue(Supervisor.lostTheConversation(""))
        XCTAssertTrue(Supervisor.lostTheConversation("\u{1B}[2K\n╭──────╮\n"))
    }

    /// An agent that ran and had something to say did not lose its session, and
    /// must not be quietly restarted from nothing.
    func testAnAgentThatSpokeIsNotALostSession() {
        XCTAssertFalse(Supervisor.lostTheConversation(
            "rebasing…\nCONFLICT in Digest.swift\nI could not decide and I am stopping."))
        XCTAssertFalse(Supervisor.lostTheConversation("Credit balance is too low"))
    }
}
