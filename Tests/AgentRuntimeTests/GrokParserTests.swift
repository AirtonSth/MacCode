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

    func test_parseObject_matchesParseLineForTextToken() throws {
        // WHY: GrokRunner now feeds the already-decoded dict. parseObject must
        // keep the same itemDelta as parseLine or answer tokens vanish.
        let line = #"{"type":"text","data":"Hello"}"#
        let viaLine = GrokParser()
        let viaObject = GrokParser()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let lineText = viaLine.parseLine(line).compactMap { ev -> String? in
            if case .itemDelta(_, let body, _, _) = ev { return body }
            return nil
        }
        let objectText = viaObject.parseObject(object, now: 1).compactMap { ev -> String? in
            if case .itemDelta(_, let body, _, _) = ev { return body }
            return nil
        }
        XCTAssertEqual(lineText, objectText)
        XCTAssertEqual(lineText, ["Hello"])
    }

    func test_emptyAndNonJSONLinesAreIgnored() {
        let parser = GrokParser()
        XCTAssertTrue(parser.parseLine("").isEmpty)
        XCTAssertTrue(parser.parseLine("not-json").isEmpty)
        XCTAssertTrue(parser.parseLine("   ").isEmpty)
    }

    /// Token Saver Grok ring stays "No data" unless end.usage becomes a tokenUsage event.
    func test_endEventEmitsTokenUsageForTokenSaverRing() {
        let line = #"""
        {"type":"end","stopReason":"EndTurn","sessionId":"s1","requestId":"r1","usage":{"input_tokens":25103,"cache_read_input_tokens":6016,"output_tokens":18,"reasoning_tokens":13,"total_tokens":31137,"cost_in_usd_ticks":123450000},"modelUsage":{"grok-4.5":{"inputTokens":25103,"outputTokens":18,"cacheReadInputTokens":6016,"modelCalls":1}}}
        """#
        let events = GrokParser().parseLine(line)
        let usage = events.compactMap { ev -> AssistantTokenUsage? in
            if case .tokenUsage(let u) = ev { return u }
            return nil
        }.first
        XCTAssertNotNil(usage, "Grok end.usage must feed Token Saver so the purple ring is not stuck on No data")
        XCTAssertEqual(usage?.totalTokens, 31137)
        XCTAssertEqual(usage?.resolvedSemantics, .cumulative)
        XCTAssertEqual(usage?.outputTokens, 18)
        // input = uncached + cache read (25103 + 6016) when using modelUsage path
        XCTAssertEqual(usage?.inputTokens, 25103 + 6016)
        XCTAssertEqual(usage?.cacheReadInputTokens, 6016)
        XCTAssertEqual(usage?.reportedCostMicros, 12_345,
                       "Grok cost_in_usd_ticks must become integer micros without floating pricing")
    }

    func test_tokenUsageFromUsageOnlyObject() {
        let usage = GrokParser.tokenUsage(from: [
            "usage": [
                "input_tokens": 100,
                "cache_read_input_tokens": 20,
                "output_tokens": 5,
                "total_tokens": 125
            ]
        ])
        XCTAssertEqual(usage?.totalTokens, 125)
        XCTAssertEqual(usage?.inputTokens, 120)
        XCTAssertEqual(usage?.outputTokens, 5)
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

    /// Terminal UX: thought → text must finish the Thought row so it collapses to
    /// "Thought" and stops rewriting above the assistant answer while tokens arrive.
    func test_textPhaseClosesReasoningBeforeAssistantStreams() {
        let parser = GrokParser()
        var events: [AssistantEvent] = []
        events += parser.parseLine(#"{"type":"thought","data":"plan"}"#)
        events += parser.parseLine(#"{"type":"text","data":"hello"}"#)

        let reasoningIds = events.compactMap { ev -> String? in
            if case .itemStarted(let item) = ev, item.type == .reasoning { return item.id }
            return nil
        }
        let assistantIds = events.compactMap { ev -> String? in
            if case .itemStarted(let item) = ev, item.type == .assistantMessage { return item.id }
            return nil
        }
        XCTAssertEqual(reasoningIds.count, 1, "one Thought row for the thought phase")
        XCTAssertEqual(assistantIds.count, 1, "assistant text opens its own item")

        let reasoningId = reasoningIds[0]
        let completedReasoningBeforeText = events.firstIndex {
            if case .itemCompleted(let id, .completed) = $0 { return id == reasoningId }
            return false
        }
        let assistantStart = events.firstIndex {
            if case .itemStarted(let item) = $0 { return item.id == assistantIds[0] }
            return false
        }
        XCTAssertNotNil(completedReasoningBeforeText,
                        "reasoning must complete when text starts so the UI collapses Thinking… → Thought")
        XCTAssertNotNil(assistantStart)
        if let completedReasoningBeforeText, let assistantStart {
            XCTAssertLessThan(completedReasoningBeforeText, assistantStart,
                              "Thought must finish before the answer streams so it cannot keep mutating on top of the message")
        }
    }

    /// Multi-phase agent turns re-open Thought after tools/text (Grok TUI order),
    /// rather than appending late thoughts into the first reasoning block at the top.
    func test_thoughtAfterTextOpensNewReasoningPhase() {
        let parser = GrokParser()
        var events: [AssistantEvent] = []
        events += parser.parseLine(#"{"type":"thought","data":"first"}"#)
        events += parser.parseLine(#"{"type":"text","data":"mid"}"#)
        events += parser.parseLine(#"{"type":"thought","data":"second"}"#)
        events += parser.parseLine(#"{"type":"text","data":"final"}"#)
        events += parser.finalize()

        let reasoningStarts = events.compactMap { ev -> String? in
            if case .itemStarted(let item) = ev, item.type == .reasoning { return item.id }
            return nil
        }
        XCTAssertEqual(Set(reasoningStarts).count, 2,
                       "each thought phase after text must be its own timeline item (terminal interleaving)")

        var timeline = AssistantTimelineState()
        for ev in events { timeline.apply(ev) }
        let bodies = timeline.turns.first?.items.filter { $0.type == .reasoning }.map(\.body) ?? []
        XCTAssertEqual(bodies, ["first", "second"],
                       "late thoughts must not concatenate into the first Thought block above the answer")
    }

    func test_finalMessageUsesOnlyLastAssistantTextPhase() {
        let parser = GrokParser(initialSessionId: "preassigned")
        var events: [AssistantEvent] = []
        events += parser.parseLine(#"{"type":"text","data":"preface"}"#)
        events += parser.parseLine(#"{"type":"thought","data":"more work"}"#)
        events += parser.parseLine(#"{"type":"text","data":"final answer"}"#)
        events += parser.parseLine(#"{"type":"end","stopReason":"EndTurn"}"#)
        XCTAssertTrue(events.contains {
            if case .turnCompleted(_, let final) = $0 { return final == "final answer" }
            return false
        })
        XCTAssertEqual(parser.capturedSessionId, "preassigned")
    }

    /// CLI path parity with GrokACPEventMapper: leaked `<|eos|>` must not appear
    /// in streamed deltas or turnCompleted.finalMessage.
    func test_stripsLeakedControlTokensFromTextStream() {
        let parser = GrokParser()
        var events: [AssistantEvent] = []
        events += parser.parseLine(#"{"type":"text","data":"Repos"}"#)
        events += parser.parseLine(#"{"type":"text","data":"8"}"#)
        events += parser.parseLine(#"{"type":"text","data":"<|eos|>"}"#)
        events += parser.parseLine(#"{"type":"end","stopReason":"EndTurn"}"#)

        let text = events.compactMap { ev -> String? in
            if case .itemDelta(_, let body, _, _) = ev { return body }
            return nil
        }.joined()
        XCTAssertEqual(text, "Repos8")
        XCTAssertFalse(text.contains("<|eos|>"))
        XCTAssertTrue(events.contains {
            if case .turnCompleted(_, let final) = $0 { return final == "Repos8" }
            return false
        })
    }

    func test_toolCallClosesOpenReasoning() {
        let parser = GrokParser()
        var events: [AssistantEvent] = []
        events += parser.parseLine(#"{"type":"thought","data":"need shell"}"#)
        events += parser.parseLine(#"{"type":"tool_call","id":"t1","name":"run_terminal_command","input":{"command":"echo hi"}}"#)

        let reasoningId = events.compactMap { ev -> String? in
            if case .itemStarted(let item) = ev, item.type == .reasoning { return item.id }
            return nil
        }.first
        XCTAssertNotNil(reasoningId)
        XCTAssertTrue(events.contains {
            if case .itemCompleted(let id, .completed) = $0 { return id == reasoningId }
            return false
        }, "tool calls must seal the Thought row so tool lines render after it, not under an ever-growing Thinking… block")
    }

    /// GROK-PARSER-001: live grok 1.0 streaming-json completes tools via
    /// `type=tool_call_update` (not tool_result). Parser must emit output + terminal state.
    func test_toolCallUpdate_completesToolWithOutput() {
        let parser = GrokParser()
        var events: [AssistantEvent] = []
        events += parser.parseLine(#"{"type":"tool_call","toolCallId":"tc-1","title":"run_terminal_command","rawInput":{"command":"echo hi"}}"#)
        events += parser.parseLine(#"{"type":"tool_call_update","toolCallId":"tc-1","status":"pending"}"#)
        events += parser.parseLine(#"{"type":"tool_call_update","toolCallId":"tc-1","status":"completed","rawOutput":"hi\n"}"#)

        XCTAssertTrue(events.contains {
            if case .itemStarted(let item) = $0 {
                return item.id == "tc-1" && item.type == .tool && item.state == .streaming
            }
            return false
        }, "tool_call must open a streaming tool item keyed by toolCallId")
        XCTAssertTrue(events.contains {
            if case .itemDelta(let id, _, let output, _) = $0 {
                return id == "tc-1" && output == "hi\n"
            }
            return false
        }, "completed tool_call_update must surface rawOutput as itemDelta")
        XCTAssertTrue(events.contains {
            if case .itemCompleted("tc-1", .completed) = $0 { return true }
            return false
        }, "terminal status on tool_call_update must complete the tool item")
        // pending must not complete
        let completions = events.filter {
            if case .itemCompleted("tc-1", _) = $0 { return true }
            return false
        }
        XCTAssertEqual(completions.count, 1, "only the terminal update should complete the tool")
    }

    /// Open tools without a terminal update must seal on `end` so CLI timeline
    /// rows do not remain streaming after the turn completes (parity with ACP).
    func test_end_sealsOpenToolWithoutTerminalUpdate() {
        let parser = GrokParser()
        var events: [AssistantEvent] = []
        events += parser.parseLine(#"{"type":"tool_call","toolCallId":"tc-open","title":"run_terminal_command","rawInput":{"command":"sleep 999"}}"#)
        events += parser.parseLine(#"{"type":"text","data":"still working"}"#)
        events += parser.parseLine(#"{"type":"end","stopReason":"EndTurn","sessionId":"sess-tools"}"#)

        let toolCompletions = events.compactMap { event -> AssistantItemState? in
            if case .itemCompleted(let id, let state) = event, id == "tc-open" { return state }
            return nil
        }
        XCTAssertEqual(toolCompletions, [.completed],
                       "end with completed-class stopReason must seal open tools as completed")

        let toolDone = events.firstIndex {
            if case .itemCompleted("tc-open", _) = $0 { return true }
            return false
        }
        let turnDone = events.firstIndex {
            if case .turnCompleted = $0 { return true }
            return false
        }
        XCTAssertNotNil(toolDone)
        XCTAssertNotNil(turnDone)
        if let toolDone, let turnDone {
            XCTAssertLessThan(toolDone, turnDone, "open tools must complete before turnCompleted")
        }
    }

    func test_end_cancelledStopReason_sealsOpenToolAsCancelled() {
        let parser = GrokParser()
        var events: [AssistantEvent] = []
        events += parser.parseLine(#"{"type":"tool_call","toolCallId":"tc-cancel","name":"shell"}"#)
        events += parser.parseLine(#"{"type":"end","stopReason":"cancelled"}"#)
        XCTAssertTrue(events.contains {
            if case .itemCompleted("tc-cancel", .cancelled) = $0 { return true }
            return false
        }, "cancelled end must seal open tools as cancelled, not completed")
    }

    // SEP-3: normalizeStopReason compiles its camelCase regex once. A camelCase
    // multi-word reason must still snake_case before classification.
    func test_end_camelCaseStopReason_normalizesBeforeClassify() {
        let parser = GrokParser()
        var events: [AssistantEvent] = []
        events += parser.parseLine(#"{"type":"tool_call","toolCallId":"tc-camel","name":"shell"}"#)
        events += parser.parseLine(#"{"type":"end","stopReason":"maxTokens"}"#)
        XCTAssertTrue(events.contains {
            if case .itemCompleted("tc-camel", .completed) = $0 { return true }
            return false
        }, "camelCase maxTokens must normalize to max_tokens and seal as completed")
    }
}
