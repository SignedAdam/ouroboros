import XCTest
@testable import ZeroCore

final class InboxWordsTests: XCTestCase {
    func testTheNewWordsAreWhatGetsWritten() {
        XCTAssertEqual(InboxItem.Kind.review.rawValue, "review")
        XCTAssertEqual(InboxItem.Kind.merged.rawValue, "merged")
    }

    func testTheOldWordsStillDecode() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(InboxItem.Kind.self, from: Data("\"ready\"".utf8)),
                       .review)
        XCTAssertEqual(try decoder.decode(InboxItem.Kind.self, from: Data("\"landed\"".utf8)),
                       .merged)
    }

    func testTheNewWordsDecode() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(InboxItem.Kind.self, from: Data("\"review\"".utf8)),
                       .review)
        XCTAssertEqual(try decoder.decode(InboxItem.Kind.self, from: Data("\"merged\"".utf8)),
                       .merged)
    }

    func testTheOtherKindsAreUnchanged() throws {
        let decoder = JSONDecoder()
        for word in ["question", "failed", "proposal"] {
            XCTAssertEqual(try decoder.decode(InboxItem.Kind.self, from: Data("\"\(word)\"".utf8)).rawValue,
                           word)
        }
    }

    func testAnUnknownKindStillFails() {
        XCTAssertThrowsError(try JSONDecoder().decode(InboxItem.Kind.self,
                                                      from: Data("\"nonsense\"".utf8)))
    }

    func testAnOldNotifyOnStillSelectsTheSameKinds() {
        let configured = ["question", "failed", "landed", "ready"]
        let canonical = Set(configured.map(InboxItem.Kind.canonical))
        XCTAssertTrue(canonical.contains(InboxItem.Kind.merged.rawValue))
        XCTAssertTrue(canonical.contains(InboxItem.Kind.review.rawValue))
        XCTAssertEqual(canonical, ["question", "failed", "merged", "review"])
    }

    func testCanonicalLeavesCurrentWordsAlone() {
        XCTAssertEqual(InboxItem.Kind.canonical("review"), "review")
        XCTAssertEqual(InboxItem.Kind.canonical("merged"), "merged")
        XCTAssertEqual(InboxItem.Kind.canonical("question"), "question")
    }

    func testAnItemRoundTrips() throws {
        let item = InboxItem(id: "r-1", kind: .review, projectName: "p", title: "t",
                             detail: "d", createdAt: Date(), runId: "r-1",
                             actions: ["merge", "diff"])
        let data = try JSONEncoder().encode(item)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"review\""))
        let back = try JSONDecoder().decode(InboxItem.self, from: data)
        XCTAssertEqual(back.kind, .review)
    }
}
