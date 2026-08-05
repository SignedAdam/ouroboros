import XCTest
@testable import Ouroboros

final class IssueTrackingTests: XCTestCase {
    private func tempDir() -> String {
        let p = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ouroboros-tracking-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

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

    private func put(_ root: String, _ status: String, _ name: String, _ content: String) throws -> String {
        let d = (root as NSString).appendingPathComponent(".issues/\(status)")
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        let p = (d as NSString).appendingPathComponent(name)
        try content.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    func testListScansStatusFoldersSortedCreatedDesc() throws {
        let root = tempDir()
        let store = IssueStore(rootDir: root)
        _ = try put(root, "new", "Middle.md",
                    "---\ntitle: Middle\ncreated: 2026-07-02T00:00:00Z\n---\n\n## Middle\n\nm\n")
        _ = try put(root, "planned", "Newest.md",
                    "---\ntitle: Newest\ncreated: 2026-07-03T00:00:00Z\n---\n\n## Newest\n\nn\n")
        _ = try put(root, "done", "Oldest.md",
                    "---\ntitle: Oldest\ncreated: 2026-07-01T00:00:00Z\n---\n\n## Oldest\n\no\n")
        _ = try put(root, "new", "Undated.md",
                    "---\ntitle: Undated\n---\n\n## Undated\n\nu\n")
        _ = try put(root, "new", "notes.txt", "not an issue")

        let issues = store.list()
        XCTAssertEqual(issues.map(\.title), ["Newest", "Middle", "Oldest", "Undated"])
        XCTAssertEqual(issues.map(\.status), [.planned, .new, .done, .new])
        XCTAssertNil(issues.last?.created)
    }

    func testListEmptyRootReturnsEmpty() {
        XCTAssertEqual(IssueStore(rootDir: tempDir()).list().count, 0)
    }

    func testSetStatusMovesFileToStatusFolder() {
        let root = tempDir()
        let store = IssueStore(rootDir: root)
        let issue = store.write(title: "Move me", body: "b")!
        let moved = store.setStatus(issue, .done)
        XCTAssertNotNil(moved)
        XCTAssertEqual(moved?.status, .done)
        XCTAssertEqual(moved?.path, (root as NSString).appendingPathComponent(".issues/done/Move me.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: issue.path!))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved!.path!))
        XCTAssertEqual(moved?.title, issue.title)
        XCTAssertEqual(moved?.created, issue.created)
    }

    func testSetStatusDedupsNameCollision() throws {
        let root = tempDir()
        let store = IssueStore(rootDir: root)
        _ = try put(root, "done", "Same.md", "## Same\n\nalready here\n")
        let issue = store.write(title: "Same", body: "incoming")!
        let moved = store.setStatus(issue, .done)
        XCTAssertEqual(moved?.path, (root as NSString).appendingPathComponent(".issues/done/Same 2.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved!.path!))
    }

    func testSetStatusSameFolderIsNoOpMove() {
        let root = tempDir()
        let store = IssueStore(rootDir: root)
        let issue = store.write(title: "Stay", body: "b")!
        let same = store.setStatus(issue, .new)
        XCTAssertEqual(same?.path, issue.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: issue.path!))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (root as NSString).appendingPathComponent(".issues/new/Stay 2.md")))
    }

    func testSetStatusNilOnMissingPath() {
        let store = IssueStore(rootDir: tempDir())
        XCTAssertNil(store.setStatus(Issue(title: "X", slug: "x", body: "b"), .done))
        XCTAssertNil(store.setStatus(Issue(title: "X", slug: "x", body: "b",
                                           path: "/nonexistent/X.md"), .done))
    }

    func testUpdateBodyPreservesTitleAndCreated() throws {
        let root = tempDir()
        let pinned = ISO8601DateFormatter().date(from: "2026-07-03T02:55:12Z")!
        let store = IssueStore(rootDir: root, now: { pinned })
        let issue = store.write(title: "Keep meta", body: "old body")!
        let updated = store.updateBody(issue, body: "  new body\nwith detail  ")
        XCTAssertEqual(updated?.body, "new body\nwith detail")
        XCTAssertEqual(updated?.title, "Keep meta")
        XCTAssertEqual(updated?.created, pinned)
        XCTAssertEqual(updated?.path, issue.path)
        let content = try String(contentsOfFile: issue.path!, encoding: .utf8)
        XCTAssertEqual(content, """
        ---
        title: Keep meta
        created: 2026-07-03T02:55:12Z
        ---

        ## Keep meta

        new body
        with detail

        """)
    }

    func testUpdateBodyRejectsEmptyAndMissingPath() throws {
        let root = tempDir()
        let store = IssueStore(rootDir: root)
        let issue = store.write(title: "Solid", body: "original")!
        XCTAssertNil(store.updateBody(issue, body: "   \n  "))
        let content = try String(contentsOfFile: issue.path!, encoding: .utf8)
        XCTAssertTrue(content.contains("original"))
        XCTAssertNil(store.updateBody(Issue(title: "X", slug: "x", body: "b"), body: "new"))
        XCTAssertNil(store.updateBody(Issue(title: "X", slug: "x", body: "b",
                                            path: "/nonexistent/X.md"), body: "new"))
    }

    func testUpdateBodyOnLegacyFileWritesDerivedFrontmatter() throws {
        let root = tempDir()
        let store = IssueStore(rootDir: root)
        let path = try put(root, "new", "Old issue.md", "## Old issue\n\nlegacy body\n")
        let mtime = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as! Date
        let issue = store.read(path: path)!
        let updated = store.updateBody(issue, body: "edited body")
        XCTAssertEqual(updated?.title, "Old issue")
        XCTAssertEqual(updated?.body, "edited body")
        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(content, """
        ---
        title: Old issue
        created: \(IssueStore.isoString(mtime))
        ---

        ## Old issue

        edited body

        """)
    }
}
