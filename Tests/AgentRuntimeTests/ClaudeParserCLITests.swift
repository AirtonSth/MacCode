import XCTest
@testable import AgentRuntime
import CoreModel

/// Regression: `claude --print --output-format stream-json --verbose`
/// emits whole `{"type":"assistant"}` / `{"type":"result"}` messages, NOT
/// Anthropic-API `content_block_delta` events. The parser must surface the
/// final answer from these or the chat shows the prompt and nothing back.
final class ClaudeParserCLITests: XCTestCase {

    private func collect(_ lines: [String]) -> [AssistantEvent] {
        let p = ClaudeParser()
        var evs: [AssistantEvent] = []
        for l in lines { evs += p.parseLine(l) }
        evs += p.finalize()
        return evs
    }

    private func finalMessage(_ evs: [AssistantEvent]) -> String? {
        for e in evs.reversed() {
            if case .turnCompleted(_, let m) = e { return m }
        }
        return nil
    }

    func test_cliAssistantThenResult_surfacesFinalAnswer() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"sess-1"}"#,
            #"{"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"pong"}]}}"#,
            #"{"type":"result","subtype":"success","result":"pong","session_id":"sess-1"}"#
        ])
        var threadStarted = false, turnStarted = false, sawText = false
        for e in evs {
            if case .threadStarted(_, let ptid) = e { threadStarted = true; XCTAssertEqual(ptid, "sess-1") }
            if case .turnStarted = e { turnStarted = true }
            if case .itemDelta(_, let body, _, _) = e, body == "pong" { sawText = true }
        }
        XCTAssertTrue(threadStarted, "system/init must start the thread with the session id")
        XCTAssertTrue(turnStarted, "a turn must be synthesized — the CLI sends no message_start")
        XCTAssertTrue(sawText, "the assistant text block must become a rendered item")
        XCTAssertEqual(finalMessage(evs), "pong",
                       "the top-level result string is the authoritative final answer")
    }

    func test_resultOnly_stillCompletesTurn() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s2"}"#,
            #"{"type":"result","subtype":"success","result":"done"}"#
        ])
        XCTAssertEqual(finalMessage(evs), "done",
                       "even with no assistant block, result must finalize the turn (not hang)")
    }

    func test_errorResult_isLoud() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s3"}"#,
            #"{"type":"result","subtype":"error_max_turns","is_error":true,"result":"hit the limit"}"#
        ])
        XCTAssertTrue(evs.contains {
            if case .error(let m, _) = $0 { return m == "hit the limit" }
            return false
        }, "a non-success result must emit a loud error, not silently complete")
    }

    func test_toolUseBlock_becomesToolItem() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s4"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"result","subtype":"success","result":"ok"}"#
        ])
        XCTAssertTrue(evs.contains {
            if case .itemStarted(let it) = $0 { return it.type == .tool && it.summary == "Bash" }
            return false
        }, "a tool_use block must render as a tool item with its name")
    }
}
