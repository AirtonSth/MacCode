import XCTest
@testable import CoreModel

final class AssistantTimelineTests: XCTestCase {
    func test_attachmentResolverKeepsStructuredMetadataAndClassifiesImages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-code-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("screen.png")
        let text = root.appendingPathComponent("notes.txt")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        try "notes".write(to: text, atomically: true, encoding: .utf8)

        let attachments = try AgentAttachmentResolver.resolve(paths: [image.path, text.path, image.path])

        XCTAssertEqual(attachments.map(\.path), [image.path, text.path],
                       "attachment resolution must dedupe by canonical file path")
        XCTAssertEqual(attachments.map(\.kind), [.image, .file],
                       "image attachments need a provider-native channel while other files stay structured metadata")
        XCTAssertEqual(attachments.first?.mimeType, "image/png")
    }

    func test_attachmentResolverFailsForMissingOrDirectoryPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-code-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try AgentAttachmentResolver.resolve(paths: [root.path]),
                             "directory attachments must fail loud before provider spawn")
        XCTAssertThrowsError(try AgentAttachmentResolver.resolve(paths: [root.appendingPathComponent("missing.png").path]),
                             "missing attachment paths must fail loud before provider spawn")
    }

    func test_proposedPlanCollapsedPreviewKeepsFirstTenLines() {
        let markdown = (1...12).map { "\($0). Step \($0)" }.joined(separator: "\n")
        let plan = AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: markdown)

        XCTAssertEqual(plan.collapsedPreview.split(separator: "\n", omittingEmptySubsequences: false).count, 10,
                       "collapsed plan cards must keep the first ten lines for scanability")
        XCTAssertTrue(plan.collapsedPreview.contains("10. Step 10"))
        XCTAssertFalse(plan.collapsedPreview.contains("11. Step 11"),
                       "collapsed previews must hide overflow until the user expands the plan")
        XCTAssertEqual(AssistantProposedPlan.collapsedPreview(for: "1\n2", maxLines: 10), "1\n2")
    }

    func test_proposedPlanExportTitleAndFileNameAreStable() {
        let plan = AssistantProposedPlan(
            id: "plan-1",
            turnId: "turn-1",
            markdown: "# Fix Agent Freeze!\n\n1. Inspect sessions\n2. Patch lifecycle"
        )

        XCTAssertEqual(plan.exportTitle, "Fix Agent Freeze!",
                       "exported plan cards need a human-readable title, not only raw markdown")
        XCTAssertEqual(plan.exportFileName, "fix-agent-freeze.md",
                       "saving a proposed plan must produce a stable markdown filename safe for desktop/mobile export")
    }

    func test_timeline_appliesItemLifecycle() {
        var s = AssistantTimelineState()
        s.apply(.threadStarted(threadId: "t", providerThreadId: "pt"))
        s.apply(.turnStarted(turnId: "turn1"))
        s.apply(.itemStarted(item: AssistantItem(id: "i1", turnId: "turn1", type: .assistantMessage, startedAtMs: 0)))
        s.apply(.itemDelta(itemId: "i1", bodyAppend: "Hel", outputAppend: nil, summary: nil))
        s.apply(.itemDelta(itemId: "i1", bodyAppend: "lo", outputAppend: nil, summary: nil))
        s.apply(.itemCompleted(itemId: "i1", finalState: .completed))
        s.apply(.turnCompleted(turnId: "turn1", finalMessage: "Hello"))
        XCTAssertEqual(s.threadId, "t")
        XCTAssertEqual(s.providerThreadId, "pt")
        XCTAssertEqual(s.turns.count, 1)
        XCTAssertEqual(s.turns[0].items.count, 1)
        XCTAssertEqual(s.turns[0].items[0].body, "Hello")
        XCTAssertEqual(s.turns[0].items[0].state, .completed)
        XCTAssertTrue(s.turns[0].finished)
        XCTAssertEqual(s.turns[0].finalAssistantMessage, "Hello")
    }

    func test_timelineDuplicateItemStartDoesNotEraseStreamedAssistantText() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "turn1"))
        s.apply(.itemStarted(item: AssistantItem(id: "answer", turnId: "turn1", type: .assistantMessage, startedAtMs: 1)))
        s.apply(.itemDelta(itemId: "answer", bodyAppend: "1", outputAppend: nil, summary: nil))
        s.apply(.itemStarted(item: AssistantItem(id: "answer", turnId: "turn1", type: .assistantMessage, startedAtMs: 2)))
        s.apply(.itemDelta(itemId: "answer", bodyAppend: " 2 3", outputAppend: nil, summary: nil))

        XCTAssertEqual(s.turns[0].items.count, 1,
                       "duplicate provider item-start events must update the existing item instead of creating empty answer rows")
        XCTAssertEqual(s.turns[0].items[0].body, "1 2 3",
                       "a repeated item-start must not erase streamed assistant text before the final answer is rendered")
    }

    func test_timeline_handlesError() {
        var s = AssistantTimelineState()
        s.apply(.error(message: "boom", recoverable: false))
        XCTAssertEqual(s.error, "boom")
    }

    func test_latestAssistantMessage_skipsEmptyTrailingTurns() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "real"))
        s.apply(.itemStarted(item: AssistantItem(id: "a1", turnId: "real", type: .assistantMessage, startedAtMs: 1)))
        s.apply(.itemDelta(itemId: "a1", bodyAppend: "final answer", outputAppend: nil, summary: nil))
        s.apply(.turnCompleted(turnId: "real", finalMessage: "final answer"))
        s.apply(.itemStarted(item: AssistantItem(id: "empty", turnId: "", type: .assistantMessage, startedAtMs: 2)))
        XCTAssertEqual(s.latestAssistantMessage, "final answer",
                       "persistence must use the last real assistant reply, not a trailing empty turn")
    }

    func test_assistantTextsIncludesStreamBodyAndFinalsForDuplicateSuppression() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "streamed"))
        s.apply(.itemStarted(item: AssistantItem(id: "a1", turnId: "streamed", type: .assistantMessage, startedAtMs: 1)))
        s.apply(.itemDelta(itemId: "a1", bodyAppend: "stream body", outputAppend: nil, summary: nil))
        s.apply(.turnCompleted(turnId: "streamed", finalMessage: "final body"))

        XCTAssertEqual(s.assistantTexts, ["stream body", "final body"],
                       "when replayed timeline already renders an answer, persisted assistant bubbles must be suppressible without hiding tool/history items")
    }

    func test_liveTimelineCapsStreamingTextSoLongThreadsStayResponsive() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "long"))
        s.apply(.itemStarted(item: AssistantItem(id: "tool", turnId: "long", type: .tool, startedAtMs: 1)))

        for i in 0..<400 {
            s.apply(.itemDelta(itemId: "tool",
                               bodyAppend: "command \(i)\n",
                               outputAppend: String(repeating: "x", count: 1_000),
                               summary: nil))
        }

        let item = s.turns[0].items[0]
        XCTAssertLessThanOrEqual(item.body.count, AssistantTimelineState.liveTextLimit,
                                 "live tool labels must be bounded so one long thread cannot freeze the transcript")
        XCTAssertLessThanOrEqual(item.output?.count ?? 0, AssistantTimelineState.liveOutputLimit,
                                 "live tool output must be bounded because expanded output is rendered on the main UI")

        s.apply(.turnCompleted(turnId: "long", finalMessage: String(repeating: "z", count: 200_000)))
        XCTAssertLessThanOrEqual(s.turns[0].finalAssistantMessage?.count ?? 0, AssistantTimelineState.liveTextLimit,
                                 "terminal live text must also stay bounded before it is moved into persisted history")
    }

    func test_timelineRetainsFullTurnHistoryForLongSessions() {
        var s = AssistantTimelineState()

        // A long-but-realistic session (140 turns) must be retained IN FULL — reopening a
        // thread used to truncate to the last 80 turns ("thread cortado"); the cap is now a
        // pathological-OOM ceiling (>= the ~5000 DB event-prune cap), not a display window.
        for i in 0..<140 {
            let turn = "turn-\(i)"
            let item = "item-\(i)"
            s.apply(.turnStarted(turnId: turn))
            s.apply(.itemStarted(item: AssistantItem(id: item, turnId: turn, type: .assistantMessage, startedAtMs: Int64(i))))
            s.apply(.itemDelta(itemId: item, bodyAppend: "answer \(i)", outputAppend: nil, summary: nil))
            s.apply(.turnCompleted(turnId: turn, finalMessage: "answer \(i)"))
        }

        XCTAssertEqual(s.turns.count, 140,
                       "every turn of a long session must be retained — no 80-turn truncation of the reopened thread")
        XCTAssertEqual(s.turns.first?.turnId, "turn-0",
                       "the OLDEST turn must still be present (the thread is shown 100%, not from the middle)")
        XCTAssertEqual(s.latestAssistantMessage, "answer 139",
                       "the newest agent output stays visible")
        XCTAssertLessThanOrEqual(s.turns.count, AssistantTimelineState.liveTurnLimit,
                                 "the memory-ceiling backstop still bounds turns")
    }

    func test_timelineTracksApprovalsUserInputPlansAndTokenUsage() {
        var s = AssistantTimelineState()
        s.apply(.requestOpened(AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run tests",
            detail: "swift test",
            createdAtMs: 1
        )))
        s.apply(.userInputRequested(AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Pick mode",
            options: ["Plan", "Run"],
            createdAtMs: 2
        )))
        s.apply(.proposedPlan(AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: "1. Inspect\n2. Patch")))
        s.apply(.tokenUsage(AssistantTokenUsage(inputTokens: 10, outputTokens: 5, totalTokens: 15, contextWindow: 100, compactsAutomatically: true)))
        s.apply(.contextCompaction(summary: "older messages compacted"))
        s.apply(.requestResolved(requestId: "approval-1", state: .approved))
        s.apply(.userInputResolved(requestId: "question-1", answer: "Run"))

        XCTAssertEqual(s.pendingRequests.first?.state, .approved,
                       "approval state must persist in the timeline so stale requests can be diagnosed after restart")
        XCTAssertEqual(s.pendingUserInputs.first?.answer, "Run",
                       "user-input answers must remain associated with their provider request id")
        XCTAssertEqual(s.proposedPlans.first?.markdown, "1. Inspect\n2. Patch",
                       "provider plan artifacts must be structured, not only assistant text")
        XCTAssertEqual(s.tokenUsage?.totalTokens, 15,
                       "token usage must be tracked for long-running context health")
        XCTAssertEqual(s.tokenUsage?.compactsAutomatically, true,
                       "automatic compaction capability must stay attached to token usage telemetry")
        XCTAssertEqual(s.contextCompactionSummary, "older messages compacted")
    }

    func test_liveTimelineCapsRequestAndPlanDiagnosticsForLongAgentSessions() {
        var s = AssistantTimelineState()

        for i in 0..<(AssistantTimelineState.pendingRequestLimit + 40) {
            s.apply(.requestOpened(AssistantPendingRequest(
                id: "approval-\(i)",
                turnId: "turn-\(i)",
                kind: .commandExecution,
                title: "Run \(i)",
                detail: String(repeating: "x", count: 1_000),
                createdAtMs: Int64(i)
            )))
            s.apply(.requestResolved(requestId: "approval-\(i)", state: .approved))
            s.apply(.userInputRequested(AssistantUserInputRequest(
                id: "question-\(i)",
                turnId: "turn-\(i)",
                prompt: "Question \(i)",
                createdAtMs: Int64(i)
            )))
            s.apply(.userInputResolved(requestId: "question-\(i)", answer: "Answer \(i)"))
        }
        for i in 0..<(AssistantTimelineState.proposedPlanLimit + 20) {
            s.apply(.proposedPlan(AssistantProposedPlan(
                id: "plan-\(i)",
                turnId: "turn-\(i)",
                markdown: "Plan \(i)"
            )))
        }

        XCTAssertLessThanOrEqual(s.pendingRequests.count, AssistantTimelineState.pendingRequestLimit,
                                 "resolved approval diagnostics must be bounded so a 24h Agent App run cannot retain every callback card")
        XCTAssertFalse(s.pendingRequests.contains { $0.id == "approval-0" },
                       "bounded approval diagnostics must evict the oldest resolved callbacks first")
        XCTAssertEqual(s.pendingRequests.last?.id, "approval-\(AssistantTimelineState.pendingRequestLimit + 39)",
                       "bounded approval diagnostics must keep the newest callback visible")
        XCTAssertLessThanOrEqual(s.pendingUserInputs.count, AssistantTimelineState.pendingRequestLimit,
                                 "resolved user-input diagnostics must be bounded for long provider sessions")
        XCTAssertFalse(s.pendingUserInputs.contains { $0.id == "question-0" },
                       "bounded question diagnostics must evict the oldest resolved callbacks first")
        XCTAssertEqual(s.pendingUserInputs.last?.id, "question-\(AssistantTimelineState.pendingRequestLimit + 39)")
        XCTAssertLessThanOrEqual(s.proposedPlans.count, AssistantTimelineState.proposedPlanLimit,
                                 "proposed plans must not accumulate forever in the live Agent App timeline")
        XCTAssertFalse(s.proposedPlans.contains { $0.id == "plan-0" },
                       "bounded plan diagnostics must evict oldest plan artifacts first")
        XCTAssertEqual(s.proposedPlans.last?.id, "plan-\(AssistantTimelineState.proposedPlanLimit + 19)")
    }

    func test_activePlanTracksStepStateSeparatelyFromProposedPlan() {
        var s = AssistantTimelineState()
        s.apply(.proposedPlan(AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: "1. Inspect\n2. Patch")))
        s.apply(.activePlanUpdated(AssistantActivePlan(
            explanation: "Executing plan",
            steps: [
                AssistantPlanStep(id: "step-1", title: "Inspect", status: .completed),
                AssistantPlanStep(id: "step-2", title: "Patch", status: .inProgress),
                AssistantPlanStep(id: "step-3", title: "Verify", status: .pending)
            ],
            updatedAtMs: 42
        )))

        XCTAssertEqual(s.proposedPlans.first?.id, "plan-1",
                       "proposed plans must remain durable artifacts for implementation, not be overwritten by transient step progress")
        XCTAssertEqual(s.activePlan?.steps.map(\.status), [.completed, .inProgress, .pending],
                       "active plan updates must preserve step state so long-running /goal work exposes current progress")
    }

    func test_richItemTypesRemainDistinct() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "turn"))
        for type in [AssistantItemType.commandExecution, .fileChange, .mcpToolCall, .dynamicToolCall, .collabToolCall, .webSearch, .imageView, .review, .contextCompaction, .error] {
            s.apply(.itemStarted(item: AssistantItem(id: type.rawValue, turnId: "turn", type: type, startedAtMs: 1)))
        }

        XCTAssertEqual(s.turns[0].items.map(\.type), [.commandExecution, .fileChange, .mcpToolCall, .dynamicToolCall, .collabToolCall, .webSearch, .imageView, .review, .contextCompaction, .error],
                       "provider runtime items must not collapse into one generic tool bucket because UI/mobile need distinct rendering and replay")
    }

    func test_providerRuntimeEventsPreserveRawProviderRefsAndPayload() {
        let line = #"{"type":"item.completed","turn_id":"turn-native","item":{"id":"item-native","type":"agent_message","text":"hi"}}"#
        guard let runtime = ProviderRuntimeEvent.fromJSONLine(line, provider: .codex, source: "codex.exec.json", receivedAtMs: 7) else {
            return XCTFail("raw provider JSON lines must become canonical runtime events")
        }

        var s = AssistantTimelineState()
        s.apply(.providerRuntime(runtime))

        XCTAssertEqual(s.providerRuntimeEvents.first?.method, "item.completed")
        XCTAssertEqual(s.providerRuntimeEvents.first?.providerTurnId, "turn-native",
                       "native provider turn id must survive normalized conversion for read/rollback/debug parity")
        XCTAssertEqual(s.providerRuntimeEvents.first?.providerItemId, "item-native",
                       "native provider item id must survive normalized conversion for tool/content traceability")
        XCTAssertTrue(s.providerRuntimeEvents.first?.payloadJSON.contains(#""agent_message""#) == true,
                      "canonical runtime events must keep the raw payload so unknown Codex/Claude fields are not lost")
    }

    func test_workActivitiesSummarizeToolRequestAndRuntimeProgress() {
        let runtime = ProviderRuntimeEvent(
            id: "runtime-1",
            provider: .codex,
            source: "codex.exec.json",
            method: "item.started",
            providerTurnId: "turn-native",
            providerItemId: "item-native",
            payloadJSON: #"{"type":"item.started"}"#,
            receivedAtMs: 3
        )
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "turn-1"))
        s.apply(.itemStarted(item: AssistantItem(
            id: "tool-1",
            turnId: "turn-1",
            type: .commandExecution,
            summary: "swift test",
            startedAtMs: 1
        )))
        s.apply(.requestOpened(AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run tests",
            detail: "swift test",
            createdAtMs: 2
        )))
        s.apply(.providerRuntime(runtime))
        s.apply(.itemCompleted(itemId: "tool-1", finalState: .completed))

        XCTAssertTrue(s.workActivities.contains { $0.id == "item:tool-1" && $0.state == "completed" },
                      "work log must expose tool progress without forcing users to inspect raw provider output")
        XCTAssertTrue(s.workActivities.contains { $0.id == "request:approval-1" && $0.title.contains("Approval requested") },
                      "work log must include approval/request progress because pending cards can move or become stale")
        XCTAssertTrue(s.workActivities.contains { $0.id == "runtime:runtime-1" && $0.title.contains("item.started") },
                      "work log must include raw provider runtime events so unknown Codex/Claude progress remains visible")
    }

    func test_workActivitiesTrackProviderPercentProgress() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "turn-1"))
        s.apply(.itemStarted(item: AssistantItem(
            id: "tool-1",
            turnId: "turn-1",
            type: .commandExecution,
            summary: "swift test",
            startedAtMs: 1
        )))
        s.apply(.itemProgress(itemId: "tool-1", progress: 42))

        XCTAssertEqual(s.turns.first?.items.first?.progress, 0.42,
                       "provider progress may arrive as 0-1 or 0-100 and must normalize before rendering")
        XCTAssertTrue(s.workActivities.last?.title.contains("42% swift test") == true,
                      "work log must expose current percent progress for long-running provider tools")
    }
}
