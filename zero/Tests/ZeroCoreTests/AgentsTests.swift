import XCTest
import Foundation
@testable import ZeroCore

private func scratchDir(_ name: String) -> String {
    let path = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("zeroagents-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

// MARK: - which harness is this

final class HarnessDetectionTests: XCTestCase {
    func testRecognisesTheUsualSuspects() {
        XCTAssertEqual(Harness.of(agent: "claude", template: ["claude", "-p", "{prompt}"]), .claude)
        XCTAssertEqual(Harness.of(agent: "codex", template: ["codex", "exec", "{prompt}"]), .codex)
        XCTAssertEqual(Harness.of(agent: "gemini", template: ["gemini", "-p", "{prompt}"]), .gemini)
    }

    /// The executable is the truth, not the key someone filed it under.
    func testAnAbsolutePathIsStillTheSameHarness() {
        XCTAssertEqual(
            Harness.of(agent: "my-agent", template: ["/opt/homebrew/bin/claude", "{prompt}"]),
            .claude)
    }

    func testAnUnknownHarnessLosesTheExtrasButNotDispatch() {
        let harness = Harness.of(agent: "bespoke", template: ["/usr/local/bin/bespoke", "{prompt}"])
        XCTAssertEqual(harness, .other)
        XCTAssertFalse(harness.canResume)
        XCTAssertFalse(harness.acceptsSessionId)
        XCTAssertNil(Agents.resumeArgv(harness: harness, template: nil, sessionId: "x"))
    }
}

// MARK: - telling a harness which conversation this is

final class DispatchArgvTests: XCTestCase {
    func testClaudeIsToldItsSessionId() {
        let argv = Agents.dispatchArgv(template: ["claude", "-p", "{prompt}"],
                                       prompt: "fix the button", sessionId: "abc-123",
                                       harness: .claude)
        XCTAssertEqual(argv, ["claude", "--session-id", "abc-123", "-p", "fix the button"])
    }

    /// Codex will not be told, so nothing is injected and the argv is exactly
    /// what the user configured.
    func testCodexIsLeftAlone() {
        let argv = Agents.dispatchArgv(template: ["codex", "exec", "{prompt}"],
                                       prompt: "fix the button", sessionId: "abc-123",
                                       harness: .codex)
        XCTAssertEqual(argv, ["codex", "exec", "fix the button"])
    }

    /// A hand-written template is law: `{session}` says where the id goes, and
    /// nothing else is added around it.
    func testAnExplicitPlaceholderWins() {
        let argv = Agents.dispatchArgv(
            template: ["claude", "--session-id={session}", "-p", "{prompt}"],
            prompt: "hello", sessionId: "abc-123", harness: .claude)
        XCTAssertEqual(argv, ["claude", "--session-id=abc-123", "-p", "hello"])
    }

    func testAnAlreadyPresentFlagIsNotDuplicated() {
        let argv = Agents.dispatchArgv(
            template: ["claude", "--session-id", "mine", "-p", "{prompt}"],
            prompt: "hello", sessionId: "ignored", harness: .claude)
        XCTAssertEqual(argv, ["claude", "--session-id", "mine", "-p", "hello"])
    }
}

final class ResumeArgvTests: XCTestCase {
    func testEachHarnessKnowsItsOwnWayBackIn() {
        XCTAssertEqual(
            Agents.resumeArgv(harness: .claude, template: ["claude", "-p"], sessionId: "s1"),
            ["claude", "--resume", "s1"])
        XCTAssertEqual(
            Agents.resumeArgv(harness: .codex, template: ["codex", "exec"], sessionId: "s2"),
            ["codex", "resume", "s2"])
        XCTAssertNil(Agents.resumeArgv(harness: .gemini, template: ["gemini"], sessionId: "s3"))
    }

    func testResumeUsesTheConfiguredExecutable() {
        XCTAssertEqual(
            Agents.resumeArgv(harness: .claude, template: ["/opt/bin/claude", "-p"],
                              sessionId: "s"),
            ["/opt/bin/claude", "--resume", "s"])
    }

    func testAgentViewIsScopedToTheProject() {
        XCTAssertEqual(Agents.agentViewArgv(cwd: "/Users/a/dev/atlas", template: ["claude"]),
                       ["claude", "agents", "--cwd", "/Users/a/dev/atlas"])
    }
}

// MARK: - asking a harness that would not be told

final class CodexSessionDiscoveryTests: XCTestCase {
    private func rollout(in root: String, id: String, cwd: String, day: String = "2026/07/29") {
        let dir = (root as NSString).appendingPathComponent(day)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let line = """
        {"timestamp":"2026-07-29T10:00:00.000Z","type":"session_meta","payload":\
        {"id":"\(id)","cwd":"\(cwd)","originator":"codex_cli_rs"}}
        """
        try? (line + "\n").write(
            toFile: (dir as NSString).appendingPathComponent("rollout-2026-07-29T10-00-00-\(id).jsonl"),
            atomically: true, encoding: .utf8)
    }

    func testFindsTheRolloutForThisWorkingDirectory() {
        let root = scratchDir("codex")
        rollout(in: root, id: "aaaa-1111", cwd: "/Users/a/dev/other")
        rollout(in: root, id: "bbbb-2222", cwd: "/Users/a/dev/atlas")

        let found = Agents.discoverCodexSession(
            cwd: "/Users/a/dev/atlas", since: Date().addingTimeInterval(-60), root: root)
        XCTAssertEqual(found, "bbbb-2222")
    }

    /// A conversation from before this run started is somebody else's.
    func testIgnoresRolloutsOlderThanTheRun() {
        let root = scratchDir("codex-old")
        rollout(in: root, id: "cccc-3333", cwd: "/Users/a/dev/atlas")
        let path = (root as NSString)
            .appendingPathComponent("2026/07/29/rollout-2026-07-29T10-00-00-cccc-3333.jsonl")
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: path)

        XCTAssertNil(Agents.discoverCodexSession(cwd: "/Users/a/dev/atlas", since: Date(),
                                                 root: root))
    }

    func testNoSessionsAtAllIsNotAnError() {
        XCTAssertNil(Agents.discoverCodexSession(cwd: "/Users/a/dev/atlas", since: Date(),
                                                 root: scratchDir("codex-empty")))
    }

    func testAPathThatIsNotAnAbsoluteMatchIsNotAMatch() {
        let root = scratchDir("codex-prefix")
        rollout(in: root, id: "dddd-4444", cwd: "/Users/a/dev/atlas-2")
        XCTAssertNil(Agents.discoverCodexSession(
            cwd: "/Users/a/dev/atlas", since: Date().addingTimeInterval(-60), root: root))
    }
}

// MARK: - curation

final class ProjectCurationTests: XCTestCase {
    private func registry(_ name: String) -> Registry {
        Registry(file: (scratchDir(name) as NSString).appendingPathComponent("projects.json"))
    }

    /// The whole promise of "hide until it is active again": Ouroboros being
    /// used here brings it back, and nothing else does.
    func testUsingAProjectUnhidesIt() {
        let reg = registry("hide")
        var project = Project(id: "p", name: "p", path: "/tmp/p")
        project.hidden = true
        reg.upsert(project)
        XCTAssertTrue(reg.find("p")?.hidden ?? false)

        reg.touch("p")
        XCTAssertFalse(reg.find("p")?.hidden ?? true)
        XCTAssertNotNil(reg.find("p")?.lastUsed)
    }

    /// The registry outlives the app, so the flags have to survive a reload —
    /// and a registry written before these fields existed has to still load.
    func testFlagsSurviveAReloadAndOldFilesStillDecode() throws {
        let file = (scratchDir("persist") as NSString).appendingPathComponent("projects.json")
        let reg = Registry(file: file)
        var project = Project(id: "p", name: "p", path: "/tmp/p")
        project.favourite = true
        reg.upsert(project)

        XCTAssertTrue(Registry(file: file).find("p")?.favourite ?? false)

        // A registry from before favourites existed.
        try """
        [{"id":"old","name":"old","path":"/tmp/old","policy":{"autonomy":"manual",\
        "maxParallel":2,"worktreeDefault":true,"finishDefault":"merge","protectedPaths":[]},\
        "createdAt":"2026-07-01T00:00:00Z"}]
        """.write(toFile: file, atomically: true, encoding: .utf8)
        let reloaded = Registry(file: file)
        XCTAssertEqual(reloaded.all().count, 1)
        XCTAssertFalse(reloaded.find("old")?.favourite ?? true)
        XCTAssertFalse(reloaded.find("old")?.hidden ?? true)
    }
}
