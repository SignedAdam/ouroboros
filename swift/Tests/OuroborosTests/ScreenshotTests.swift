import XCTest
@testable import Ouroboros

final class ScreenshotTests: XCTestCase {
    private func tempRoot() throws -> String {
        let p = (NSTemporaryDirectory() as NSString).appendingPathComponent("ouro-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    private let png = Data([0x89, 0x50, 0x4E, 0x47])

    func testWriteStoresPngAndAppendsSection() throws {
        let root = try tempRoot()
        let shot = IssueScreenshot(pngData: png, textNotes: ["This button is dead"], hasPenMarks: true)
        let issue = IssueStore(rootDir: root).write(title: "Broken save", body: "repro", screenshot: shot)

        let pngPath = (root as NSString).appendingPathComponent(".issues/attachments/broken-save.png")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: pngPath)), png)

        let body = issue!.body
        XCTAssertTrue(body.contains("## Screenshot"))
        XCTAssertTrue(body.contains("`\(pngPath)`"))
        XCTAssertTrue(body.contains("read this image file"))
        XCTAssertTrue(body.contains("pen markings"))
        XCTAssertTrue(body.contains("verbatim:"))
        XCTAssertTrue(body.contains("- \"This button is dead\""))
        XCTAssertFalse(body.contains("infer the target"))

        let onDisk = try String(contentsOfFile: issue!.path!, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("- \"This button is dead\""))
    }

    func testPenOnlyMentionsMarkingsAndInferLine() throws {
        let root = try tempRoot()
        let shot = IssueScreenshot(pngData: png, textNotes: [], hasPenMarks: true)
        let body = IssueStore(rootDir: root).write(title: "X", body: "y", screenshot: shot)!.body
        XCTAssertTrue(body.contains("pen markings"))
        XCTAssertTrue(body.contains("infer the target"))
        XCTAssertFalse(body.contains("verbatim:"))
    }

    func testCleanScreenshotMentionsNeitherMarkingsNorNotes() throws {
        let root = try tempRoot()
        let shot = IssueScreenshot(pngData: png)
        let body = IssueStore(rootDir: root).write(title: "X", body: "y", screenshot: shot)!.body
        XCTAssertTrue(body.contains("## Screenshot"))
        XCTAssertFalse(body.contains("pen markings"))
        XCTAssertFalse(body.contains("verbatim:"))
        XCTAssertFalse(body.contains("infer the target"))
    }

    func testNoScreenshotNoSection() throws {
        let root = try tempRoot()
        let body = IssueStore(rootDir: root).write(title: "X", body: "y")!.body
        XCTAssertFalse(body.contains("## Screenshot"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (root as NSString).appendingPathComponent(".issues/attachments")))
    }

    func testAttachmentFilenameDedups() throws {
        let root = try tempRoot()
        let store = IssueStore(rootDir: root)
        store.write(title: "Same", body: "a", screenshot: IssueScreenshot(pngData: png))
        let second = store.write(title: "Same", body: "b", screenshot: IssueScreenshot(pngData: png))
        XCTAssertTrue(second!.body.contains("attachments/same 2.png"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (root as NSString).appendingPathComponent(".issues/attachments/same 2.png")))
    }
}
