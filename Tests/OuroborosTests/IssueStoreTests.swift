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
        let store = IssueStore(rootDir: root)
        let issue = store.write(title: "Fix login", body: "  the button does nothing  ")
        XCTAssertNotNil(issue)
        let expectedPath = (root as NSString)
            .appendingPathComponent(".issues/new/Fix login.md")
        XCTAssertEqual(issue?.path, expectedPath)
        let content = try String(contentsOfFile: expectedPath, encoding: .utf8)
        XCTAssertEqual(content, "## Fix login\n\nthe button does nothing\n")
        XCTAssertEqual(issue?.slug, "fix-login")
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
