import XCTest
@testable import Ouroboros

final class IssueStoreTests: XCTestCase {
    private func tempDir() -> String {
        let p = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ouroboros-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func testWriteCreatesFileWithExpectedContent() throws {
        let root = tempDir()
        let pinned = ISO8601DateFormatter().date(from: "2026-07-03T02:55:12Z")!
        let store = IssueStore(rootDir: root, now: { pinned })
        let issue = store.write(title: "Fix login", body: "  the button does nothing  ")
        XCTAssertNotNil(issue)
        let expectedPath = (root as NSString)
            .appendingPathComponent(".issues/new/Fix login.md")
        XCTAssertEqual(issue?.path, expectedPath)
        let content = try String(contentsOfFile: expectedPath, encoding: .utf8)
        XCTAssertEqual(content, """
        ---
        title: Fix login
        created: 2026-07-03T02:55:12Z
        ---

        ## Fix login

        the button does nothing

        """)
        XCTAssertEqual(issue?.slug, "fix-login")
        XCTAssertEqual(issue?.created, pinned)
        XCTAssertEqual(issue?.status, .new)
    }

    func testWriteDedupsOnCollision() {
        let root = tempDir()
        let store = IssueStore(rootDir: root)
        let a = store.write(title: "Same", body: "first")
        let b = store.write(title: "Same", body: "second")
        XCTAssertTrue(a!.path!.hasSuffix(".issues/new/Same.md"))
        XCTAssertTrue(b!.path!.hasSuffix(".issues/new/Same 2.md"))
    }

    func testWriteRejectsEmpty() {
        let store = IssueStore(rootDir: tempDir())
        XCTAssertNil(store.write(title: "", body: "x"))
        XCTAssertNil(store.write(title: "x", body: "   "))
    }
}
