import XCTest
import Foundation
@testable import ZeroCore

private func tempDir(_ name: String) -> String {
    let path = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("zerotests-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

// MARK: - Registry

final class RegistryTests: XCTestCase {
    func testSlugIsStableAndDedupes() {
        XCTAssertEqual(Registry.slug("Atlas App", taken: []), "atlas-app")
        XCTAssertEqual(Registry.slug("Atlas App", taken: ["atlas-app"]), "atlas-app-2")
        XCTAssertEqual(Registry.slug("!!!", taken: []), "project")
    }

    func testNormalizeStripsTrailingSlashes() {
        XCTAssertEqual(Registry.normalize("/tmp/foo/"), "/tmp/foo")
        XCTAssertEqual(Registry.normalize("/tmp/foo//"), "/tmp/foo")
    }

    func testContainingPrefersTheDeepestProject() {
        let file = (tempDir("reg") as NSString).appendingPathComponent("projects.json")
        let registry = Registry(file: file)
        registry.upsert(Project(id: "outer", name: "outer", path: "/tmp/work"))
        registry.upsert(Project(id: "inner", name: "inner", path: "/tmp/work/api"))

        XCTAssertEqual(registry.containing("/tmp/work/api/src")?.id, "inner")
        XCTAssertEqual(registry.containing("/tmp/work/web")?.id, "outer")
        XCTAssertNil(registry.containing("/tmp/elsewhere"))
    }

    func testContainingDoesNotMatchSiblingPrefixes() {
        // "/tmp/work-2" must NOT be considered inside "/tmp/work".
        let file = (tempDir("reg2") as NSString).appendingPathComponent("projects.json")
        let registry = Registry(file: file)
        registry.upsert(Project(id: "work", name: "work", path: "/tmp/work"))
        XCTAssertNil(registry.containing("/tmp/work-2/src"))
    }

    func testFindByUnambiguousPrefix() {
        let file = (tempDir("reg3") as NSString).appendingPathComponent("projects.json")
        let registry = Registry(file: file)
        registry.upsert(Project(id: "atlas", name: "Atlas", path: "/tmp/a"))
        registry.upsert(Project(id: "lantern", name: "Lantern", path: "/tmp/b"))
        XCTAssertEqual(registry.find("mond")?.id, "atlas")
        XCTAssertEqual(registry.find("ATLAS")?.id, "atlas")
        XCTAssertNil(registry.find("nope"))
    }

    func testBulkRegistrationDoesNotCountAsUse() {
        // `ouro setup` adopts every repo under ~/dev at once. If that counted as
        // use, the capture panel's default project would be whichever of 57
        // registrations won a microsecond race.
        let dir = tempDir("bulk")
        let file = (dir as NSString).appendingPathComponent("projects.json")
        let registry = Registry(file: file)
        for name in ["zzworld", "alpha", "atlas"] {
            let path = (dir as NSString).appendingPathComponent(name)
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            registry.register(path: path)
        }
        XCTAssertTrue(registry.all().allSatisfy { $0.lastUsed == nil })
        XCTAssertEqual(registry.all().map(\.name), ["alpha", "atlas", "zzworld"],
                       "unused projects sort by name, not by registration race")
    }

    func testTouchedProjectsSortFirst() {
        let dir = tempDir("touched")
        let file = (dir as NSString).appendingPathComponent("projects.json")
        let registry = Registry(file: file)
        for name in ["alpha", "zzworld"] {
            let path = (dir as NSString).appendingPathComponent(name)
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            registry.register(path: path)
        }
        registry.touch("zzworld")
        XCTAssertEqual(registry.all().first?.name, "zzworld",
                       "the one you actually used leads")
    }

    func testRecentListsDoNotOverlap() {
        let dir = tempDir("recents")
        let file = (dir as NSString).appendingPathComponent("projects.json")
        let registry = Registry(file: file)
        let git = ["alpha", "beta", "gamma"]
        for name in git {
            let path = (dir as NSString).appendingPathComponent(name)
            try? FileManager.default.createDirectory(
                atPath: (path as NSString).appendingPathComponent(".git"),
                withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: ((path as NSString).appendingPathComponent(".git") as NSString)
                    .appendingPathComponent("logs/HEAD"),
                contents: Data("x".utf8))
            registry.register(path: path)
        }
        registry.touch("alpha")

        let used = registry.recentlyUsed(limit: 5)
        let byGit = registry.recentlyTouchedByGit(limit: 5, excluding: Set(used.map(\.id)))
        XCTAssertEqual(used.map(\.name), ["alpha"])
        XCTAssertFalse(byGit.contains { $0.id == "alpha" },
                       "a project must never appear in both lists")
        XCTAssertEqual(Set(byGit.map(\.name)), ["beta", "gamma"])
    }

    func testGitActivityFallsBackWhenLogsAreMissing() {
        let dir = tempDir("nogitlogs")
        let repo = (dir as NSString).appendingPathComponent("repo")
        try? FileManager.default.createDirectory(
            atPath: (repo as NSString).appendingPathComponent(".git"),
            withIntermediateDirectories: true)
        // A fresh clone has no logs/HEAD yet; the repo still exists and must rank.
        XCTAssertNotNil(Registry.gitActivity(at: repo))
        XCTAssertNil(Registry.gitActivity(at: tempDir("notarepo")))
    }

    func testGuessVerifyCommand() {
        let dir = tempDir("guess")
        FileManager.default.createFile(
            atPath: (dir as NSString).appendingPathComponent("Package.swift"), contents: Data())
        XCTAssertEqual(Registry.guessVerifyCommand(dir), "swift build")
        XCTAssertNil(Registry.guessVerifyCommand(tempDir("empty")))
    }
}

// MARK: - Runs

final class RunStoreTests: XCTestCase {
    private func makeRun(_ id: String = "r-1", status: RunStatus = .queued) -> Run {
        Run(id: id, projectId: "p", projectName: "P", kind: .fix, agent: "claude",
            title: "a title", cwd: "/tmp", base: "main", finish: .merge, status: status)
    }

    func testSaveAndReload() {
        let root = tempDir("runs")
        let store = RunStore(root: root)
        store.save(makeRun("r-abc-1234"))

        let reopened = RunStore(root: root)
        XCTAssertEqual(reopened.get("r-abc-1234")?.title, "a title")
    }

    func testShortIdLookupIsUnambiguousOnly() {
        let store = RunStore(root: tempDir("runs2"))
        store.save(makeRun("r-aaa-1111"))
        XCTAssertNotNil(store.get("r-aaa"))
        store.save(makeRun("r-aaa-2222"))
        XCTAssertNil(store.get("r-aaa"), "an ambiguous prefix must not resolve")
    }

    func testMutatePersists() {
        let root = tempDir("runs3")
        let store = RunStore(root: root)
        store.save(makeRun("r-x"))
        store.mutate("r-x") { $0.status = .succeeded; $0.note = "done" }
        XCTAssertEqual(RunStore(root: root).get("r-x")?.status, .succeeded)
    }

    func testStatusClassification() {
        XCTAssertTrue(RunStatus.running.isActive)
        XCTAssertTrue(RunStatus.queued.isActive)
        XCTAssertFalse(RunStatus.awaiting.isActive)
        XCTAssertTrue(RunStatus.failed.isTerminal)
        XCTAssertFalse(RunStatus.verifying.isTerminal)
    }
}

// MARK: - Inbox

final class InboxTests: XCTestCase {
    private func run(_ id: String, _ status: RunStatus, merged: String? = nil,
                     acknowledged: Bool = false, result: AgentResult? = nil) -> Run {
        var r = Run(id: id, projectId: "p", projectName: "P", kind: .fix, agent: "claude",
                    title: "t-\(id)", cwd: "/tmp", branch: "fix/x", base: "main",
                    finish: .merge, status: status)
        r.mergedInto = merged
        r.acknowledged = acknowledged
        r.result = result
        r.endedAt = Date()
        return r
    }

    func testOnlyDecisionsAppear() {
        let items = Inbox.build(runs: [
            run("a", .running),
            run("b", .queued),
            run("c", .verifying),
        ], proposals: [])
        XCTAssertTrue(items.isEmpty, "status is not a decision and must not enter the inbox")
    }

    func testQuestionsRankFirst() {
        let items = Inbox.build(runs: [
            run("landed", .succeeded, merged: "main"),
            run("failed", .failed),
            run("asked", .awaiting, result: AgentResult(outcome: "needs-input", question: "which?")),
        ], proposals: [])
        XCTAssertEqual(items.map(\.kind), [.question, .failed, .merged])
        XCTAssertEqual(items[0].detail, "which?")
    }

    func testSucceededWithoutMergeIsReadyNotLanded() {
        let items = Inbox.build(runs: [run("x", .succeeded)], proposals: [])
        XCTAssertEqual(items.first?.kind, .review)
        XCTAssertTrue(items.first!.actions.contains("merge"))
    }

    func testAcknowledgedRunsDisappear() {
        let items = Inbox.build(runs: [run("x", .failed, acknowledged: true)], proposals: [])
        XCTAssertTrue(items.isEmpty)
    }

    func testPendingProposalsOnly() {
        let pending = Proposal(id: "p1", projectId: "p", title: "one", body: "b",
                               source: "sentinel", dedupeKey: "k1")
        var dismissed = Proposal(id: "p2", projectId: "p", title: "two", body: "b",
                                 source: "sentinel", dedupeKey: "k2")
        dismissed.state = .dismissed
        let items = Inbox.build(runs: [], proposals: [pending, dismissed])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "one")
    }
}

// MARK: - Proposals

final class ProposalStoreTests: XCTestCase {
    func testDedupeSuppressesRepeats() {
        let store = ProposalStore(root: tempDir("prop"))
        let first = Proposal(id: "p1", projectId: "x", title: "misaligned button", body: "b",
                             source: "sentinel", dedupeKey: "x:misaligned-button")
        let second = Proposal(id: "p2", projectId: "x", title: "misaligned button", body: "b",
                              source: "sentinel", dedupeKey: "x:misaligned-button")

        let (a, createdA) = store.upsert(first)
        let (b, createdB) = store.upsert(second)
        XCTAssertTrue(createdA)
        XCTAssertFalse(createdB, "a screen watcher re-noticing the same thing must not refile it")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(store.pending().count, 1)
    }

    func testDismissedKeyCanBeFiledAgain() {
        let store = ProposalStore(root: tempDir("prop2"))
        _ = store.upsert(Proposal(id: "p1", projectId: "x", title: "t", body: "b",
                                  source: "s", dedupeKey: "k"))
        store.setState("p1", .dismissed)
        let (_, created) = store.upsert(Proposal(id: "p2", projectId: "x", title: "t", body: "b",
                                                 source: "s", dedupeKey: "k"))
        XCTAssertTrue(created)
    }
}

// MARK: - Ideas

final class IdeaStoreTests: XCTestCase {
    func testRoundTripWithProjectHint() {
        let store = IdeaStore(root: tempDir("ideas"))
        let idea = store.create(title: nil, body: "a webhook replay tool", projectId: "atlas")
        XCTAssertNotNil(idea)
        XCTAssertEqual(idea?.projectId, "atlas")
        XCTAssertEqual(idea?.body, "a webhook replay tool",
                       "the project hint must not leak into the body")

        let listed = store.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.title, "a webhook replay tool")
        XCTAssertNotNil(store.find(listed.first!.id))
    }

    func testRetiredIdeasLeaveTheList() {
        let store = IdeaStore(root: tempDir("ideas2"))
        _ = store.create(title: "x", body: "body")
        guard let (_, issue) = store.find(store.list().first!.id) else {
            return XCTFail("idea not found")
        }
        store.retire(issue)
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertEqual(store.list(includeDone: true).count, 1, "the trail is kept")
    }
}

// MARK: - Prompt

final class SupervisedPromptTests: XCTestCase {
    private var context: SupervisedPrompt.Context {
        SupervisedPrompt.Context(
            title: "Login button dead", body: "clicking it does nothing",
            issuePath: "/repo/.issues/new/x.md", branch: "fix/login", base: "main",
            worktree: true, verifyCmd: "swift build",
            resultPath: "/runs/r-1/result.json")
    }

    func testForbidsTheAgentFromLanding() {
        let prompt = SupervisedPrompt.fix(context)
        // The single most important property of the supervised prompt.
        XCTAssertTrue(prompt.contains("do NOT"))
        XCTAssertTrue(prompt.contains("merge, rebase onto, or push"))
        XCTAssertTrue(prompt.contains("move or resolve the issue file"))
    }

    func testCarriesTheContract() {
        let prompt = SupervisedPrompt.fix(context)
        XCTAssertTrue(prompt.contains("/runs/r-1/result.json"))
        XCTAssertTrue(prompt.contains("needs-input"))
        XCTAssertTrue(prompt.contains("swift build"))
        XCTAssertTrue(prompt.contains("fix/login"))
        XCTAssertTrue(prompt.contains("Login button dead"))
    }

    func testProtectedPathsAreStated() {
        var ctx = context
        ctx.protectedPaths = ["migrations/", "deploy/"]
        let prompt = SupervisedPrompt.fix(ctx)
        XCTAssertTrue(prompt.contains("migrations/, deploy/"))
    }

    func testReplyReplaysTheOriginal() {
        let prompt = SupervisedPrompt.reply(original: "ORIGINAL-PROMPT", question: "which one?",
                                            answer: "the second", resultPath: "/runs/r-2/result.json")
        XCTAssertTrue(prompt.hasPrefix("ORIGINAL-PROMPT"))
        XCTAssertTrue(prompt.contains("which one?"))
        XCTAssertTrue(prompt.contains("the second"))
    }

    func testResolutionSectionUsesTheAgentSummary() {
        let section = SupervisedPrompt.resolutionSection(
            summary: "Rewired the click handler.", branch: "fix/login", merged: "main")
        XCTAssertTrue(section.contains("## Resolution"))
        XCTAssertTrue(section.contains("Rewired the click handler."))
        XCTAssertTrue(section.contains("merged into `main`"))
    }

    func testResolutionSectionSurvivesASilentAgent() {
        let section = SupervisedPrompt.resolutionSection(summary: nil, branch: nil, merged: "main")
        XCTAssertTrue(section.contains("Fixed by an Ouroboros agent."))
    }
}

// MARK: - Transport

final class HTTPParsingTests: XCTestCase {
    func testSplitTargetDecodesQuery() {
        let (path, query) = HTTPServer.splitTarget("/v1/issues?project=my%20app&status=new")
        XCTAssertEqual(path, "/v1/issues")
        XCTAssertEqual(query["project"], "my app")
        XCTAssertEqual(query["status"], "new")
    }

    func testSplitTargetWithoutQuery() {
        let (path, query) = HTTPServer.splitTarget("/v1/health")
        XCTAssertEqual(path, "/v1/health")
        XCTAssertTrue(query.isEmpty)
    }

    func testFlagParsing() {
        let request = HTTPRequest(method: "GET", path: "/x",
                                  query: ["a": "true", "b": "0", "c": "maybe"],
                                  headers: [:], body: Data())
        XCTAssertEqual(request.flag("a"), true)
        XCTAssertEqual(request.flag("b"), false)
        XCTAssertNil(request.flag("c"))
        XCTAssertNil(request.flag("missing"))
    }
}

// MARK: - Paths

final class PathsTests: XCTestCase {
    func testLongHomeFallsBackToAShortSocketPath() {
        let deep = "/tmp/" + String(repeating: "a-very-long-directory-name/", count: 6)
        setenv("OUROBOROS_HOME", deep, 1)
        defer { unsetenv("OUROBOROS_HOME") }

        let socket = Paths.socket
        XCTAssertLessThan(socket.utf8.count, 104,
                          "sockaddr_un.sun_path is 104 bytes — bind() fails past that")
        XCTAssertTrue(socket.hasPrefix("/tmp/ouroboros-"))
    }

    func testShortHomeKeepsTheNaturalPath() {
        setenv("OUROBOROS_HOME", "/tmp/ouro-test", 1)
        defer { unsetenv("OUROBOROS_HOME") }
        XCTAssertEqual(Paths.socket, "/tmp/ouro-test/ourod.sock")
    }

    func testIDsAreUniqueAndPrefixed() {
        let ids = (0..<200).map { _ in Zero.newID("r") }
        XCTAssertEqual(Set(ids).count, 200)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("r-") })
    }
}

// MARK: - Config

final class ConfigTests: XCTestCase {
    func testOlderConfigsKeepTheirSettings() throws {
        // The regression that cost an evening: adding `hotkey` to the struct made
        // every existing config.json fail to decode, and load() wrote defaults
        // over the top. The user's `-p` flag vanished and every dispatched agent
        // launched an interactive TUI and hung.
        let json = """
        {"maxParallel": 7, "defaultAgent": "codex", "terminal": "tmux",
         "agents": {"claude": ["claude", "-p", "{prompt}"]},
         "projectsRoot": "~/code"}
        """
        let config = try XCTUnwrap(Zero.decode(Config.self, from: Data(json.utf8)))
        XCTAssertEqual(config.agents["claude"], ["claude", "-p", "{prompt}"])
        XCTAssertEqual(config.maxParallel, 7)
        XCTAssertEqual(config.defaultAgent, "codex")
        XCTAssertEqual(config.projectsRoot, "~/code")
        XCTAssertEqual(config.hotkey, "opt+space", "a missing field takes its default")
        XCTAssertNil(config.repoPath)
    }

    func testEmptyObjectDecodesToDefaults() throws {
        let config = try XCTUnwrap(Zero.decode(Config.self, from: Data("{}".utf8)))
        XCTAssertEqual(config.hotkey, Config().hotkey)
        XCTAssertEqual(config.agents, Config.defaultAgents)
    }

    func testDefaultAgentsAreNonInteractive() {
        // A supervised agent gets /dev/null on stdin. Any harness that would open
        // an interactive session here hangs forever with an empty log.
        for (name, argv) in Config.defaultAgents {
            XCTAssertGreaterThan(argv.count, 2,
                                 "\(name) needs a non-interactive flag, not just a prompt")
            XCTAssertTrue(argv.contains("{prompt}"), "\(name) must take the prompt")
        }
    }
}

// MARK: - Failure diagnosis

final class DiagnoseTests: XCTestCase {
    func testInheritedKeyIsNamedAsTheCause() {
        // The real failure in the field: the daemon was started from inside an agent
        // session, inherited its key, and every run died pointing at billing.
        let log = """
        ⚠ claude.ai connectors are disabled because ANTHROPIC_API_KEY or another auth
        source is set and takes precedence over your claude.ai login
        Credit balance is too low
        """
        let text = try! XCTUnwrap(Supervisor.diagnose(log))
        XCTAssertTrue(text.contains("daemon was started in"))
        XCTAssertTrue(text.contains("ouro daemon restart"))
    }

    func testPlainCreditFailureStaysPlain() {
        let text = try! XCTUnwrap(Supervisor.diagnose("Credit balance is too low"))
        XCTAssertTrue(text.contains("out of credit"))
        XCTAssertFalse(text.contains("daemon was started in"))
    }

    func testMissingCLI() {
        XCTAssertTrue(try XCTUnwrap(Supervisor.diagnose("zsh: command not found: claude"))
            .contains("PATH"))
    }

    func testOrdinaryFailureGetsNoDiagnosis() {
        XCTAssertNil(Supervisor.diagnose("error: cannot find 'foo' in scope"))
    }
}

// MARK: - Merge safety

final class GitMergeSafetyTests: XCTestCase {
    private func makeRepo() -> String {
        let dir = tempDir("repo")
        let git = Git(dir)
        git.run(["init", "-q", "-b", "main"])
        git.run(["config", "user.email", "t@t"])
        git.run(["config", "user.name", "t"])
        FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent("a.txt"),
                                       contents: Data("one\n".utf8))
        git.run(["add", "-A"])
        git.run(["commit", "-qm", "initial"])
        return dir
    }

    private func write(_ dir: String, _ name: String, _ text: String) {
        let path = (dir as NSString).appendingPathComponent(name)
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testCleanRepoIsMergeSafe() {
        XCTAssertFalse(Git(makeRepo()).hasUncommittedTrackedChanges())
    }

    func testUntrackedJunkDoesNotBlockAMerge() {
        // The bug this test exists for: a __pycache__ directory created by the
        // verification command blocked every auto-merge.
        let dir = makeRepo()
        write(dir, "__pycache__/x.pyc", "junk")
        write(dir, "scratch.txt", "notes")
        XCTAssertFalse(Git(dir).hasUncommittedTrackedChanges(),
                       "untracked files cannot break a merge — git guards that itself")
    }

    func testModifiedTrackedFileBlocksAMerge() {
        let dir = makeRepo()
        write(dir, "a.txt", "changed\n")
        XCTAssertTrue(Git(dir).hasUncommittedTrackedChanges())
    }

    func testStagedChangeBlocksAMerge() {
        let dir = makeRepo()
        write(dir, "b.txt", "new\n")
        Git(dir).run(["add", "b.txt"])
        XCTAssertTrue(Git(dir).hasUncommittedTrackedChanges())
    }

    func testOuroborosOwnChurnIsIgnored() {
        let dir = makeRepo()
        write(dir, ".issues/new/thing.md", "# thing")
        Git(dir).run(["add", "-A", ".issues"])
        XCTAssertFalse(Git(dir).hasUncommittedTrackedChanges(),
                       "the issue being fixed must never block its own merge")
    }

    func testNotARepoIsTreatedAsUnsafe() {
        XCTAssertTrue(Git(tempDir("norepo")).hasUncommittedTrackedChanges())
    }
}

// MARK: - Failure reporting

final class LastWordsTests: XCTestCase {
    func testExtractsTheFinalMeaningfulLine() {
        let log = """
        \u{1B}[33mwarning: something\u{1B}[39m
        ╭──────────────╮
        │              │
        ╰──────────────╯
        Credit balance is too low
        \u{1B}[?25h
        """
        XCTAssertEqual(Supervisor.lastWords(log), "Credit balance is too low")
    }

    func testNilWhenThereIsNothingToSay() {
        XCTAssertNil(Supervisor.lastWords("\n\n   \n"))
    }

    func testTruncatesLongLines() {
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(Supervisor.lastWords(long, limit: 20)?.count, 20)
    }
}

// MARK: - Policy

final class PolicyTests: XCTestCase {
    func testAutonomyDecidesTheDefaultFinishOnly() {
        var project = Project(id: "p", name: "P", path: "/tmp")
        project.policy.autonomy = .manual
        XCTAssertEqual(Supervisor.defaultFinish(for: project), .leave)
        project.policy.autonomy = .assist
        XCTAssertEqual(Supervisor.defaultFinish(for: project), .leave)
        project.policy.autonomy = .auto
        XCTAssertEqual(Supervisor.defaultFinish(for: project), .merge)
    }

    func testNewProjectsAreManual() {
        XCTAssertEqual(Policy().autonomy, .manual)
        XCTAssertTrue(Policy().worktreeDefault)
    }
}
