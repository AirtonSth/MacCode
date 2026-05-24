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

    func test_realExecSchema_agentMessageSurfacesAsFinal() {
        // `codex exec --json`: reply arrives as item.completed{item:…},
        // turn.completed carries NO message.
        let p = CodexParser()
        var state = AssistantTimelineState()
        for l in [
            #"{"type":"thread.started","thread_id":"019e-abc"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"HELLO123"}}"#,
            #"{"type":"turn.completed"}"#
        ] { for ev in p.parseLine(l) { state.apply(ev) } }
        XCTAssertEqual(state.providerThreadId, "019e-abc",
                       "thread_id must persist for `codex exec resume`")
        XCTAssertEqual(state.turns.count, 1)
        XCTAssertEqual(state.turns[0].finalAssistantMessage, "HELLO123",
                       "agent_message item must become the turn's final reply")
    }

    func test_turnFailed_isLoudError() {
        let p = CodexParser()
        let evs = p.parseLine(#"{"type":"turn.failed","error":{"message":"model blocked"}}"#)
        guard case .error(let m, _)? = evs.first else { return XCTFail("turn.failed must error") }
        XCTAssertEqual(m, "model blocked")
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

    func test_providerRequestsUserInputPlanAndUsageStayStructured() {
        let p = CodexParser()
        _ = p.parseLine(#"{"type":"turn.started","turn_id":"turn-1"}"#)
        let events =
            p.parseLine(#"{"type":"request.opened","request_id":"approval-1","request_type":"command_execution","title":"Run tests","command":"swift test"}"#) +
            p.parseLine(#"{"type":"user_input.requested","request_id":"question-1","prompt":"Pick mode","options":["Plan","Run"]}"#) +
            p.parseLine(#"{"type":"turn.proposed_plan","plan_id":"plan-1","plan_markdown":"1. Inspect\n2. Patch"}"#) +
            p.parseLine(#"{"type":"thread.token_usage","input_tokens":10,"output_tokens":5,"total_tokens":15,"context_window":100,"compacts_automatically":true}"#) +
            p.parseLine(#"{"type":"context.compaction","summary":"older messages compacted"}"#) +
            p.parseLine(#"{"type":"request.resolved","request_id":"approval-1","state":"approved"}"#) +
            p.parseLine(#"{"type":"user_input.resolved","request_id":"question-1","answer":"Run"}"#)

        var state = AssistantTimelineState()
        for event in events { state.apply(event) }

        XCTAssertEqual(state.pendingRequests.first?.kind, .commandExecution)
        XCTAssertEqual(state.pendingRequests.first?.detail, "swift test")
        XCTAssertEqual(state.pendingRequests.first?.state, .approved)
        XCTAssertEqual(state.pendingUserInputs.first?.options, ["Plan", "Run"])
        XCTAssertEqual(state.pendingUserInputs.first?.answer, "Run")
        XCTAssertEqual(state.proposedPlans.first?.markdown, "1. Inspect\n2. Patch")
        XCTAssertEqual(state.tokenUsage?.totalTokens, 15)
        XCTAssertEqual(state.tokenUsage?.compactsAutomatically, true)
        XCTAssertEqual(state.contextCompactionSummary, "older messages compacted")
    }

    func test_codexPlanUpdateTracksActiveStepState() {
        let p = CodexParser()
        let events = p.parseLine(#"{"type":"update_plan","explanation":"Working","plan":[{"step":"Inspect","status":"completed"},{"step":"Patch","status":"in_progress"},{"step":"Verify","status":"pending"}]}"#)
        var state = AssistantTimelineState()
        for event in events { state.apply(event) }

        XCTAssertEqual(state.activePlan?.explanation, "Working")
        XCTAssertEqual(state.activePlan?.steps.map(\.title), ["Inspect", "Patch", "Verify"])
        XCTAssertEqual(state.activePlan?.steps.map(\.status), [.completed, .inProgress, .pending],
                       "Codex update_plan events must become structured active-plan state instead of static transcript text")
    }

    func test_codexUserInputRequestedTracksMultiSelectContract() {
        let p = CodexParser()
        let events = p.parseLine(#"{"type":"user_input.requested","request_id":"question-1","prompt":"Pick checks","options":["Unit","UI"],"allows_multiple_selection":true}"#)
        var state = AssistantTimelineState()
        for event in events { state.apply(event) }

        XCTAssertEqual(state.pendingUserInputs.first?.options, ["Unit", "UI"])
        XCTAssertEqual(state.pendingUserInputs.first?.allowsMultipleSelection, true,
                       "multi-select provider questions must stay structured so UI can submit one final answer instead of firing each option immediately")
    }

    func test_codexItemProgressStaysStructured() {
        let p = CodexParser()
        let events =
            p.parseLine(#"{"type":"item.started","item_id":"tool-1","turn_id":"turn-1","item_type":"command_execution","summary":"swift test","progress":25}"#) +
            p.parseLine(#"{"type":"item.delta","item_id":"tool-1","progress":50}"#)
        var state = AssistantTimelineState()
        state.apply(.turnStarted(turnId: "turn-1"))
        for event in events { state.apply(event) }

        XCTAssertEqual(state.turns.first?.items.first?.progress, 0.5,
                       "Codex percent progress must stay structured so long-running tools can update their visible state")
        XCTAssertTrue(events.contains {
            if case .itemProgress(let itemId, let progress) = $0 {
                return itemId == "tool-1" && progress == 0.5
            }
            return false
        })
    }

    func test_richProviderItemTypesStayDistinct() {
        let p = CodexParser()
        _ = p.parseLine(#"{"type":"turn.started","turn_id":"turn-1"}"#)
        let commandEvents = p.parseLine(#"{"type":"item.completed","item":{"id":"cmd","type":"command_execution","command":"swift test","output":"ok"}}"#)
        let fileEvents = p.parseLine(#"{"type":"item.completed","item":{"id":"file","type":"file_change","text":"updated App.swift"}}"#)
        let mcpEvents = p.parseLine(#"{"type":"item.completed","item":{"id":"mcp","type":"mcp_tool_call","text":"tool output"}}"#)

        func startedType(_ events: [AssistantEvent]) -> AssistantItemType? {
            for event in events {
                if case .itemStarted(let item) = event { return item.type }
            }
            return nil
        }

        XCTAssertEqual(startedType(commandEvents), .commandExecution)
        XCTAssertEqual(startedType(fileEvents), .fileChange)
        XCTAssertEqual(startedType(mcpEvents), .mcpToolCall)
    }

    func test_realtimeCodexEventsBecomeVisibleUnsupportedItems() {
        let p = CodexParser()
        _ = p.parseLine(#"{"type":"turn.started","turn_id":"turn-1"}"#)
        let events = p.parseLine(#"{"type":"realtime.audio.delta","event_id":"audio-1"}"#)

        let item = events.compactMap { event -> AssistantItem? in
            if case .itemStarted(let item) = event { return item }
            return nil
        }.first

        XCTAssertEqual(item?.type, .error)
        XCTAssertEqual(item?.summary, "Unsupported realtime event")
        XCTAssertEqual(item?.body, "Unsupported Codex realtime event: realtime.audio.delta",
                       "unsupported realtime/audio Codex events must be visible instead of silently vanishing")
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

    func test_claudePlanUpdateTracksActiveStepState() {
        let p = ClaudeParser()
        let events = p.parseLine(#"{"type":"plan_update","explanation":"Working","steps":[{"title":"Inspect","status":"completed"},{"title":"Patch","status":"inProgress"}]}"#)
        var state = AssistantTimelineState()
        for event in events { state.apply(event) }

        XCTAssertEqual(state.activePlan?.steps.map(\.title), ["Inspect", "Patch"])
        XCTAssertEqual(state.activePlan?.steps.map(\.status), [.completed, .inProgress],
                       "Claude plan_update events must use the same active-plan contract as Codex")
    }
}
