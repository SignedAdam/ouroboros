import XCTest
@testable import ZeroCore

/// The question the capture panel gets wrong most easily: which right-click
/// verbs close it. These lock the answer down by name, so adding a verb to a
/// menu without deciding is a failing test rather than a panel that vanishes
/// under someone who was only trying to delete an issue.
final class RowVerbTests: XCTestCase {

    /// A verb whose whole result is inside the panel leaves it exactly where
    /// it was. Deleting is the one this issue was filed about.
    func testVerbsWithNothingElseToShowKeepThePanelOpen() {
        let stays: [RowVerb] = [
            .delete, .forget, .hide, .favourite, .captureInto, .defaultAgent, .autonomy,
            .copyPath, .copyTitle, .copyCommand,
            .merge, .rebase, .undoMerge, .stop, .clear, .markDone,
            // The diff is a sheet on this panel and `reply` writes into the
            // field you are looking at. Neither is another window.
            .diff, .reply,
        ]
        for verb in stays {
            XCTAssertFalse(verb.handsOff, "\(verb.rawValue) should leave the panel open")
        }
    }

    /// A verb that puts another window in front of you takes the panel away
    /// with it — otherwise it is floating over the thing you asked for.
    func testVerbsThatOpenAWindowCloseThePanel() {
        let closes: [RowVerb] = [
            .openFile, .openFinder, .openTerminal, .openAgentView, .openWorktree,
            .resume, .fix, .retry, .watch,
        ]
        for verb in closes {
            XCTAssertTrue(verb.handsOff, "\(verb.rawValue) should close the panel behind it")
        }
    }

    /// Both lists together are the whole enum: a new verb cannot be added
    /// without landing in one of them.
    func testEveryVerbIsClassified() {
        XCTAssertEqual(RowVerb.allCases.count, 27)
        let handsOff = RowVerb.allCases.filter(\.handsOff)
        XCTAssertEqual(handsOff.count, 9)
        XCTAssertEqual(RowVerb.allCases.count - handsOff.count, 18)
    }

    /// A verb without a word and a glyph is a verb nobody can put on a row.
    func testEveryVerbHasSomethingToDraw() {
        for verb in RowVerb.allCases {
            XCTAssertFalse(verb.label.isEmpty, "\(verb.rawValue) has no label")
            XCTAssertFalse(verb.symbol.isEmpty, "\(verb.rawValue) has no symbol")
            XCTAssertEqual(verb.label, verb.label.lowercased(),
                           "\(verb.rawValue): row copy is lower case")
        }
    }
}

/// The table the drawer draws from: which verbs a row offers, by state.
final class WorkStateVerbTests: XCTestCase {

    /// Three at the outside. A row with six buttons is a row nobody reads.
    func testNoRowOffersMoreThanThreeVerbs() {
        for state in WorkState.allCases {
            let verbs = state.verbs
            XCTAssertFalse(verbs.isEmpty, "\(state.rawValue) offers nothing")
            XCTAssertLessThanOrEqual(verbs.count, 3, "\(state.rawValue) offers too much")
            XCTAssertEqual(Set(verbs).count, verbs.count, "\(state.rawValue) repeats a verb")
        }
    }

    /// The one that matters: a branch that will not go in is never offered a
    /// merge. Ouroboros calling a run `ready` without having tried the merge is
    /// the bug this whole state exists to close, and offering the action is the
    /// same claim as printing the word.
    func testConflictsOffersRebaseAndNeverMerge() {
        XCTAssertEqual(WorkState.conflicts.verbs, [.diff, .rebase])
        XCTAssertFalse(WorkState.conflicts.verbs.contains(.merge))
    }

    /// Only the state that actually merges gets the merge.
    func testOnlyReviewOffersMerge() {
        for state in WorkState.allCases where state != .review {
            XCTAssertFalse(state.verbs.contains(.merge),
                           "\(state.rawValue) should not offer merge")
        }
        XCTAssertTrue(WorkState.review.verbs.contains(.merge))
    }

    /// Live work can be watched and stopped; nothing live can be marked done,
    /// because it is not done.
    func testLiveWorkIsWatchedAndStopped() {
        XCTAssertEqual(WorkState.running.verbs, [.watch, .stop])
        XCTAssertEqual(WorkState.queued.verbs, [.watch, .stop])
        XCTAssertEqual(WorkState.asking.verbs, [.reply, .watch])
        for state in WorkState.allCases where state.isLive {
            XCTAssertFalse(state.verbs.contains(.markDone),
                           "\(state.rawValue) is not finished")
        }
    }

    /// A verb only appears on a row that has something for it to act on.
    func testDiffIsOnlyOfferedWhereABranchExists() {
        for state in WorkState.allCases where state.verbs.contains(.diff) {
            XCTAssertTrue(state.hasDiff, "\(state.rawValue) offers a diff it does not have")
        }
    }

    /// Only dispatching waits before the panel goes: its terminal takes a
    /// moment to appear, and a panel that vanishes onto an unchanged screen
    /// reads as a click that did nothing.
    func testOnlyDispatchGetsABeatBeforeClosing() {
        XCTAssertEqual(RowVerb.fix.beat, 0.5)
        XCTAssertEqual(RowVerb.retry.beat, 0.5)
        for verb in RowVerb.allCases where verb != .fix && verb != .retry {
            XCTAssertEqual(verb.beat, 0, "\(verb.rawValue) should close immediately")
        }
    }

    /// A verb that keeps the panel open has no business asking for a pause
    /// before closing it.
    func testNoStayingVerbAsksForABeat() {
        for verb in RowVerb.allCases where !verb.handsOff {
            XCTAssertEqual(verb.beat, 0, "\(verb.rawValue) never closes, so its beat is moot")
        }
    }
}
