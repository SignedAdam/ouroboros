import XCTest
import Foundation
import Ouroboros
@testable import ZeroCore

private func scratch(_ name: String) -> String {
    let path = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("zerodigest-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

final class GitLogDescribeTests: XCTestCase {
    func testCommitKeepsItsSubject() {
        let (kind, text) = GitLog.describe("commit: feat(zero): a drawer that latches on")
        XCTAssertEqual(kind, "commit")
        XCTAssertEqual(text, "feat(zero): a drawer that latches on")
    }

    func testAmendedAndInitialCommitsAreStillCommits() {
        XCTAssertEqual(GitLog.describe("commit (amend): fix the thing").kind, "commit")
        XCTAssertEqual(GitLog.describe("commit (initial): first").kind, "commit")
        XCTAssertEqual(GitLog.describe("commit (amend): fix the thing").text, "fix the thing")
    }

    func testMergeReportsTheBranchNotTheStrategy() {
        let (kind, text) = GitLog.describe("merge feat/behavior-profiles: Fast-forward")
        XCTAssertEqual(kind, "merge")
        XCTAssertEqual(text, "feat/behavior-profiles")
    }

    func testCheckoutReportsWhereYouEndedUp() {
        let (kind, text) = GitLog.describe("checkout: moving from main to fix/the-panel")
        XCTAssertEqual(kind, "checkout")
        XCTAssertEqual(text, "fix/the-panel")
    }

    func testMessageWithoutAColonStillHasAKind() {
        XCTAssertEqual(GitLog.describe("pull").kind, "pull")
        XCTAssertEqual(GitLog.describe("pull").text, "")
    }
}

final class GitLogTailTests: XCTestCase {
    func testReadsTheLastLineOfARealisticReflog() throws {
        let repo = scratch("reflog")
        let logs = (repo as NSString).appendingPathComponent(".git/logs")
        try FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        let lines = [
            "0000000000000000000000000000000000000000 a1b2c3d A Developer <dev@example.com> 1785200000 +0200\tcommit (initial): first",
            "a1b2c3d e4f5a6b A Developer <dev@example.com> 1785306646 +0200\tcommit: fix(zero): adding a config field no longer erases the config",
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(toFile: (logs as NSString).appendingPathComponent("HEAD"),
                   atomically: true, encoding: .utf8)

        let pulse = try XCTUnwrap(GitLog.lastEvent(repo: repo))
        XCTAssertEqual(pulse.kind, "commit")
        XCTAssertEqual(pulse.text, "fix(zero): adding a config field no longer erases the config")
        XCTAssertEqual(pulse.at.timeIntervalSince1970, 1_785_306_646, accuracy: 1)
    }

    func testTailSurvivesALogLongerThanItsWindow() throws {
        let dir = scratch("bigreflog")
        let path = (dir as NSString).appendingPathComponent("HEAD")
        var lines: [String] = []
        for i in 0..<400 {
            lines.append("a\(i) b\(i) Someone With A Long Name <x@y.z> 17853000\(i % 10)0 +0200\tcommit: entry \(i)")
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let line = try XCTUnwrap(GitLog.tail(of: path))
        XCTAssertTrue(line.hasSuffix("commit: entry 399"), line)
    }

    func testNoRepoIsNotAnError() {
        XCTAssertNil(GitLog.lastEvent(repo: scratch("bare")))
    }
}

final class DigestTests: XCTestCase {
    func testFiledIsTheIssuesNobodyWasDispatchedFor() throws {
        let repo = scratch("digest")
        let store = IssueStore(rootDir: repo)
        let dispatched = try XCTUnwrap(store.write(title: "already being fixed", body: "one"))
        _ = try XCTUnwrap(store.write(title: "still waiting", body: "two"))

        let project = Project(id: "p", name: "p", path: repo, lastUsed: Date())
        let run = Run(id: "r-1", projectId: "p", projectName: "p", kind: .fix, agent: "claude",
                      title: "already being fixed", issuePath: dispatched.path, cwd: repo,
                      base: "main", finish: .merge, status: .running)

        let digest = Digests().digest(project, runs: [run])
        XCTAssertEqual(digest.openCount, 1)

        XCTAssertEqual(digest.issues.map(\.state), [.running, .filed])
        XCTAssertEqual(digest.issues.map(\.title), ["already being fixed", "still waiting"])
        XCTAssertEqual(digest.issues.first?.runId, "r-1")
        XCTAssertNil(digest.issues.last?.runId)
        XCTAssertEqual(digest.running, 1)
        XCTAssertTrue(digest.handled)
    }

    func testARunStillFindsItsIssueAfterTheFileMoved() throws {
        let repo = scratch("moved")
        let store = IssueStore(rootDir: repo)
        let issue = try XCTUnwrap(store.write(title: "the receipt total is wrong", body: "…"))
        let dispatchedPath = try XCTUnwrap(issue.path)
        let run = Run(id: "r-2", projectId: "p", projectName: "p", kind: .fix, agent: "claude",
                      title: "the receipt total is wrong", issuePath: dispatchedPath, cwd: repo,
                      base: "main", finish: .merge, status: .succeeded, mergedInto: "main")
        _ = store.setStatus(issue, .done)

        let project = Project(id: "p", name: "p", path: repo, lastUsed: Date())
        let digest = Digests().digest(project, runs: [run])
        XCTAssertEqual(digest.issues.count, 1)
        XCTAssertEqual(digest.issues.first?.state, .merged)

        XCTAssertEqual(digest.issues.first?.id,
                       IssueService.id(project: project,
                                       path: (repo as NSString)
                                           .appendingPathComponent(".issues/done/"
                                               + (dispatchedPath as NSString).lastPathComponent)))
        XCTAssertEqual(digest.openCount, 0)
    }

    func testRetriesCollapseIntoOneRowWithACount() throws {
        let repo = scratch("retries")
        let store = IssueStore(rootDir: repo)
        let issue = try XCTUnwrap(store.write(title: "flaky", body: "…"))
        let project = Project(id: "p", name: "p", path: repo, lastUsed: Date())
        func run(_ id: String, _ status: RunStatus) -> Run {
            Run(id: id, projectId: "p", projectName: "p", kind: .fix, agent: "claude",
                title: "flaky", issuePath: issue.path, cwd: repo, base: "main",
                finish: .merge, status: status)
        }

        let digest = Digests().digest(project, runs: [run("r-4", .running), run("r-3", .failed)])
        XCTAssertEqual(digest.issues.count, 1)
        XCTAssertEqual(digest.issues.first?.attempts, 2)
        XCTAssertEqual(digest.issues.first?.state, .running)
    }

    func testAProjectOuroborosHasNeverTouchedFallsBackToGit() throws {
        let repo = scratch("untouched")
        let logs = (repo as NSString).appendingPathComponent(".git/logs")
        try FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        try "a b Someone <s@x.y> 1785306646 +0200\tcommit: something entirely unrelated\n"
            .write(toFile: (logs as NSString).appendingPathComponent("HEAD"),
                   atomically: true, encoding: .utf8)

        let digest = Digests().digest(Project(id: "q", name: "q", path: repo), runs: [])
        XCTAssertFalse(digest.handled)
        XCTAssertEqual(digest.pulse?.kind, "commit")
        XCTAssertEqual(digest.pulse?.text, "something entirely unrelated")
        XCTAssertEqual(digest.openCount, 0)
    }

    func testAHandledProjectLeadsWithItsLastIssue() throws {
        let repo = scratch("handled")
        let logs = (repo as NSString).appendingPathComponent(".git/logs")
        try FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        try "a b Someone <s@x.y> 1785306646 +0200\tcommit: a commit\n"
            .write(toFile: (logs as NSString).appendingPathComponent("HEAD"),
                   atomically: true, encoding: .utf8)
        _ = IssueStore(rootDir: repo).write(title: "the drawer will not fold", body: "…")

        let digest = Digests().digest(Project(id: "h", name: "h", path: repo, lastUsed: Date()),
                                      runs: [])
        XCTAssertEqual(digest.pulse?.kind, "filed")
        XCTAssertEqual(digest.pulse?.text, "the drawer will not fold")
    }

    func testANewIssueInvalidatesTheCache() throws {
        let repo = scratch("cache")
        let store = IssueStore(rootDir: repo)
        _ = store.write(title: "first", body: "one")
        let digests = Digests()
        let project = Project(id: "c", name: "c", path: repo, lastUsed: Date())
        XCTAssertEqual(digests.digest(project, runs: []).openCount, 1)

        _ = store.write(title: "second", body: "two")
        XCTAssertEqual(digests.digest(project, runs: []).openCount, 2)
    }

    func testTheTallyCountsPastTheSixRowsTheDrawerDraws() throws {
        let repo = scratch("tally-cap")
        let store = IssueStore(rootDir: repo)
        for i in 0..<9 { _ = store.write(title: "filed \(i)", body: "…") }

        let digest = Digests().digest(Project(id: "t", name: "t", path: repo, lastUsed: Date()),
                                      runs: [])
        XCTAssertEqual(digest.issues.count, 6)
        XCTAssertEqual(digest.tally.filed, 9)
        XCTAssertEqual(digest.tally.open, 9)
    }

    func testTheTallySeparatesReviewFromLanded() throws {
        let repo = scratch("tally-states")
        let store = IssueStore(rootDir: repo)
        let project = Project(id: "s", name: "s", path: repo, lastUsed: Date())

        var runs: [Run] = []
        func dispatched(_ id: String, _ title: String, _ status: RunStatus,
                        merged: String? = nil) throws {
            let issue = try XCTUnwrap(store.write(title: title, body: "…"))
            runs.append(Run(id: id, projectId: "s", projectName: "s", kind: .fix,
                            agent: "claude", title: title, issuePath: issue.path, cwd: repo,
                            base: "main", finish: .merge, status: status, mergedInto: merged))
        }
        try dispatched("r-a", "in flight", .running)
        try dispatched("r-b", "asked me something", .awaiting)
        try dispatched("r-c", "verified, not merged", .succeeded)
        try dispatched("r-d", "merged", .succeeded, merged: "main")
        try dispatched("r-e", "blew up", .failed)
        _ = store.write(title: "nobody has looked at this", body: "…")

        let tally = Digests().digest(project, runs: runs).tally
        XCTAssertEqual(tally.running, 1)
        XCTAssertEqual(tally.asking, 1)

        XCTAssertEqual(tally.review, 1)
        XCTAssertEqual(tally.merged, 1)
        XCTAssertEqual(tally.failed, 1)
        XCTAssertEqual(tally.filed, 1)

        XCTAssertEqual(tally.open, 5)
        XCTAssertEqual(tally.total, 6)
        XCTAssertEqual(tally.yours, 3)
        XCTAssertEqual(tally.openStates.map(\.state),
                       [.asking, .failed, .review, .running, .filed])
    }

    func testADigestWithoutATallyStillDecodes() throws {
        let json = """
        {"id":"p","name":"p","path":"/tmp/p","handled":true,"issues":[],"openCount":2}
        """
        let digest = try JSONDecoder().decode(ProjectDigest.self, from: Data(json.utf8))
        XCTAssertEqual(digest.openCount, 2)
        XCTAssertEqual(digest.tally.total, 0)
        XCTAssertTrue(digest.tally.openStates.isEmpty)
    }
}

final class AgoTests: XCTestCase {
    func testTheWholeScale() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ seconds: TimeInterval) -> String {
            Ago.short(now.addingTimeInterval(-seconds), now: now)
        }
        XCTAssertEqual(ago(0), "now")
        XCTAssertEqual(ago(44), "now")
        XCTAssertEqual(ago(60 * 3), "3m")
        XCTAssertEqual(ago(3_600 * 5), "5h")
        XCTAssertEqual(ago(86_400 * 3), "3d")
        XCTAssertEqual(ago(86_400 * 20), "2w")
        XCTAssertEqual(ago(86_400 * 400), "1y")
    }

    func testAFutureTimestampReadsAsNow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Ago.short(now.addingTimeInterval(90), now: now), "now")
    }
}

final class SnapshotDecodingTests: XCTestCase {
    func testASnapshotWithoutTheNewFieldsStillDecodes() throws {
        let json = """
        {"health":{"ok":true,"version":"0.1.0","pid":1,"uptime":1,"projects":0,
        "activeRuns":0,"queuedRuns":0,"inbox":0},"projects":[],"inbox":[],
        "activeRuns":[],"recentRuns":[]}
        """
        let snapshot = try XCTUnwrap(Zero.decode(API.Snapshot.self, from: Data(json.utf8)))
        XCTAssertTrue(snapshot.recents.isEmpty)
        XCTAssertEqual(snapshot.stats.handled, 0)
        XCTAssertTrue(snapshot.health.ok)
    }

    func testRoundTrip() throws {
        let digest = ProjectDigest(id: "p", name: "p", path: "/tmp/p", handled: true,
                                   autonomy: .assist,
                                   pulse: Pulse(kind: "filed", text: "x", at: Date()),
                                   issues: [IssuePip(id: "t1", title: "a", state: .filed,
                                                     at: Date(), path: "/tmp/a.md")],
                                   openCount: 1)
        let snapshot = API.Snapshot(
            health: HealthDTO(ok: true, version: "0.1.0", pid: 1, uptime: 1, projects: 1,
                              activeRuns: 0, queuedRuns: 0, inbox: 0),
            projects: [], inbox: [], activeRuns: [], recentRuns: [],
            recents: [digest],
            stats: API.Stats(handled: 3, fixed: 2, tape: [.succeeded, .failed]))
        let decoded = try XCTUnwrap(
            Zero.decode(API.Snapshot.self, from: Zero.encode(snapshot)))
        XCTAssertEqual(decoded.recents.first?.issues.map(\.title), ["a"])
        XCTAssertEqual(decoded.recents.first?.issues.first?.state, .filed)
        XCTAssertEqual(decoded.recents.first?.autonomy, .assist)
        XCTAssertEqual(decoded.stats.tape, [RunStatus.succeeded, .failed])
        XCTAssertEqual(decoded.stats.fixed, 2)
    }
}

final class WorkStateWordsTests: XCTestCase {
    private func succeeded(merge: MergeVerdict? = nil, mergedInto: String? = nil) -> Run {
        Run(id: "r", projectId: "p", projectName: "p", kind: .fix, agent: "claude",
            title: "t", cwd: "/tmp", branch: "fix/t", base: "main", finish: .leave,
            status: .succeeded, mergedInto: mergedInto, merge: merge)
    }

    private func verdict(clean: Bool, error: String? = nil,
                         staleness: Staleness? = nil) -> MergeVerdict {
        MergeVerdict(base: "main", branch: "fix/t", baseSha: "aaa", branchSha: "bbb",
                     clean: clean, conflicts: clean ? [] : ["a.swift"], error: error,
                     staleness: staleness)
    }

    private let spent = Staleness(commits: 2, commitsUpstream: 2)

    func testAVerifiedBranchThatStillMergesIsUpForReview() {
        XCTAssertEqual(WorkState.of(succeeded(merge: verdict(clean: true))), .review)
    }

    func testAVerifiedBranchThatNoLongerMergesSaysSo() {
        XCTAssertEqual(WorkState.of(succeeded(merge: verdict(clean: false))), .conflicts)
    }

    func testAnUnaskableQuestionIsNotAConflict() {
        let unknown = verdict(clean: false, error: "not a git repository")
        XCTAssertEqual(WorkState.of(succeeded(merge: unknown)), .review)
    }

    func testASpentBranchIsObsoleteRatherThanConflicting() {
        XCTAssertEqual(WorkState.of(succeeded(merge: verdict(clean: false, staleness: spent))),
                       .obsolete)
    }

    func testASpentBranchThatStillMergesIsAlsoObsolete() {
        XCTAssertEqual(WorkState.of(succeeded(merge: verdict(clean: true, staleness: spent))),
                       .obsolete)
    }

    func testAnUnaskableQuestionIsNeverObsolete() {
        let unknown = verdict(clean: false, error: "not a git repository", staleness: spent)
        XCTAssertEqual(WorkState.of(succeeded(merge: unknown)), .review)
    }

    func testABranchWithSomethingLeftIsStillAConflict() {
        let partial = Staleness(commits: 2, commitsUpstream: 1, added: 100, addedUpstream: 40)
        XCTAssertEqual(WorkState.of(succeeded(merge: verdict(clean: false, staleness: partial))),
                       .conflicts)
    }

    func testMergedOutranksObsolete() {
        XCTAssertEqual(WorkState.of(succeeded(merge: verdict(clean: true, staleness: spent),
                                              mergedInto: "main")), .merged)
    }

    func testNoVerdictReadsAsReview() {
        XCTAssertEqual(WorkState.of(succeeded()), .review)
    }

    func testSomethingThatWentInIsMerged() {
        XCTAssertEqual(WorkState.of(succeeded(mergedInto: "main")), .merged)
    }

    func testAnOpenPRCountsAsMerged() {
        var run = succeeded()
        run.result = AgentResult(outcome: "done", prUrl: "https://example.com/pr/1")
        XCTAssertEqual(WorkState.of(run), .merged)
    }

    func testTheOldSpellingsStillDecode() throws {
        XCTAssertEqual(try decodeState("\"ready\""), .review)
        XCTAssertEqual(try decodeState("\"landed\""), .merged)
        XCTAssertEqual(try decodeState("\"filed\""), .filed)
    }

    func testAWordFromNeitherVocabularyIsStillAnError() {
        XCTAssertThrowsError(try decodeState("\"almost\""))
    }

    private func decodeState(_ json: String) throws -> WorkState {
        try JSONDecoder().decode(WorkState.self, from: Data(json.utf8))
    }

    func testWhatCountsAsWaitingOnYou() {
        XCTAssertEqual(Set(WorkState.allCases.filter(\.needsYou)),
                       [.asking, .review, .conflicts])
    }
}

final class DeletedIssueTests: XCTestCase {
    func testARunWhoseIssueWasDeletedIsNotDrawn() throws {
        let repo = scratch("deleted")
        let store = IssueStore(rootDir: repo)
        let issue = try XCTUnwrap(store.write(title: "never mind", body: "…"))
        let path = try XCTUnwrap(issue.path)
        let run = Run(id: "r-1", projectId: "p", projectName: "p", kind: .fix, agent: "claude",
                      title: "never mind", issuePath: path, cwd: repo,
                      base: "main", finish: .leave, status: .succeeded)

        let project = Project(id: "p", name: "p", path: repo, lastUsed: Date())
        XCTAssertEqual(Digests().digest(project, runs: [run]).issues.count, 1)

        try FileManager.default.removeItem(atPath: path)
        XCTAssertTrue(Digests().digest(project, runs: [run]).issues.isEmpty)
    }

    func testACancelledIssueIsNotAStateTheDrawerShows() throws {
        let repo = scratch("cancelled")
        let store = IssueStore(rootDir: repo)
        let issue = try XCTUnwrap(store.write(title: "the bright hairline", body: "…"))
        let run = Run(id: "r-2", projectId: "p", projectName: "p", kind: .fix, agent: "claude",
                      title: "the bright hairline", issuePath: issue.path, cwd: repo,
                      base: "main", finish: .leave, status: .succeeded)
        _ = store.setStatus(issue, .cancelled)

        let project = Project(id: "p", name: "p", path: repo, lastUsed: Date())
        let digest = Digests().digest(project, runs: [run])
        XCTAssertTrue(digest.issues.isEmpty)
        XCTAssertEqual(digest.openCount, 0)
    }

    func testAFreeformRunIsUntouched() {
        let repo = scratch("freeform")
        let run = Run(id: "r-3", projectId: "p", projectName: "p", kind: .freeform,
                      agent: "claude", title: "one-off", cwd: repo,
                      base: "main", finish: .leave, status: .running)
        let project = Project(id: "p", name: "p", path: repo, lastUsed: Date())
        XCTAssertEqual(Digests().digest(project, runs: [run]).issues.map(\.title), ["one-off"])
    }
}
