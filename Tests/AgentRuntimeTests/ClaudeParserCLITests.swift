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
                       "Claude SDK bridge result.modelUsage must feed Token Saver and context pressure; otherwise /distill responses complete but Saved stays 0")
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
        }, "Claude rate_limit_info must feed Token Saver weekly account usage instead of leaving the rings at fake 100%")
        XCTAssertFalse(evs.contains {
            if case .error(let message, _) = $0 {
                return message.contains("requests")
            }
            return false
        }, "Claude rate_limit_event must not render as an agent error when the turn later succeeds")
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
}
