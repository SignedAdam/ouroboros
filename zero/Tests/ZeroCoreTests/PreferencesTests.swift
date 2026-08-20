import XCTest
@testable import ZeroCore

private func tempHome(_ name: String) -> String {
    let path = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("zerotests-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

final class PreferencesStoreTests: XCTestCase {
    func testRoundTrip() {
        let prefs = Preferences(home: tempHome("prefs"))
        XCTAssertTrue(prefs.isEmpty)
        XCTAssertTrue(prefs.write("write tests for every fix"))
        XCTAssertEqual(prefs.text(), "write tests for every fix")

        XCTAssertTrue(prefs.append("no comments unless the code can't say it"))
        XCTAssertEqual(prefs.lines.count, 2)
        XCTAssertEqual(prefs.lines.last, "no comments unless the code can't say it")
    }

    func testClearingRemovesTheFile() {
        let prefs = Preferences(home: tempHome("prefs-clear"))
        prefs.write("keep the diffs small")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefs.file))

        XCTAssertTrue(prefs.clear())
        XCTAssertTrue(prefs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefs.file))
    }

    func testBlankWritesAreNotStored() {
        let prefs = Preferences(home: tempHome("prefs-blank"))
        prefs.append("   \n  ")
        XCTAssertTrue(prefs.isEmpty)

        prefs.write("  keep the diffs small \n")
        XCTAssertEqual(prefs.text(), "keep the diffs small")
    }

    func testASecondStoreOnTheSameHomeSeesTheWrite() {
        let home = tempHome("prefs-shared")
        Preferences(home: home).write("ask before adding a dependency")
        XCTAssertEqual(Preferences(home: home).text(), "ask before adding a dependency")
    }

    func testNothingIsRenderedForAnEmptyFile() {
        XCTAssertNil(Preferences(home: tempHome("prefs-none")).section())
        XCTAssertNil(Preferences.section("   \n\t "))
    }
}

final class PreferencesInPromptTests: XCTestCase {
    private var context: SupervisedPrompt.Context {
        SupervisedPrompt.Context(
            title: "Login button dead", body: "clicking it does nothing",
            issuePath: "/repo/.issues/new/x.md", branch: "fix/login", base: "main",
            worktree: true, verifyCmd: "swift build",
            resultPath: "/runs/r-1/result.json")
    }

    func testTheFixPromptCarriesThem() {
        var ctx = context
        ctx.preferences = "write tests for every fix"
        let prompt = SupervisedPrompt.fix(ctx)

        XCTAssertTrue(prompt.contains(Preferences.heading))
        XCTAssertTrue(prompt.contains("write tests for every fix"))
        XCTAssertTrue(prompt.contains("Where they contradict the work you were given above"))
    }

    func testTheContractStaysLast() {
        var ctx = context
        ctx.preferences = "write tests for every fix"
        let prompt = SupervisedPrompt.fix(ctx)

        guard let preferences = prompt.range(of: Preferences.heading),
              let contract = prompt.range(of: "/runs/r-1/result.json") else {
            return XCTFail("prompt is missing a section")
        }
        XCTAssertTrue(preferences.lowerBound < contract.lowerBound,
                      "the result-file contract must be the last thing the agent reads")
    }

    func testAnEmptyPreferenceFileAddsNothing() {
        XCTAssertFalse(SupervisedPrompt.fix(context).contains(Preferences.heading))

        var blank = context
        blank.preferences = "  \n "
        XCTAssertFalse(SupervisedPrompt.fix(blank).contains(Preferences.heading))
    }

    func testTheConflictPromptCarriesThemToo() {
        var ctx = SupervisedPrompt.ConflictContext(
            branch: "fix/login", base: "main",
            branchSha: "bbbbbbbbbbbbbbbb", baseSha: "aaaaaaaaaaaaaaaa",
            files: ["Sources/RowActions.swift"],
            resultPath: "/runs/r-3/result.json", verifyCmd: "swift build")
        ctx.preferences = "keep the diffs small"

        let prompt = SupervisedPrompt.resolve(ctx)
        XCTAssertTrue(prompt.contains("keep the diffs small"))
        XCTAssertTrue(prompt.contains("you never perform the merge"),
                      "the preferences must not displace the rules")
    }

    func testARawPromptGetsThemAppendedOnce() {
        let prefs = Preferences(home: tempHome("prefs-append"))
        prefs.write("write tests for every fix")

        let once = prefs.appended(to: "Rename the button to Save.")
        XCTAssertTrue(once.hasPrefix("Rename the button to Save."))
        XCTAssertTrue(once.contains("write tests for every fix"))

        XCTAssertEqual(prefs.appended(to: once), once,
                       "a re-dispatched prompt must not collect a second copy")
    }

    func testARawPromptIsUntouchedWhenThereAreNoPreferences() {
        let prefs = Preferences(home: tempHome("prefs-untouched"))
        XCTAssertEqual(prefs.appended(to: "Rename the button to Save."),
                       "Rename the button to Save.")
    }
}
