import XCTest
@testable import ZeroCore

// ⇥ / ⇧⇥ in the capture panel. The key is swallowed before the text field ever
// sees it, so every one of these edge cases fails as "tab does nothing" or as a
// crash on a keystroke — neither of which a diff shows.

final class ProjectCycleTests: XCTestCase {
    private let order = ["zero", "orbit", "lantern", "harbor"]

    func testTabWalksTowardsTheOlderProjects() {
        XCTAssertEqual(ProjectCycle.step(from: "zero", in: order, by: 1), "orbit")
        XCTAssertEqual(ProjectCycle.step(from: "orbit", in: order, by: 1), "lantern")
        XCTAssertEqual(ProjectCycle.step(from: "lantern", in: order, by: 1), "harbor")
    }

    func testShiftTabWalksBack() {
        XCTAssertEqual(ProjectCycle.step(from: "harbor", in: order, by: -1), "lantern")
        XCTAssertEqual(ProjectCycle.step(from: "lantern", in: order, by: -1), "orbit")
        XCTAssertEqual(ProjectCycle.step(from: "orbit", in: order, by: -1), "zero")
    }

    func testItIsARingAtBothEnds() {
        XCTAssertEqual(ProjectCycle.step(from: "harbor", in: order, by: 1), "zero")
        XCTAssertEqual(ProjectCycle.step(from: "zero", in: order, by: -1), "harbor")
    }

    func testAWholeLapLandsWhereItStarted() {
        var id: String? = "zero"
        for _ in order.indices { id = ProjectCycle.step(from: id, in: order, by: 1) }
        XCTAssertEqual(id, "zero")
    }

    /// A project picked from the full folder menu need not be in the recents.
    func testAnUnknownSelectionEntersFromTheEndYouAreWalkingTowards() {
        XCTAssertEqual(ProjectCycle.step(from: "atlantis", in: order, by: 1), "zero")
        XCTAssertEqual(ProjectCycle.step(from: "atlantis", in: order, by: -1), "harbor")
        XCTAssertEqual(ProjectCycle.step(from: nil, in: order, by: 1), "zero")
        XCTAssertEqual(ProjectCycle.step(from: nil, in: order, by: -1), "harbor")
    }

    func testNothingToWalkLeavesTheSelectionAlone() {
        XCTAssertNil(ProjectCycle.step(from: "zero", in: [], by: 1))
        XCTAssertNil(ProjectCycle.step(from: nil, in: [], by: -1))
    }

    func testOneProjectIsAlwaysItself() {
        XCTAssertEqual(ProjectCycle.step(from: "zero", in: ["zero"], by: 1), "zero")
        XCTAssertEqual(ProjectCycle.step(from: "zero", in: ["zero"], by: -1), "zero")
    }

    /// Held-down tab arrives as a stream of single steps, but nothing stops a
    /// caller passing a bigger one — it must still land inside the list.
    func testStepsLargerThanTheListStayInBounds() {
        XCTAssertEqual(ProjectCycle.step(from: "zero", in: order, by: 9), "orbit")
        XCTAssertEqual(ProjectCycle.step(from: "zero", in: order, by: -9), "harbor")
        XCTAssertEqual(ProjectCycle.step(from: "lantern", in: order, by: 0), "lantern")
    }
}
