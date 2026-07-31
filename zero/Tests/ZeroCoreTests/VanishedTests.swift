import XCTest
@testable import ZeroCore

/// A deleted row is hidden by the app before the daemon's next snapshot agrees.
/// The part worth testing is letting go again — a row that stays hidden for ever
/// because a call silently failed is worse than the delay this exists to remove.
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

    /// Once the daemon stops listing it, there is nothing left to hide.
    func testReconcileForgetsRowsTheDaemonNoLongerLists() {
        var vanished = Vanished()
        vanished.hide("gone")
        vanished.reconcile(live: ["still-here"])
        XCTAssertTrue(vanished.isEmpty)
    }

    /// The row stays hidden while the snapshot has not caught up yet — this is
    /// the whole point of the type, and it is the common case.
    func testRowStaysHiddenWhileTheSnapshotLags() {
        let now = Date()
        var vanished = Vanished()
        vanished.hide("issue", at: now)
        vanished.reconcile(live: ["issue"], now: now.addingTimeInterval(1))
        XCTAssertTrue(vanished.contains("issue"))
    }

    /// But not for ever. A delete that failed server-side has to look like a
    /// failed delete, which means the row coming back.
    func testARowTheDaemonKeepsListingComesBack() {
        let now = Date()
        var vanished = Vanished()
        vanished.hide("issue", at: now)
        vanished.reconcile(live: ["issue"],
                           now: now.addingTimeInterval(Vanished.grace + 0.1))
        XCTAssertFalse(vanished.contains("issue"))
    }

    /// Two deletes of the same row are one delete: the second must not push the
    /// deadline out and keep a stuck row hidden indefinitely.
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
