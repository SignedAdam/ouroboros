import XCTest
@testable import ZeroCore

final class VanishedTests: XCTestCase {
    private struct Row: Identifiable { let id: String }

    func testHiddenRowsAreDroppedFromTheList() {
        var vanished = Vanished()
        vanished.hide("b")
        let rows = [Row(id: "a"), Row(id: "b"), Row(id: "c")]
        XCTAssertEqual(vanished.visible(rows).map(\.id), ["a", "c"])
    }

    func testNothingIsHiddenUntilSomethingIsDeleted() {
        let vanished = Vanished()
        XCTAssertTrue(vanished.isEmpty)
        XCTAssertFalse(vanished.contains("a"))
        XCTAssertEqual(vanished.visible([Row(id: "a")]).map(\.id), ["a"])
    }

    func testReconcileForgetsRowsTheDaemonNoLongerLists() {
        var vanished = Vanished()
        vanished.hide("gone")
        vanished.reconcile(live: ["still-here"])
        XCTAssertTrue(vanished.isEmpty)
    }

    func testRowStaysHiddenWhileTheSnapshotLags() {
        let now = Date()
        var vanished = Vanished()
        vanished.hide("issue", at: now)
        vanished.reconcile(live: ["issue"], now: now.addingTimeInterval(1))
        XCTAssertTrue(vanished.contains("issue"))
    }

    func testARowTheDaemonKeepsListingComesBack() {
        let now = Date()
        var vanished = Vanished()
        vanished.hide("issue", at: now)
        vanished.reconcile(live: ["issue"],
                           now: now.addingTimeInterval(Vanished.grace + 0.1))
        XCTAssertFalse(vanished.contains("issue"))
    }

    func testHidingTwiceDoesNotRestartTheClock() {
        let now = Date()
        var vanished = Vanished()
        vanished.hide("issue", at: now)
        vanished.hide("issue", at: now.addingTimeInterval(Vanished.grace - 0.1))
        vanished.reconcile(live: ["issue"],
                           now: now.addingTimeInterval(Vanished.grace + 0.1))
        XCTAssertFalse(vanished.contains("issue"))
    }

    func testRowsAreHiddenOneAtATimeAndCounted() {
        var vanished = Vanished()
        vanished.hide("a")
        vanished.hide("b")
        XCTAssertEqual(vanished.count, 2)
        vanished.reconcile(live: ["a"])
        XCTAssertEqual(vanished.count, 1)
        XCTAssertTrue(vanished.contains("a"))
    }
}
