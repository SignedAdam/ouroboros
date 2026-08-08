import XCTest
@testable import ZeroCore

final class ToastDwellTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testAToastStaysUpLongerThanTheOldFiveSeconds() {
        XCTAssertGreaterThan(ToastDwell.standard, 5)
    }

    func testTheClockRunsDownToZeroAndExpires() {
        let dwell = ToastDwell(total: 10, now: now)
        XCTAssertEqual(dwell.remaining(at: now), 10, accuracy: 0.001)
        XCTAssertEqual(dwell.fractionLeft(at: now.addingTimeInterval(4)), 0.6, accuracy: 0.001)
        XCTAssertFalse(dwell.hasExpired(at: now.addingTimeInterval(9.9)))
        XCTAssertTrue(dwell.hasExpired(at: now.addingTimeInterval(10)))
    }

    func testFractionNeverLeavesZeroToOne() {
        let dwell = ToastDwell(total: 10, now: now)
        XCTAssertEqual(dwell.fractionLeft(at: now.addingTimeInterval(-5)), 1, accuracy: 0.001)
        XCTAssertEqual(dwell.fractionLeft(at: now.addingTimeInterval(40)), 0, accuracy: 0.001)
    }

    func testPausingHoldsTheRemainingTimeStill() {
        var dwell = ToastDwell(total: 10, now: now)
        dwell.pause(at: now.addingTimeInterval(3))
        XCTAssertTrue(dwell.isPaused)
        XCTAssertEqual(dwell.remaining(at: now.addingTimeInterval(300)), 7, accuracy: 0.001)
        XCTAssertFalse(dwell.hasExpired(at: now.addingTimeInterval(300)))
    }

    func testPausingTwiceDoesNotGiveBackTime() {
        var dwell = ToastDwell(total: 10, now: now)
        dwell.pause(at: now.addingTimeInterval(3))
        dwell.pause(at: now.addingTimeInterval(8))
        XCTAssertEqual(dwell.remaining(at: now.addingTimeInterval(8)), 7, accuracy: 0.001)
    }

    func testResumingCarriesOnFromWhereItStopped() {
        var dwell = ToastDwell(total: 10, now: now)
        dwell.pause(at: now.addingTimeInterval(4))
        dwell.resume(at: now.addingTimeInterval(90))
        XCTAssertFalse(dwell.isPaused)
        XCTAssertEqual(dwell.remaining(at: now.addingTimeInterval(91)), 5, accuracy: 0.001)
    }

    func testLeavingTheToastLateStillLeavesTimeToRead() {
        var dwell = ToastDwell(total: 10, now: now)
        dwell.pause(at: now.addingTimeInterval(9.5))
        dwell.resume(at: now.addingTimeInterval(20), atLeast: 3)
        XCTAssertEqual(dwell.remaining(at: now.addingTimeInterval(20)), 3, accuracy: 0.001)
    }

    func testTheFloorNeverStretchesPastTheWholeDwell() {
        var dwell = ToastDwell(total: 2, now: now)
        dwell.pause(at: now.addingTimeInterval(1.9))
        dwell.resume(at: now.addingTimeInterval(5), atLeast: 30)
        XCTAssertEqual(dwell.remaining(at: now.addingTimeInterval(5)), 2, accuracy: 0.001)
    }

    func testUnpinningStartsTheWholeCountdownAgain() {
        var dwell = ToastDwell(total: 10, now: now)
        dwell.pause(at: now.addingTimeInterval(9.9))
        dwell.restart(at: now.addingTimeInterval(600))
        XCTAssertFalse(dwell.isPaused)
        XCTAssertEqual(dwell.remaining(at: now.addingTimeInterval(600)), 10, accuracy: 0.001)
    }

    func testATotalOfZeroCannotDivideTheRing() {
        let dwell = ToastDwell(total: 0, now: now)
        XCTAssertGreaterThan(dwell.total, 0)
        XCTAssertEqual(dwell.fractionLeft(at: now), 1, accuracy: 0.001)
    }
}
