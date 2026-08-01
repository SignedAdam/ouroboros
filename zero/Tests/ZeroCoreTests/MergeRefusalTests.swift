import XCTest
@testable import ZeroCore

/// The operator clicked merge, the panel said "merging…", and then nothing happened.
///
/// The merge had been refused for a good reason — uncommitted tracked changes,
/// which is exactly when you do not want a merge landing on top of you. But
/// `mergeNow` reported a refusal by handing back the unchanged `Run`, and a
/// completed merge by handing back a changed one. The daemon returned 200 for
/// both, so every caller except the inbox, which re-reads the run anyway, saw a
/// refusal as a success.
///
/// A verb that can be refused has to say so in its answer, not in a field the
/// caller has to know to go and look at.
final class MergeRefusalTests: XCTestCase {

    private var root: String!
    private var home: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "ouro-refuse-\(UUID().uuidString)"
        home = NSTemporaryDirectory() + "ouro-refuse-home-\(UUID().uuidString)"
        for path in [root!, home!] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let git = Git(root)
        git.run(["init", "-q", "-b", "main"])
        git.run(["config", "user.email", "test@ouroboros.local"])
        git.run(["config", "user.name", "Ouroboros Test"])
        git.run(["config", "commit.gpgsign", "false"])
        write("tracked.txt", "one\n")
        git.run(["add", "-A"])
        git.run(["commit", "-q", "-m", "base"])
    }

    override func tearDownWithError() throws {
        for path in [root, home].compactMap({ $0 }) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func write(_ name: String, _ body: String) {
        try? body.write(toFile: root + "/" + name, atomically: true, encoding: .utf8)
    }

    /// Builds a supervisor over the scratch repo with one verified run sitting
    /// on a branch, which is the state the inbox calls `review`.
    private func supervisorWithReviewableRun() throws -> (Supervisor, String) {
        let git = Git(root)
        git.run(["checkout", "-q", "-b", "fix/thing"])
        write("tracked.txt", "one\ntwo\n")
        git.run(["add", "-A"])
        git.run(["commit", "-q", "-m", "the fix"])
        git.run(["checkout", "-q", "main"])

        let registry = Registry(file: home + "/projects.json")
        let project = try XCTUnwrap(registry.register(path: root, name: "scratch"))
        let runs = RunStore(root: home + "/runs")
        _ = runs.save(Run(id: "r-refuse", projectId: project.id, projectName: project.name,
                          kind: .fix, agent: "claude", title: "the fix", cwd: root,
                          branch: "fix/thing", base: "main", finish: .merge,
                          status: .succeeded))
        let supervisor = Supervisor(config: Config(), registry: registry, runs: runs,
                                    issues: IssueService(registry: registry),
                                    events: EventBus(), notifier: Notifier(config: Config()),
                                    ouroPath: "/nonexistent/ouro", home: home)
        return (supervisor, "r-refuse")
    }

    func testADirtyTreeRefusesTheMergeAndSaysWhy() throws {
        let (supervisor, id) = try supervisorWithReviewableRun()
        // The thing that actually happened: an edited, tracked, uncommitted file.
        write("tracked.txt", "one\nedited by a human mid-thought\n")

        let (run, refused) = supervisor.mergeNow(id)
        XCTAssertNotNil(run)
        let reason = try XCTUnwrap(refused, "a refused merge must carry its reason")
        XCTAssertTrue(reason.lowercased().contains("uncommitted"), reason)
        XCTAssertNil(run?.mergedInto, "nothing may have landed")
    }

    func testACleanTreeMergesAndRefusesNothing() throws {
        let (supervisor, id) = try supervisorWithReviewableRun()

        let (run, refused) = supervisor.mergeNow(id)
        XCTAssertNil(refused, "a merge that happened has nothing to explain")
        XCTAssertEqual(run?.mergedInto, "main")
    }

    /// The second click. Without this the panel would merge, refresh, and offer
    /// merge again on a row that had already landed.
    func testMergingTwiceIsRefusedRatherThanRepeated() throws {
        let (supervisor, id) = try supervisorWithReviewableRun()
        _ = supervisor.mergeNow(id)

        let (_, refused) = supervisor.mergeNow(id)
        let reason = try XCTUnwrap(refused)
        XCTAssertTrue(reason.contains("already merged"), reason)
    }

    func testAnUnknownRunIsRefusedWithoutARun() throws {
        let (supervisor, _) = try supervisorWithReviewableRun()
        let (run, refused) = supervisor.mergeNow("r-does-not-exist")
        XCTAssertNil(run)
        XCTAssertEqual(refused, "no such run")
    }
}
