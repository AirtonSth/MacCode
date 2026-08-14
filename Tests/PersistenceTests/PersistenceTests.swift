import XCTest
@testable import Persistence
import CoreModel

final class PersistenceTests: XCTestCase {
    func test_bootstrap_freshStart_isEmpty_andTouchesOnlyOwnedPaths() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let bs = Bootstrap(channel: .debug, appSupportOverride: tmp)
        let (rep, db) = try bs.run()
        XCTAssertTrue(rep.firstRun)
        XCTAssertEqual(rep.schemaVersion, Schema.currentVersion)
        let schemaStmt = try db.prepare("SELECT MAX(version) FROM schema_meta;")
        XCTAssertTrue(try schemaStmt.step())
        XCTAssertEqual(Int(schemaStmt.columnInt64(0)), Schema.currentVersion,
                       "bootstrap must report the same schema version that migration actually records, otherwise restart diagnostics can lie about persistence shape")
        // touchedPaths only inside tmp
        for path in rep.touchedPaths {
            XCTAssertTrue(path.hasPrefix(tmp), "touched path \(path) escapes \(tmp)")
        }
        // tables empty
        let projects = try ProjectRepository(db: db).list()
        XCTAssertTrue(projects.isEmpty)
        let threads = try AgentThreadRepository(db: db).list()
        XCTAssertTrue(threads.isEmpty)
    }

    func test_bootstrapDefaultsRemoteAccessOffUntilExplicitOptIn() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()

        let value = try SettingsRepository(db: db).get("remote_access_enabled")
        XCTAssertEqual(value, "0", "LAN pairing must require explicit opt-in before the Mac advertises itself.")
    }

    func test_schemaIsIdempotent() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let bs = Bootstrap(channel: .debug, appSupportOverride: tmp)
        _ = try bs.run()
        // re-open and migrate again
        let (rep2, _) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        XCTAssertFalse(rep2.firstRun)
    }

    func test_threadAndMessage_roundtrip() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let tr = AgentThreadRepository(db: db)
        var t = AgentThread(workspaceId: WorkspaceID(), title: "demo", provider: .codex, model: "gpt-5")
        t.providerInstanceId = "codex-personal"
        t.executionMode = .worktree
        t.baseBranch = "main"
        t.worktreePath = "/tmp/rc-agent-worktree"
        t.serviceTier = .fast
        t.modelSelection = AgentModelSelection(provider: .codex,
                                               modelId: "",
                                               customModelId: "gpt-5.5-experimental",
                                               reasoningEffort: .xhigh,
                                               serviceTier: .fast)
        try tr.upsert(t)
        let list = try tr.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].title, "demo")
        XCTAssertEqual(list[0].providerInstanceId, "codex-personal",
                       "provider instance id must persist on threads so future personal/work providers cannot mix continuation state")
        XCTAssertEqual(list[0].executionMode, .worktree,
                       "agent thread execution mode must persist so first-send worktree routing survives app restart")
        XCTAssertEqual(list[0].baseBranch, "main")
        XCTAssertEqual(list[0].worktreePath, "/tmp/rc-agent-worktree")
        XCTAssertEqual(list[0].serviceTier, .fast,
                       "agent service tier must persist so Codex fast mode survives app restart")
        XCTAssertEqual(list[0].modelSelection.modelId, "")
        XCTAssertEqual(list[0].modelSelection.customModelId, "gpt-5.5-experimental")
        XCTAssertEqual(list[0].modelSelection.effectiveModel, "gpt-5.5-experimental",
                       "custom model selection must persist as structured data so restart does not flatten it into a loose model string")
        XCTAssertEqual(list[0].modelSelection.reasoningEffort, .xhigh)
        XCTAssertEqual(list[0].modelSelection.serviceTier, .fast)

        let mr = AgentMessageRepository(db: db)
        try mr.append(AgentMessage(threadId: t.id, role: .user, content: "hi"))
        try mr.append(AgentMessage(threadId: t.id, role: .assistant, content: "hello"))
        let msgs = try mr.list(threadId: t.id)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].role, .user)

        let runs = AgentRunRepository(db: db)
        let run = AgentRun(threadId: t.id, provider: .codex, providerInstanceId: "codex-personal", model: "gpt-5", status: .running)
        try runs.upsert(run)
        XCTAssertEqual(try runs.get(id: run.id)?.providerInstanceId, "codex-personal",
                       "provider instance id must persist on runs so recovery/debugging can identify the exact provider identity used")
    }

    func test_agentMessageRepositoryPagesOlderHistoryWithStableCursor() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let tr = AgentThreadRepository(db: db)
        let t = AgentThread(title: "long history", provider: .codex, model: "gpt-5")
        try tr.upsert(t)
        let mr = AgentMessageRepository(db: db)
        let base = Date(timeIntervalSinceReferenceDate: 2_000)
        for index in 0..<35 {
            let id = AgentMessageID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!)
            try mr.append(AgentMessage(
                id: id,
                threadId: t.id,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "message-\(index)",
                createdAt: base.addingTimeInterval(TimeInterval(index / 2))
            ))
        }

        let first = try mr.listPage(threadId: t.id, limit: 10, before: nil)
        let older = try mr.listPage(threadId: t.id, limit: 30, before: first.nextBefore)

        XCTAssertEqual(first.messages.map(\.content), (25..<35).map { "message-\($0)" },
                       "initial history page must return the newest 10 in display order")
        XCTAssertTrue(first.hasMoreOlder)
        XCTAssertEqual(older.messages.map(\.content), (0..<25).map { "message-\($0)" },
                       "older page must use created_at plus id as the cursor so duplicate timestamps do not skip rows")
        XCTAssertFalse(older.hasMoreOlder)

        let newer = try mr.listPage(threadId: t.id, limit: 10, before: nil, after: older.nextAfter)
        XCTAssertEqual(newer.messages.map(\.content), (25..<35).map { "message-\($0)" },
                       "newer page must use created_at plus id as the cursor so viewport-only history can reload rows below the current scroll position")
        XCTAssertFalse(newer.hasMoreNewer)
    }

    func test_snapshot_roundtrip() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: SurfaceDescriptor(type: .agentApp, title: "a")))
        let snap = SessionSnapshot(layout: s)
        let repo = SessionSnapshotRepository(db: db)
        try repo.save(snap)
        let loaded = try XCTUnwrap(try repo.latest())
        XCTAssertEqual(loaded.layout.window.workspaces.count, 1)
    }

    func test_runReconcile_marksRunningAsInterrupted() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let runs = AgentRunRepository(db: db)
        let r = AgentRun(threadId: AgentThreadID(), provider: .codex, model: "m", status: .running)
        // need parent thread row to satisfy FK
        let tr = AgentThreadRepository(db: db)
        let t = AgentThread(id: r.threadId, title: "t", provider: .codex, model: "m")
        try tr.upsert(t)
        try runs.upsert(r)
        let count = try runs.reconcileRunningOnLaunch()
        XCTAssertEqual(count, 1)
    }

    func test_providerSessionRuntime_roundtripsRecoveryStateAcrossBootstrapRestart() throws {
        let tmp = NSTemporaryDirectory() + "RC2ProviderSession-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let threadId: AgentThreadID
        do {
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            let threads = AgentThreadRepository(db: db)
            let thread = AgentThread(title: "resume", provider: .codex, model: "gpt-5.5")
            threadId = thread.id
            try threads.upsert(thread)
            try ProviderSessionRuntimeRepository(db: db).upsert(ProviderSessionRuntime(
                threadId: thread.id,
                provider: .codex,
                providerInstanceId: "default",
                adapterKey: "CodexSessionRuntime",
                binaryIdentity: "codex:/opt/homebrew/bin/codex",
                status: .completed,
                resumeCursor: "codex-thread-1",
                cwd: "/tmp/remote-code",
                model: "gpt-5.5",
                serviceTier: .fast,
                runtimeMode: .autoAcceptEdits,
                lastEventKind: "turn.completed",
                runtimePayloadJSON: #"{"turnCount":1}"#
            ))
        }

        let (_, reopened) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = ProviderSessionRuntimeRepository(db: reopened)
        let session = try XCTUnwrap(try repo.get(threadId: threadId))
        XCTAssertEqual(session.resumeCursor, "codex-thread-1",
                       "provider resume cursor must survive app restart so long-running agent sessions can continue")
        XCTAssertEqual(session.cwd, "/tmp/remote-code")
        XCTAssertEqual(session.model, "gpt-5.5")
        XCTAssertEqual(session.serviceTier, .fast)
        XCTAssertEqual(session.runtimeMode, .autoAcceptEdits)
        XCTAssertEqual(session.adapterKey, "CodexSessionRuntime")
        XCTAssertEqual(session.binaryIdentity, "codex:/opt/homebrew/bin/codex")
        XCTAssertEqual(session.lastEventKind, "turn.completed")
        XCTAssertEqual(session.runtimePayloadJSON, #"{"turnCount":1}"#,
                       "provider runtime payload must survive app restart so exact provider resume metadata is not reduced to diagnostics")
        XCTAssertEqual(try repo.recoveryState(threadId: threadId), .recoverable(session),
                       "completed sessions with a resume cursor must be classified as recoverable, not silently lost")
    }

    func test_updateDiagnostics_skipsNoOpUpsertWhileStreamingSameKind() throws {
        // WHY: persistStreamBatch calls updateDiagnostics on every 16-event /
        // 250ms flush. Token deltas on one item keep lastEventKind as
        // `itemDelta(id)` but used to rewrite the whole provider_session_runtime
        // row (runtime_payload_json included) just to bump updatedAt.
        let tmp = NSTemporaryDirectory() + "RC2DiagnosticsNoOp-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let thread = AgentThread(title: "stream", provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let repo = ProviderSessionRuntimeRepository(db: db)
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = String(repeating: "x", count: 8_192)
        try repo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .running,
            lastEventKind: "itemDelta(item-1)",
            runtimePayloadJSON: payload,
            updatedAt: frozen
        ))

        var upserts = 0
        db.beforeStatementStepForTesting = { sql in
            if sql.contains("INSERT INTO provider_session_runtime") {
                upserts += 1
            }
        }
        defer { db.beforeStatementStepForTesting = nil }

        try repo.updateDiagnostics(
            threadId: thread.id,
            lastEventKind: "itemDelta(item-1)",
            lastErrorMessage: nil,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(upserts, 0, "same lastEventKind must not WAL-write the session row")
        let afterNoop = try XCTUnwrap(try repo.get(threadId: thread.id))
        XCTAssertEqual(afterNoop.lastEventKind, "itemDelta(item-1)")
        XCTAssertEqual(afterNoop.updatedAt.timeIntervalSince1970, frozen.timeIntervalSince1970,
                       "updatedAt must stay put so skip is observable; reaper only lists completed sessions")
        XCTAssertEqual(afterNoop.runtimePayloadJSON, payload)

        try repo.updateDiagnostics(
            threadId: thread.id,
            lastEventKind: "itemDelta(item-2)",
            lastErrorMessage: nil,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(upserts, 1, "a new lastEventKind must still persist")
        let afterChange = try XCTUnwrap(try repo.get(threadId: thread.id))
        XCTAssertEqual(afterChange.lastEventKind, "itemDelta(item-2)")
        XCTAssertEqual(afterChange.updatedAt.timeIntervalSince1970, 1_800_000_000)

        try repo.updateDiagnostics(
            threadId: thread.id,
            lastEventKind: "itemDelta(item-2)",
            lastErrorMessage: "boom",
            at: Date(timeIntervalSince1970: 1_900_000_000)
        )
        XCTAssertEqual(upserts, 2, "a new lastErrorMessage must still persist")
        let afterError = try XCTUnwrap(try repo.get(threadId: thread.id))
        XCTAssertEqual(afterError.lastErrorMessage, "boom")
        XCTAssertEqual(afterError.lastEventKind, "itemDelta(item-2)")
    }

    func test_interruptedProviderSessionWithCursorIsRecoverableButCancelledSessionIsStopped() throws {
        let tmp = NSTemporaryDirectory() + "RC2InterruptedRecovery-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let thread = AgentThread(title: "resume after relaunch", provider: .codex, model: "gpt-5.5")
        try AgentThreadRepository(db: db).upsert(thread)
        let repo = ProviderSessionRuntimeRepository(db: db)
        let session = ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .interrupted,
            resumeCursor: "codex-resume-cursor"
        )
        try repo.upsert(session)

        guard case .recoverable(let recovered) = try repo.recoveryState(threadId: thread.id) else {
            return XCTFail("a launch-interrupted provider session with a cursor must expose Continue instead of becoming an unreachable stopped session")
        }
        XCTAssertEqual(recovered.status, .interrupted)
        XCTAssertEqual(recovered.resumeCursor, "codex-resume-cursor")

        try repo.markStopped(threadId: thread.id)
        guard case .stopped(let stopped) = try repo.recoveryState(threadId: thread.id) else {
            return XCTFail("an intentional stop must remain stopped even when the old provider cursor is retained")
        }
        XCTAssertEqual(stopped.status, .cancelled)
        XCTAssertEqual(stopped.resumeCursor, "codex-resume-cursor")
    }

    func test_proposedPlan_roundtripsIndependentlyFromMessagesAcrossBootstrapRestart() throws {
        let tmp = NSTemporaryDirectory() + "RC2ProposedPlan-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let threadId: AgentThreadID
        do {
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            let thread = AgentThread(title: "plan", provider: .claude, model: "sonnet")
            threadId = thread.id
            try AgentThreadRepository(db: db).upsert(thread)
            try AgentMessageRepository(db: db).append(AgentMessage(threadId: thread.id, role: .assistant, content: "normal assistant text"))
            try AgentProposedPlanRepository(db: db).upsert(
                threadId: thread.id,
                plan: AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: "1. Inspect\n2. Patch")
            )
        }

        let (_, reopened) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let plans = try AgentProposedPlanRepository(db: reopened).list(threadId: threadId)
        let messages = try AgentMessageRepository(db: reopened).list(threadId: threadId)

        XCTAssertEqual(plans.map(\.plan.markdown), ["1. Inspect\n2. Patch"],
                       "proposed plans must survive restart as structured artifacts, not only as assistant chat text")
        XCTAssertEqual(messages.map(\.content), ["normal assistant text"],
                       "plan artifacts must stay separate from normal assistant messages")
    }

    func test_turnCheckpoint_roundtripsFilesAndProviderTurnCountAcrossBootstrapRestart() throws {
        let tmp = NSTemporaryDirectory() + "RC2TurnCheckpoint-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let threadId: AgentThreadID
        do {
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            let thread = AgentThread(title: "checkpoint", provider: .codex, model: "gpt-5.5")
            threadId = thread.id
            let runId = AgentRunID()
            try AgentThreadRepository(db: db).upsert(thread)
            try AgentRunRepository(db: db).upsert(AgentRun(id: runId, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .completed))
            try AgentTurnCheckpointRepository(db: db).upsert(AgentTurnCheckpointSummary(
                threadId: thread.id,
                runId: runId,
                turnId: "turn-1",
                checkpointTurnCount: 1,
                checkpointRef: "local-diff:\(runId.value.uuidString):turn-1",
                status: .ready,
                files: [AgentTurnCheckpointFile(path: "Sources/App.swift", kind: "modified", additions: 3, deletions: 1)]
            ))
        }

        let (_, reopened) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let checkpoints = try AgentTurnCheckpointRepository(db: reopened).list(threadId: threadId)

        XCTAssertEqual(checkpoints.count, 1)
        XCTAssertEqual(checkpoints[0].turnId, "turn-1")
        XCTAssertEqual(checkpoints[0].checkpointTurnCount, 1,
                       "checkpoint turn count must survive restart so provider turns can be matched to workspace checkpoints")
        XCTAssertEqual(checkpoints[0].status, .ready)
        XCTAssertEqual(checkpoints[0].files, [AgentTurnCheckpointFile(path: "Sources/App.swift", kind: "modified", additions: 3, deletions: 1)],
                       "checkpoint file summaries must survive as structured data, not only as display text")
    }

    func test_turnCheckpointCorruptionReportsSkippedRowsWithoutDroppingHealthyData() throws {
        let tmp = NSTemporaryDirectory() + "RC2TurnCheckpointCorrupt-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let thread = AgentThread(title: "checkpoint corrupt", provider: .codex, model: "gpt-5.5")
        let runId = AgentRunID()
        try AgentThreadRepository(db: db).upsert(thread)
        try AgentRunRepository(db: db).upsert(AgentRun(id: runId, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .completed))
        try AgentTurnCheckpointRepository(db: db).upsert(AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: runId,
            turnId: "turn-corrupt",
            checkpointTurnCount: 1,
            checkpointRef: "local-diff:\(runId.value.uuidString):turn-corrupt",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "Sources/App.swift", kind: "modified", additions: 3, deletions: 1)]
        ))
        try db.execute("UPDATE agent_turn_checkpoints SET file_snapshots_json = '{broken json' WHERE turn_id = 'turn-corrupt';")

        let result = try AgentTurnCheckpointRepository(db: db).listTolerant(threadId: thread.id)
        XCTAssertEqual(result.healthy.count, 0)
        XCTAssertEqual(result.corruptCount, 1,
                       "corrupt checkpoint snapshot JSON must be counted so restore diagnostics fail loud without hiding other healthy checkpoints")
        XCTAssertEqual(try AgentTurnCheckpointRepository(db: db).list(threadId: thread.id), [],
                       "legacy list() should skip corrupt rows while listTolerant reports the skipped-row count")
    }

    func test_commandReceipt_roundtripsAcrossBootstrapRestart() throws {
        let tmp = NSTemporaryDirectory() + "RC2CommandReceipt-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        do {
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            try CommandReceiptRepository(db: db).record(
                method: "agent.message.send",
                clientRequestId: "mobile-send-1",
                resultJSON: #"{"run_id":"run-1"}"#
            )
        }

        let (_, reopened) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        XCTAssertEqual(
            try CommandReceiptRepository(db: reopened).get(method: "agent.message.send", clientRequestId: "mobile-send-1"),
            #"{"run_id":"run-1"}"#,
            "agent command receipts must survive app restart so mobile retries cannot duplicate long-running provider turns"
        )
    }

    func test_providerPendingCallbacks_roundtripResolveAndStaleAcrossRestart() throws {
        let tmp = NSTemporaryDirectory() + "RC2PendingCallbacks-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let threadId: AgentThreadID
        do {
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            let thread = AgentThread(title: "callbacks", provider: .codex, model: "gpt-5.5")
            threadId = thread.id
            try AgentThreadRepository(db: db).upsert(thread)
            let repo = ProviderPendingCallbackRepository(db: db)
            try repo.record(threadId: thread.id, request: AssistantPendingRequest(
                id: "approval-1",
                turnId: "turn-1",
                kind: .commandExecution,
                title: "Run command",
                detail: "swift test",
                createdAtMs: 1_000
            ))
            try repo.record(threadId: thread.id, userInput: AssistantUserInputRequest(
                id: "question-1",
                turnId: "turn-1",
                prompt: "Continue?",
                options: ["Plan", "Run"],
                createdAtMs: 2_000
            ))
            try repo.resolve(threadId: thread.id, requestId: "approval-1", kind: .approval, state: .approved)
        }

        let (_, reopened) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = ProviderPendingCallbackRepository(db: reopened)
        let approval = try XCTUnwrap(try repo.get(threadId: threadId, requestId: "approval-1", kind: .approval))
        XCTAssertEqual(approval.state, .approved,
                       "approval callback decisions must persist so retry/reload does not resurrect a resolved approval")
        let staleCount = try repo.markOpenStale(reason: "Provider callback state does not survive app restart.")
        let question = try XCTUnwrap(try repo.get(threadId: threadId, requestId: "question-1", kind: .userInput))
        XCTAssertEqual(staleCount, 1)
        XCTAssertEqual(question.state, .stale,
                       "open provider questions must become explicitly stale after restart instead of leaving dead UI")
        XCTAssertEqual(question.staleReason, "Provider callback state does not survive app restart.")
    }

    func test_streamEventReplayIncludesEveryRunForThread() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threads = AgentThreadRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let thread = AgentThread(title: "history", provider: .codex, model: "m")
        try threads.upsert(thread)

        let firstRun = AgentRun(threadId: thread.id, provider: .codex, model: "m", startedAt: Date(timeIntervalSince1970: 1))
        let secondRun = AgentRun(threadId: thread.id, provider: .codex, model: "m", startedAt: Date(timeIntervalSince1970: 2))
        try runs.upsert(firstRun)
        try runs.upsert(secondRun)
        try runs.appendStreamEvent(runId: firstRun.id, seq: 1, kind: "turnStarted(first)", payloadJSON: #"{"turnStarted":{"turnId":"first"}}"#)
        try runs.appendStreamEvent(runId: firstRun.id, seq: 2, kind: "error(first)", payloadJSON: #"{"error":{"message":"first update","recoverable":false}}"#)
        try runs.appendStreamEvent(runId: secondRun.id, seq: 1, kind: "turnStarted(second)", payloadJSON: #"{"turnStarted":{"turnId":"second"}}"#)

        let replayed = try runs.listLatestStreamEvents(threadId: thread.id)

        XCTAssertEqual(replayed, [
            .turnStarted(turnId: "first"),
            .error(message: "first update", recoverable: false),
            .turnStarted(turnId: "second")
        ], "reopening or following up must replay every persisted run event, not only the latest response")
    }

    func test_streamEventReplayLimitKeepsNewestEventsInChronologicalOrder() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threads = AgentThreadRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let thread = AgentThread(title: "bounded history", provider: .codex, model: "m")
        try threads.upsert(thread)

        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", startedAt: Date(timeIntervalSince1970: 1))
        try runs.upsert(run)
        for index in 0..<650 {
            try runs.appendStreamEvent(
                runId: run.id,
                seq: index + 1,
                kind: "turnStarted(turn-\(index))",
                payloadJSON: #"{"turnStarted":{"turnId":"turn-\#(index)"}}"#
            )
        }

        let replayed = try runs.listLatestStreamEvents(threadId: thread.id, limit: 500)

        XCTAssertEqual(replayed.count, 500)
        XCTAssertEqual(replayed.first, .turnStarted(turnId: "turn-150"),
                       "long Agent App reload must drop the oldest persisted provider events, not the newest output")
        XCTAssertEqual(replayed.last, .turnStarted(turnId: "turn-649"),
                       "bounded replay must keep the newest provider event visible after restart")
    }

    func test_streamEventPruneKeepsNewestEventsAcrossRuns() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threads = AgentThreadRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let thread = AgentThread(title: "retention", provider: .codex, model: "m")
        try threads.upsert(thread)

        let firstRun = AgentRun(threadId: thread.id, provider: .codex, model: "m", startedAt: Date(timeIntervalSince1970: 1))
        let secondRun = AgentRun(threadId: thread.id, provider: .codex, model: "m", startedAt: Date(timeIntervalSince1970: 2))
        try runs.upsert(firstRun)
        try runs.upsert(secondRun)
        for index in 0..<8 {
            try runs.appendStreamEvent(
                runId: firstRun.id,
                seq: index + 1,
                kind: "turnStarted(first-\(index))",
                payloadJSON: #"{"turnStarted":{"turnId":"first-\#(index)"}}"#
            )
        }
        for index in 0..<8 {
            try runs.appendStreamEvent(
                runId: secondRun.id,
                seq: index + 1,
                kind: "turnStarted(second-\(index))",
                payloadJSON: #"{"turnStarted":{"turnId":"second-\#(index)"}}"#
            )
        }

        try runs.pruneStreamEvents(threadId: thread.id, keepLatest: 10)
        let replayed = try runs.listLatestStreamEvents(threadId: thread.id, limit: 20)

        XCTAssertEqual(try runs.countStreamEvents(threadId: thread.id), 10,
                       "long provider streams must not grow persisted event rows without a retention cap")
        XCTAssertEqual(replayed.first, .turnStarted(turnId: "first-6"),
                       "retention pruning must remove oldest events across runs, not only trim the latest run")
        XCTAssertEqual(replayed.last, .turnStarted(turnId: "second-7"),
                       "retention pruning must keep newest provider output for restart replay")
    }

    func test_providerEventLogSurvivesBoundedStreamEventPruning() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threads = AgentThreadRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let thread = AgentThread(title: "provider logs", provider: .codex, model: "m")
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", startedAt: Date(timeIntervalSince1970: 1))
        try threads.upsert(thread)
        try runs.upsert(run)

        for index in 0..<20 {
            let runtime = ProviderRuntimeEvent(
                id: "runtime-\(index)",
                provider: .codex,
                source: "codex.app-server",
                method: "item/completed",
                providerTurnId: "turn-\(index)",
                providerItemId: "item-\(index)",
                providerRequestId: nil,
                payloadJSON: #"{"type":"item/completed","index":\#(index)}"#,
                receivedAtMs: Int64(index)
            )
            try runs.appendStreamEvent(
                runId: run.id,
                seq: index + 1,
                kind: "providerRuntime(\(runtime.method))",
                payloadJSON: String(data: try JSONEncoder().encode(AssistantEvent.providerRuntime(runtime)), encoding: .utf8)!
            )
            try runs.appendProviderEventLog(threadId: thread.id, runId: run.id, event: runtime)
        }

        try runs.pruneStreamEvents(threadId: thread.id, keepLatest: 5)

        XCTAssertEqual(try runs.countStreamEvents(threadId: thread.id), 5,
                       "UI replay stream events should stay bounded for long Agent App sessions")
        XCTAssertEqual(try runs.countProviderEventLogs(threadId: thread.id), 20,
                       "native provider event logs must survive stream replay pruning so transport diagnostics are not lost")
        let latest = try runs.listLatestProviderEventLogs(threadId: thread.id, limit: 3)
        XCTAssertEqual(latest.map(\.id), ["runtime-17", "runtime-18", "runtime-19"])
        XCTAssertEqual(latest.last?.providerItemId, "item-19",
                       "provider log replay must retain native item/request refs for later debugging")
    }

    func test_providerEventLogCorruptionFailsLoudInsteadOfSkippingNativeEvidence() throws {
        let tmp = NSTemporaryDirectory() + "RC2ProviderLogCorrupt-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threads = AgentThreadRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let thread = AgentThread(title: "provider logs corrupt", provider: .codex, model: "m")
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", startedAt: Date(timeIntervalSince1970: 1))
        try threads.upsert(thread)
        try runs.upsert(run)
        try runs.appendProviderEventLog(threadId: thread.id, runId: run.id, event: ProviderRuntimeEvent(
            id: "runtime-corrupt",
            provider: .codex,
            source: "codex.app-server",
            method: "item/completed",
            providerTurnId: "turn-corrupt",
            providerItemId: "item-corrupt",
            providerRequestId: nil,
            payloadJSON: #"{"type":"item/completed"}"#,
            receivedAtMs: 1
        ))
        try db.execute("UPDATE agent_provider_event_logs SET provider = 'unknown-provider' WHERE event_id = 'runtime-corrupt';")

        XCTAssertThrowsError(try runs.listLatestProviderEventLogs(threadId: thread.id),
                             "corrupt provider event rows must fail loud instead of skipping native evidence during long-run diagnostics") { error in
            XCTAssertTrue(String(describing: error).contains("Corrupt provider event log"))
        }
    }

    func test_terminalOutputHistoryReadsBoundedOlderWindows() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = TerminalOutputRepository(db: db)
        let surfaceID = UUID().uuidString

        try repo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: 1, data: Data("older-".utf8))
        try repo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: 2, data: Data("middle-".utf8))
        try repo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: 3, data: Data("newest".utf8))

        let latest = try repo.readWindow(surfaceID: surfaceID, maxBytes: 14)

        XCTAssertEqual(latest.text, "middle-newest",
                       "terminal history fetch must return newest DB chunks without loading the whole scrollback into memory")
        XCTAssertTrue(latest.hasMoreOlder, "bounded history windows must expose an older-page cursor for infinite scroll")
        let older = try repo.readWindow(surfaceID: surfaceID, beforeChunkID: latest.nextBeforeChunkID, maxBytes: 64)
        XCTAssertEqual(older.text, "older-",
                       "fetching before the cursor must read the next older DB-backed terminal history page")
        XCTAssertFalse(older.hasMoreOlder)
    }

    // The history cap must allow more than 20 entries so older prompts are not
    // silently lost when the user types more than 20 commands in a session.
    func test_promptHistoryStore_capAllowsMoreThan20Entries() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PromptHistoryStore(db: db)
        let ws = WorkspaceID()

        let entries = (1...25).map { "cmd-\($0)" }
        store.save(entries, workspaceID: ws)

        let loaded = store.load(workspaceID: ws)
        XCTAssertEqual(loaded.count, 25,
                       "raising the cap beyond 20 must allow all 25 entries to survive a save/load round-trip; a 20-cap makes older prompts unrecoverable")
        XCTAssertEqual(loaded.last, "cmd-25",
                       "most recent entry must appear last (append order) after load")
        XCTAssertTrue(PromptHistoryStore.limit > 20,
                      "static limit must be greater than 20 so up-arrow recall is not silently truncated")
    }

    // search must return entries matching the query (case-insensitive), exclude
    // non-matches, respect the result limit, and return most-recent-first.
    func test_promptHistoryStore_search_filtersCaseInsensitiveAndMostRecentFirst() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PromptHistoryStore(db: db)
        let ws = WorkspaceID()

        // Save in chronological order (oldest first); load returns same order.
        store.save([
            "swift build",
            "swift test",
            "git status",
            "Swift Package Show Dependencies",
            "git log --oneline"
        ], workspaceID: ws)

        // Case-insensitive match: "swift" should hit entries 1, 2, 4 (most-recent-first).
        let matches = store.search(workspaceID: ws, query: "swift")
        XCTAssertEqual(matches, [
            "Swift Package Show Dependencies",
            "swift test",
            "swift build"
        ], "search must return matching entries most-recent-first so the most useful history is surfaced first; a missing search makes older prompts unrecoverable")

        // Non-matching query returns empty.
        let none = store.search(workspaceID: ws, query: "docker")
        XCTAssertTrue(none.isEmpty,
                      "search must exclude entries that do not contain the query string")

        // Limit is respected.
        let limited = store.search(workspaceID: ws, query: "swift", limit: 2)
        XCTAssertEqual(limited.count, 2,
                       "search limit must cap the result set so callers can control result list size")
        XCTAssertEqual(limited.first, "Swift Package Show Dependencies",
                       "search with limit must still return most-recent entries first")
    }

    // search must be scoped per-workspace: entries from another workspace must
    // not appear in results.
    func test_promptHistoryStore_search_isScopedToWorkspace() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PromptHistoryStore(db: db)
        let wsA = WorkspaceID()
        let wsB = WorkspaceID()

        store.save(["swift build", "swift test"], workspaceID: wsA)
        store.save(["git status"], workspaceID: wsB)

        let resultsA = store.search(workspaceID: wsA, query: "swift")
        let resultsB = store.search(workspaceID: wsB, query: "swift")

        XCTAssertEqual(resultsA.count, 2,
                       "search must return matching entries scoped to the requested workspace")
        XCTAssertTrue(resultsB.isEmpty,
                      "search must not leak entries across workspace boundaries")
    }

    // search on empty history must return empty without crashing.
    func test_promptHistoryStore_search_emptyHistoryReturnsEmpty() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PromptHistoryStore(db: db)
        let ws = WorkspaceID()

        XCTAssertTrue(store.search(workspaceID: ws, query: "anything").isEmpty,
                      "search on a workspace with no history must return empty without crashing")
    }

    // search deduplicates: if the same command appears multiple times only the
    // most-recent occurrence should be returned.
    func test_promptHistoryStore_search_deduplicatesEntries() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PromptHistoryStore(db: db)
        let ws = WorkspaceID()

        store.save(["swift build", "git status", "swift build", "swift build"], workspaceID: ws)

        let matches = store.search(workspaceID: ws, query: "swift build")
        XCTAssertEqual(matches, ["swift build"],
                       "search must deduplicate repeated prompts so the history list is not cluttered with identical entries")
    }

    // Closing a workspace must delete its prompt history so user-typed prompts do
    // not leak on disk indefinitely (privacy + unbounded settings-table growth).
    func test_promptHistoryStore_deleteWorkspace_removesItsHistoryAndPreservesOthers() throws {
        let tmp = NSTemporaryDirectory() + "RC2Test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let store = PromptHistoryStore(db: db)

        let wsA = WorkspaceID()
        let wsB = WorkspaceID()

        store.save(["cmd-a1", "cmd-a2"], workspaceID: wsA)
        store.save(["cmd-b1"], workspaceID: wsB)

        // Precondition: both workspaces have history.
        XCTAssertEqual(store.load(workspaceID: wsA), ["cmd-a1", "cmd-a2"])
        XCTAssertEqual(store.load(workspaceID: wsB), ["cmd-b1"])

        // Simulate workspace A being closed/removed.
        try store.delete(workspaceID: wsA)

        // Post-condition: A's history is gone; B's is untouched.
        XCTAssertTrue(store.load(workspaceID: wsA).isEmpty,
                      "closing a workspace must purge its prompt history from the settings table")
        XCTAssertEqual(store.load(workspaceID: wsB), ["cmd-b1"],
                       "deleting one workspace's prompt history must not affect other workspaces")
    }
}
