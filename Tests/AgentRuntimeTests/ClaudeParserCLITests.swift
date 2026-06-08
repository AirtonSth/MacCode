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

    func test_hookLinesBeforeInit_keepSessionIdForResume() {
        // The cmux claude wrapper emits hook_started/hook_response BEFORE
        // init — these must not strip the resume id.
        let evs = collect([
            #"{"type":"system","subtype":"hook_started","session_id":"sess-X","hook_name":"SessionStart"}"#,
            #"{"type":"system","subtype":"hook_response","session_id":"sess-X","output":"OK"}"#,
            #"{"type":"system","subtype":"init","session_id":"sess-X"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#,
            #"{"type":"result","subtype":"success","result":"hi","session_id":"sess-X"}"#
        ])
        var ptid: String?
        for e in evs { if case .threadStarted(_, let p) = e { ptid = p } }
        XCTAssertEqual(ptid, "sess-X",
                       "session id from init must survive preceding hook_* lines → becomes the resume id")
    }

    func test_resultOnly_stillCompletesTurn() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s2"}"#,
            #"{"type":"result","subtype":"success","result":"done"}"#
        ])
        XCTAssertEqual(finalMessage(evs), "done",
                       "even with no assistant block, result must finalize the turn (not hang)")
    }

    func test_resultModelUsageEmitsTokenUsageForClaudeSdkBridge() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s-usage"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"S: ready"}]}}"#,
            #"{"type":"result","subtype":"success","result":"S: ready","modelUsage":{"claude-haiku-4-5-20251001":{"inputTokens":510,"outputTokens":13,"cacheCreationInputTokens":0,"cacheReadInputTokens":0,"contextWindow":200000},"claude-sonnet-4-6":{"inputTokens":6,"outputTokens":175,"cacheCreationInputTokens":22947,"cacheReadInputTokens":22517,"contextWindow":200000}}}"#
        ])

        let usage = evs.compactMap { event -> AssistantTokenUsage? in
            if case .tokenUsage(let usage) = event { return usage }
            return nil
        }.last

        XCTAssertEqual(usage?.inputTokens, 45_980)
        XCTAssertEqual(usage?.outputTokens, 188)
        XCTAssertEqual(usage?.totalTokens, 46_168)
        XCTAssertEqual(usage?.contextWindow, 200_000,
                       "Claude SDK bridge result.modelUsage must feed Token Saver and context pressure; otherwise /distill responses complete but Saved stays 0")
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

    func test_askUserQuestionTool_becomesStructuredUserInputRequest() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s5"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"ask-1","name":"AskUserQuestion","input":{"question":"Pick path","options":[{"label":"Plan"},{"label":"Run"}],"allows_multiple_selection":true}}]}}"#,
            #"{"type":"result","subtype":"success","result":"waiting"}"#
        ])

        let request = evs.compactMap { event -> AssistantUserInputRequest? in
            if case .userInputRequested(let request) = event { return request }
            return nil
        }.first

        XCTAssertEqual(request?.id, "ask-1")
        XCTAssertEqual(request?.prompt, "Pick path")
        XCTAssertEqual(request?.options, ["Plan", "Run"])
        XCTAssertEqual(request?.allowsMultipleSelection, true,
                       "Claude AskUserQuestion must become actionable RemoteCode user-input state instead of a dead generic tool row")
    }

    func test_exitPlanModeTool_becomesStructuredProposedPlan() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s6"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"plan-1","name":"ExitPlanMode","input":{"plan":"1. Inspect\n2. Patch\n3. Test"}}]}}"#,
            #"{"type":"result","subtype":"success","result":"plan ready"}"#
        ])

        let plan = evs.compactMap { event -> AssistantProposedPlan? in
            if case .proposedPlan(let plan) = event { return plan }
            return nil
        }.first

        XCTAssertEqual(plan?.id, "plan-1")
        XCTAssertEqual(plan?.markdown, "1. Inspect\n2. Patch\n3. Test",
                       "Claude ExitPlanMode must create a persisted proposed-plan artifact that can be implemented later")
    }

    func test_streamingAskUserQuestionTool_becomesStructuredUserInputRequest() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s7"}"#,
            #"{"type":"message_start","message":{"id":"m7"}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"ask-stream","name":"AskUserQuestion"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"question\":\"Pick device\",\"options\":[\"Mac\",\"iPhone\"],\"multi_select\":false}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"result","subtype":"success","result":"waiting"}"#
        ])

        let request = evs.compactMap { event -> AssistantUserInputRequest? in
            if case .userInputRequested(let request) = event { return request }
            return nil
        }.first

        XCTAssertEqual(request?.id, "ask-stream")
        XCTAssertEqual(request?.prompt, "Pick device")
        XCTAssertEqual(request?.options, ["Mac", "iPhone"])
        XCTAssertEqual(request?.allowsMultipleSelection, false,
                       "Streaming Claude tool input must become actionable RemoteCode user-input state")
    }

    func test_streamingExitPlanModeTool_becomesStructuredProposedPlan() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s8"}"#,
            #"{"type":"message_start","message":{"id":"m8"}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"plan-stream","name":"ExitPlanMode"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"plan\":\"1. Inspect\\n2. Patch\\n3. Test\"}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"result","subtype":"success","result":"plan ready"}"#
        ])

        let plan = evs.compactMap { event -> AssistantProposedPlan? in
            if case .proposedPlan(let plan) = event { return plan }
            return nil
        }.first

        XCTAssertEqual(plan?.id, "plan-stream")
        XCTAssertEqual(plan?.markdown, "1. Inspect\n2. Patch\n3. Test",
                       "Streaming Claude ExitPlanMode must create the same persisted plan artifact as whole-message CLI output")
    }

    func test_claudeSystemLifecycleEventsBecomeVisibleLongRunTelemetry() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s9","usage":{"input_tokens":10,"output_tokens":2,"context_window":200,"compacts_automatically":true}}"#,
            #"{"type":"system","subtype":"status","status":"running","message":"working"}"#,
            #"{"type":"system","subtype":"hook_started","hook_name":"SessionStart","message":"boot"}"#,
            #"{"type":"system","subtype":"task_progress","task_id":"task-1","task":"Build","message":"half","progress":50}"#,
            #"{"type":"system","subtype":"files_persisted","files":["a.swift","b.swift"]}"#,
            #"{"type":"system","subtype":"compact_boundary","summary":"older Claude turns summarized"}"#,
            #"{"type":"auth_status","status":"expired","authenticated":false,"message":"Claude login expired"}"#,
            #"{"type":"rate_limit_event","limit_type":"requests","reset_at":"2026-05-23T12:00:00Z","rate_limit_info":{"primary":{"usedPercent":57,"windowDurationMins":10080,"resetsAt":"2026-05-23T12:00:00Z"}}}"#
        ])

        XCTAssertTrue(evs.contains {
            if case .tokenUsage(let usage) = $0 {
                return usage.totalTokens == 12 && usage.contextWindow == 200 && usage.compactsAutomatically == true
            }
            return false
        }, "Claude SDK/CLI usage telemetry must update context pressure for long-running sessions")
        XCTAssertTrue(evs.contains {
            if case .contextCompaction(let summary) = $0 {
                return summary == "older Claude turns summarized"
            }
            return false
        }, "Claude compact_boundary must surface as normalized context compaction instead of raw-only runtime")
        XCTAssertTrue(evs.contains {
            if case .itemStarted(let item) = $0 {
                return item.type == .tool && item.summary == "Claude hook: SessionStart"
            }
            return false
        }, "Claude hook lifecycle must be visible in the work log so the UI does not look frozen")
        XCTAssertTrue(evs.contains {
            if case .itemProgress(let itemId, let progress) = $0 {
                return itemId == "task-1" && progress == 0.5
            }
            return false
        }, "Claude task progress must preserve percent updates for long-running work")
        XCTAssertTrue(evs.contains {
            if case .itemStarted(let item) = $0 {
                return item.type == .fileChange && item.body.contains("a.swift")
            }
            return false
        }, "Claude files_persisted must render as file-change work instead of disappearing")
        XCTAssertTrue(evs.contains {
            if case .error(let message, let recoverable) = $0 {
                return recoverable && message.contains("Claude login expired")
            }
            return false
        }, "Claude auth_status failures must fail loud and recoverable")
        XCTAssertTrue(evs.contains {
            if case .itemStarted(let item) = $0 {
                return item.type == .tool && item.summary == "Claude rate limit" && item.body.contains("requests")
            }
            return false
        }, "Claude rate_limit_event must be visible before the user assumes the app hung")
        XCTAssertTrue(evs.contains {
            if case .accountUsage(let usage) = $0 {
                return usage.provider == .claude && usage.weeklyUsedPercent == 57 && usage.weeklyWindowDurationMinutes == 10_080
            }
            return false
        }, "Claude rate_limit_info must feed Token Saver weekly account usage instead of leaving the rings at fake 100%")
        XCTAssertFalse(evs.contains {
            if case .error(let message, _) = $0 {
                return message.contains("requests")
            }
            return false
        }, "Claude rate_limit_event must not render as an agent error when the turn later succeeds")
    }

    func test_claudeSdkPermissionLifecycleBecomesApprovalRequest() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s10"}"#,
            #"{"type":"message_start","message":{"id":"turn-10"}}"#,
            #"{"type":"canUseTool/request","request_id":"perm-1","tool_name":"Bash","input":{"command":"swift test"}}"#,
            #"{"type":"canUseTool/decision","request_id":"perm-1","decision":"approved"}"#
        ])

        let opened = evs.compactMap { event -> AssistantPendingRequest? in
            if case .requestOpened(let request) = event { return request }
            return nil
        }.first
        XCTAssertEqual(opened?.id, "perm-1")
        XCTAssertEqual(opened?.kind, .commandExecution)
        XCTAssertEqual(opened?.title, "Bash")
        XCTAssertTrue(opened?.detail?.contains("swift test") == true,
                      "Claude SDK canUseTool permission requests must preserve tool input detail for approval review")

        XCTAssertTrue(evs.contains {
            if case .requestResolved(let requestId, let state) = $0 {
                return requestId == "perm-1" && state == .approved
            }
            return false
        }, "Claude SDK canUseTool decisions must resolve the matching RemoteCode approval card")
    }

    func test_sdkNestedStreamEventsRenderAssistantDeltasWithoutDuplicatingWholeMessage() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"sdk-stream"}"#,
            #"{"type":"stream_event","session_id":"sdk-stream","event":{"type":"message_start","message":{"id":"turn-sdk"}}}"#,
            #"{"type":"stream_event","session_id":"sdk-stream","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","session_id":"sdk-stream","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"S partial "}}}"#,
            #"{"type":"stream_event","session_id":"sdk-stream","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"visible"}}}"#,
            #"{"type":"stream_event","session_id":"sdk-stream","event":{"type":"content_block_stop","index":0}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"S partial visible"}]},"session_id":"sdk-stream"}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"S partial visible","session_id":"sdk-stream"}"#
        ])

        let assistantDeltas = evs.compactMap { event -> String? in
            if case .itemDelta(_, let body, _, _) = event { return body }
            return nil
        }
        XCTAssertTrue(assistantDeltas.contains("S partial "),
                      "Claude Agent SDK nested stream_event text deltas must render immediately as assistant partial updates")
        XCTAssertTrue(assistantDeltas.contains("visible"),
                      "Claude Agent SDK nested stream_event continuation deltas must keep updating the same visible assistant item")
        XCTAssertEqual(assistantDeltas.filter { $0 == "S partial visible" }.count, 0,
                       "the later whole assistant message must not duplicate text already streamed from nested SDK events")
        XCTAssertEqual(finalMessage(evs), "S partial visible")
    }

    func test_cliRepeatedAssistantTextBlocksDoNotRenderTwiceWithinTurn() {
        let final = "O committed + pushed. Done. Commit 3fcf1ceb fix(attendance): refresh camp report after attendance changes. Pre-commit passed."
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"sess-repeat"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Pre-commit hooks passed. Push."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Pre-commit hooks passed. Push."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(final)"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(final)"}]}}"#,
            #"{"type":"result","subtype":"success","result":"\#(final)","session_id":"sess-repeat"}"#
        ])

        let assistantBodies = evs.compactMap { event -> String? in
            if case .itemDelta(_, let body, _, _) = event { return body }
            return nil
        }
        XCTAssertEqual(assistantBodies.filter { $0 == "Pre-commit hooks passed. Push." }.count, 1,
                       "Claude whole-message replay can repeat a mid-turn assistant text block; the parser must emit it once")
        XCTAssertEqual(assistantBodies.filter { $0 == final }.count, 1,
                       "Claude whole-message replay can repeat the completed answer before result; the parser must not create two visible answer items")
        XCTAssertEqual(finalMessage(evs), final)
    }
}
