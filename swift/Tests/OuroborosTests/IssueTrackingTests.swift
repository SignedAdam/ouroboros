import XCTest
@testable import Ouroboros

final class IssueTrackingTests: XCTestCase {
    private func tempDir() -> String {
        let p = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ouroboros-tracking-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    // MARK: - IssueStatus + Issue metadata fields

    func testIssueStatusCases() {
        XCTAssertEqual(IssueStatus.allCases.map(\.rawValue), ["new", "planned", "done", "cancelled"])
    }

    func testIssueDefaultsKeepOldArity() {
        let issue = Issue(title: "T", slug: "t", body: "b", path: "/x.md")
        XCTAssertNil(issue.created)
        XCTAssertEqual(issue.status, .new)
        let dated = Issue(title: "T", slug: "t", body: "b", path: nil,
                          created: Date(timeIntervalSince1970: 100), status: .done)
        XCTAssertEqual(dated.created, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(dated.status, .done)
    }

    // MARK: - statusDir layout rule

    func testStatusDirReplacesStatusSuffix() {
        let store = IssueStore(rootDir: "/repo")
        XCTAssertEqual(store.statusDir(.new), "/repo/.issues/new")
        XCTAssertEqual(store.statusDir(.done), "/repo/.issues/done")
        XCTAssertEqual(store.statusDir(.cancelled), "/repo/.issues/cancelled")
    }

    func testStatusDirAppendsWhenSubdirHasNoStatusSuffix() {
        let store = IssueStore(rootDir: "/repo", subdir: "tickets")
        XCTAssertEqual(store.statusDir(.new), "/repo/tickets/new")
        XCTAssertEqual(store.statusDir(.planned), "/repo/tickets/planned")
    }
}
