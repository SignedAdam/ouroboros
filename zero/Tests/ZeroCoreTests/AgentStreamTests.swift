import XCTest
import Foundation
@testable import ZeroCore

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

final class AgentStreamTests: XCTestCase {
    func testWhatTheAgentSaysComesOutAsItSaidIt() {
        var stream = AgentStream()
        let line = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"I'll run that command."}]}}
        """
        XCTAssertEqual(stream.readable(line), "I'll run that command.")
    }

    func testAToolCallReadsAsOneLine() {
        var stream = AgentStream()
        let line = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash",\
        "input":{"command":"swift build","description":"build it"}}]}}
        """
        XCTAssertEqual(stream.readable(line), "  → Bash  swift build")
    }

    func testAToolResultIsTrimmedToOneLine() {
        var stream = AgentStream()
        let line = """
        {"type":"user","message":{"content":[{"type":"tool_result","content":"hello\\nworld"}]}}
        """
        XCTAssertEqual(stream.readable(line), "    hello world")
    }

    func testAFailedToolResultIsMarked() {
        var stream = AgentStream()
        let line = """
        {"type":"user","message":{"content":[{"type":"tool_result","is_error":true,\
        "content":[{"type":"text","text":"no such file"}]}]}}
        """
        XCTAssertEqual(stream.readable(line), "    ! no such file")
    }

    func testHousekeepingEventsAreNotShown() {
        var stream = AgentStream()
        XCTAssertNil(stream.readable(#"{"type":"system","subtype":"init","tools":["Bash"]}"#))
        XCTAssertNil(stream.readable(#"{"type":"rate_limit_event","status":"ok"}"#))
        XCTAssertNil(stream.readable(
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"}]}}"#))
    }

    func testTheFinalAnswerIsNotRepeated() {
        var stream = AgentStream()
        _ = stream.readable("""
        {"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}
        """)
        XCTAssertNil(stream.readable(#"{"type":"result","subtype":"success","result":"done"}"#))
    }

    func testAnAnswerNobodyStreamedIsStillKept() {
        var stream = AgentStream()
        XCTAssertEqual(stream.readable(#"{"type":"result","subtype":"success","result":"all set"}"#),
                       "all set")
    }

    func testAFailedRunSaysWhy() {
        var stream = AgentStream()
        XCTAssertEqual(
            stream.readable(#"{"type":"result","subtype":"error_max_turns","result":""}"#),
            "  ! error_max_turns")
        XCTAssertEqual(
            stream.readable(#"{"type":"result","subtype":"success","is_error":true,"result":"boom"}"#),
            "  ! boom")
    }

    func testPlainOutputIsLeftExactlyAsItIs() {
        var stream = AgentStream()
        XCTAssertEqual(stream.readable("No conversation found with session ID: abc"),
                       "No conversation found with session ID: abc")
        XCTAssertEqual(stream.readable("{not json"), "{not json")
        XCTAssertEqual(stream.readable(""), "")
    }

    func testAnEventSplitAcrossChunksIsStillOneLine() {
        var stream = AgentStream()
        let line = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"halfway"}]}}
        """
        let bytes = Array(line.utf8)
        let head = Data(bytes[..<20]), tail = Data(bytes[20...])

        XCTAssertEqual(text(stream.feed(head)), "")
        XCTAssertEqual(text(stream.feed(tail)), "")
        XCTAssertEqual(text(stream.finish()), "halfway\n")
    }

    func testEachCompleteLineComesOutAsSoonAsItArrives() {
        var stream = AgentStream()
        let chunk = """
        {"type":"system","subtype":"init"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"one"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"two"}]}}

        """
        XCTAssertEqual(text(stream.feed(Data(chunk.utf8))), "one\ntwo\n")
    }

    func testACarriageReturnDoesNotSurviveIntoTheLog() {
        var stream = AgentStream()
        XCTAssertEqual(text(stream.feed(Data("plain\r\n".utf8))), "plain\n")
    }

    func testOutputWithNoNewlineInItIsNotHeldForever() {
        var stream = AgentStream()
        let bar = String(repeating: "=", count: AgentStream.holdLimit + 40)
        XCTAssertEqual(text(stream.feed(Data(bar.utf8))), bar)
        XCTAssertEqual(text(stream.finish()), "")
    }

    func testALongToolInputIsCutShort() {
        let summary = AgentStream.summarise(["command": String(repeating: "x", count: 400)])
        XCTAssertEqual(summary.count, 110)
        XCTAssertTrue(summary.hasSuffix("…"))
    }

    func testAToolWithNoFamiliarFieldStillSaysSomething() {
        XCTAssertEqual(AgentStream.summarise(["todos": "two"]), #"{"todos":"two"}"#)
        XCTAssertEqual(AgentStream.summarise([:]), "")
    }
}
