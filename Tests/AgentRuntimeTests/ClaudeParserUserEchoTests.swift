import XCTest
@testable import AgentRuntime
import CoreModel

/// Regression (audit F20): `claude --print --input-format stream-json` runs with
/// `--replay-user-messages`, so the CLI echoes the host's own prompt back as a
/// `{"type":"user"}` message. The parser used to render those text blocks as
/// assistant prose (every prompt appeared twice: user bubble + assistant text)
/// AND fed them into `assembledAssistantBody`, so an interrupted run's
/// finalize() persisted the user's prompt as the assistant's final answer.
/// User-role messages may only contribute tool_result blocks.
final class ClaudeParserUserEchoTests: XCTestCase {

    private func assistantItemEvents(_ events: [AssistantEvent]) -> [AssistantItem] {
        events.compactMap { event in
            if case .itemStarted(let item) = event, item.type == .assistantMessage { return item }
            return nil
        }
    }

    // WHY: the echoed prompt is the USER's message; rendering it as an
    // assistant item duplicates every prompt into the turn as the agent's prose.
    func test_echoedUserTextBlock_doesNotRenderAsAssistantProse() {
        let parser = ClaudeParser()
        _ = parser.parseLine(#"{"type":"system","subtype":"init","session_id":"s-echo"}"#)
        let echo = parser.parseLine(#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"fix the bug"}]},"session_id":"s-echo"}"#)
        XCTAssertTrue(assistantItemEvents(echo).isEmpty,
                      "an echoed user text block must NOT become an assistantMessage item — it would render the prompt as the agent's own prose")
        XCTAssertFalse(echo.contains { if case .itemDelta = $0 { return true }; return false },
                       "no body delta may be emitted for the echoed user prompt")

        // The real answer must still flow through untouched.
        let answer = parser.parseLine(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done, see patch"}]},"session_id":"s-echo"}"#)
        XCTAssertEqual(assistantItemEvents(answer).count, 1,
                       "the assistant's own message must still render exactly once")
    }

    // WHY: the echo used to contaminate assembledAssistantBody, so an
    // interrupted run (no `result` line, EOF -> finalize) reported the user's
    // own prompt as the turn's final assistant message, which the coordinator
    // then persisted as the assistant's answer.
    func test_interruptedRunAfterEcho_finalizeDoesNotReturnThePromptAsTheAnswer() {
        let parser = ClaudeParser()
        _ = parser.parseLine(#"{"type":"system","subtype":"init","session_id":"s-echo-2"}"#)
        _ = parser.parseLine(#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"count to 10"}]},"session_id":"s-echo-2"}"#)

        let finalized = parser.finalize()
        let finalMessage = finalized.compactMap { event -> String?? in
            if case .turnCompleted(_, let message) = event { return message }
            return nil
        }.first
        XCTAssertEqual(finalMessage, .some(nil),
                       "an interrupted run whose only content was the user echo must finalize with NO assistant message — not the user's own prompt")
    }

    // WHY: tool_result blocks legitimately arrive on user-role messages
    // (Anthropic API shape) — filtering the echo must not drop tool outputs.
    func test_userMessageToolResultBlock_stillRenders() {
        let parser = ClaudeParser()
        _ = parser.parseLine(#"{"type":"system","subtype":"init","session_id":"s-echo-3"}"#)
        let events = parser.parseLine(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","id":"tr-1","content":"42 files changed"}]},"session_id":"s-echo-3"}"#)
        let toolItems = events.compactMap { event -> AssistantItem? in
            if case .itemStarted(let item) = event, item.type == .tool { return item }
            return nil
        }
        XCTAssertEqual(toolItems.first?.output, "42 files changed",
                       "tool_result blocks ride on user-role messages and must keep rendering after the echo filter")
    }

    // WHY: user messages can also carry thinking blocks in replay shapes; they
    // are user-side content and must not render as the agent's reasoning.
    func test_echoedUserThinkingBlock_isSkipped() {
        let parser = ClaudeParser()
        _ = parser.parseLine(#"{"type":"system","subtype":"init","session_id":"s-echo-4"}"#)
        let events = parser.parseLine(#"{"type":"user","message":{"role":"user","content":[{"type":"thinking","thinking":"user-side note"}]},"session_id":"s-echo-4"}"#)
        XCTAssertFalse(events.contains { event in
            if case .itemStarted(let item) = event { return item.type == .reasoning }
            return false
        }, "a user-role thinking block must not become an agent reasoning item")
    }
}
