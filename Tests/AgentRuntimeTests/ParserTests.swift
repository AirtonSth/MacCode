import XCTest
@testable import AgentRuntime
import CoreModel

final class CodexParserTests: XCTestCase {
    func test_threadStart_turn_item_completed() {
        let p = CodexParser()
        let lines = [
            #"{"type":"thread.started","thread_id":"abc"}"#,
            #"{"type":"turn.started","turn_id":"t1"}"#,
            #"{"type":"item.started","item_id":"i1","turn_id":"t1","item_type":"assistantMessage"}"#,
            #"{"type":"item.delta","item_id":"i1","body_delta":"Hello"}"#,
            #"{"type":"item.completed","item_id":"i1"}"#,
            #"{"type":"turn.completed","turn_id":"t1","final_message":"Hello"}"#
        ]
        var state = AssistantTimelineState()
        for l in lines {
            for ev in p.parseLine(l) { state.apply(ev) }
        }
        XCTAssertEqual(state.providerThreadId, "abc")
        XCTAssertEqual(state.turns.count, 1)
        XCTAssertEqual(state.turns[0].finalAssistantMessage, "Hello")
        XCTAssertEqual(state.turns[0].items[0].body, "Hello")
    }

    func test_unknownEvent_ignored() {
        let p = CodexParser()
        XCTAssertEqual(p.parseLine(#"{"type":"unknown.event","payload":1}"#).count, 0)
    }

    func test_malformedJson_returnsEmpty() {
        let p = CodexParser()
        XCTAssertEqual(p.parseLine("not-json").count, 0)
        XCTAssertEqual(p.parseLine("").count, 0)
    }

    func test_error_event() {
        let p = CodexParser()
        let evs = p.parseLine(#"{"type":"error","message":"boom"}"#)
        XCTAssertEqual(evs.count, 1)
        if case .error(let m, _) = evs[0] { XCTAssertEqual(m, "boom") } else { XCTFail() }
    }
}

final class ClaudeParserTests: XCTestCase {
    func test_session_init_emits_threadStarted_once() {
        let p = ClaudeParser()
        let ev1 = p.parseLine(#"{"type":"system","subtype":"init","session_id":"sid"}"#)
        if case .threadStarted(_, let pt) = ev1.first { XCTAssertEqual(pt, "sid") } else { XCTFail() }
        // next event shouldn't repeat threadStarted; would emit turnStarted from message_start
        let ev2 = p.parseLine(#"{"type":"message_start","message":{"id":"m1"}}"#)
        XCTAssertEqual(ev2.count, 1)
        if case .turnStarted = ev2[0] {} else { XCTFail() }
    }

    func test_textDelta_appendsBody_andResultEmitsTurnCompleted() {
        let p = ClaudeParser()
        _ = p.parseLine(#"{"type":"system","subtype":"init","session_id":"sid"}"#)
        _ = p.parseLine(#"{"type":"message_start","message":{"id":"m1"}}"#)
        _ = p.parseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#)
        _ = p.parseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#)
        _ = p.parseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}"#)
        _ = p.parseLine(#"{"type":"content_block_stop","index":0}"#)
        let resultEvs = p.parseLine(#"{"type":"result","subtype":"success"}"#)
        var state = AssistantTimelineState()
        // re-play from scratch
        let parser2 = ClaudeParser()
        for line in [
            #"{"type":"system","subtype":"init","session_id":"sid"}"#,
            #"{"type":"message_start","message":{"id":"m1"}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"result","subtype":"success"}"#
        ] {
            for ev in parser2.parseLine(line) { state.apply(ev) }
        }
        XCTAssertEqual(state.providerThreadId, "sid")
        XCTAssertEqual(state.turns.count, 1)
        XCTAssertEqual(state.turns[0].items.first?.body, "Hello world")
        XCTAssertEqual(state.turns[0].finalAssistantMessage, "Hello world")
        // also ensure ad-hoc test resultEvs flows
        XCTAssertGreaterThan(resultEvs.count, 0)
    }

    func test_thinkingDelta_mapsToReasoning() {
        let p = ClaudeParser()
        _ = p.parseLine(#"{"type":"system","subtype":"init","session_id":"sid"}"#)
        _ = p.parseLine(#"{"type":"message_start","message":{"id":"m1"}}"#)
        let starts = p.parseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#)
        if case .itemStarted(let it) = starts.first { XCTAssertEqual(it.type, .reasoning) } else { XCTFail() }
    }
}
