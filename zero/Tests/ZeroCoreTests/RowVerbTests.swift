import XCTest
@testable import ZeroCore

final class RowVerbTests: XCTestCase {
    func testVerbsWithNothingElseToShowKeepThePanelOpen() {
        let stays: [RowVerb] = [
            .delete, .forget, .hide, .favourite, .captureInto, .defaultAgent, .autonomy,
            .copyPath, .copyTitle, .copyCommand,
            .merge, .rebase, .undoMerge, .stop, .clear, .markDone,

            .diff, .reply,

            .discard,
        ]
        for verb in stays {
            XCTAssertFalse(verb.handsOff, "\(verb.rawValue) should leave the panel open")
        }
    }

    func testVerbsThatOpenAWindowCloseThePanel() {
        let closes: [RowVerb] = [
            .openFile, .openFinder, .openTerminal, .openAgentView, .openWorktree,

            .resume, .fix, .retry, .watch, .resolve,
        ]
        for verb in closes {
            XCTAssertTrue(verb.handsOff, "\(verb.rawValue) should close the panel behind it")
        }
    }

    func testEveryVerbIsClassified() {
        XCTAssertEqual(RowVerb.allCases.count, 29)
        let handsOff = RowVerb.allCases.filter(\.handsOff)
        XCTAssertEqual(handsOff.count, 10)
        XCTAssertEqual(RowVerb.allCases.count - handsOff.count, 19)
    }

    func testEveryVerbHasSomethingToDraw() {
        for verb in RowVerb.allCases {
            XCTAssertFalse(verb.label.isEmpty, "\(verb.rawValue) has no label")
            XCTAssertFalse(verb.symbol.isEmpty, "\(verb.rawValue) has no symbol")
            XCTAssertEqual(verb.label, verb.label.lowercased(),
                           "\(verb.rawValue): row copy is lower case")
        }
    }
}

final class WorkStateVerbTests: XCTestCase {
    func testNoRowOffersMoreThanThreeVerbs() {
        for state in WorkState.allCases {
            let verbs = state.verbs
            XCTAssertFalse(verbs.isEmpty, "\(state.rawValue) offers nothing")
            XCTAssertLessThanOrEqual(verbs.count, 3, "\(state.rawValue) offers too much")
            XCTAssertEqual(Set(verbs).count, verbs.count, "\(state.rawValue) repeats a verb")
        }
    }

    func testConflictsOffersRebaseAndNeverMerge() {
        XCTAssertEqual(WorkState.conflicts.verbs, [.resolve, .diff, .rebase])
        XCTAssertFalse(WorkState.conflicts.verbs.contains(.merge))
    }

    func testResolveComesFirstOnAConflictingRow() {
        XCTAssertEqual(WorkState.conflicts.verbs.first, .resolve)
        XCTAssertEqual(WorkState.conflicts.verbs.last, .rebase)
    }

    func testObsoleteOffersOnlyReadingAndLettingGo() {
        XCTAssertEqual(WorkState.obsolete.verbs, [.diff, .discard])
        XCTAssertFalse(WorkState.obsolete.verbs.contains(.merge))
        XCTAssertFalse(WorkState.obsolete.verbs.contains(.resolve))
        XCTAssertFalse(WorkState.obsolete.verbs.contains(.rebase))
    }

    func testOnlyObsoleteOffersDiscard() {
        for state in WorkState.allCases where state != .obsolete {
            XCTAssertFalse(state.verbs.contains(.discard),
                           "\(state.rawValue) should not offer discard")
        }
    }

    func testOnlyConflictsOffersResolve() {
        for state in WorkState.allCases where state != .conflicts {
            XCTAssertFalse(state.verbs.contains(.resolve),
                           "\(state.rawValue) should not offer resolve")
        }
    }

    func testObsoleteDoesNotWaitOnYou() {
        XCTAssertFalse(WorkState.obsolete.needsYou)
        XCTAssertFalse(WorkState.obsolete.isLive)
    }

    func testOnlyReviewOffersMerge() {
        for state in WorkState.allCases where state != .review {
            XCTAssertFalse(state.verbs.contains(.merge),
                           "\(state.rawValue) should not offer merge")
        }
        XCTAssertTrue(WorkState.review.verbs.contains(.merge))
    }

    func testLiveWorkIsWatchedAndStopped() {
        XCTAssertEqual(WorkState.running.verbs, [.watch, .stop])
        XCTAssertEqual(WorkState.queued.verbs, [.watch, .stop])
        XCTAssertEqual(WorkState.asking.verbs, [.reply, .watch])
        for state in WorkState.allCases where state.isLive {
            XCTAssertFalse(state.verbs.contains(.markDone),
                           "\(state.rawValue) is not finished")
        }
    }

    func testDiffIsOnlyOfferedWhereABranchExists() {
        for state in WorkState.allCases where state.verbs.contains(.diff) {
            XCTAssertTrue(state.hasDiff, "\(state.rawValue) offers a diff it does not have")
        }
    }

    func testOnlyDispatchGetsABeatBeforeClosing() {
        let dispatches: Set<RowVerb> = [.fix, .retry, .resolve]
        for verb in dispatches {
            XCTAssertEqual(verb.beat, 0.5, "\(verb.rawValue) starts an agent")
        }
        for verb in RowVerb.allCases where !dispatches.contains(verb) {
            XCTAssertEqual(verb.beat, 0, "\(verb.rawValue) should close immediately")
        }
    }

    func testNoStayingVerbAsksForABeat() {
        for verb in RowVerb.allCases where !verb.handsOff {
            XCTAssertEqual(verb.beat, 0, "\(verb.rawValue) never closes, so its beat is moot")
        }
    }
}
