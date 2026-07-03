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

    // MARK: - read (frontmatter roundtrip + legacy tolerance)

    func testReadRoundtripsFrontmatter() {
        let root = tempDir()
        let pinned = ISO8601DateFormatter().date(from: "2026-07-03T02:55:12Z")!
        let store = IssueStore(rootDir: root, now: { pinned })
        let written = store.write(title: "Fix login", body: "the button does nothing")!
        let issue = store.read(path: written.path!)
        XCTAssertEqual(issue?.title, "Fix login")
        XCTAssertEqual(issue?.slug, "fix-login")
        XCTAssertEqual(issue?.body, "the button does nothing")
        XCTAssertEqual(issue?.created, pinned)
        XCTAssertEqual(issue?.status, .new)
        XCTAssertEqual(issue?.path, written.path)
    }

    func testReadInfersStatusFromParentFolder() throws {
        let root = tempDir()
        let store = IssueStore(rootDir: root)
        let doneDir = (root as NSString).appendingPathComponent(".issues/done")
        try FileManager.default.createDirectory(atPath: doneDir, withIntermediateDirectories: true)
        let path = (doneDir as NSString).appendingPathComponent("Shipped.md")
        try "---\ntitle: Shipped\ncreated: 2026-01-01T00:00:00Z\n---\n\n## Shipped\n\ndone body\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        let issue = store.read(path: path)
        XCTAssertEqual(issue?.status, .done)
        XCTAssertEqual(issue?.title, "Shipped")
        XCTAssertEqual(issue?.body, "done body")
        XCTAssertEqual(issue?.created, ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
    }

    func testReadLegacyFileDerivesTitleBodyAndMtime() throws {
        let root = tempDir()
        let store = IssueStore(rootDir: root)
        let newDir = (root as NSString).appendingPathComponent(".issues/new")
        try FileManager.default.createDirectory(atPath: newDir, withIntermediateDirectories: true)
        let path = (newDir as NSString).appendingPathComponent("Old issue.md")
        try "## Old issue\n\nlegacy body\nsecond line\n".write(toFile: path, atomically: true, encoding: .utf8)
        let mtime = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        let issue = store.read(path: path)
        XCTAssertEqual(issue?.title, "Old issue")
        XCTAssertEqual(issue?.body, "legacy body\nsecond line")
        XCTAssertEqual(issue?.created, mtime)
        XCTAssertEqual(issue?.status, .new)
    }

    func testReadLegacyFileWithoutHeadingFallsBackToFilename() throws {
        let root = tempDir()
        let store = IssueStore(rootDir: root)
        let newDir = (root as NSString).appendingPathComponent(".issues/new")
        try FileManager.default.createDirectory(atPath: newDir, withIntermediateDirectories: true)
        let path = (newDir as NSString).appendingPathComponent("Random notes.md")
        try "just some markdown\nno heading here\n".write(toFile: path, atomically: true, encoding: .utf8)
        let issue = store.read(path: path)
        XCTAssertEqual(issue?.title, "Random notes")
        XCTAssertEqual(issue?.body, "just some markdown\nno heading here")
    }

    func testReadMissingFileReturnsNil() {
        let store = IssueStore(rootDir: tempDir())
        XCTAssertNil(store.read(path: "/nonexistent/nope.md"))
    }
}
