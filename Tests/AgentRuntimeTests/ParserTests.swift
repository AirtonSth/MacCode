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

    func test_parseObject_matchesParseLineForItemDelta() throws {
        // WHY: CodexRunner now feeds the already-decoded dict. parseObject must
        // keep the same itemDelta as parseLine or exec --json tokens vanish.
        let line = #"{"type":"item.delta","item_id":"i1","body_delta":"Hello"}"#
        func warmUp(_ p: CodexParser) {
            _ = p.parseObject(["type": "turn.started", "turn_id": "t1"], now: 1)
            _ = p.parseObject([
                "type": "item.started", "item_id": "i1", "turn_id": "t1",
                "item_type": "assistantMessage",
            ], now: 1)
        }
        let viaLine = CodexParser()
        let viaObject = CodexParser()
        warmUp(viaLine)
        warmUp(viaObject)
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

    func test_realExecSchema_agentMessageSurfacesAsFinal() {
        // `codex exec --json`: reply arrives as item.completed{item:...},
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

    func test_realExecSchema_nestedItemStartedAndAggregatedOutput() {
        // WHY: openai/codex emits item.started with nested `item`, and
        // command_execution output lives in aggregated_output (not `output`).
        let p = CodexParser()
        var state = AssistantTimelineState()
        for l in [
            #"{"type":"thread.started","thread_id":"t-nested"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"bash -lc ls","aggregated_output":"","status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"bash -lc ls","aggregated_output":"README.md\nSources","status":"completed"}}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"command_execution","command":"rm -rf /","aggregated_output":"","status":"declined"}}"#,
            #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Listed the repo."}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"cache_write_input_tokens":12,"output_tokens":122,"reasoning_output_tokens":0}}"#
        ] { for ev in p.parseLine(l) { state.apply(ev) } }

        let command = state.turns[0].items.first { $0.id == "item_1" }
        XCTAssertEqual(command?.type, .commandExecution)
        XCTAssertEqual(command?.output, "README.md\nSources",
                       "aggregated_output must become the command item output")
        XCTAssertEqual(command?.state, .completed)

        let declined = state.turns[0].items.first { $0.id == "item_2" }
        XCTAssertEqual(declined?.state, .cancelled,
                       "declined command_execution must map to cancelled like app-server")
        XCTAssertEqual(declined?.output ?? "", "",
                       "empty aggregated_output is empty stdout, not the command line")
        XCTAssertEqual(declined?.summary, "rm -rf /",
                       "the command line stays in summary")

        XCTAssertEqual(state.turns[0].finalAssistantMessage, "Listed the repo.")
        XCTAssertEqual(state.tokenUsage?.inputTokens, 24763)
        XCTAssertEqual(state.tokenUsage?.cacheReadInputTokens, 24448)
        XCTAssertEqual(state.tokenUsage?.uncachedInputTokens, 24763 - 24448)
        XCTAssertEqual(state.tokenUsage?.cacheCreationInputTokens, 12,
                       "cache_write_input_tokens maps to cache creation bucket")
        XCTAssertEqual(state.tokenUsage?.outputTokens, 122)
    }

    func test_realExecSchema_omittedAggregatedOutputIsNotTheCommand() {
        // WHY: openai/codex may omit aggregated_output while a command is in
        // progress or printed nothing. Falling through to `command` paints the
        // argv as fake stdout.
        let p = CodexParser()
        var state = AssistantTimelineState()
        for l in [
            #"{"type":"thread.started","thread_id":"t-empty"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_empty","type":"command_execution","command":"true","status":"completed"}}"#
        ] { for ev in p.parseLine(l) { state.apply(ev) } }
        let item = state.turns[0].items.first { $0.id == "item_empty" }
        XCTAssertEqual(item?.type, .commandExecution)
        XCTAssertEqual(item?.summary, "true")
        XCTAssertEqual(item?.output ?? "", "",
                       "omitted aggregated_output must not display the command string")
    }

    func test_realExecSchema_camelCaseCommandExecutionIsNotAssistantText() {
        // WHY: app-server ThreadItem uses camelCase commandExecution. After
        // lowercasing, that is "commandexecution", which used to miss
        // command_execution and fall through to assistantMessage.
        let p = CodexParser()
        var state = AssistantTimelineState()
        for l in [
            #"{"type":"thread.started","thread_id":"t-camel"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_camel","type":"commandExecution","command":"ls","aggregated_output":"README.md","status":"completed"}}"#
        ] { for ev in p.parseLine(l) { state.apply(ev) } }
        let item = state.turns[0].items.first { $0.id == "item_camel" }
        XCTAssertEqual(item?.type, .commandExecution)
        XCTAssertEqual(item?.summary, "ls")
        XCTAssertEqual(item?.output, "README.md")
    }

    func test_realExecSchema_itemUpdatedTodoList() {
        let p = CodexParser()
        var state = AssistantTimelineState()
        state.apply(.turnStarted(turnId: "turn-1"))
        let events = p.parseLine(#"{"type":"item.updated","item":{"id":"todo-1","type":"todo_list","text":"Working","plan":[{"step":"Inspect","status":"completed"},{"step":"Patch","status":"in_progress"}]}}"#)
        for event in events { state.apply(event) }
        XCTAssertEqual(state.activePlan?.steps.map(\.title), ["Inspect", "Patch"])
        XCTAssertTrue(events.contains {
            if case .itemStarted(let item) = $0 { return item.id == "todo-1" && item.type == .plan }
            return false
        }, "item.updated nested todo_list must surface as a plan item")
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
        // P2-T2: no cached portion => whole input is uncached, read/creation zero.
        XCTAssertEqual(state.tokenUsage?.uncachedInputTokens, 10)
        XCTAssertEqual(state.tokenUsage?.cacheReadInputTokens, 0)
        XCTAssertEqual(state.tokenUsage?.cacheCreationInputTokens, 0)
    }

    func test_codexTokenUsageSplitsCachedInput() {
        let p = CodexParser()
        let events = p.parseLine(#"{"type":"thread.token_usage","input_tokens":1000,"output_tokens":50,"total_tokens":1050,"cached_input_tokens":800}"#)
        let usage = events.compactMap { event -> AssistantTokenUsage? in
            if case .tokenUsage(let u) = event { return u }
            return nil
        }.last
        // G3: inputTokens stays the billed total; the split breaks out the cached read.
        XCTAssertEqual(usage?.inputTokens, 1000, "billed total preserved (back-compat)")
        XCTAssertEqual(usage?.cacheReadInputTokens, 800, "cached portion is a cache read (~0.1x cost)")
        XCTAssertEqual(usage?.uncachedInputTokens, 200, "uncached = input - cached")
        XCTAssertEqual(usage?.cacheCreationInputTokens, 0, "Codex has no separate creation bucket")
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

    func test_reasoningFileChangeAndWebSearchLandInOutputNotBody() {
        // WHY: Agent App Thought/edit/search cards read item.output; exec JSONL
        // used to park these types in body so the UI showed a placeholder.
        let p = CodexParser()
        var state = AssistantTimelineState()
        for l in [
            #"{"type":"thread.started","thread_id":"t-output"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"**Scanning docs**"}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"file_change","text":"updated App.swift"}}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"web_search","query":"RemoteCode"}}"#,
            #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Done."}}"#,
            #"{"type":"turn.completed"}"#
        ] { for ev in p.parseLine(l) { state.apply(ev) } }

        let reasoning = state.turns[0].items.first { $0.id == "item_0" }
        XCTAssertEqual(reasoning?.type, .reasoning)
        XCTAssertEqual(reasoning?.output, "**Scanning docs**")
        XCTAssertEqual(reasoning?.body ?? "", "")
        let file = state.turns[0].items.first { $0.id == "item_1" }
        XCTAssertEqual(file?.type, .fileChange)
        XCTAssertEqual(file?.output, "updated App.swift")
        let search = state.turns[0].items.first { $0.id == "item_2" }
        XCTAssertEqual(search?.type, .webSearch)
        XCTAssertEqual(search?.output, "RemoteCode")
        XCTAssertEqual(state.turns[0].finalAssistantMessage, "Done.",
                       "assistant text stays on body/assembled; reasoning must not steal the reply")
    }

    func test_todoListItemsUseTextAndCompleted() {
        // WHY: official exec todo_list is items[].{text,completed}, not plan/steps.
        let p = CodexParser()
        var state = AssistantTimelineState()
        state.apply(.turnStarted(turnId: "turn-1"))
        let events = p.parseLine(#"{"type":"item.updated","item":{"id":"item_2","type":"todo_list","items":[{"text":"Scan protocol","completed":false},{"text":"Patch wire","completed":true}]}}"#)
        for event in events { state.apply(event) }
        XCTAssertEqual(state.activePlan?.steps.map(\.title), ["Scan protocol", "Patch wire"])
        XCTAssertEqual(state.activePlan?.steps.map(\.status), [.pending, .completed])
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

    // MARK: - T021: ExitPlanMode plan extraction uses the real tool output

    /// WHY (MAC-AGENT-RUNTIME-T021): The Anthropic API sends tool input as a
    /// stream of input_json_delta fragments, but ExitPlanModeInput contains only
    /// allowedPrompts. The plan markdown is returned later in ExitPlanModeOutput.
    /// Reading `input.plan` fabricates a schema field and loses real SDK plans.
    func test_exitPlanModeUsesRealToolResultAfterFragmentedInput() {
        let p = ClaudeParser()
        // System init so threadEmitted is set and turn id is allocated.
        _ = p.parseLine(#"{"type":"system","subtype":"init","session_id":"sess-t021"}"#)
        _ = p.parseLine(#"{"type":"message_start","message":{"id":"msg-t021"}}"#)
        // Tool use block start for ExitPlanMode (no pre-loaded input; input arrives via deltas).
        _ = p.parseLine(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-t021","name":"exit_plan_mode"}}"#)
        // Three input_json_delta fragments that together form {"allowedPrompts":[]}.
        // Each partial_json value is a raw fragment (byte slice) of the final JSON.
        // Fragment 1 outer partial_json = {"plan":"Inspect (quotes inside escaped as \")
        _ = p.parseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"allowed"}}"#)
        // Fragment 2 outer partial_json = " then " (no special chars).
        _ = p.parseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"Prompts\":"}}"#)
        // Fragment 3 outer partial_json = Patch"} (closing the inner JSON string+object).
        _ = p.parseLine(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"[]}"}}"#)
        let stopEvs = p.parseLine(#"{"type":"content_block_stop","index":0}"#)
        XCTAssertFalse(stopEvs.contains { if case .proposedPlan = $0 { return true }; return false },
                       "ExitPlanMode input must not be mistaken for the plan output")

        let outputEvs = p.parseLine(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-t021","content":{"plan":"Inspect then Patch","filePath":"/tmp/plan.md"}}]}}"#)

        let plans = outputEvs.compactMap { ev -> AssistantProposedPlan? in
            if case .proposedPlan(let plan) = ev { return plan }
            return nil
        }
        XCTAssertEqual(plans.count, 1,
                       "T021: the matching ExitPlanMode tool_result must produce exactly one proposedPlan event")
        XCTAssertEqual(plans.first?.markdown, "Inspect then Patch",
                       "T021: plan markdown must come from the real ExitPlanModeOutput fixture")
    }

    // MARK: - T022: result{is_error:true} error message fallback chain

    /// WHY (MAC-AGENT-RUNTIME-T022): When Claude finishes with is_error:true the
    /// user must see a meaningful error message. The fallback chain is:
    ///   1. result field  2. error.message  3. hardcoded "claude run failed"
    /// Without asserting each branch, a future refactor can silently drop the
    /// fallback and leave the user with a blank or missing error message.
    func test_resultIsErrorTrue_withResultText_emitsErrorWithResultMessage() {
        let p = ClaudeParser()
        _ = p.parseLine(#"{"type":"system","subtype":"init","session_id":"s1"}"#)
        _ = p.parseLine(#"{"type":"message_start","message":{"id":"m1"}}"#)
        let evs = p.parseLine(#"{"type":"result","is_error":true,"result":"authentication failed"}"#)

        let errors = evs.compactMap { ev -> (String, Bool)? in
            if case .error(let msg, let recoverable) = ev { return (msg, recoverable) }
            return nil
        }
        XCTAssertEqual(errors.count, 1, "T022: is_error result must emit exactly one .error event")
        XCTAssertEqual(errors.first?.0, "authentication failed",
                       "T022 branch-1: when result field is present it is used as the error message")
        XCTAssertEqual(errors.first?.1, false,
                       "T022: errors from a result event are not recoverable (the run is finished)")
    }

    func test_resultIsErrorTrue_withoutResultText_fallsBackToErrorMessage() {
        let p = ClaudeParser()
        _ = p.parseLine(#"{"type":"system","subtype":"init","session_id":"s2"}"#)
        _ = p.parseLine(#"{"type":"message_start","message":{"id":"m2"}}"#)
        let evs = p.parseLine(#"{"type":"result","is_error":true,"result":null,"error":{"message":"session expired"}}"#)

        let errors = evs.compactMap { ev -> String? in
            if case .error(let msg, _) = ev { return msg }
            return nil
        }
        XCTAssertEqual(errors.first, "session expired",
                       "T022 branch-2: when result is nil/absent, error.message is used as fallback; " +
                       "losing this fallback makes auth failures show a blank error in the Agent App")
    }

    func test_resultIsErrorTrue_withNoMessageFields_fallsBackToHardcodedString() {
        let p = ClaudeParser()
        _ = p.parseLine(#"{"type":"system","subtype":"init","session_id":"s3"}"#)
        _ = p.parseLine(#"{"type":"message_start","message":{"id":"m3"}}"#)
        let evs = p.parseLine(#"{"type":"result","is_error":true}"#)

        let errors = evs.compactMap { ev -> String? in
            if case .error(let msg, _) = ev { return msg }
            return nil
        }
        XCTAssertEqual(errors.first, "claude run failed",
                       "T022 branch-3: when neither result nor error.message is present the hardcoded " +
                       "sentinel string must be used so the Agent App always shows a non-empty error")
    }
}

// MARK: - CodexParser: assembled buffer bleed + synthesized turn id

extension CodexParserTests {

    // MARK: - T027: assembled buffer must not bleed across synthesized turns

    /// WHY (MAC-AGENT-RUNTIME-T027): CodexParser.assembled is only reset inside
    /// turn.started (line 40). After turn.completed it stays populated. If a
    /// second agent_message item arrives without an intervening turn.started
    /// (which happens in some codex exec schemas), the second turn's
    /// finalAssistantMessage would be "A\nB" instead of "B", causing the Agent
    /// App to display a doubled transcript and iOS to mirror the wrong text.
    ///
    /// NOTE: This test documents the EXISTING behavior (bleed present in current
    /// code). It is written as a characterization test so it fails loudly if the
    /// behavior changes in either direction.
    func test_assembledBuffer_bleeds_acrossTurnsWithoutTurnStarted() {
        let p = CodexParser()
        _ = p.parseLine(#"{"type":"thread.started","thread_id":"tid"}"#)

        // First turn: turn.started -> item.completed{agent_message:"A"} -> turn.completed
        _ = p.parseLine(#"{"type":"turn.started","turn_id":"turn-1"}"#)
        _ = p.parseLine(#"{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"A"}}"#)
        let turn1Evs = p.parseLine(#"{"type":"turn.completed","turn_id":"turn-1"}"#)
        let turn1Final = turn1Evs.compactMap { ev -> String? in
            if case .turnCompleted(_, let msg) = ev { return msg }
            return nil
        }.first
        XCTAssertEqual(turn1Final, "A",
                       "T027 setup: first turn must produce final message 'A'")

        // Second turn: item.completed{agent_message:"B"} -> turn.completed WITHOUT turn.started.
        // assembled was NOT reset because turn.started was skipped.
        _ = p.parseLine(#"{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"B"}}"#)
        let turn2Evs = p.parseLine(#"{"type":"turn.completed"}"#)
        let turn2Final = turn2Evs.compactMap { ev -> String? in
            if case .turnCompleted(_, let msg) = ev { return msg }
            return nil
        }.first

        // FIXED: assembled now resets on turn.completed, so the second turn's
        // final message is just "B" (no bleed of the previous turn's "A"), even
        // when the second turn arrives without a turn.started.
        XCTAssertEqual(turn2Final, "B",
                       "assembled must reset on turn.completed so a second turn (even without " +
                       "turn.started) does not concatenate the previous turn text -- prevents " +
                       "the doubled-transcript bug in the iOS mirror")
    }

    // MARK: - T028: turn.completed without prior turn.started uses ensureTurn id

    /// WHY (MAC-AGENT-RUNTIME-T028): When turn.started is absent, CodexParser
    /// uses ensureTurn to synthesize a turn id. turn.completed then looks up
    /// currentTurnId (set by ensureTurn) but also tries obj["turn_id"] from the
    /// event. If the event carries its OWN id it could orphan the items that
    /// used the ensureTurn id. This test pins that items and turn.completed share
    /// the same turn id when no explicit turn id is present in either event.
    func test_turnCompleted_withoutTurnStarted_usesSynthesizedTurnId() {
        let p = CodexParser()
        _ = p.parseLine(#"{"type":"thread.started","thread_id":"tid2"}"#)

        // item.completed triggers ensureTurn which synthesizes a turn id.
        let itemEvs = p.parseLine(#"{"type":"item.completed","item":{"id":"i3","type":"agent_message","text":"hello"}}"#)
        let itemTurnId = itemEvs.compactMap { ev -> String? in
            if case .turnStarted(let tid) = ev { return tid }
            return nil
        }.first
        XCTAssertNotNil(itemTurnId,
                        "T028: ensureTurn must emit turnStarted when no turn.started preceded item.completed")

        // turn.completed with no turn_id field must use currentTurnId (set by ensureTurn).
        let completedEvs = p.parseLine(#"{"type":"turn.completed"}"#)
        let completedTurnId = completedEvs.compactMap { ev -> String? in
            if case .turnCompleted(let tid, _) = ev { return tid }
            return nil
        }.first
        XCTAssertEqual(completedTurnId, itemTurnId,
                       "T028: turn.completed without a turn_id must use the same synthesized id that " +
                       "ensureTurn assigned to the preceding items; a mismatch orphans the items' " +
                       "turn and the Agent App cannot match them")
    }
}
