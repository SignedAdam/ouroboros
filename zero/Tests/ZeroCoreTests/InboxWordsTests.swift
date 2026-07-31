import XCTest
@testable import ZeroCore

/// `ready` became `review` and `landed` became `merged`. The words are the
/// point of the change, but the compatibility is the part that breaks quietly:
/// every run already on disk and every `notifyOn` in a config file was written
/// with the old ones.
final class InboxWordsTests: XCTestCase {

    func testTheNewWordsAreWhatGetsWritten() {
        XCTAssertEqual(InboxItem.Kind.review.rawValue, "review")
        XCTAssertEqual(InboxItem.Kind.merged.rawValue, "merged")
    }

    /// A run.json written by an older build still decodes, and decodes to the
    /// same item — not to a failure that would take the whole inbox with it.
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

    /// The untouched three are untouched.
    func testTheOtherKindsAreUnchanged() throws {
        let decoder = JSONDecoder()
        for word in ["question", "failed", "proposal"] {
            XCTAssertEqual(try decoder.decode(InboxItem.Kind.self, from: Data("\"\(word)\"".utf8)).rawValue,
                           word)
        }
    }

    /// A word from neither vocabulary is still an error. Leniency about two
    /// renames is not leniency about anything at all.
    func testAnUnknownKindStillFails() {
        XCTAssertThrowsError(try JSONDecoder().decode(InboxItem.Kind.self,
                                                      from: Data("\"nonsense\"".utf8)))
    }

    /// `notifyOn: ["question","failed","landed","ready"]` is in a config file
    /// on a real machine right now. It has to go on meaning what it meant.
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

    /// A whole item round-trips through the wire, written new and read new.
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
