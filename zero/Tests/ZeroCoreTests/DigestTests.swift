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

// MARK: - the reflog as an activity feed

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
        // "Fast-forward" tells you nothing; the branch name tells you what landed.
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

// MARK: - digests

final class DigestTests: XCTestCase {
    /// The one distinction the drawer is built on: an issue with a run against
    /// it is a job; an issue without one is a task still waiting for you.
    func testTasksAreTheIssuesNobodyWasDispatchedFor() throws {
        let repo = scratch("digest")
        let store = IssueStore(rootDir: repo)
        let dispatched = try XCTUnwrap(store.write(title: "already being fixed", body: "one"))
        _ = try XCTUnwrap(store.write(title: "still waiting", body: "two"))

        let project = Project(id: "p", name: "p", path: repo, lastUsed: Date())
        let run = Run(id: "r-1", projectId: "p", projectName: "p", kind: .fix, agent: "claude",
                      title: "already being fixed", issuePath: dispatched.path, cwd: repo,
                      base: "main", finish: .merge, status: .running)

        let digest = Digests().digest(project, runs: [run])
        XCTAssertEqual(digest.taskCount, 1)
        XCTAssertEqual(digest.tasks.map(\.title), ["still waiting"])
        XCTAssertEqual(digest.jobs.map(\.id), ["r-1"])
        XCTAssertEqual(digest.running, 1)
        XCTAssertTrue(digest.handled)
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
        XCTAssertEqual(digest.taskCount, 0)
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

    /// The cache is keyed on directory mtimes, so a new issue has to show up
    /// without waiting for anything to expire.
    func testANewIssueInvalidatesTheCache() throws {
        let repo = scratch("cache")
        let store = IssueStore(rootDir: repo)
        _ = store.write(title: "first", body: "one")
        let digests = Digests()
        let project = Project(id: "c", name: "c", path: repo, lastUsed: Date())
        XCTAssertEqual(digests.digest(project, runs: []).taskCount, 1)

        _ = store.write(title: "second", body: "two")
        XCTAssertEqual(digests.digest(project, runs: []).taskCount, 2)
    }
}

// MARK: - ages

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

// MARK: - the wire

final class SnapshotDecodingTests: XCTestCase {
    /// A daemon that predates the drawer sends no `recents` and no `stats`. The
    /// app has to render an empty drawer, not decide it has lost the daemon.
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
                                   tasks: [TaskPip(id: "t1", title: "a", path: "/tmp/a.md")], taskCount: 1)
        let snapshot = API.Snapshot(
            health: HealthDTO(ok: true, version: "0.1.0", pid: 1, uptime: 1, projects: 1,
                              activeRuns: 0, queuedRuns: 0, inbox: 0),
            projects: [], inbox: [], activeRuns: [], recentRuns: [],
            recents: [digest],
            stats: API.Stats(handled: 3, fixed: 2, tape: [.succeeded, .failed]))
        let decoded = try XCTUnwrap(
            Zero.decode(API.Snapshot.self, from: Zero.encode(snapshot)))
        XCTAssertEqual(decoded.recents.first?.tasks.map(\.title), ["a"])
        XCTAssertEqual(decoded.recents.first?.autonomy, .assist)
        XCTAssertEqual(decoded.stats.tape, [RunStatus.succeeded, .failed])
        XCTAssertEqual(decoded.stats.fixed, 2)
    }
}
