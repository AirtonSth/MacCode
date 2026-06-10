import XCTest
@testable import AgentRuntime
import CoreModel

/// Tests that the stream_event fast-path (no re-serialize + re-parse) produces
/// identical events to the direct-line path.  Perf win: 1 JSON parse per line
/// instead of 2-3 for stream_event-wrapped lines.
final class ClaudeParserNoReserializeTests: XCTestCase {

    // MARK: - Helpers

    private func eventsForDirectLine(_ line: String) -> [AssistantEvent] {
        ClaudeParser().parseLine(line)
    }

    private func eventsForWrappedLine(_ innerJSON: String, sessionId: String = "sid") -> [AssistantEvent] {
        // Wrap the inner event in a stream_event envelope exactly as the CLI shim does.
        let wrapped = "{\"type\":\"stream_event\",\"session_id\":\"\(sessionId)\",\"event\":\(innerJSON)}"
        return ClaudeParser().parseLine(wrapped)
    }

    // Compare two event arrays field-by-field where identity matters.
    // We compare via a stable string projection so exact AssistantEvent
    // equality isn't needed (Equatable not guaranteed on all payloads).
    private func summarize(_ events: [AssistantEvent]) -> [String] {
        events.map { event -> String in
            switch event {
            case .threadStarted(let tid, let pt):
                return "threadStarted(threadId:\(tid),providerThreadId:\(pt ?? "nil"))"
            case .turnStarted(let tid):
                return "turnStarted(\(tid))"
            case .turnCompleted(let tid, let msg):
                return "turnCompleted(\(tid),\(msg ?? "nil"))"
            case .itemStarted(let item):
                return "itemStarted(id:\(item.id),type:\(item.type),summary:\(item.summary ?? "nil"),body:\(item.body))"
            case .itemDelta(let id, let body, let output, let summary):
                return "itemDelta(id:\(id),body:\(body ?? "nil"),output:\(output ?? "nil"),summary:\(summary ?? "nil"))"
            case .itemCompleted(let id, let state):
                return "itemCompleted(id:\(id),state:\(state))"
            case .itemProgress(let id, let p):
                return "itemProgress(id:\(id),p:\(p))"
            case .tokenUsage(let u):
                return "tokenUsage(in:\(u.inputTokens),out:\(u.outputTokens))"
            case .error(let msg, let recoverable):
                return "error(\(msg),recoverable:\(recoverable))"
            case .requestOpened(let r):
                return "requestOpened(id:\(r.id),kind:\(r.kind))"
            case .requestResolved(let id, let state):
                return "requestResolved(id:\(id),state:\(state))"
            case .userInputRequested(let r):
                return "userInputRequested(id:\(r.id),prompt:\(r.prompt))"
            case .userInputResolved(let id, let answer):
                return "userInputResolved(id:\(id),answer:\(answer ?? "nil"))"
            case .activePlanUpdated(let plan):
                return "activePlanUpdated(steps:\(plan.steps.count))"
            case .contextCompaction(let summary):
                return "contextCompaction(\(summary))"
            default:
                return "other(\(event))"
            }
        }
    }

    // MARK: - Core parity: stream_event wrapper == direct line

    func test_streamEvent_textDelta_matchesDirectLine() {
        // WHY: a stream_event wrapper around content_block_delta must produce
        // the identical itemDelta event as feeding the inner line directly.
        // If re-serialize+re-parse were removed incorrectly the text field
        // would be lost or corrupted.
        let inner = #"{"type":"content_block_delta","index":0,"session_id":"sid","delta":{"type":"text_delta","text":"Hello world"}}"#

        // Prepare both parsers with identical warm-up state so they differ only
        // in HOW the delta line arrives.
        func warmUp(_ p: ClaudeParser) {
            _ = p.parseLine(#"{"type":"system","subtype":"init","session_id":"sid"}"#)
            _ = p.parseLine(#"{"type":"message_start","message":{"id":"m1"}}"#)
            _ = p.parseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","id":"item0"}}"#)
        }

        let directParser = ClaudeParser()
        warmUp(directParser)
        let directEvents = directParser.parseLine(inner)

        let wrappedParser = ClaudeParser()
        warmUp(wrappedParser)
        let wrappedEvents = wrappedParser.parseLine(
            "{\"type\":\"stream_event\",\"session_id\":\"sid\",\"event\":\(inner)}"
        )

        XCTAssertFalse(directEvents.isEmpty, "direct path must produce events")
        XCTAssertEqual(summarize(directEvents), summarize(wrappedEvents),
                       "stream_event wrapper must yield identical events to direct line — no re-serialize round trip")
    }

    func test_streamEvent_contentBlockStart_matchesDirectLine() {
        // WHY: content_block_start nested fields (type, id, name) must survive
        // the fast-path without re-encoding.
        let inner = #"{"type":"content_block_start","index":1,"session_id":"sid","content_block":{"type":"tool_use","id":"tool1","name":"Bash"}}"#

        func warmUp(_ p: ClaudeParser) {
            _ = p.parseLine(#"{"type":"system","subtype":"init","session_id":"sid"}"#)
            _ = p.parseLine(#"{"type":"message_start","message":{"id":"m1"}}"#)
        }

        let directParser = ClaudeParser()
        warmUp(directParser)
        let directEvents = directParser.parseLine(inner)

        let wrappedParser = ClaudeParser()
        warmUp(wrappedParser)
        let wrappedEvents = wrappedParser.parseLine(
            "{\"type\":\"stream_event\",\"session_id\":\"sid\",\"event\":\(inner)}"
        )

        XCTAssertFalse(directEvents.isEmpty)
        XCTAssertEqual(summarize(directEvents), summarize(wrappedEvents),
                       "tool_use content_block_start nested fields must survive fast-path dispatch")
    }

    func test_streamEvent_thinkingDelta_matchesDirectLine() {
        // WHY: thinking_delta uses a different key ("thinking" not "text").
        // The fast-path must not drop it.
        let inner = #"{"type":"content_block_delta","index":0,"session_id":"sid","delta":{"type":"thinking_delta","thinking":"step 1"}}"#

        func warmUp(_ p: ClaudeParser) {
            _ = p.parseLine(#"{"type":"system","subtype":"init","session_id":"sid"}"#)
            _ = p.parseLine(#"{"type":"message_start","message":{"id":"m1"}}"#)
            _ = p.parseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","id":"think0"}}"#)
        }

        let directParser = ClaudeParser()
        warmUp(directParser)
        let directEvents = directParser.parseLine(inner)

        let wrappedParser = ClaudeParser()
        warmUp(wrappedParser)
        let wrappedEvents = wrappedParser.parseLine(
            "{\"type\":\"stream_event\",\"session_id\":\"sid\",\"event\":\(inner)}"
        )

        XCTAssertEqual(summarize(directEvents), summarize(wrappedEvents),
                       "thinking_delta must pass through fast-path with body preserved")
    }

    // MARK: - session_id injection via stream_event envelope

    func test_streamEvent_injectsSessionId_whenInnerEventOmitsIt() {
        // WHY: the cmux shim wraps inner events that omit session_id; the
        // fast-path must still capture the outer session_id so resume works.
        // Inner event has NO session_id — outer envelope carries it.
        let inner = #"{"type":"system","subtype":"init"}"#
        let wrapped = "{\"type\":\"stream_event\",\"session_id\":\"outer-sid\",\"event\":\(inner)}"

        let parser = ClaudeParser()
        let events = parser.parseLine(wrapped)
        let threadEvent = events.first {
            if case .threadStarted = $0 { return true }
            return false
        }
        guard case .threadStarted(_, let providerThreadId) = threadEvent else {
            XCTFail("threadStarted must be emitted")
            return
        }
        XCTAssertEqual(providerThreadId, "outer-sid",
                       "session_id from outer stream_event envelope must be available after fast-path dispatch")
    }

    // MARK: - Nested field preservation

    func test_streamEvent_nestedDeltaFields_preserved() {
        // WHY: the old code re-encoded to JSON string then re-decoded; key order
        // is nondeterministic but more critically any value that round-trips
        // through JSONSerialization could lose type fidelity (e.g. Int -> Double).
        // The fast-path keeps the original decoded dict so types are exact.
        let inner = #"{"type":"content_block_delta","index":0,"session_id":"sid","delta":{"type":"input_json_delta","partial_json":"{\"k\":1}"}}"#

        func warmUp(_ p: ClaudeParser) {
            _ = p.parseLine(#"{"type":"system","subtype":"init","session_id":"sid"}"#)
            _ = p.parseLine(#"{"type":"message_start","message":{"id":"m1"}}"#)
            _ = p.parseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"Bash"}}"#)
        }

        let wrappedParser = ClaudeParser()
        warmUp(wrappedParser)
        let wrappedEvents = wrappedParser.parseLine(
            "{\"type\":\"stream_event\",\"session_id\":\"sid\",\"event\":\(inner)}"
        )

        let delta = wrappedEvents.first {
            if case .itemDelta = $0 { return true }
            return false
        }
        guard case .itemDelta(_, _, let outputAppend, _) = delta else {
            XCTFail("itemDelta must be emitted for input_json_delta")
            return
        }
        XCTAssertEqual(outputAppend, "{\"k\":1}",
                       "partial_json field must survive fast-path without re-encode/re-decode")
    }

    // MARK: - One-parse semantics: same result on repeated calls

    func test_twoDirectCalls_sameLineProduceSameEvents() {
        // WHY: Rule 8 — tests must encode WHY. This verifies the parser is
        // stateless enough that the fast-path (which does NOT re-parse) yields
        // the same result as the original path, not a cached-vs-fresh mismatch.
        // Compare two INDEPENDENT parsers feeding the same line — never compare
        // a cached value against a fresh JSONEncoder output.
        let line = #"{"type":"content_block_delta","index":0,"session_id":"sid","delta":{"type":"text_delta","text":"ping"}}"#

        func warmUp(_ p: ClaudeParser) {
            _ = p.parseLine(#"{"type":"system","subtype":"init","session_id":"sid"}"#)
            _ = p.parseLine(#"{"type":"message_start","message":{"id":"m1"}}"#)
            _ = p.parseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","id":"i0"}}"#)
        }

        let p1 = ClaudeParser(); warmUp(p1)
        let p2 = ClaudeParser(); warmUp(p2)

        let ev1 = summarize(p1.parseLine(line))
        let ev2 = summarize(p2.parseLine(line))
        XCTAssertEqual(ev1, ev2, "two independent parsers must produce identical summaries for the same input")
    }
}
