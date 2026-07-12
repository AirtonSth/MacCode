import XCTest
@testable import AgentRuntime
import CoreModel

/// Grok Build CLI streaming-json → AssistantEvent mapping.
/// Fixtures match real `grok -p … --output-format streaming-json` lines.
final class GrokParserTests: XCTestCase {

    func test_parsesThoughtTextAndEndWithSessionId() {
        let parser = GrokParser()
        var events: [AssistantEvent] = []
        events += parser.parseLine(#"{"type":"thought","data":"Thinking"}"#)
        events += parser.parseLine(#"{"type":"text","data":"Hello"}"#)
        events += parser.parseLine(#"{"type":"text","data":" world"}"#)
        events += parser.parseLine(#"{"type":"end","stopReason":"EndTurn","sessionId":"sess-abc-123","requestId":"req-1"}"#)
        events += parser.finalize()

        XCTAssertTrue(events.contains {
            if case .threadStarted(_, let ptid) = $0 { return ptid == "sess-abc-123" }
            return false
        }, "end.sessionId must become providerThreadId so multi-turn --resume works")

        XCTAssertTrue(events.contains {
            if case .turnStarted = $0 { return true }
            return false
        })

        let text = events.compactMap { ev -> String? in
            if case .itemDelta(_, let body, _, _) = ev { return body }
            return nil
        }.joined()
        XCTAssertTrue(text.contains("Hello"), "assistant text chunks must surface for Agent App transcript")
        XCTAssertTrue(text.contains(" world"))

        XCTAssertTrue(events.contains {
            if case .turnCompleted(_, let final) = $0 {
                return final == "Hello world"
            }
            return false
        }, "final assistant message must assemble streamed text for finished-run display")

        XCTAssertEqual(parser.capturedSessionId, "sess-abc-123")
    }

    func test_emptyAndNonJSONLinesAreIgnored() {
        let parser = GrokParser()
        XCTAssertTrue(parser.parseLine("").isEmpty)
        XCTAssertTrue(parser.parseLine("not-json").isEmpty)
        XCTAssertTrue(parser.parseLine("   ").isEmpty)
    }

    func test_errorEventProducesFailedItem() {
        let parser = GrokParser()
        let events = parser.parseLine(#"{"type":"error","message":"auth required"}"#)
        XCTAssertTrue(events.contains {
            if case .itemStarted(let item) = $0 {
                return item.type == .error && item.body.contains("auth required")
            }
            return false
        }, "CLI error events must appear in the timeline so users see why the turn failed")
    }
}
