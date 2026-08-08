import XCTest
@testable import ZeroCore

final class ToastPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let card = CGSize(width: 380, height: 92)

    func testTheFirstToastSitsInTheBottomRightCorner() {
        let origin = ToastPlacement.origin(remembered: nil, size: card, screens: [screen])
        XCTAssertEqual(origin?.x, 1440 - 380 - ToastPlacement.inset)
        XCTAssertEqual(origin?.y, ToastPlacement.inset)
    }

    func testTheNextToastComesBackWhereItWasDraggedTo() {
        let moved = CGPoint(x: 210, y: 640)
        let origin = ToastPlacement.origin(remembered: moved, size: card, screens: [screen])
        XCTAssertEqual(origin, moved)
    }

    func testAPositionOffTheEdgeIsPulledBackOnScreen() {
        let origin = ToastPlacement.origin(remembered: CGPoint(x: 1300, y: 870),
                                           size: card, screens: [screen])
        XCTAssertEqual(origin?.x, 1440 - 380 - ToastPlacement.margin)
        XCTAssertEqual(origin?.y, 900 - 92 - ToastPlacement.margin)
    }

    func testAPositionOnADisconnectedScreenGoesHome() {
        let gone = CGPoint(x: -1800, y: 300)
        let origin = ToastPlacement.origin(remembered: gone, size: card, screens: [screen])
        XCTAssertEqual(origin, ToastPlacement.resting(size: card, in: screen))
    }

    func testASecondScreenKeepsItsOwnCorner() {
        let second = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let there = CGPoint(x: -1000, y: 500)
        let origin = ToastPlacement.origin(remembered: there, size: card,
                                           screens: [screen, second])
        XCTAssertEqual(origin, there)
    }

    func testWithNoScreensThereIsNowhereToPutIt() {
        XCTAssertNil(ToastPlacement.origin(remembered: nil, size: card, screens: []))
    }

    func testAScreenSmallerThanTheCardStillGivesAPoint() {
        let tiny = CGRect(x: 0, y: 0, width: 100, height: 40)
        let origin = ToastPlacement.clamp(CGPoint(x: 500, y: 500), size: card, into: tiny)
        XCTAssertEqual(origin.x, ToastPlacement.margin)
        XCTAssertEqual(origin.y, ToastPlacement.margin)
    }
}
