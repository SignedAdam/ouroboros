import XCTest
import Foundation
@testable import ZeroCore

private func tempLogPath(_ name: String) -> String {
    let dir = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("zerolog-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return (dir as NSString).appendingPathComponent("log.jsonl")
}

final class LogWritingTests: XCTestCase {
    func testIDsAreMonotonicAndStartAtOne() {
        let log = Log(path: tempLogPath("ids"))
        for i in 1...5 { log.write("run.queued", "line \(i)") }
        let lines = log.recent()
        XCTAssertEqual(lines.map(\.id).sorted(), [1, 2, 3, 4, 5])
    }

    func testIDsResumeAcrossProcesses() {
        let path = tempLogPath("resume")
        let first = Log(path: path)
        for i in 1...3 { first.write("run.queued", "\(i)") }

        let second = Log(path: path)
        second.write("run.started", "after restart")
        XCTAssertEqual(second.recent().first?.id, 4)
    }

    func testRecentIsNewestFirstAndRespectsLimit() {
        let log = Log(path: tempLogPath("recent"))
        for i in 1...50 { log.write("e", "line \(i)") }
        var query = Log.Query()
        query.limit = 10
        let lines = log.recent(query)
        XCTAssertEqual(lines.count, 10)
        XCTAssertEqual(lines.first?.message, "line 50")
        XCTAssertEqual(lines.last?.message, "line 41")
    }

    func testRoundTripKeepsEveryField() {
        let log = Log(path: tempLogPath("fields"))
        log.write("merge.succeeded", "merged fix/x into main", level: .warn,
                  project: "receipts", run: "r-abc", issue: "/repo/.issues/new/x.md",
                  path: "/repo", branch: "fix/x", agent: "claude", session: "sess-9",
                  durationMs: 1234, exitCode: 0, detail: ["commit": "a1b2c3"])
        guard let event = log.recent().first else { return XCTFail("nothing written") }
        XCTAssertEqual(event.event, "merge.succeeded")
        XCTAssertEqual(event.level, .warn)
        XCTAssertEqual(event.project, "receipts")
        XCTAssertEqual(event.run, "r-abc")
        XCTAssertEqual(event.branch, "fix/x")
        XCTAssertEqual(event.session, "sess-9")
        XCTAssertEqual(event.durationMs, 1234)
        XCTAssertEqual(event.exitCode, 0)
        XCTAssertEqual(event.detail?["commit"], "a1b2c3")
    }

    func testOneObjectPerLine() throws {
        let path = tempLogPath("jsonl")
        let log = Log(path: path)
        log.write("a", "first with a \n newline in it")
        log.write("b", "second")
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let lines = raw.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2, "an embedded newline must not split a record")
        for line in lines {
            XCTAssertNotNil(Log.decode(String(line)))
        }
    }

    func testDisabledWritesNothing() {
        let log = Log(path: tempLogPath("off"))
        log.enabled = false
        log.write("e", "should not appear")
        XCTAssertTrue(log.recent().isEmpty)
    }

    func testTheSharedLogIsMutedUnderTest() {
        XCTAssertTrue(Log.underTest)
        XCTAssertFalse(Log.shared.enabled,
                       "tests must never write to ~/.ouroboros/log.jsonl")
    }
}

final class LogFilterTests: XCTestCase {
    private func seeded() -> Log {
        let log = Log(path: tempLogPath("filter"))
        log.write("run.queued", "queued one", project: "receipts", run: "r-aaa")
        log.write("verify.failed", "tests failed", level: .error, project: "receipts", run: "r-aaa")
        log.write("merge.refused", "held back", level: .warn, project: "atlas", run: "r-bbb")
        log.write("merge.succeeded", "merged", project: "atlas", run: "r-bbb")
        return log
    }

    func testErrorsOnly() {
        var query = Log.Query()
        query.minLevel = .error
        let lines = seeded().recent(query)
        XCTAssertEqual(lines.map(\.event), ["verify.failed"])
    }

    func testWarnIncludesErrors() {
        var query = Log.Query()
        query.minLevel = .warn
        XCTAssertEqual(Set(seeded().recent(query).map(\.event)), ["verify.failed", "merge.refused"])
    }

    func testProjectFilter() {
        var query = Log.Query()
        query.project = "atlas"
        XCTAssertEqual(seeded().recent(query).count, 2)
    }

    func testEventIsSubstringMatched() {
        var query = Log.Query()
        query.event = "merge"
        XCTAssertEqual(Set(seeded().recent(query).map(\.event)), ["merge.refused", "merge.succeeded"])
    }

    func testRunFilterMatchesPrefix() {
        var query = Log.Query()
        query.run = "r-aa"
        XCTAssertEqual(seeded().recent(query).count, 2)
    }

    func testSearchLooksAcrossFields() {
        var query = Log.Query()
        query.search = "held back"
        XCTAssertEqual(seeded().recent(query).first?.event, "merge.refused")
    }
}

final class LogAroundTests: XCTestCase {
    func testAroundReturnsHalfEitherSide() {
        let log = Log(path: tempLogPath("around"))
        for i in 1...200 { log.write("e", "line \(i)") }

        let window = log.around(id: 100, span: 50)
        XCTAssertEqual(window.count, 51, "25 before, the line itself, 25 after")
        XCTAssertEqual(window.first?.id, 75)
        XCTAssertEqual(window.last?.id, 125)
        XCTAssertEqual(window.map(\.id), Array(75...125), "oldest first, no gaps")
    }

    func testAroundClampsAtTheStart() {
        let log = Log(path: tempLogPath("around-start"))
        for i in 1...20 { log.write("e", "line \(i)") }
        let window = log.around(id: 3, span: 50)
        XCTAssertEqual(window.first?.id, 1)
        XCTAssertTrue(window.contains { $0.id == 3 })
    }

    func testAroundUnknownIDIsEmpty() {
        let log = Log(path: tempLogPath("around-missing"))
        log.write("e", "only line")
        XCTAssertTrue(log.around(id: 999).isEmpty)
    }

    func testGetByID() {
        let log = Log(path: tempLogPath("get"))
        for i in 1...10 { log.write("e", "line \(i)") }
        XCTAssertEqual(log.get(id: 7)?.message, "line 7")
    }
}

final class LogTailReaderTests: XCTestCase {
    func testTailLinesReturnsTheLastN() throws {
        let path = tempLogPath("tail")
        let body = (1...500).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try body.write(toFile: path, atomically: true, encoding: .utf8)

        let lines = Log.tailLines(path: path, maxLines: 5)
        XCTAssertEqual(lines, ["line 496", "line 497", "line 498", "line 499", "line 500"])
    }

    func testTailLinesHandlesFilesSmallerThanAChunk() throws {
        let path = tempLogPath("small")
        try "only\n".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(Log.tailLines(path: path, maxLines: 50), ["only"])
    }

    func testTailLinesSpansChunkBoundaries() throws {
        let path = tempLogPath("chunky")
        let padded = (1...4000).map { "line \($0) " + String(repeating: "x", count: 40) }
        try (padded.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let lines = Log.tailLines(path: path, maxLines: 3000)
        XCTAssertEqual(lines.count, 3000)
        XCTAssertTrue(lines.last!.hasPrefix("line 4000 "))
        XCTAssertTrue(lines.first!.hasPrefix("line 1001 "))
        XCTAssertFalse(lines.contains { $0.isEmpty })
    }

    func testMissingFileIsEmptyNotACrash() {
        XCTAssertEqual(Log.tailLines(path: "/nope/does/not/exist.jsonl", maxLines: 10), [])
    }
}
