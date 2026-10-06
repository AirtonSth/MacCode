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
            #"{"type":"result","subtype":"success","result":"S: ready","total_cost_usd":0.012345,"modelUsage":{"claude-haiku-4-5-20251001":{"inputTokens":510,"outputTokens":13,"cacheCreationInputTokens":0,"cacheReadInputTokens":0,"contextWindow":200000},"claude-sonnet-4-6":{"inputTokens":6,"outputTokens":175,"cacheCreationInputTokens":22947,"cacheReadInputTokens":22517,"contextWindow":200000}}}"#
        ])

        let usage = evs.compactMap { event -> AssistantTokenUsage? in
            if case .tokenUsage(let usage) = event { return usage }
            return nil
        }.last

        XCTAssertEqual(usage?.inputTokens, 45_980)
        XCTAssertEqual(usage?.outputTokens, 188)
        XCTAssertEqual(usage?.totalTokens, 46_168)
        XCTAssertEqual(usage?.resolvedSemantics, .cumulative,
                       "final modelUsage is an authoritative run snapshot, not another request charge")
        XCTAssertEqual(usage?.contextWindow, 200_000,
                       "Claude SDK bridge result.modelUsage must feed usage and context pressure; otherwise the usage totals stay 0")
        // G3: the three cache buckets are recorded SEPARATELY (not folded), so net
        // dollars are computable. uncached(510+6) + creation(0+22947) + read(0+22517) = 45980.
        XCTAssertEqual(usage?.uncachedInputTokens, 516)
        XCTAssertEqual(usage?.cacheCreationInputTokens, 22_947)
        XCTAssertEqual(usage?.cacheReadInputTokens, 22_517)
        XCTAssertEqual(usage?.reportedCostMicros, 12_345,
                       "Claude total_cost_usd must become an exact integer-micros receipt")
        XCTAssertEqual(
            (usage?.uncachedInputTokens ?? 0) + (usage?.cacheCreationInputTokens ?? 0) + (usage?.cacheReadInputTokens ?? 0),
            usage?.inputTokens,
            "the split must sum to the billed input total (back-compat preserved)"
        )
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

    /// CLAUDE-INT-003: host interrupt `aborted_streaming` is a cancelled completion,
    /// not a hard provider error (SDK bridge parity).
    func test_abortedStreamingResult_doesNotEmitHardError() throws {
        let liveResult = #"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_streaming","result":"","session_id":"388003a9-918d-4850-9190-fdbe2ea6ab53","errors":["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null"]}"#
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(liveResult.utf8)) as? [String: Any]
        )
        XCTAssertTrue(ClaudeParser.isHostInterruptResult(obj))
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"388003a9-918d-4850-9190-fdbe2ea6ab53"}"#,
            liveResult
        ])
        XCTAssertFalse(evs.contains {
            if case .error(_, let recoverable) = $0 { return !recoverable }
            return false
        }, "aborted_streaming must not surface as a hard error on Stop")
        XCTAssertTrue(evs.contains {
            if case .turnCompleted = $0 { return true }
            return false
        }, "interrupted result still completes the turn so the host can mark cancelled")
    }

    /// CLAUDE-INT-002: inbound interrupt receipt is parseable and is not an error event.
    func test_controlResponseReceipt_parsesLiveInterruptReceipt() throws {
        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"3ad25933-b695-4e02-9b43-0ad5c0cf0fcd","response":{"still_queued":[],"cancelled":[]}}}"#
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let receipt = try XCTUnwrap(ClaudeParser.controlResponseReceipt(from: obj))
        XCTAssertEqual(receipt.requestId, "3ad25933-b695-4e02-9b43-0ad5c0cf0fcd")
        XCTAssertTrue(receipt.success)
        XCTAssertEqual(receipt.cancelled, [])
        XCTAssertEqual(receipt.stillQueued, [])
        let evs = collect([line])
        XCTAssertFalse(evs.contains {
            if case .error = $0 { return true }
            return false
        }, "inbound control_response must not emit an error event")
        XCTAssertNil(
            ClaudeParser.controlResponseReceipt(from: ["type": "control_request"]),
            "outbound control_request is not a receipt"
        )
    }

    /// CLAUDE-AUTH-001: live unauthenticated CLI 2.1.258 emits a synthetic
    /// assistant envelope, not `auth_status`. That must fail recoverable, not
    /// render as a successful assistant reply.
    func test_authenticationFailedAssistantEnvelope_isRecoverableError() throws {
        let live = #"{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Not logged in · Please run /login"}]},"error":"authentication_failed","is_api_error_message":true,"uuid":"9d8248d5-c007-45f9-a2ae-5b0cebb67ec3"}"#
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(live.utf8)) as? [String: Any]
        )
        XCTAssertTrue(ClaudeParser.isAuthenticationFailedAssistantEnvelope(obj))
        XCTAssertFalse(
            ClaudeParser.isAuthenticationFailedAssistantEnvelope(
                ["type": "assistant", "message": ["content": [["type": "text", "text": "pong"]]]]
            ),
            "normal assistant text must not be classified as authentication failure"
        )
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"adf68b25-91dc-4dea-ad48-6b2d4b1c03f0"}"#,
            live
        ])
        XCTAssertTrue(evs.contains {
            if case .error(let message, let recoverable) = $0 {
                return recoverable && message.contains("Not logged in")
            }
            return false
        }, "authentication_failed assistant envelope must be a recoverable error")
        XCTAssertFalse(evs.contains {
            if case .itemStarted(let item) = $0 {
                return item.type == .assistantMessage
            }
            return false
        }, "synthetic auth assistant text must not render as an assistant reply")
        XCTAssertFalse(evs.contains {
            if case .itemDelta(_, let body, _, _) = $0 { return body?.contains("Not logged in") == true }
            return false
        }, "auth-failed body must not stream as assistant deltas")
        XCTAssertTrue(evs.contains {
            if case .turnCompleted = $0 { return true }
            return false
        }, "auth-failed envelope with no result must still complete the turn")
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

    // Real Claude AskUserQuestion schema: a `questions` array, each with its own
    // `question`, `header`, structured `options` (label+description), and
    // `multiSelect`. The previous parser only read a singular `question`/`options`
    // shape that the tool never emits, so the card degraded to an unanswerable
    // "Input required" box (screenshot bug). This proves the real shape becomes a
    // structured, human-readable question instead.
    func test_askUserQuestionRealSchema_becomesStructuredQuestions() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s5b"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"ask-real","name":"AskUserQuestion","input":{"questions":[{"question":"Which auth method should we use?","header":"Auth","options":[{"label":"OAuth","description":"Delegated OAuth 2.0"},{"label":"API key","description":"Static shared key"}],"multiSelect":false}]}}]}}"#,
            #"{"type":"result","subtype":"success","result":"waiting"}"#
        ])

        let request = evs.compactMap { event -> AssistantUserInputRequest? in
            if case .userInputRequested(let request) = event { return request }
            return nil
        }.first

        XCTAssertEqual(request?.id, "ask-real")
        XCTAssertNotEqual(request?.prompt, "Input required",
                          "the real AskUserQuestion schema must not degrade to a placeholder prompt the user cannot act on")
        XCTAssertEqual(request?.questions.count, 1,
                       "the structured `questions` array must drive a human-readable question card")
        XCTAssertEqual(request?.questions.first?.prompt, "Which auth method should we use?")
        XCTAssertEqual(request?.questions.first?.header, "Auth")
        XCTAssertEqual(request?.questions.first?.options.map(\.label), ["OAuth", "API key"],
                       "option labels must be extracted so the user sees real choices instead of raw JSON")
        XCTAssertEqual(request?.questions.first?.options.map(\.detail), ["Delegated OAuth 2.0", "Static shared key"],
                       "option descriptions explain trade-offs and must survive parsing")
        XCTAssertEqual(request?.questions.first?.allowsMultipleSelection, false)
    }

    func test_askUserQuestionRealSchema_multiQuestionMultiSelect() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s5c"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"ask-multi","name":"AskUserQuestion","input":{"questions":[{"question":"Pick the framework?","header":"Framework","options":[{"label":"SwiftUI","description":"Declarative"},{"label":"AppKit","description":"Imperative"}],"multiSelect":false},{"question":"Which targets to support?","header":"Targets","options":[{"label":"macOS","description":""},{"label":"iPadOS","description":""}],"multiSelect":true}]}}]}}"#,
            #"{"type":"result","subtype":"success","result":"waiting"}"#
        ])

        let request = evs.compactMap { event -> AssistantUserInputRequest? in
            if case .userInputRequested(let request) = event { return request }
            return nil
        }.first

        XCTAssertEqual(request?.questions.count, 2,
                       "every question in the array must render, not just the first")
        XCTAssertEqual(request?.questions.last?.prompt, "Which targets to support?")
        XCTAssertEqual(request?.questions.last?.allowsMultipleSelection, true,
                       "per-question multiSelect must be preserved so checkbox vs radio rendering is correct")
        XCTAssertEqual(request?.questions.last?.options.map(\.label), ["macOS", "iPadOS"])
    }

    func test_askUserQuestionStreamingAndWholeAssistantEchoEmitOneStructuredRequest() {
        let parser = ClaudeParser()
        var events: [AssistantEvent] = []
        events += parser.parseLine(#"{"type":"system","subtype":"init","session_id":"ask-dedup-session"}"#)
        events += parser.parseLine(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"ask-dedup","name":"AskUserQuestion","input":{"questions":[{"question":"Pick one","header":"Gate","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}}]}}"#)
        events += parser.parseLine(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"ask-dedup","name":"AskUserQuestion","input":{"questions":[{"question":"Pick one","header":"Gate","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}}]}}"#)

        let requests = events.compactMap { event -> AssistantUserInputRequest? in
            if case .userInputRequested(let request) = event { return request }
            return nil
        }
        XCTAssertEqual(requests.count, 1,
                       "streaming and whole assistant echoes describe one AskUserQuestion and must render one structured event")
        XCTAssertEqual(requests.first?.id, "ask-dedup")
    }

    func test_exitPlanModeTool_becomesStructuredProposedPlan() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s6"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"plan-1","name":"ExitPlanMode","input":{"allowedPrompts":[]}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"plan-1","content":{"plan":"1. Inspect\n2. Patch\n3. Test","filePath":"/tmp/plan.md","isAgent":false}}]}}"#,
            #"{"type":"result","subtype":"success","result":"plan ready"}"#
        ])

        let plan = evs.compactMap { event -> AssistantProposedPlan? in
            if case .proposedPlan(let plan) = event { return plan }
            return nil
        }.first

        XCTAssertEqual(plan?.id, "plan-1")
        XCTAssertEqual(plan?.markdown, "1. Inspect\n2. Patch\n3. Test",
                       "Claude ExitPlanMode must use the real SDK tool output; its input contains allowedPrompts, not plan markdown")
    }

    func test_exitPlanModeUsesSDKTopLevelToolResultContract() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s6-real"}"#,
            ##"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"plan-real","name":"ExitPlanMode","input":{"plan":"# Review me","planFilePath":"/tmp/plan.md"}}]}}"##,
            ##"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"plan-real","content":"User has approved your plan."}]},"tool_use_result":{"plan":"# Review me","filePath":"/tmp/plan.md","isAgent":false}}"##
        ])

        let plans = evs.compactMap { event -> AssistantProposedPlan? in
            if case .proposedPlan(let plan) = event { return plan }
            return nil
        }
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.markdown, "# Review me",
                       "the installed SDK carries ExitPlanModeOutput at top level, while message.content is only approval prose")
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
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"allowedPrompts\":[]}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"plan-stream","content":"{\"plan\":\"1. Inspect\\n2. Patch\\n3. Test\",\"filePath\":\"/tmp/plan.md\"}"}]}}"#,
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
        }, "Claude rate_limit_info must feed weekly account usage instead of leaving the rings at fake 100%")
        XCTAssertFalse(evs.contains {
            if case .error(let message, _) = $0 {
                return message.contains("requests")
            }
            return false
        }, "Claude rate_limit_event must not render as an agent error when the turn later succeeds")
    }

    /// Live Claude Code 2.1.258 emits `unifiedWindows` instead of `primary.usedPercent`.
    /// Parser must still feed `.accountUsage` so the usage rings move during the turn.
    func test_rateLimitEvent_unifiedWindowsFeedsAccountUsage() {
        let line = #"{"type":"rate_limit_event","uuid":"rl-1","session_id":"s-rl","rate_limit_info":{"rateLimitType":"five_hour","resetsAt":1788368400,"status":"allowed","unifiedWindows":{"five_hour":{"resetsAt":1788368400,"utilization":0.58},"seven_day":{"resetsAt":1788703200,"utilization":0.30},"seven_day_overage_included":{"resetsAt":1788703200,"utilization":0.39}}}}"#
        let evs = collect([line])
        XCTAssertTrue(evs.contains {
            if case .itemStarted(let item) = $0 {
                return item.type == .tool
                    && item.summary == "Claude rate limit"
                    && item.body.contains("five_hour")
                    && item.body.contains("allowed")
            }
            return false
        }, "unifiedWindows rate_limit_event must stay visible in the work log")
        XCTAssertTrue(evs.contains {
            if case .accountUsage(let usage) = $0 {
                return usage.provider == .claude
                    && usage.weeklyUsedPercent == 30
                    && usage.currentSessionUsedPercent == 58
            }
            return false
        }, "Claude Code 2.1.258 unifiedWindows must update the usage rings during the turn")
    }

    /// Headless docs: system/api_retry precedes a retriable API failure. Without a
    /// visible row, long retries look like a hung Claude turn.
    func test_systemApiRetry_becomesVisibleTelemetry() {
        let line = #"{"type":"system","subtype":"api_retry","attempt":2,"max_retries":5,"retry_delay_ms":1200,"error_status":429,"error":"rate_limit","uuid":"retry-1","session_id":"s-retry"}"#
        let evs = collect([line])
        XCTAssertTrue(evs.contains {
            if case .itemStarted(let item) = $0 {
                return item.type == .tool
                    && item.summary == "Claude API retry"
                    && item.body.contains("2/5")
                    && item.body.contains("rate_limit")
                    && item.body.contains("1200ms")
            }
            return false
        }, "system/api_retry must surface so retries are not mistaken for a hung turn")
    }

    /// Live Claude CLI (2.1.219) task / heartbeat payloads put human text on
    /// `description` / `task_type` / `status` / `elapsed_time_seconds` — not on
    /// the older `title`/`message` keys. Rows must not fall back to raw JSON.
    func test_backgroundTaskAndHeartbeatPayloads_renderHumanReadableText() {
        // Real captured payloads (claude CLI 2.1.219), wrapped as the stream
        // delivers them: task_* as system subtypes, tool_progress as top-level.
        let taskStarted = #"{"type":"system","description":"Check C-04 and poll for new completions","session_id":"sess-bg","subtype":"task_started","task_id":"bjl1462g4","task_type":"local_bash","tool_use_id":"toolu_01B3YGG"}"#
        let taskNotification = #"{"type":"system","output_file":"","session_id":"sess-bg","status":"completed","subtype":"task_notification","task_id":"bjl1462g4"}"#
        let heartbeat = #"{"type":"tool_progress","elapsed_time_seconds":30,"heartbeat":true,"parent_tool_use_id":"toolu_01B3YGG","session_id":"sess-bg"}"#
        let sparseUnknown = #"{"type":"system","subtype":"task_started","task_id":"sparse-1"}"#

        let startedEvs = collect([taskStarted])
        let started = startedEvs.compactMap { event -> AssistantItem? in
            if case .itemStarted(let item) = event { return item }
            return nil
        }.first
        XCTAssertEqual(started?.summary, "Background shell",
                       "local_bash task_started must label as a background shell")
        XCTAssertEqual(started?.body, "Check C-04 and poll for new completions",
                       "task_started body must prefer description over raw JSON")
        XCTAssertFalse(started?.body.contains("session_id") == true)
        XCTAssertFalse(started?.body.contains("subtype") == true)
        XCTAssertFalse(started?.body.contains("tool_use_id") == true)

        let notifEvs = collect([taskNotification])
        let notif = notifEvs.compactMap { event -> AssistantItem? in
            if case .itemStarted(let item) = event { return item }
            return nil
        }.first
        XCTAssertTrue(notif?.body.contains("completed") == true,
                      "task_notification body must surface status; got \(notif?.body ?? "nil")")
        XCTAssertFalse(notif?.body.contains("session_id") == true)
        XCTAssertFalse(notif?.body.contains("subtype") == true)
        XCTAssertFalse(notif?.body.contains("\"status\"") == true,
                       "status must be human text, not a raw JSON key fragment")

        let beatEvs = collect([heartbeat])
        let beat = beatEvs.compactMap { event -> AssistantItem? in
            if case .itemStarted(let item) = event { return item }
            return nil
        }.first
        XCTAssertTrue(beat?.body.contains("30") == true,
                      "heartbeat tool_progress must surface elapsed_time_seconds; got \(beat?.body ?? "nil")")
        XCTAssertTrue(
            beat?.body.localizedCaseInsensitiveContains("elapsed") == true
                || beat?.body.localizedCaseInsensitiveContains("running") == true,
            "heartbeat body must read as running/elapsed human text; got \(beat?.body ?? "nil")"
        )
        XCTAssertFalse(beat?.body.contains("session_id") == true)
        XCTAssertFalse(beat?.body.contains("parent_tool_use_id") == true)
        XCTAssertFalse(beat?.body.contains("\"heartbeat\"") == true)

        // Last-resort: sparse/unknown task payload still yields a non-empty body
        // (jsonString fallback) so the row is not blank.
        let sparseEvs = collect([sparseUnknown])
        let sparse = sparseEvs.compactMap { event -> AssistantItem? in
            if case .itemStarted(let item) = event { return item }
            return nil
        }.first
        XCTAssertEqual(sparse?.summary, "Claude task",
                       "unrecognised/missing task_type falls back to generic label")
        XCTAssertFalse(sparse?.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
                       "sparse task payload must keep a non-empty last-resort body")
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

    // REGRESSION (live run 2026-08-21, claude CLI 2.1.238, default CLI engine):
    // with --include-partial-messages every API message arrives TWICE — streamed
    // (message_start → content_block_start/delta) AND replayed as whole `assistant`
    // events carrying the SAME message.id, one event per completed block, emitted
    // BEFORE that block's content_block_stop. Thinking blocks had no dedup at all,
    // and text dedup keyed off content_block_stop (not yet arrived), so every
    // thought and answer rendered twice in the Agent App transcript. The replay of
    // a streamed message must not open a second item; content still renders once.
    func test_partialMessagesWholeAssistantReplay_doesNotDuplicateThinkingOrText() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"sess-partial"}"#,
            #"{"type":"stream_event","session_id":"sess-partial","event":{"type":"message_start","message":{"id":"msg_live1","role":"assistant","content":[]}}}"#,
            #"{"type":"stream_event","session_id":"sess-partial","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}"#,
            #"{"type":"stream_event","session_id":"sess-partial","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Pondering the fix."}}}"#,
            #"{"type":"assistant","session_id":"sess-partial","message":{"id":"msg_live1","role":"assistant","content":[{"type":"thinking","thinking":"Pondering the fix."}]}}"#,
            #"{"type":"stream_event","session_id":"sess-partial","event":{"type":"content_block_stop","index":0}}"#,
            #"{"type":"stream_event","session_id":"sess-partial","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","session_id":"sess-partial","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"All new locators verified."}}}"#,
            #"{"type":"assistant","session_id":"sess-partial","message":{"id":"msg_live1","role":"assistant","content":[{"type":"text","text":"All new locators verified."}]}}"#,
            #"{"type":"stream_event","session_id":"sess-partial","event":{"type":"content_block_stop","index":1}}"#,
            #"{"type":"result","subtype":"success","result":"All new locators verified.","session_id":"sess-partial"}"#
        ])

        let reasoningStarts = evs.filter {
            if case .itemStarted(let item) = $0 { return item.type == .reasoning }
            return false
        }
        let assistantMessageStarts = evs.filter {
            if case .itemStarted(let item) = $0 { return item.type == .assistantMessage }
            return false
        }
        XCTAssertEqual(reasoningStarts.count, 1,
                       "the whole-assistant replay of a streamed thinking block must not open a second reasoning item — every thought rendered twice")
        XCTAssertEqual(assistantMessageStarts.count, 1,
                       "the whole-assistant replay of a streamed text block must not open a second answer item — every answer rendered twice")
        let bodies = evs.compactMap { event -> String? in
            if case .itemDelta(_, let body, _, _) = event { return body }
            return nil
        }
        XCTAssertEqual(bodies.filter { $0 == "Pondering the fix." }.count, 1,
                       "streamed thinking must still render exactly once")
        XCTAssertEqual(bodies.filter { $0 == "All new locators verified." }.count, 1,
                       "streamed answer text must still render exactly once")
        XCTAssertEqual(finalMessage(evs), "All new locators verified.")
    }

    // REGRESSION (Agent App CPU ramp on long Claude runs): `claude --output-format
    // stream-json` emits WHOLE assistant messages and never sends message_start, so
    // the dedup accumulators (assembledAssistantBody + emitted bodies) reset only at
    // the final `result`. The old dedup re-ran the \s+ normalize regex over the
    // ENTIRE growing assembledAssistantBody and linearly over every prior emitted
    // body on each block => O(n^2) per run, ramping CPU as the run accumulated text.
    // Feed many DISTINCT blocks with NO `result` (state never resets) and assert the
    // dedup normalization work grows linearly, not quadratically, with block count.
    func test_cliWholeAssistantBlocksDedupCostStaysLinearAcrossALongRun() {
        let p = ClaudeParser()
        let blocks = 1_500
        var emittedAssistantDeltas = 0
        ClaudeParser.assistantTextNormalizationsForTesting = 0
        for i in 0..<blocks {
            // Distinct, non-duplicate text so nothing is suppressed — worst case:
            // every block is recorded and compared against all accumulated state.
            let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"block \#(i) unique payload number \#(i)"}]}}"#
            for event in p.parseLine(line) {
                if case .itemDelta(_, let body?, _, _) = event, body.hasPrefix("block ") {
                    emittedAssistantDeltas += 1
                }
            }
        }
        let normalizations = ClaudeParser.assistantTextNormalizationsForTesting

        // Per-block dedup cost must be O(1) in accumulated text. The old code did
        // ~O(prior blocks) normalize passes per block (~1.1M total here); the fix
        // does a small constant per block (~8 * blocks).
        XCTAssertLessThanOrEqual(normalizations, blocks * 16,
            "per-block dedup normalization must not scale with accumulated assistant text (was O(n^2)/run, the long-run CPU ramp)")
        // Intent: the bound must not be met by dropping real content — every distinct
        // block must still render exactly once.
        XCTAssertEqual(emittedAssistantDeltas, blocks,
            "distinct assistant blocks must each render once; dedup must suppress only true duplicates")
    }

    func test_controlRequestCanUseToolOpensApprovalWithEnvelopeRequestId() {
        // WHY: live CLI stream-json emits control_request / can_use_tool with the
        // correlation id on the envelope (request_id), while tool_use_id lives only
        // inside request. Approvals must open under the envelope id so the host
        // control_response can complete the round-trip.
        let line = #"{"type":"control_request","request_id":"req-ctrl-1","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"toolu-xyz","input":{"command":"ls -la"}}}"#
        let evs = ClaudeParser().parseLine(line)
        let opened = evs.compactMap { event -> AssistantPendingRequest? in
            if case .requestOpened(let request) = event { return request }
            return nil
        }.first
        XCTAssertEqual(opened?.id, "req-ctrl-1",
                       "control_request approvals must use envelope request_id, not tool_use_id")
        XCTAssertNotEqual(opened?.id, "toolu-xyz")
        XCTAssertEqual(opened?.title, "Bash")
        XCTAssertEqual(opened?.kind, .commandExecution)
        XCTAssertTrue(opened?.detail?.contains("ls -la") == true,
                      "can_use_tool input must surface in approval detail for review")
    }

    /// CLAUDE-CLI-004: AskUserQuestion on can_use_tool must open structured user
    /// input (not a permission card) keyed by envelope request_id so answers can
    /// complete via control_response updatedInput.
    func test_controlRequestAskUserQuestionOpensUserInputWithEnvelopeRequestId() {
        let line = #"{"type":"control_request","request_id":"req-ask-ctrl","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","tool_use_id":"toolu-ask","input":{"questions":[{"question":"Which auth?","header":"Auth","options":[{"label":"OAuth"},{"label":"API key"}],"multiSelect":false}]}}}"#
        let evs = ClaudeParser().parseLine(line)
        let openedPerms = evs.compactMap { event -> AssistantPendingRequest? in
            if case .requestOpened(let request) = event { return request }
            return nil
        }
        let userInputs = evs.compactMap { event -> AssistantUserInputRequest? in
            if case .userInputRequested(let request) = event { return request }
            return nil
        }
        XCTAssertTrue(openedPerms.isEmpty,
                      "AskUserQuestion must not open a generic Approve/Deny permission card")
        XCTAssertEqual(userInputs.count, 1)
        XCTAssertEqual(userInputs.first?.id, "req-ask-ctrl",
                       "control AskUserQuestion must key the card on envelope request_id")
        XCTAssertTrue(userInputs.first?.isStructured == true)
        XCTAssertEqual(userInputs.first?.questions.first?.prompt, "Which auth?")
        XCTAssertEqual(userInputs.first?.questions.first?.options.map(\.label), ["OAuth", "API key"])
    }

    /// CLAUDE-CLI-004: when tool_use already opened a card, control_request must
    /// resolve the tool_use id and prefer the envelope request_id (no dual pending).
    func test_controlRequestAskUserQuestionPrefersEnvelopeIdOverPriorToolUseCard() {
        let parser = ClaudeParser()
        var events = parser.parseLine(
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu-ask-dup","name":"AskUserQuestion","input":{"questions":[{"question":"Pick one","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}}]}}"#
        )
        events += parser.parseLine(
            #"{"type":"control_request","request_id":"req-ask-prefer","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","tool_use_id":"toolu-ask-dup","input":{"questions":[{"question":"Pick one","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}}}"#
        )
        let opened = events.compactMap { event -> String? in
            if case .userInputRequested(let request) = event { return request.id }
            return nil
        }
        let resolved = events.compactMap { event -> String? in
            if case .userInputResolved(let id, let answer) = event, answer == nil { return id }
            return nil
        }
        XCTAssertEqual(opened, ["toolu-ask-dup", "req-ask-prefer"])
        XCTAssertTrue(resolved.contains("toolu-ask-dup"),
                      "prior tool_use card must be closed when control_request arrives")
    }

    /// CLAUDE-CLI-005: control_request subtype elicitation opens user input.
    func test_controlRequestElicitationOpensUserInput() {
        let line = #"{"type":"control_request","request_id":"req-elicit-1","request":{"subtype":"elicitation","message":"Configure deployment","title":"Deploy","requested_schema":{"type":"object","properties":{"environment":{"type":"string","title":"Environment","enum":["staging","production"]},"token":{"type":"string","title":"Token","format":"password"}}}}}"#
        let evs = ClaudeParser().parseLine(line)
        let request = evs.compactMap { event -> AssistantUserInputRequest? in
            if case .userInputRequested(let request) = event { return request }
            return nil
        }.first
        XCTAssertEqual(request?.id, "req-elicit-1")
        XCTAssertEqual(request?.prompt, "Configure deployment")
        XCTAssertEqual(Set(request?.questions.map(\.id) ?? []), Set(["environment", "token"]))
        XCTAssertTrue(request?.isSecret == true)
        XCTAssertTrue(evs.allSatisfy {
            if case .requestOpened = $0 { return false }
            return true
        }, "elicitation must not open a tool permission card")
    }

    /// CLAUDE-CLI-013: request_user_dialog must not be dropped (CLI parks until response).
    func test_controlRequestUserDialogOpensUserInput() {
        let line = #"{"type":"control_request","request_id":"req-dialog-1","request":{"subtype":"request_user_dialog","dialog_kind":"computer_use_approval","payload":{"reason":"grant screen access"}}}"#
        let evs = ClaudeParser().parseLine(line)
        let request = evs.compactMap { event -> AssistantUserInputRequest? in
            if case .userInputRequested(let request) = event { return request }
            return nil
        }.first
        XCTAssertEqual(request?.id, "req-dialog-1")
        XCTAssertEqual(request?.prompt, "Claude requested dialog: computer_use_approval")
        XCTAssertTrue(evs.allSatisfy {
            if case .requestOpened = $0 { return false }
            return true
        }, "request_user_dialog must not open a tool permission card")
    }

    /// CLAUDE-CLI-008: control_cancel_request settles both approval and user-input pending.
    func test_controlCancelRequestResolvesPendingApprovalAndUserInput() {
        let line = #"{"type":"control_cancel_request","request_id":"req-cancel-me"}"#
        let evs = ClaudeParser().parseLine(line)
        var sawRequestCancelled = false
        var sawUserInputResolved: String?
        for event in evs {
            if case .requestResolved(let id, let state) = event {
                XCTAssertEqual(id, "req-cancel-me")
                XCTAssertEqual(state, .cancelled)
                sawRequestCancelled = true
            }
            if case .userInputResolved(let id, let answer) = event {
                XCTAssertEqual(id, "req-cancel-me")
                XCTAssertNil(answer)
                sawUserInputResolved = id
            }
        }
        XCTAssertTrue(sawRequestCancelled, "control_cancel_request must cancel open approval UI")
        XCTAssertEqual(sawUserInputResolved, "req-cancel-me",
                       "control_cancel_request must clear open user-input UI")
    }

    func test_sdkElicitationPreservesObjectPropertyNamesTypesAndSecretPresentation() throws {
        let parser = ClaudeParser()
        let events = parser.parseLine(#"{"type":"user_input_request","request_id":"elicitation-typed","prompt":"Configure deployment","requested_schema":{"type":"object","required":["environment","replicas","dryRun","token"],"properties":{"environment":{"type":"string","title":"Environment","enum":["staging","production"]},"replicas":{"type":"integer","title":"Replicas"},"dryRun":{"type":"boolean","title":"Dry run"},"token":{"type":"string","title":"Token","format":"password"}}}}"#)
        let request = try XCTUnwrap(events.compactMap { event -> AssistantUserInputRequest? in
            if case .userInputRequested(let request) = event { return request }
            return nil
        }.first)

        XCTAssertEqual(request.prompt, "Configure deployment")
        XCTAssertEqual(Set(request.questions.map(\.id)), Set(["environment", "replicas", "dryRun", "token"]),
                       "schema property names are the provider response keys and must survive parsing")
        XCTAssertEqual(request.questions.first(where: { $0.id == "environment" })?.options.map(\.label),
                       ["staging", "production"])
        XCTAssertEqual(request.questions.first(where: { $0.id == "dryRun" })?.options.map(\.label),
                       ["true", "false"])
        XCTAssertTrue(request.isSecret, "a password schema must render masked input")
    }

    // MARK: - CLAUDE-AMBIENT-TASK-RESULT

    /// WHY: after a previous Claude process dies mid-task, resume dumps orphaned
    /// `task_notification` rows and a success result with origin.kind =
    /// task-notification, num_turns=0, empty body — without processing the new
    /// user prompt. Completing a turn for that ambient result paints
    /// "without producing an assistant response" and drops the real answer.
    func test_ambientTaskNotificationResult_doesNotCompleteTurn() {
        let ambient = #"{"type":"result","subtype":"success","is_error":false,"result":"","num_turns":0,"origin":{"kind":"task-notification"},"session_id":"sess-ambient","usage":{"input_tokens":0,"output_tokens":0}}"#
        let real = #"{"type":"result","subtype":"success","is_error":false,"result":"REAL_ANSWER","session_id":"sess-ambient"}"#
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"sess-ambient"}"#,
            #"{"type":"system","subtype":"task_notification","task_id":"orphan-1","status":"stopped","summary":"Orphaned by a previous Claude Code process exit","session_id":"sess-ambient"}"#,
            ambient,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"REAL_ANSWER"}]}}"#,
            real
        ])
        let completed = evs.compactMap { event -> String? in
            if case .turnCompleted(_, let final) = event { return final }
            return nil
        }
        XCTAssertEqual(completed, ["REAL_ANSWER"],
                       "ambient task-notification results must not synthesize turnCompleted; only the real user-turn result owns lifecycle")
        XCTAssertFalse(completed.contains(where: { $0.isEmpty }),
                       "empty ambient results must never complete a turn")
    }

    func test_isAmbientTaskNotificationResult_helper() {
        let ambient: [String: Any] = [
            "type": "result",
            "subtype": "success",
            "is_error": false,
            "result": "",
            "num_turns": 0,
            "origin": ["kind": "task-notification"]
        ]
        XCTAssertTrue(
            ClaudeParser.isAmbientTaskNotificationResult(ambient, resultText: "", hasAssistantBody: false),
            "empty success with origin.task-notification and no assistant body is ambient"
        )
        XCTAssertFalse(
            ClaudeParser.isAmbientTaskNotificationResult(ambient, resultText: "", hasAssistantBody: true),
            "assistant body already accumulated means the result is not ambient-only"
        )
        XCTAssertFalse(
            ClaudeParser.isAmbientTaskNotificationResult(ambient, resultText: "hi", hasAssistantBody: false),
            "non-empty result text is a real answer even if origin is set"
        )
        var errored = ambient
        errored["is_error"] = true
        XCTAssertFalse(
            ClaudeParser.isAmbientTaskNotificationResult(errored, resultText: "", hasAssistantBody: false),
            "errors must still complete the turn"
        )
        let plain: [String: Any] = [
            "type": "result", "subtype": "success", "result": "", "is_error": false
        ]
        XCTAssertFalse(
            ClaudeParser.isAmbientTaskNotificationResult(plain, resultText: "", hasAssistantBody: false),
            "empty success without origin is not classified ambient (may be a real empty answer)"
        )
    }

    func test_systemInitMcpAndPluginErrorsEmitProviderRuntime() {
        // WHY: stderr is a Pipe, so CLI skip warnings never print. Hosts must
        // read mcp_server_errors / plugin_errors on system/init (CLAUDE-CLI-010).
        let line = #"{"type":"system","subtype":"init","session_id":"sess-err","mcp_server_errors":[{"name":"bot-peer","type":"config","message":"skipped by validation"}],"plugin_errors":[{"plugin":"broken-plugin","type":"load","message":"failed to load"}]}"#
        let evs = collect([line])
        let runtime = evs.compactMap { event -> ProviderRuntimeEvent? in
            if case .providerRuntime(let runtime) = event { return runtime }
            return nil
        }
        XCTAssertEqual(runtime.filter { $0.method == "claude.init.mcp_server_error" }.count, 1,
                       "each mcp_server_errors row must become a providerRuntime event")
        XCTAssertEqual(runtime.filter { $0.method == "claude.init.plugin_error" }.count, 1,
                       "each plugin_errors row must become a providerRuntime event")
        XCTAssertTrue(runtime.contains {
            $0.method == "claude.init.mcp_server_error" && $0.payloadJSON.contains("bot-peer")
        })
        XCTAssertTrue(runtime.contains {
            $0.method == "claude.init.plugin_error" && $0.payloadJSON.contains("broken-plugin")
        })
        XCTAssertFalse(evs.contains {
            if case .error(_, let recoverable) = $0 { return !recoverable }
            return false
        }, "init load skips must not fail the turn")
    }

    func test_systemInitWithoutLoadErrorArraysEmitsNoInitErrorRuntime() {
        let evs = collect([#"{"type":"system","subtype":"init","session_id":"sess-ok"}"#])
        XCTAssertFalse(evs.contains {
            if case .providerRuntime(let runtime) = $0 {
                return runtime.method == "claude.init.mcp_server_error"
                    || runtime.method == "claude.init.plugin_error"
            }
            return false
        }, "omitted mcp_server_errors/plugin_errors must stay silent")
    }

    func test_parentToolUseIdDoesNotJoinParentAssembledBody() {
        // WHY: --forward-subagent-text emits nested assistant text with
        // parent_tool_use_id. If that text joins assembledAssistantBody, an
        // empty result falls back to nested prose as the parent answer.
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"sess-sub"}"#,
            #"{"type":"assistant","parent_tool_use_id":"toolu_parent","message":{"id":"m-nested","role":"assistant","content":[{"type":"text","text":"nested-prose"}]}}"#,
            #"{"type":"assistant","message":{"id":"m-parent","role":"assistant","content":[{"type":"text","text":"parent-answer"}]}}"#,
            #"{"type":"result","subtype":"success","result":"","session_id":"sess-sub"}"#
        ])
        XCTAssertEqual(finalMessage(evs), "parent-answer",
                       "nested forwarded text must not become the parent final message")
        let nested = evs.compactMap { event -> AssistantItem? in
            if case .itemStarted(let item) = event, item.body.isEmpty || item.id.contains("toolu_parent") {
                return item
            }
            return nil
        }.first { item in
            item.summary?.contains("toolu_parent") == true
        }
        XCTAssertNotNil(nested, "nested text must surface parent_tool_use_id on the item")
        XCTAssertTrue(nested?.id.contains("toolu_parent") == true)
        XCTAssertTrue(evs.contains {
            if case .itemDelta(_, let body, _, _) = $0 { return body == "nested-prose" }
            return false
        }, "nested prose must still render as an item delta")
    }

    func test_streamEventParentToolUseIdDoesNotJoinParentAssembledBody() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"sess-se"}"#,
            #"{"type":"stream_event","parent_tool_use_id":"toolu_p","session_id":"sess-se","event":{"type":"message_start","message":{"id":"sm-nested"}}}"#,
            #"{"type":"stream_event","parent_tool_use_id":"toolu_p","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","id":"txt-nested"}}}"#,
            #"{"type":"stream_event","parent_tool_use_id":"toolu_p","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"nested-delta"}}}"#,
            #"{"type":"stream_event","parent_tool_use_id":"toolu_p","event":{"type":"content_block_stop","index":0}}"#,
            #"{"type":"assistant","message":{"id":"m-parent","role":"assistant","content":[{"type":"text","text":"parent-answer"}]}}"#,
            #"{"type":"result","subtype":"success","result":"","session_id":"sess-se"}"#
        ])
        XCTAssertEqual(finalMessage(evs), "parent-answer",
                       "stream_event nested deltas must not fill the parent assembled body")
        XCTAssertTrue(evs.contains {
            if case .itemStarted(let item) = $0 {
                return item.summary?.contains("toolu_p") == true || item.id.contains("toolu_p")
            }
            return false
        }, "stream_event unwrap must copy parent_tool_use_id onto nested blocks")
    }
    /// CLAUDE-AUTH-001: bare is_api_error_message without authentication_failed is not auth.
    func test_isApiErrorMessageAlone_isNotAuthenticationFailure() throws {
        let rateLimit = #"{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Rate limited"}]},"error":"rate_limit","is_api_error_message":true}"#
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rateLimit.utf8)) as? [String: Any])
        XCTAssertFalse(
            ClaudeParser.isAuthenticationFailedAssistantEnvelope(obj),
            "non-auth API error envelopes must not be classified as authentication failure"
        )
        let auth = #"{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Not logged in · Please run /login"}]},"error":"authentication_failed","is_api_error_message":true}"#
        let authObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(auth.utf8)) as? [String: Any])
        XCTAssertTrue(ClaudeParser.isAuthenticationFailedAssistantEnvelope(authObj))
    }

    /// CLAUDE-AUTH-002: live 2.1.270 always follows the AUTH-001 envelope with
    /// `result terminal_reason=api_error`. That must not become a second
    /// recoverable:false hard error or a second empty turn.
    func test_authFailedResultAfterAssistant_doesNotHardErrorOrStartSecondTurn() throws {
        let assistant = try loadPlanFixture("auth-failed-assistant-20260914.json")
        let result = try loadPlanFixture("auth-failed-result-20260914.json")
        let resultObj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        )
        XCTAssertTrue(ClaudeParser.isAuthenticationFailedResult(resultObj),
                      "live 2.1.270 auth result fixture must match AUTH-002 classifier")
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"4d139d35-6f36-4382-91af-070d46344e05"}"#,
            assistant,
            result
        ])
        let recoverable = evs.filter {
            if case .error(_, let recoverable) = $0 { return recoverable }
            return false
        }
        XCTAssertEqual(recoverable.count, 1,
                       "AUTH-001 already emitted the recoverable login error; the result must not add another")
        XCTAssertFalse(evs.contains {
            if case .error(_, let recoverable) = $0 { return !recoverable }
            return false
        }, "auth result after AUTH-001 must not emit recoverable:false")
        XCTAssertEqual(evs.filter { if case .turnStarted = $0 { return true }; return false }.count, 1,
                       "result must not ensureTurn a second empty turn")
        XCTAssertEqual(evs.filter { if case .turnCompleted = $0 { return true }; return false }.count, 1,
                       "the AUTH-001 turn remains the only completed turn")
        XCTAssertFalse(evs.contains {
            if case .itemStarted(let item) = $0 { return item.type == .assistantMessage }
            return false
        }, "synthetic auth text must still not render as an assistant reply")
    }

    /// CLAUDE-AUTH-002: the live unauth JSONL (hook, init, status, assistant, result)
    /// must complete as a single recoverable auth failure.
    func test_liveUnauthStreamJSONL_doesNotHardErrorOrOpenSecondTurn() throws {
        let jsonl = try loadPlanFixture("live-stream-json-unauth-20260914.jsonl")
        let lines = jsonl.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 6, "live capture is hook/init/status/assistant/result")
        let evs = collect(lines)
        XCTAssertFalse(evs.contains {
            if case .error(_, let recoverable) = $0 { return !recoverable }
            return false
        }, "live 2.1.270 unauth stream must not emit a hard error after AUTH-001")
        XCTAssertEqual(evs.filter { if case .turnStarted = $0 { return true }; return false }.count, 1,
                       "live result must not open a second turn")
        XCTAssertEqual(evs.filter {
            if case .error(let message, let recoverable) = $0 {
                return recoverable && message.contains("Not logged in")
            }
            return false
        }.count, 1, "exactly one recoverable login error")
        XCTAssertFalse(evs.contains {
            if case .providerRuntime(let runtime) = $0 {
                return runtime.method == "claude.result.permission_denial"
            }
            return false
        }, "empty permission_denials on the live auth result must stay silent")
    }

    /// CLAUDE-AUTH-002: result-only (no AUTH-001 envelope) with live login
    /// semantics is still a recoverable auth failure, not a provider crash.
    func test_authFailedResultAlone_isRecoverableNotHardError() throws {
        let result = try loadPlanFixture("auth-failed-result-20260914.json")
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"4d139d35-6f36-4382-91af-070d46344e05"}"#,
            result
        ])
        XCTAssertTrue(evs.contains {
            if case .error(let message, let recoverable) = $0 {
                return recoverable && message.contains("Not logged in")
            }
            return false
        }, "result-only login failure must be recoverable so login recovery can run")
        XCTAssertFalse(evs.contains {
            if case .error(_, let recoverable) = $0 { return !recoverable }
            return false
        }, "login result must not be a hard error")
        XCTAssertEqual(evs.filter { if case .turnStarted = $0 { return true }; return false }.count, 1)
        XCTAssertTrue(evs.contains {
            if case .turnCompleted = $0 { return true }
            return false
        }, "result-only auth failure still completes the turn")
    }

    func test_apiErrorWithoutLoginSemantics_isStillHardError() throws {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"api_error","result":"HTTP 500 overloaded"}"#.utf8)) as? [String: Any])
        XCTAssertFalse(
            ClaudeParser.isAuthenticationFailedResult(obj),
            "generic api_error must not be classified as login failure"
        )
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"s-api"}"#,
            #"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"api_error","result":"HTTP 500 overloaded"}"#
        ])
        XCTAssertTrue(evs.contains {
            if case .error(let message, let recoverable) = $0 {
                return !recoverable && message.contains("HTTP 500")
            }
            return false
        }, "non-login api_error must stay a loud hard error")
    }

    /// CLAUDE-PERM-DENIED-001: system/permission_denied is a denial card, not a
    /// dropped unknown subtype.
    func test_systemPermissionDenied_emitsRuntimeAndDenialItem() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"sess-deny"}"#,
            #"{"type":"system","subtype":"permission_denied","tool_name":"Read","tool_use_id":"toolu_deny","reason":"path-scoped deny rule"}"#
        ])
        XCTAssertTrue(evs.contains {
            if case .providerRuntime(let runtime) = $0 {
                return runtime.method == "claude.permission_denied"
                    && runtime.payloadJSON.contains("Read")
            }
            return false
        }, "system/permission_denied must surface as providerRuntime")
        XCTAssertTrue(evs.contains {
            if case .itemStarted(let item) = $0 {
                return item.type == .error && item.summary?.contains("Read") == true
            }
            return false
        }, "auto-denied tools must open a denial card")
        XCTAssertFalse(evs.contains {
            if case .error(_, let recoverable) = $0 { return !recoverable }
            return false
        }, "a permission denial is not a hard provider crash")
    }

    /// CLAUDE-PERM-DENIED-001: result.permission_denials is the authoritative
    /// record (complete for path-scoped Read/Edit/Write as of 2.1.269).
    func test_resultPermissionDenials_emitRuntimeEvents() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"sess-deny-r"}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"ok","permission_denials":[{"tool_name":"Edit","tool_use_id":"toolu_edit","reason":"path-scoped deny"}]}"#
        ])
        XCTAssertTrue(evs.contains {
            if case .providerRuntime(let runtime) = $0 {
                return runtime.method == "claude.result.permission_denial"
                    && runtime.payloadJSON.contains("Edit")
            }
            return false
        }, "non-empty permission_denials must surface")
        XCTAssertEqual(finalMessage(evs), "ok")
    }

    func test_emptyPermissionDenials_areSilent() {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"sess-deny-empty"}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"ok","permission_denials":[]}"#
        ])
        XCTAssertFalse(evs.contains {
            if case .providerRuntime(let runtime) = $0 {
                return runtime.method == "claude.result.permission_denial"
                    || runtime.method == "claude.permission_denied"
            }
            return false
        }, "empty permission_denials must not mint denial events")
    }

    /// CLAUDE-INIT-MCP-001: runtime connect failures are `mcp_servers[].status=failed`,
    /// not `mcp_server_errors` (those are config-validation skips).
    func test_systemInitMcpServersFailedStatus_emitsProviderRuntime() throws {
        let evs = collect([
            #"{"type":"system","subtype":"init","session_id":"sess-mcp","mcp_servers":[{"name":"computer-use-mcp","status":"failed"},{"name":"slack","status":"failed"},{"name":"railway","status":"connected"},{"name":"linear","status":"pending"}]}"#
        ])
        let runtime = evs.compactMap { event -> ProviderRuntimeEvent? in
            if case .providerRuntime(let runtime) = event { return runtime }
            return nil
        }.filter { $0.method == "claude.init.mcp_server_error" }
        XCTAssertEqual(runtime.count, 2, "only status=failed rows emit")
        XCTAssertTrue(runtime.contains { $0.payloadJSON.contains("computer-use-mcp") })
        XCTAssertTrue(runtime.contains { $0.payloadJSON.contains("slack") })
        XCTAssertFalse(runtime.contains { $0.payloadJSON.contains("railway") },
                       "connected MCP servers must stay silent")
        XCTAssertFalse(evs.contains {
            if case .error(_, let recoverable) = $0 { return !recoverable }
            return false
        }, "MCP connect failures must not fail the turn")
    }

    func test_liveSystemInitPendingMcpServers_doNotEmitFailedRuntime() throws {
        let initJSON = try loadPlanFixture("system-init-20260914.json")
        let evs = collect([initJSON])
        XCTAssertFalse(evs.contains {
            if case .providerRuntime(let runtime) = $0 {
                return runtime.method == "claude.init.mcp_server_error"
            }
            return false
        }, "live init fixture is pending/connected only — no failed runtime events")
    }

    private func loadPlanFixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/AgentRuntimeTests/Fixtures/claude-auth-20260914/\(name)")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
