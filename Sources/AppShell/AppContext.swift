import Foundation
import AppKit
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import Surfaces
import DistillCore

struct ProjectScriptRunOutcome: Sendable, Equatable {
    let workspaceID: WorkspaceID
    let surfaceID: SurfaceID
    let name: String
    let exitCode: Int32?
    let durationMilliseconds: Int64

    var result: String { exitCode == 0 ? "success" : "failure" }
}

final class ProjectScriptRunRegistry: @unchecked Sendable {
    private struct Entry {
        let workspaceID: WorkspaceID
        let name: String
        let startedAt: Date
    }

    private let lock = NSLock()
    private var entries: [SurfaceID: Entry] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func register(workspaceID: WorkspaceID, surfaceID: SurfaceID, name: String) {
        lock.lock()
        entries[surfaceID] = Entry(workspaceID: workspaceID, name: name, startedAt: now())
        lock.unlock()
    }

    func consumeTerminalDeath(surfaceID: SurfaceID, health: TerminalRuntimeHealth) -> ProjectScriptRunOutcome? {
        guard !health.processAlive else { return nil }
        lock.lock()
        let entry = entries.removeValue(forKey: surfaceID)
        lock.unlock()
        guard let entry else { return nil }

        let duration = max(0, Int64(now().timeIntervalSince(entry.startedAt) * 1_000))
        return ProjectScriptRunOutcome(
            workspaceID: entry.workspaceID,
            surfaceID: surfaceID,
            name: entry.name,
            exitCode: Self.exitCode(rawStatus: health.exitStatus, terminationSignal: health.terminationSignal),
            durationMilliseconds: duration
        )
    }

    private static func exitCode(rawStatus: Int32?, terminationSignal: Int32?) -> Int32? {
        guard let rawStatus else { return nil }
        let signal = terminationSignal ?? (rawStatus & 0x7F)
        guard signal == 0 else { return 128 + signal }
        return (rawStatus >> 8) & 0xFF
    }
}

@MainActor
public final class AppContext {
    public let channel: ReleaseChannel
    public let db: SQLiteDB
    public let bootstrapReport: BootstrapReport
    public let appSupportDirectory: URL
    public let projectRepo: ProjectRepository
    public let threadRepo: AgentThreadRepository
    public let messageRepo: AgentMessageRepository
    public let queuedMessageRepo: AgentQueuedMessageRepository
    public let runRepo: AgentRunRepository
    public let snapshotRepo: SessionSnapshotRepository
    public let settingsRepo: SettingsRepository
    public let eventLog: EventLogRepository
    public let terminalOutputRepo: TerminalOutputRepository
    public let providerSessionRuntimeRepo: ProviderSessionRuntimeRepository
    public let commandReceiptRepo: CommandReceiptRepository
    public let providerPendingCallbackRepo: ProviderPendingCallbackRepository
    public let proposedPlanRepo: AgentProposedPlanRepository
    public let turnCheckpointRepo: AgentTurnCheckpointRepository
    public let tokenSaverSavingsRepo: TokenSaverSavingsRepository
    public let privateNotificationBridge: PrivateNotificationBridge
    public let liveActivitySyncCoordinator: LiveActivitySyncCoordinator
    public let tokenSaverDistillServiceController: TokenSaverDistillServiceController
    let projectScriptRuns = ProjectScriptRunRegistry()
    public private(set) var managedDistillSkillInstallResults: [AgentSkillInstallResult] = []
    /// Last managed-distill reconcile error (nil when off or installed cleanly). Lets
    /// the UI distinguish "Token Saver off" from "install failed" instead of both
    /// looking like an empty result set.
    public private(set) var managedDistillSkillInstallError: String?
    public private(set) var tokenSaverAccountUsageRefreshCount = 0
    public private(set) var persistenceWriteErrorMessage: String?
    public var onPersistenceWriteError: ((String) -> Void)?

    public let reducer = LayoutReducer()
    public var state = LayoutState()

    public let coordinator: AgentRunCoordinator
    public var router: AppCommandRouter!
    public var socketServer: UnixSocketServer?
    private let tokenSaverAccountUsageRefresher: TokenSaverAccountUsageRefreshing
    private var tokenSaverAccountUsageRefreshTask: Task<Void, Never>?
    private var tokenSaverUsageNotificationTask: Task<Void, Never>?
    private var tokenSaverLastUsageNotificationAt: Date = .distantPast
    /// Per-run accumulator: sums token counts between debounced flushes so the
    /// expensive file I/O happens at most once per debounce window rather than
    /// once per token-usage event.
    private struct PendingUsage {
        var provider: AgentProvider
        var totalTokens: Int
        var billedTokenUnits: Double
        var eligibleRuns: Int
        var currentSessionTokens: Int
        var currentSessionLimitTokens: Int?
    }
    private var pendingUsageByRun: [AgentRunID: PendingUsage] = [:]
    private var sessionLearnInputTokensByRun: [AgentRunID: Int] = [:]
    private var pendingUsageFlushTask: Task<Void, Never>?
    private var cachedDistillClientKey: String?
    private var cachedDistillClient: DistillServiceClient?
    private var tokenSaverPromptSkipSet: [DistillResultCacheKey: Date] = [:]
    /// Test seam: when set, used instead of resolving a client from the live
    /// sidecar status. Production code never sets this.
    var distillClientOverrideForTesting: DistillServiceClient?
    /// Test seam: sandbox the SessionLearn target instruction files so tests never write
    /// into the developer's real ~/.claude/CLAUDE.md or ~/.codex/AGENTS.md.
    var sessionLearnInstructionFilesOverrideForTesting: [URL]?
    /// Test seam: sandboxes the managed-skill/config install roots under a temp home so
    /// tests never write /distill state into the developer's real ~/.claude or
    /// ~/.codex. Production code never sets this (installs to the real provider dirs).
    var agentSkillsHomeOverrideForTesting: URL?
    /// Prompts shorter than this are sent verbatim: distillation overhead/latency
    /// isn't worth it and tiny instructions have nothing to compress.
    // Raised from 600: below ~2k chars a model round-trip on the awaited prompt path
    // rarely nets out positive once MLX latency is counted (NetPositiveGate floor, G3).
    private static let tokenSaverMinCompressChars = 2_000
    private static let tokenSaverDistillStartupPolls = 300
    private static let tokenSaverPromptSkipSetTTL: TimeInterval = 1_800
    private static let tokenSaverUsageNotificationMinimumInterval: TimeInterval = 2
    /// Debounce window for coalescing per-token usage writes into one disk write.
    private static let tokenSaverUsageDebounceInterval: TimeInterval = 0.75

    public init(
        channel: ReleaseChannel = .debug,
        dbPathOverride: String? = nil,
        appSupportOverride: String? = nil,
        tokenSaverAccountUsageRefresher: TokenSaverAccountUsageRefreshing = TokenSaverAccountUsageRefresher(),
        agentSkillsHomeOverrideForTesting: URL? = nil
    ) throws {
        self.channel = channel
        self.tokenSaverAccountUsageRefresher = tokenSaverAccountUsageRefresher
        self.agentSkillsHomeOverrideForTesting = agentSkillsHomeOverrideForTesting
        let bs = Bootstrap(channel: channel, dbPathOverride: dbPathOverride, appSupportOverride: appSupportOverride)
        let (rep, db) = try bs.run()
        self.bootstrapReport = rep
        self.appSupportDirectory = AppPaths.appSupportDirectory(for: channel, override: appSupportOverride)
        self.db = db
        self.projectRepo = ProjectRepository(db: db)
        self.threadRepo = AgentThreadRepository(db: db)
        self.messageRepo = AgentMessageRepository(db: db)
        self.queuedMessageRepo = AgentQueuedMessageRepository(db: db)
        self.runRepo = AgentRunRepository(db: db)
        self.snapshotRepo = SessionSnapshotRepository(db: db)
        self.settingsRepo = SettingsRepository(db: db)
        self.eventLog = EventLogRepository(db: db)
        self.terminalOutputRepo = TerminalOutputRepository(db: db)
        self.providerSessionRuntimeRepo = ProviderSessionRuntimeRepository(db: db)
        self.commandReceiptRepo = CommandReceiptRepository(db: db)
        self.providerPendingCallbackRepo = ProviderPendingCallbackRepository(db: db)
        self.proposedPlanRepo = AgentProposedPlanRepository(db: db)
        self.turnCheckpointRepo = AgentTurnCheckpointRepository(db: db)
        self.tokenSaverSavingsRepo = TokenSaverSavingsRepository(db: db)
        let privateNotificationBridge = PrivateNotificationBridge(
            accountStore: PrivateAccountSessionStore(repo: self.settingsRepo),
            pushTargetStore: PrivatePushTargetStore(repo: self.settingsRepo)
        )
        self.privateNotificationBridge = privateNotificationBridge
        let liveActivityIdentity = try LiveActivityIdentityStore.beginBoot(settings: self.settingsRepo)
        let settingsRepo = self.settingsRepo
        self.liveActivitySyncCoordinator = LiveActivitySyncCoordinator(
            serverId: liveActivityIdentity.serverId,
            bootEpoch: liveActivityIdentity.bootEpoch,
            initialActivityGeneration: liveActivityIdentity.activityGeneration,
            registerToken: { target in
                await privateNotificationBridge.registerLiveActivityTokenV2(target)
            }
        ) { delivery in
            try? LiveActivityIdentityStore.persistActivityGeneration(
                delivery.activityGeneration,
                settings: settingsRepo
            )
            await privateNotificationBridge.deliverLiveActivity(delivery)
        }
        self.tokenSaverDistillServiceController = TokenSaverDistillServiceController(
            appSupportDirectory: self.appSupportDirectory
        )
        let codex = CodexAppServerAdapter(binaryNameOverride: try? settingsRepo.get("cli.codex.path"))
        let claude: AgentProviderAdapter = ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_ENABLED"] == "0"
            ? ClaudeStreamingCLIAdapter(binaryNameOverride: try? settingsRepo.get("cli.claude.path"))
            : ClaudeAgentSDKBridgeAdapter()
        let grok = OneShotProviderAdapter(
            runner: GrokRunner(binaryNameOverride: try? settingsRepo.get("cli.grok.path"))
        )
        self.coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providerSessionRepo: providerSessionRuntimeRepo,
            checkpointRepo: turnCheckpointRepo,
            providerAdapters: [.codex: codex, .claude: claude, .grok: grok]
        )
        let liveActivitySyncCoordinator = self.liveActivitySyncCoordinator
        coordinator.onActiveRunProjectionChanged = { projection, cause in
            let syncCause: LiveActivitySyncCause
            switch cause {
            case .started:
                syncCause = .started
            case .finished(let status):
                syncCause = .finished(status)
            case .launchReconciliation:
                syncCause = .launchReconciliation
            }
            liveActivitySyncCoordinator.submit(projection, cause: syncCause)
        }
        try coordinator.reconcileOnLaunch()
        try? tokenSaverSavingsRepo.prune()
        self.coordinator.promptCompressor = { [weak self] prompt, provider, threadId in
            guard let self else { return prompt }
            return await self.tokenSaverCompress(prompt: prompt, provider: provider, threadId: threadId)
        }
        self.coordinator.followUpPromptCompressor = { [weak self] prompt, provider, threadId in
            guard let self else { return prompt }
            return await self.tokenSaverCompress(prompt: prompt, provider: provider, threadId: threadId, cacheState: "prompt_followup")
        }
        self.coordinator.finalResponseTranslator = { [weak self] response, provider, threadId, runId in
            guard let self else { return response }
            return await self.tokenSaverHumanizeSR1Response(response, provider: provider, threadId: threadId, runId: runId)
        }
        // Recovered sessions rebuild their own request env in the coordinator, bypassing
        // providerEnvironment; feed them the same Token Saver env so distill survives resume.
        self.coordinator.recoveryEnvironmentProvider = { [weak self] provider in
            await self?.tokenSaverAgentEnvironment(provider: provider) ?? [:]
        }
        // P3 (opt-in, default OFF): compact large tool output in persisted stream events,
        // CCR-backed and structure-preserving, so replay still decodes. Our-storage saving.
        if SettingsStore(db: db).load().historyCompactionEnabled {
            let historyStore = ReversibleContentStore(db: db)
            self.coordinator.streamPayloadCompactor = { payload in
                ReversiblePayloadCompactor.compact(payload) { original in
                    try? historyStore.store(Data(original.utf8))
                }
            }
        }
        _ = try providerPendingCallbackRepo.markOpenStale(
            reason: "Provider callback state does not survive app restarts or recovered sessions. Restart the turn to continue."
        )
        // Managed skills install into the real ~/.claude / ~/.codex skill dirs. Skip the
        // open-trigger reconcile under XCTest so the suite never mutates the developer's
        // real home; AppContext tests drive reconcile explicitly with a sandboxed home.
        if !AppContext.isRunningUnitTests || agentSkillsHomeOverrideForTesting != nil {
            reconcileManagedDistillSkills(tokenSaverEnabled: SettingsStore(db: db).load().tokenSaverEnabled)
        }
        startTokenSaverDistillServiceIfEligible()

        // GAP-7: stream agent run lifecycle + timeline to the network
        // event bus so the iOS mirror renders agent output in real time
        // (kinds/payloads match the iOS MirrorEventReducer contract).
        func itemJSON(_ item: AssistantItem) -> JSONValue {
            (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(item))) ?? .null
        }
        func runtimeEventPayload(_ event: ProviderRuntimeEvent, threadId: String) -> JSONValue {
            var payload: [String: JSONValue] = [
                "thread_id": .string(threadId),
                "id": .string(event.id),
                "provider": .string(event.provider.rawValue),
                "source": .string(event.source),
                "method": .string(event.method),
                "payload_json": .string(event.payloadJSON),
                "received_at_ms": .number(Double(event.receivedAtMs))
            ]
            if let turn = event.providerTurnId { payload["provider_turn_id"] = .string(turn) }
            if let item = event.providerItemId { payload["provider_item_id"] = .string(item) }
            if let request = event.providerRequestId { payload["provider_request_id"] = .string(request) }
            return .object(payload)
        }
        func messageJSON(_ message: AgentMessage) -> JSONValue {
            (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(message))) ?? .null
        }
        func agentRunPayload(threadId: AgentThreadID, runId: AgentRunID? = nil, status: AgentRunStatus? = nil) -> JSONValue {
            var payload: [String: JSONValue] = ["thread_id": .string(threadId.value.uuidString)]
            if let runId {
                payload["run_id"] = .string(runId.value.uuidString)
                if let run = try? runRepo.get(id: runId) {
                    let startedAtMs = Int64(run.startedAt.timeIntervalSince1970 * 1000)
                    payload["started_at_ms"] = .number(Double(startedAtMs))
                    payload["started_at"] = .number(Double(startedAtMs))
                    if let finishedAt = run.finishedAt {
                        let finishedAtMs = Int64(finishedAt.timeIntervalSince1970 * 1000)
                        payload["finished_at_ms"] = .number(Double(finishedAtMs))
                        payload["duration_ms"] = .number(Double(max(0, finishedAtMs - startedAtMs)))
                    }
                }
            }
            if let wid = try? threadRepo.get(id: threadId)?.workspaceId {
                payload["workspace_id"] = .string(wid.value.uuidString)
            }
            if let status {
                payload["status"] = .string(status.rawValue)
            }
            return .object(payload)
        }
        coordinator.onRunStarted = { [weak self] tid, runId in
            EventBus.shared.publish(kind: "agent.run.started",
                                    payload: agentRunPayload(threadId: tid, runId: runId))
        }
        coordinator.onMessageAppended = { message in
            EventBus.shared.publish(kind: "agent.message.appended", payload: messageJSON(message))
        }
        coordinator.onAssistantEvent = { ev, tid, runId in
            let t = tid.value.uuidString
            switch ev {
            case .threadStarted:
                EventBus.shared.publish(kind: "agent.run.started", payload: agentRunPayload(threadId: tid, runId: runId))
            case .turnStarted(let turnId):
                EventBus.shared.publish(kind: "agent.turn.started",
                                        payload: .object(["thread_id": .string(t), "turn_id": .string(turnId)]))
            case .itemStarted(let item):
                EventBus.shared.publish(kind: "agent.item.started",
                                        payload: .object(["thread_id": .string(t), "item": itemJSON(item)]))
            case .itemDelta(let itemId, let bodyAppend, let outputAppend, let summary):
                var p: [String: JSONValue] = ["thread_id": .string(t), "item_id": .string(itemId)]
                if let b = bodyAppend { p["body_append"] = .string(b) }
                if let o = outputAppend { p["output_append"] = .string(o) }
                if let s = summary { p["summary"] = .string(s) }
                EventBus.shared.publish(kind: "agent.item.delta", payload: .object(p))
            case .itemState(let itemId, let state):
                if state != .streaming {
                    EventBus.shared.publish(kind: "agent.item.completed",
                                            payload: .object(["thread_id": .string(t), "item_id": .string(itemId)]))
                }
            case .itemProgress(let itemId, let progress):
                var p: [String: JSONValue] = ["thread_id": .string(t), "item_id": .string(itemId)]
                if let progress { p["progress"] = .number(progress) }
                EventBus.shared.publish(kind: "agent.item.progress", payload: .object(p))
            case .itemCompleted(let itemId, let state):
                EventBus.shared.publish(kind: "agent.item.completed",
                                        payload: .object(["thread_id": .string(t), "item_id": .string(itemId), "state": .string(state.rawValue)]))
            case .turnCompleted(let turnId, let final):
                var p: [String: JSONValue] = ["thread_id": .string(t), "turn_id": .string(turnId)]
                if let f = final { p["final"] = .string(f) }
                EventBus.shared.publish(kind: "agent.turn.completed", payload: .object(p))
                self.liveActivitySyncCoordinator.submitHeartbeat()
            case .proposedPlan(let plan):
                try? self.proposedPlanRepo.upsert(threadId: tid, plan: plan)
                var planPayload: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "plan_id": .string(plan.id),
                    "markdown": .string(plan.markdown)
                ]
                if let turnId = plan.turnId { planPayload["turn_id"] = .string(turnId) }
                EventBus.shared.publish(kind: "agent.plan.proposed", payload: .object(planPayload))
            case .activePlanUpdated(let plan):
                var payload: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "steps": .array(plan.steps.map { step in
                        .object([
                            "id": .string(step.id),
                            "title": .string(step.title),
                            "status": .string(step.status.rawValue)
                        ])
                    }),
                    "updated_at_ms": .number(Double(plan.updatedAtMs))
                ]
                if let explanation = plan.explanation { payload["explanation"] = .string(explanation) }
                EventBus.shared.publish(kind: "agent.plan.active_updated", payload: .object(payload))
            case .requestOpened(let request):
                try? self.providerPendingCallbackRepo.record(threadId: tid, request: request)
                var requestPayload: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "request_id": .string(request.id),
                    "kind": .string(request.kind.rawValue),
                    "title": .string(request.title),
                    "detail": request.detail.map(JSONValue.string) ?? .null
                ]
                if let turnId = request.turnId { requestPayload["turn_id"] = .string(turnId) }
                EventBus.shared.publish(kind: "agent.request.opened", payload: .object(requestPayload))
            case .requestResolved(let requestId, let state):
                try? self.providerPendingCallbackRepo.resolve(threadId: tid, requestId: requestId, kind: .approval, state: state)
                EventBus.shared.publish(kind: "agent.request.resolved", payload: .object([
                    "thread_id": .string(t),
                    "request_id": .string(requestId),
                    "state": .string(state.rawValue)
                ]))
            case .userInputRequested(let request):
                try? self.providerPendingCallbackRepo.record(threadId: tid, userInput: request)
                var userInputPayload: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "request_id": .string(request.id),
                    "prompt": .string(request.prompt),
                    "options": .array(request.options.map(JSONValue.string)),
                    "allows_multiple_selection": .bool(request.allowsMultipleSelection),
                    "is_secret": .bool(request.isSecret),
                    // Structured AskUserQuestion payload: without it iOS can only
                    // render a degraded flat prompt for multi-question requests.
                    "questions": .array(request.questions.map { question in
                        var q: [String: JSONValue] = [
                            "id": .string(question.id),
                            "prompt": .string(question.prompt),
                            "options": .array(question.options.map { option in
                                var o: [String: JSONValue] = ["label": .string(option.label)]
                                if let detail = option.detail { o["detail"] = .string(detail) }
                                return .object(o)
                            }),
                            "allows_multiple_selection": .bool(question.allowsMultipleSelection)
                        ]
                        if let header = question.header { q["header"] = .string(header) }
                        return .object(q)
                    })
                ]
                if let turnId = request.turnId { userInputPayload["turn_id"] = .string(turnId) }
                EventBus.shared.publish(kind: "agent.user_input.requested", payload: .object(userInputPayload))
            case .userInputResolved(let requestId, let answer):
                try? self.providerPendingCallbackRepo.resolve(threadId: tid, requestId: requestId, kind: .userInput, state: .resolved)
                EventBus.shared.publish(kind: "agent.user_input.resolved", payload: .object([
                    "thread_id": .string(t),
                    "request_id": .string(requestId),
                    "answer": answer.map(JSONValue.string) ?? .null
                ]))
            case .tokenUsage(let usage):
                self.recordTokenSaverUsage(usage, runId: runId)
                var p: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "input_tokens": .number(Double(usage.inputTokens)),
                    "output_tokens": .number(Double(usage.outputTokens)),
                    "total_tokens": .number(Double(usage.totalTokens))
                ]
                if let window = usage.contextWindow { p["context_window"] = .number(Double(window)) }
                if let compactsAutomatically = usage.compactsAutomatically {
                    p["compacts_automatically"] = .bool(compactsAutomatically)
                }
                // Cache-token split (G3): mirrors the billed-unit breakdown so
                // remote clients can compute net dollars like the mac does.
                if let uncached = usage.uncachedInputTokens {
                    p["uncached_input_tokens"] = .number(Double(uncached))
                }
                if let creation = usage.cacheCreationInputTokens {
                    p["cache_creation_input_tokens"] = .number(Double(creation))
                }
                if let read = usage.cacheReadInputTokens {
                    p["cache_read_input_tokens"] = .number(Double(read))
                }
                EventBus.shared.publish(kind: "agent.thread.token_usage", payload: .object(p))
            case .accountUsage(let usage):
                self.recordTokenSaverAccountUsage(usage)
                EventBus.shared.publish(kind: "agent.account.usage",
                    payload: .object(Self.accountUsagePayload(threadId: t, usage: usage)))
            case .contextCompaction(let summary):
                EventBus.shared.publish(kind: "agent.context.compaction", payload: .object([
                    "thread_id": .string(t),
                    "summary": summary.map(JSONValue.string) ?? .null
                ]))
            case .providerRuntime(let event):
                EventBus.shared.publish(kind: "agent.provider_runtime.event", payload: runtimeEventPayload(event, threadId: t))
            case .sr1Translation(let translation):
                // Mirror SR1 rewrites so remote clients can badge translated
                // messages and offer "show original" like the mac UI. Texts are
                // capped: the model carries no bound of its own.
                var sr1Payload: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "original_text": .string(AssistantTimelineState.cappedText(translation.originalText)),
                    "rewritten_text": .string(AssistantTimelineState.cappedText(translation.rewrittenText))
                ]
                if let itemId = translation.itemId { sr1Payload["item_id"] = .string(itemId) }
                if let messageId = translation.messageId { sr1Payload["message_id"] = .string(messageId) }
                EventBus.shared.publish(kind: "agent.sr1.translation", payload: .object(sr1Payload))
            case .error(let message, let recoverable):
                // Carry the provider error text + recoverability so remote
                // clients can show the reason and a Retry affordance instead
                // of a bare FAIL badge.
                var errorPayload = agentRunPayload(threadId: tid, runId: runId).objectValue ?? [:]
                errorPayload["message"] = .string(message)
                errorPayload["recoverable"] = .bool(recoverable)
                EventBus.shared.publish(kind: "agent.run.error", payload: .object(errorPayload))
            }
        }
        coordinator.onRunFinished = { tid, rid, status in
            let kind = (status == .completed) ? "agent.run.completed" : "agent.run.failed"
            EventBus.shared.publish(kind: kind, payload: agentRunPayload(threadId: tid, runId: rid, status: status))
            EventBus.shared.publish(kind: "agent.run.finished", payload: agentRunPayload(threadId: tid, runId: rid, status: status))
            // Flush any debounced usage for this run now that the run is done so
            // the final token batch is never stranded in the accumulator.
            self.flushPendingTokenSaverUsage(runId: rid)
            self.recordSessionLearnFromRun(runId: rid, status: status) // P5 SessionLearn (off by default)
            // Drain the next queued message after ANY terminal status. A run that
            // ended .failed previously stranded queued messages (no run to pick
            // them up); drainNextQueuedAgentMessage re-checks the thread is not
            // running/pending before sending, so an unconditional drain is safe
            // and onRunFinished only fires on terminal statuses.
            Task { @MainActor in
                try? await self.router?.drainNextQueuedAgentMessage(thread: tid)
            }
            if let content = RemoteCodeNotificationContent.threadOutcome(
                threadId: tid.value.uuidString,
                workspaceId: (try? self.threadRepo.get(id: tid)?.workspaceId)?.value.uuidString,
                title: try? self.threadRepo.get(id: tid)?.title,
                phase: status
            ) {
                SystemNotifier.shared.post(content)
                Task {
                    await self.privateNotificationBridge.deliver(content)
                }
            }
        }

        // HC-1: stream terminal/surface PTY output to the mirror so iOS
        // renders a live terminal (not a poll). Raw bytes, base64 +
        // monotonic seq per surface for ordered incremental rendering.
        SurfaceOutputBus.shared.sink = { sid, seq, chunk in
            let key = sid.value.uuidString
            var payload: [String: JSONValue] = [
                "surface_id": .string(key),
                "seq": .number(Double(seq)),
                "base64": .string(chunk.base64EncodedString())
            ]
            if let terminal = SurfaceRegistry.shared.surface(sid) as? TerminalSurface {
                payload["rows"] = .number(Double(terminal.viewportSize.rows))
                payload["cols"] = .number(Double(terminal.viewportSize.cols))
            }
            EventBus.shared.publish(kind: "surface.output", payload: .object(payload))
        }
        LocalGitActivityBus.shared.sink = { activity in
            guard ["git.checkout", "git.branch_created", "git.commit", "git.push"].contains(activity.kind) else {
                return
            }
            EventBus.shared.publish(kind: activity.kind, payload: .object([
                "workspace_id": .string(activity.workspaceID.value.uuidString),
                "surface_id": .string(activity.surfaceID.value.uuidString),
                "ok": .bool(activity.succeeded)
            ]))
        }
        let projectScriptRuns = self.projectScriptRuns
        SurfaceRuntimeBus.shared.sink = { sid, health in
            let projectScriptOutcome = projectScriptRuns.consumeTerminalDeath(surfaceID: sid, health: health)
            Task { @MainActor [weak self] in
                if self?.router?.promoteWorkspaceContainingBusySurface(sid) != true {
                    self?.router?.windowController?.refreshSurfaceRuntimeState()
                }
            }
            EventBus.shared.publish(kind: "surface.health", payload: .object([
                "surface_id": .string(sid.value.uuidString),
                "alive": .bool(health.alive),
                "process_alive": .bool(health.processAlive),
                "child_pid": health.childPID.map { .number(Double($0)) } ?? .null,
                "exit_status": health.exitStatus.map { .number(Double($0)) } ?? .null,
                "termination_signal": health.terminationSignal.map { .number(Double($0)) } ?? .null,
                "pty_open": .bool(health.ptyOpen),
                "input_accepting": .bool(health.inputAccepting),
                "terminal_dead_reason": health.terminalDeadReason.map { .string($0) } ?? .null,
                "last_output_at": health.lastOutputAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                "output_partial": .bool(health.outputPartial),
                "output_pending_bytes": .number(Double(health.outputPendingBytes)),
                "history_write_failures": .number(Double(health.historyWriteFailures)),
                "dropped_output_bytes": .number(Double(health.droppedOutputBytes)),
                "rows": .number(Double(health.rows)),
                "cols": .number(Double(health.cols))
            ]))
            if let outcome = projectScriptOutcome {
                EventBus.shared.publish(kind: "project.script.finished", payload: .object([
                    "workspace_id": .string(outcome.workspaceID.value.uuidString),
                    "surface_id": .string(outcome.surfaceID.value.uuidString),
                    "name": .string(outcome.name),
                    "exit_code": outcome.exitCode.map { .number(Double($0)) } ?? .null,
                    "duration_ms": .number(Double(outcome.durationMilliseconds)),
                    "result": .string(outcome.result)
                ]))
            }
        }

        // Flush any pending debounced usage writes before the process exits so no
        // token counts are lost at quit. The observer fires on MainActor (same as
        // AppContext), so `self` access is safe. NotificationCenter retains the
        // observer token; it lives as long as the app process does.
        if !AppContext.isRunningUnitTests {
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.flushPendingTokenSaverUsage()
            }
        }

        // restore last snapshot if any
        if let snap = try snapshotRepo.latest() {
            self.state = snap.layout
        }
    }

    /// Managed `/distill` state is only useful while Token Saver is on, so the skill
    /// and provider config lifecycle tracks the Token Saver toggle: present when
    /// enabled, removed when disabled. Driven from every Token Saver trigger:
    /// app open/close and the enable/disable toggle, so it never lingers once
    /// Token Saver is off.
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil
    }

    /// Token Saver environment vars for an agent run: the `| distill` hint (both providers) and
    /// Claude's PostToolUse compression state path. Single source for both the normal run path
    /// (`AppCommandRouter.providerEnvironment`) and the recovered-session path (the coordinator
    /// rebuilds its own request env, bypassing providerEnvironment). Empty when Token Saver is off:
    /// the managed `distill` CLI is uninstalled then, so a `cmd | distill` pipe would fail. The
    /// pipe hint is also withheld when the managed CLI failed to install (F25) — same failure mode.
    func tokenSaverAgentEnvironment(provider: AgentProvider) -> [String: String] {
        guard SettingsStore(db: db).load().tokenSaverEnabled else { return [:] }
        var env: [String: String] = [:]
        // Signal the agent to pipe large command output through the managed `distill` CLI. Codex
        // (app-server) reads this in its per-turn developer_instructions; the Claude SDK bridge
        // reads it to inject the distill systemPrompt.
        // F25: only when the managed CLI install actually succeeded — the toggle can be on while
        // reconcileManagedDistillSkills failed (missing/unresolvable RemoteCodeDistillService), and
        // the hint drives hard "pipe EVERY command through distill" instructions, so sending it
        // without the binary makes every piped agent command fail with `command not found` (127).
        // Reconcile runs at launch and on every toggle, so the error state is current here.
        if managedDistillSkillInstallError == nil {
            env["RC_TOKEN_SAVER_DISTILL_HINT"] = "1"
        }
        if provider == .claude {
            // Claude additionally auto-compresses tool output via the SDK-bridge PostToolUse hook,
            // which talks straight to the sidecar over HTTP using this state file.
            env["RC_TOKEN_SAVER_POST_TOOL_USE"] = "1"
            env["REMOTE_CODE_DISTILL_STATE_PATH"] = appSupportDirectory
                .appendingPathComponent("Distill", isDirectory: true)
                .appendingPathComponent("DistillCLIState.json")
                .path
        }
        return env
    }

    public func reconcileManagedDistillSkills(tokenSaverEnabled: Bool) {
        let installer = agentSkillsHomeOverrideForTesting.map { AgentSkillInstaller(homeDirectory: $0) }
            ?? AgentSkillInstaller()
        do {
            if tokenSaverEnabled {
                let codex = try installer.installDistillSkill(
                    for: .codex,
                    sourceRevision: "github-main-remote-code-template-v1"
                )
                let claude = try installer.installDistillSkill(
                    for: .claude,
                    sourceRevision: "github-main-remote-code-template-v1"
                )
                try installer.installDistillInstructions(for: .codex)
                try installer.installDistillInstructions(for: .claude)
                _ = try installer.installDistillCLI(appSupportDirectory: appSupportDirectory)
                try? installer.installCommandWrappers() // RTK transparent wrappers (best-effort; needs the bundled binary)
                try? installer.installRetrieveMCP() // Token Saver MCP tools (best-effort; needs the bundled binary)
                managedDistillSkillInstallResults = [codex, claude]
                managedDistillSkillInstallError = nil
            } else {
                _ = try installer.uninstallDistillSkill(for: .codex)
                _ = try installer.uninstallDistillSkill(for: .claude)
                _ = try installer.uninstallDistillInstructions(for: .codex)
                _ = try installer.uninstallDistillInstructions(for: .claude)
                _ = try installer.uninstallDistillCLI()
                _ = try? installer.uninstallCommandWrappers()
                try? installer.uninstallRetrieveMCP()
                managedDistillSkillInstallResults = []
                managedDistillSkillInstallError = nil
            }
        } catch {
            NSLog("RemoteCode managed Distill skill reconcile failed: \(error)")
            managedDistillSkillInstallResults = []
            managedDistillSkillInstallError = (error as NSError).localizedDescription
        }
    }

    private func startTokenSaverDistillServiceIfEligible() {
        let settings = SettingsStore(db: db).load()
        let session = PrivateAccountSessionStore(repo: settingsRepo).load()
        let installer = TokenSaverModelInstaller(appSupportDirectory: appSupportDirectory)
        let modelValidation = installer.validateInstalledTokenSaverModels()
        tokenSaverDistillServiceController.startIfEligible(
            session: session,
            settings: settings,
            modelValidation: modelValidation
        )
        activatePreferredTokenSaverModelIfDownloaded(settings: settings, session: session)
    }

    /// The eligibility check above accepts ANY installed approved model, so a machine that already
    /// holds the higher-tier SELECTED model (e.g. the E4B model on ≥16 GB) but whose active
    /// manifest still points at a smaller fallback (e.g. the 1.7B) keeps running the fallback —
    /// the startup path never upgrades. When the selected model's weights are ALREADY on disk,
    /// activate it (write its manifest) and restart the sidecar so it actually loads it (`start()`
    /// no-ops while the sidecar is running). A not-yet-downloaded model is left alone: that
    /// multi-GB download stays toggle/UI-driven so launch never starts one silently.
    private func activatePreferredTokenSaverModelIfDownloaded(settings: AppSettings, session: PrivateAccountSession?) {
        let installer = TokenSaverModelInstaller(appSupportDirectory: appSupportDirectory)
        guard settings.tokenSaverEnabled,
              installer.validateInstalledModel(requireSelectedModel: true).state != .installed,  // selected not active
              installer.validateInstalledModel(requireSelectedModel: false).state == .installed,  // a fallback IS active
              installer.modelArtifactsPresent() else {                                           // selected already downloaded
            return
        }
        let appSupport = appSupportDirectory
        Task { @MainActor [weak self] in
            guard let self else { return }
            let installer = TokenSaverModelInstaller(appSupportDirectory: appSupport)
            do {
                // Writes the selected model's manifest; the already-present files are skipped via
                // their cached checksums, so this does not re-download multiple GB.
                _ = try await TokenSaverModelDownloader(installer: installer).downloadRequiredModels { _ in }
                self.tokenSaverDistillServiceController.stop()
                self.tokenSaverDistillServiceController.startIfEligible(
                    session: session,
                    settings: settings,
                    modelValidation: installer.validateInstalledTokenSaverModels()
                )
                NSLog("RemoteCode Token Saver: activated preferred model \(TokenSaverApprovedModels.selected().id)")
            } catch {
                NSLog("RemoteCode Token Saver preferred-model activation failed: \(error)")
            }
        }
    }

    private func recordTokenSaverAccountUsage(_ usage: AssistantAccountUsage) {
        do {
            _ = try TokenSaverUsageStore(appSupportDirectory: appSupportDirectory).recordAccountUsage(
                provider: usage.provider,
                weeklyUsedPercent: usage.weeklyUsedPercent,
                weeklyWindowDurationMinutes: usage.weeklyWindowDurationMinutes,
                weeklyResetsAt: usage.weeklyResetsAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) },
                currentSessionUsedPercent: usage.currentSessionUsedPercent,
                currentSessionResetsAt: usage.currentSessionResetsAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
            )
            NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
        } catch {
            NSLog("RemoteCode Token Saver account usage record failed: \(error)")
        }
    }

    public func refreshTokenSaverAccountUsage(reason: String) {
        guard PrivateAccountSessionStore(repo: settingsRepo).load() != nil else {
            publishTokenSaverAccountUsageRefresh(state: "skipped", reason: reason, detail: "signed_out")
            return
        }
        guard tokenSaverAccountUsageRefreshTask == nil else {
            publishTokenSaverAccountUsageRefresh(state: "skipped", reason: reason, detail: "busy")
            return
        }
        tokenSaverAccountUsageRefreshCount += 1
        publishTokenSaverAccountUsageRefresh(state: "started", reason: reason, detail: nil)

        let codexBinary = (try? settingsRepo.get("cli.codex.path"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let claudeBinary = (try? settingsRepo.get("cli.claude.path"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let grokBinary = (try? settingsRepo.get("cli.grok.path"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = TokenSaverAccountUsageRefreshRequest(
            codexBinary: codexBinary?.isEmpty == false ? codexBinary! : "codex",
            claudeBinary: claudeBinary?.isEmpty == false ? claudeBinary! : "claude",
            grokBinary: grokBinary?.isEmpty == false ? grokBinary! : "grok",
            cwd: state.workspaces.values.first?.cwd ?? NSHomeDirectory(),
            environment: [:]
        )
        let refresher = tokenSaverAccountUsageRefresher

        tokenSaverAccountUsageRefreshTask = Task { [weak self] in
            let usages = await Self.refreshAccountUsageWithTimeout(refresher: refresher, request: request)
            await MainActor.run {
                guard let self else { return }
                for usage in usages {
                    self.recordTokenSaverAccountUsage(usage)
                    EventBus.shared.publish(kind: "agent.account.usage",
                        payload: .object(Self.accountUsagePayload(reason: reason, usage: usage)))
                }
                self.publishTokenSaverAccountUsageRefresh(
                    state: "finished",
                    reason: reason,
                    detail: usages.isEmpty ? "empty" : nil,
                    providers: usages.map(\.provider.rawValue)
                )
                self.tokenSaverAccountUsageRefreshTask = nil
            }
        }
    }

    static func refreshAccountUsageWithTimeout(
        refresher: TokenSaverAccountUsageRefreshing,
        request: TokenSaverAccountUsageRefreshRequest,
        timeoutNanoseconds: UInt64 = 60_000_000_000
    ) async -> [AssistantAccountUsage] {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            var watchdog: Task<Void, Never>?
            func resume(_ usages: [AssistantAccountUsage]) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                watchdog?.cancel()
                continuation.resume(returning: usages)
            }

            let work = Task.detached {
                let usages = await refresher.refreshAccountUsage(request)
                resume(usages)
            }
            watchdog = Task.detached {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                work.cancel()
                resume([])
            }
        }
    }

    private func publishTokenSaverAccountUsageRefresh(
        state: String,
        reason: String,
        detail: String?,
        providers: [String] = []
    ) {
        let payload = Self.accountUsageRefreshPayload(
            state: state,
            reason: reason,
            detail: detail,
            providers: providers,
            refreshCount: tokenSaverAccountUsageRefreshCount
        )
        EventBus.shared.publish(kind: "agent.account.usage.refresh", payload: .object(payload))
    }

    /// Pure builder for the `agent.account.usage` event payload.
    ///
    /// WHY: the payload is constructed in two call sites (run-time event and
    /// refresh path). Extracting the builder lets golden contract tests pin
    /// the field names and types so silent schema drift fails a mac test.
    /// `threadId` is present only in the run-time path; `reason` only in the
    /// refresh path — both are optional.
    nonisolated static func accountUsagePayload(
        threadId: String? = nil,
        reason: String? = nil,
        usage: AssistantAccountUsage
    ) -> [String: JSONValue] {
        var p: [String: JSONValue] = [
            "provider": .string(usage.provider.rawValue),
            "weekly_used_percent": .number(usage.weeklyUsedPercent),
            "weekly_window_duration_minutes": usage.weeklyWindowDurationMinutes.map { .number(Double($0)) } ?? .null,
            "weekly_resets_at_ms": usage.weeklyResetsAtMs.map { .number(Double($0)) } ?? .null,
            "current_session_used_percent": usage.currentSessionUsedPercent.map { .number($0) } ?? .null,
            "current_session_resets_at_ms": usage.currentSessionResetsAtMs.map { .number(Double($0)) } ?? .null
        ]
        if let threadId { p["thread_id"] = .string(threadId) }
        if let reason   { p["reason"]    = .string(reason)   }
        return p
    }

    /// Pure builder for the `agent.account.usage.refresh` event payload.
    ///
    /// WHY: same extraction rationale as `accountUsagePayload` — lets a golden
    /// test pin `state`/`reason`/`refresh_count`/`detail`/`providers` field
    /// names independently of the private emit function.
    nonisolated static func accountUsageRefreshPayload(
        state: String,
        reason: String,
        detail: String?,
        providers: [String],
        refreshCount: Int
    ) -> [String: JSONValue] {
        var p: [String: JSONValue] = [
            "state": .string(state),
            "reason": .string(reason),
            "refresh_count": .number(Double(refreshCount))
        ]
        if let detail { p["detail"] = .string(detail) }
        if !providers.isEmpty { p["providers"] = .array(providers.map { .string($0) }) }
        return p
    }

    /// Reuse one client per live sidecar (base URL + bearer token). Rebuilds
    /// only when the service (re)starts with a new endpoint or token.
    private func currentDistillClient() -> DistillServiceClient? {
        if let distillClientOverrideForTesting { return distillClientOverrideForTesting }
        guard case .running(let ready) = tokenSaverDistillServiceController.status,
              let token = tokenSaverDistillServiceController.bearerToken else {
            cachedDistillClientKey = nil
            let staleClient = cachedDistillClient
            cachedDistillClient = nil
            staleClient?.invalidate()
            return nil
        }
        let key = "\(ready.baseURL)#\(token)"
        if cachedDistillClientKey == key, let client = cachedDistillClient {
            return client
        }
        guard let client = DistillServiceClient(ready: ready, authToken: token) else {
            return nil
        }
        let oldClient = cachedDistillClient
        cachedDistillClientKey = key
        cachedDistillClient = client
        oldClient?.invalidate()
        return client
    }

    /// Token Saver prompt compression. Returns the distilled text to send to the
    /// provider, or the original prompt unchanged when Token Saver is off, the
    /// prompt is too small, the sidecar is unavailable, compression doesn't
    /// help, or anything fails. Every real compression is measured and written
    /// to the local savings ledger. Fail-open by contract.
    /// Seconds since this thread's last provider turn, from provider_session_runtime
    /// staleness (a heuristic — that table has no billed-cache columns). nil when there
    /// is no prior turn, which the gate treats as COLD (never wrongly skip a fresh prompt).
    private func secondsSinceLastTurn(threadId: AgentThreadID) -> Double? {
        guard let runtime = try? providerSessionRuntimeRepo.get(threadId: threadId) else { return nil }
        return max(0, Date().timeIntervalSince(runtime.updatedAt))
    }

    func tokenSaverCompress(prompt: String, provider: AgentProvider, threadId: AgentThreadID, cacheState: String = "prompt") async -> String {
        guard SettingsStore(db: db).load().tokenSaverEnabled else { return prompt }
        // NetPositiveGate (G3): there is no app-side cached prefix to preserve (resume sends
        // the full wrapped prompt), so this is a numeric decision — compress the new-turn
        // argv only when it is large enough AND the session is not a warm follow-up.
        let gate = NetPositiveGate(floorCharacters: Self.tokenSaverMinCompressChars, warmResumeTTLSeconds: 300)
        let secondsSinceLastTurn = secondsSinceLastTurn(threadId: threadId)
        guard gate.shouldCompress(inputCharacters: prompt.count, secondsSinceLastTurn: secondsSinceLastTurn) else {
            return prompt
        }
        let skipKey = DistillResultCacheKey(request: DistillRequest(
            mode: .longText,
            priority: .interactive,
            input: prompt,
            maxOutputCharacters: max(512, prompt.count)
        ))
        if tokenSaverPromptSkipSetContains(skipKey) {
            return prompt
        }
        let diffWindowed = tokenSaverDiffPromptCandidate(prompt)
        // Non-lossy dedup pre-pass (P4): collapse exact-duplicate large blocks within the
        // prompt to a model-readable "identical to block above" pointer. The model keeps
        // full information (content once + a pointer it understands), so this is safe to
        // send AND a win even if the model compression step is unavailable.
        let dedupeProbe = DistillBlockDeduper.dedupe(prompt)
        let deduped: String
        if dedupeProbe.nearDedupedBlocks > 0, prompt.utf8.count >= 8_192,
           let handle = try? ReversibleContentStore(db: db).store(prompt) {
            deduped = DistillBlockDeduper
                .dedupe(prompt, originalHandleMarker: ReversibleContentStore.marker(for: handle))
                .output
        } else {
            deduped = dedupeProbe.output
        }
        let deterministicCandidate = [diffWindowed, deduped]
            .compactMap { $0 }
            .filter { $0.count < prompt.count }
            .min { $0.count < $1.count }
            ?? prompt

        // Adopt `candidate` only if it beats the ORIGINAL prompt; record honest end-to-end
        // savings (original -> final), tagged with the caller's cache_state AND the engine
        // that produced the win (deterministic pre-pass vs the model) so the Token Saver
        // breakdown attributes per technique.
        func adopt(_ candidate: String, stage: TokenSaverRouteStage) -> String {
            guard candidate.count < prompt.count else {
                self.tokenSaverPromptSkipSet[skipKey] = Date()
                return prompt
            }
            let inputTokens = TokenEstimator.estimate(prompt)
            let outputTokens = TokenEstimator.estimate(candidate)
            recordTokenSaverSidecarSavings(
                provider: provider,
                mode: DistillMode.longText.rawValue,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                savedTokens: max(inputTokens - outputTokens, 0),
                cacheState: cacheState,
                routeStage: stage
            )
            return candidate
        }

        guard let client = currentDistillClient() else {
            // No model service: deterministic pre-passes still fail open and can save tokens.
            return deterministicCandidate.count < prompt.count ? adopt(deterministicCandidate, stage: .deterministic) : prompt
        }
        let request = DistillRequest(
            mode: .longText,
            priority: .interactive,
            input: deterministicCandidate,
            maxOutputCharacters: max(512, deterministicCandidate.count)
        )
        do {
            let response = try await client.distill(request)
            let modelOutput = response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? deterministicCandidate : response.output
            let literalSafeModelOutput = LiteralPreservation.guarded(original: prompt, compressed: modelOutput).droppedLiteral == nil
                ? modelOutput
                : deterministicCandidate
            // Pick the smaller of {model output, deterministic pre-pass}, then adopt only if it beats the original.
            let modelWon = literalSafeModelOutput.count < deterministicCandidate.count
            let best = modelWon ? literalSafeModelOutput : deterministicCandidate
            // Attribute to the engine that actually produced the adopted text: the
            // sidecar's reported route when the model output won, else the deterministic pre-pass.
            let stage: TokenSaverRouteStage = modelWon ? (response.routeStage ?? .llmMLX) : .deterministic
            return adopt(best, stage: stage)
        } catch {
            NSLog("RemoteCode Token Saver compression skipped (provider=\(provider.rawValue)): \(error)")
            // Fail-open to the deterministic pre-pass if it helped, else the original.
            return deterministicCandidate.count < prompt.count ? adopt(deterministicCandidate, stage: .deterministic) : prompt
        }
    }

    private func tokenSaverDiffPromptCandidate(_ prompt: String) -> String? {
        guard DiffCrusher.looksLikeDiff(prompt),
              let windowed = DiffCrusher.window(prompt) else {
            return nil
        }
        do {
            let handle = try ReversibleContentStore(db: db).store(prompt)
            let marker = ReversibleContentStore.marker(for: handle)
            let candidate = """
            \(windowed)

            \(marker) full original diff available via rc_retrieve(\(handle)).
            """
            return candidate.count < prompt.count ? candidate : nil
        } catch {
            NSLog("RemoteCode Token Saver diff prompt windowing skipped: \(error)")
            return nil
        }
    }

    private func tokenSaverPromptSkipSetContains(_ key: DistillResultCacheKey) -> Bool {
        guard let insertedAt = tokenSaverPromptSkipSet[key] else { return false }
        if Date().timeIntervalSince(insertedAt) > Self.tokenSaverPromptSkipSetTTL {
            tokenSaverPromptSkipSet.removeValue(forKey: key)
            return false
        }
        return true
    }

    /// P5 SessionLearn: on a failed run, mine a deterministic correction rule from the
    /// run's error into the managed instructions region (FIFO-capped, appended at the file
    /// bottom so the upper instruction prefix stays byte-stable). Off by default; best-effort.
    func recordSessionLearnFromRun(runId: AgentRunID, status: AgentRunStatus) {
        let inputTokens = sessionLearnInputTokensByRun[runId] ?? 0
        sessionLearnInputTokensByRun.removeValue(forKey: runId)
        guard SettingsStore(db: db).load().sessionLearnEnabled else { return }
        guard SessionLearnRegion.shouldMine(runFailed: status == .failed, inputTokens: inputTokens) else { return }
        guard let run = try? runRepo.get(id: runId) else { return }
        let error = (run.errorMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !error.isEmpty else { return }
        let firstLine = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error
        let rule = "Avoid repeating the approach that failed with: \(String(firstLine.prefix(160))). Verify preconditions before retrying."
        let files = sessionLearnInstructionFilesOverrideForTesting
            ?? [AgentSkillInstaller.defaultClaudeInstructionsURL(), AgentSkillInstaller.defaultCodexInstructionsURL()]
        for url in files {
            try? SessionLearnRegion(fileURL: url).append(rule)
        }
    }

    func tokenSaverHumanizeSR1Response(_ response: String, provider: AgentProvider, threadId: AgentThreadID, runId: AgentRunID? = nil) async -> String {
        guard SR1ResponseDetector.isSR1(response) else { return response }

        let targetLanguage = inferredUserLanguage(threadId: threadId)
        let fallback = Self.fallbackHumanizeSR1(response, targetLanguage: targetLanguage)
        guard let client = await currentDistillClientWaitingForStartup() else {
            NSLog("RemoteCode Token Saver SR1 humanize fallback used (provider=\(provider.rawValue)): distill client unavailable (status=\(Self.describe(tokenSaverDistillServiceController.status)))")
            recordTokenSaverSR1HumanizeSavings(sr1: response, humanized: fallback, provider: provider)
            return fallback
        }

        let input = """
        TARGET_LANGUAGE: \(targetLanguage)
        USER_FACING_RULES:
        Expand any SR1 variables such as #g1 using their definitions from SR1_RESPONSE before answering.
        Never show unresolved # variables to the user.

        SR1_RESPONSE:
        \(response)
        """
        let request = DistillRequest(
            mode: .sr1Humanize,
            priority: .interactive,
            input: input,
            maxOutputCharacters: max(1_200, min(12_000, response.count * 4))
        )
        do {
            let translated = try await client.distill(request).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let expanded = SR1ResponseDetector.expandVariables(in: translated, from: response)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let humanized: String
            if !expanded.isEmpty, !SR1ResponseDetector.isSR1(expanded) {
                humanized = expanded
            } else {
                humanized = fallback
            }
            recordTokenSaverSR1HumanizeSavings(sr1: response, humanized: humanized, provider: provider)
            return humanized
        } catch {
            NSLog("RemoteCode Token Saver SR1 humanize fallback used (provider=\(provider.rawValue)): \(error)")
            recordTokenSaverSR1HumanizeSavings(sr1: response, humanized: fallback, provider: provider)
            return fallback
        }
    }

    private func currentDistillClientWaitingForStartup() async -> DistillServiceClient? {
        if let client = currentDistillClient() {
            return client
        }
        guard SettingsStore(db: db).load().tokenSaverEnabled else {
            return nil
        }

        startTokenSaverDistillServiceIfEligible()
        for _ in 0..<Self.tokenSaverDistillStartupPolls {
            if let client = currentDistillClient() {
                return client
            }
            if case .blocked = tokenSaverDistillServiceController.status {
                break
            }
            if case .failed = tokenSaverDistillServiceController.status {
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return currentDistillClient()
    }

    private static func describe(_ status: TokenSaverDistillServiceStatus) -> String {
        switch status {
        case .notStarted:
            return "notStarted"
        case .blocked(let reason):
            return "blocked:\(reason)"
        case .starting:
            return "starting"
        case .running(let ready):
            return "running:\(ready.runtime):\(ready.port)"
        case .failed(let reason):
            return "failed:\(reason)"
        }
    }

    private func inferredUserLanguage(threadId: AgentThreadID) -> String {
        let recent = (try? messageRepo.listRecent(threadId: threadId, limit: 20)) ?? []
        let latestUserText = recent.last(where: { $0.role == .user })?.content ?? ""
        if Self.looksPortuguese(latestUserText) {
            return "Portuguese (Brazil)"
        }
        if Self.looksSpanish(latestUserText) {
            return "Spanish"
        }
        if Locale.preferredLanguages.first?.lowercased().hasPrefix("pt") == true {
            return "Portuguese (Brazil)"
        }
        return "English"
    }

    private static func looksPortuguese(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        if lower.range(of: #"[áàâãçéêíóôõú]"#, options: .regularExpression) != nil {
            return true
        }
        let markers = [
            " voce ", " você ", " nao ", " não ", " corrija ", " teste ", " testes ",
            " linguagem ", " usuario ", " usuário ", " tokens salvos ", " esta ", " está ",
            " portugues ", " português ", " responda ", " explique ", " crie ", " criar ",
            " jogo ", " pt-br ", " brasil "
        ]
        return markers.contains { lower.contains($0) }
    }

    private static func looksSpanish(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        if lower.range(of: #"[¿¡ñ]"#, options: .regularExpression) != nil {
            return true
        }
        let markers = [" por favor ", " gracias ", " respuesta ", " usuario ", " prueba "]
        return markers.contains { lower.contains($0) }
    }

    private static func fallbackHumanizeSR1(_ response: String, targetLanguage: String) -> String {
        let portuguese = targetLanguage.localizedCaseInsensitiveContains("Portuguese")
        let spanish = targetLanguage.localizedCaseInsensitiveContains("Spanish")
        let labels: [Character: String]
        if portuguese {
            labels = ["S": "Estado", "C": "Contexto", "D": "Acao", "R": "Risco", "O": "Resultado", "N": "Nao fazer", "P": "Prova"]
        } else if spanish {
            labels = ["S": "Estado", "C": "Contexto", "D": "Accion", "R": "Riesgo", "O": "Resultado", "N": "No hacer", "P": "Prueba"]
        } else {
            labels = ["S": "State", "C": "Context", "D": "Action", "R": "Risk", "O": "Outcome", "N": "Do not do", "P": "Proof"]
        }

        let lines = response
            .split(whereSeparator: \.isNewline)
            .flatMap { raw -> [String] in
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return [] }
                let lower = line.lowercased()
                guard lower != "sr1",
                      lower != "dict",
                      lower != "dict:",
                      !lower.hasPrefix("dict:"),
                      !lower.hasPrefix("s=state"),
                      !lower.hasPrefix("c=context"),
                      !lower.hasPrefix("d=action"),
                      !lower.hasPrefix("r=risk"),
                      !lower.hasPrefix("o=outcome"),
                      !lower.hasPrefix("n=no-go"),
                      !lower.hasPrefix("p=proof") else {
                    return []
                }
                let segments = SR1ResponseDetector.parseSemanticSegments(line)
                guard !segments.isEmpty else {
                    return [line]
                }
                return segments.map { parsed in
                    guard let label = labels[parsed.prefix] else { return parsed.content }
                    return "\(label): \(parsed.content)"
                }
            }
        if lines.isEmpty {
            if portuguese { return "Nao consegui expandir a resposta comprimida." }
            if spanish { return "No pude expandir la respuesta comprimida." }
            return "I could not expand the compressed response."
        }
        return SR1ResponseDetector.expandVariables(in: lines.joined(separator: "\n"), from: response)
    }

    private func recordTokenSaverUsage(_ usage: AssistantTokenUsage, runId: AgentRunID) {
        guard usage.totalTokens > 0,
              let run = try? runRepo.get(id: runId) else {
            return
        }
        sessionLearnInputTokensByRun[runId, default: 0] += max(0, usage.inputTokens)
        let settings = SettingsStore(db: db).load()
        // Record only the real provider-billed token count. Savings are now
        // measured at the local sidecar call sites (`| distill` command-output
        // compression and SR1 humanization), never synthesized from provider
        // token-usage events.
        let eligibleRuns = settings.tokenSaverEnabled ? 1 : 0

        // Accumulate into the pending buffer instead of writing to disk per event.
        // A debounced Task will flush to disk after the quiet window; the run-end
        // and app-quit paths force an immediate flush so no tokens are ever lost.
        if var pending = pendingUsageByRun[runId] {
            pending.totalTokens += usage.totalTokens
            pending.billedTokenUnits += usage.billedTotalTokenUnits
            pending.eligibleRuns += eligibleRuns
            pending.currentSessionTokens = max(pending.currentSessionTokens, usage.totalTokens)
            if let window = usage.contextWindow {
                pending.currentSessionLimitTokens = max(pending.currentSessionLimitTokens ?? 0, window)
            }
            pendingUsageByRun[runId] = pending
        } else {
            pendingUsageByRun[runId] = PendingUsage(
                provider: run.provider,
                totalTokens: usage.totalTokens,
                billedTokenUnits: usage.billedTotalTokenUnits,
                eligibleRuns: eligibleRuns,
                currentSessionTokens: usage.totalTokens,
                currentSessionLimitTokens: usage.contextWindow
            )
        }
        schedulePendingUsageFlush()
    }

    /// Schedules a debounced flush; resets the timer on each call so many rapid
    /// events coalesce into a single disk write after the quiet window.
    private func schedulePendingUsageFlush() {
        pendingUsageFlushTask?.cancel()
        pendingUsageFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.tokenSaverUsageDebounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.flushPendingTokenSaverUsage()
            }
        }
    }

    /// Writes all accumulated usage to disk off the main thread.
    /// Pass a specific `runId` to flush only that run (used at run-end);
    /// pass `nil` to flush every pending run (used at app quit).
    func flushPendingTokenSaverUsage(runId: AgentRunID? = nil) {
        let keysToFlush: [AgentRunID]
        if let runId {
            guard pendingUsageByRun[runId] != nil else { return }
            keysToFlush = [runId]
        } else {
            keysToFlush = Array(pendingUsageByRun.keys)
        }
        guard !keysToFlush.isEmpty else { return }

        // Cancel the debounce timer -- the explicit flush supersedes it.
        if runId == nil {
            pendingUsageFlushTask?.cancel()
            pendingUsageFlushTask = nil
        }

        let snapshots: [(AgentRunID, PendingUsage)] = keysToFlush.compactMap { key in
            guard let pending = pendingUsageByRun.removeValue(forKey: key) else { return nil }
            return (key, pending)
        }
        guard !snapshots.isEmpty else { return }

        let appSupportDir = appSupportDirectory
        backgroundWriterQueue.async { [weak self] in
            for (_, pending) in snapshots {
                do {
                    _ = try TokenSaverUsageStore(appSupportDirectory: appSupportDir).record(
                        provider: pending.provider,
                        actualProviderTokens: pending.totalTokens,
                        estimatedRawTokens: pending.totalTokens,
                        actualProviderBilledTokenUnits: pending.billedTokenUnits,
                        estimatedRawBilledTokenUnits: pending.billedTokenUnits,
                        eligibleRuns: pending.eligibleRuns,
                        currentSessionTokens: pending.currentSessionTokens,
                        currentSessionLimitTokens: pending.currentSessionLimitTokens
                    )
                } catch {
                    NSLog("RemoteCode Token Saver usage record failed: \(error)")
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.scheduleTokenSaverUsageChangedNotification()
            }
        }
    }

    private func scheduleTokenSaverUsageChangedNotification(now: Date = Date()) {
        let elapsed = now.timeIntervalSince(tokenSaverLastUsageNotificationAt)
        guard elapsed < Self.tokenSaverUsageNotificationMinimumInterval else {
            tokenSaverLastUsageNotificationAt = now
            Task { @MainActor in
                NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
            }
            return
        }
        guard tokenSaverUsageNotificationTask == nil else { return }
        let delay = Self.tokenSaverUsageNotificationMinimumInterval - elapsed
        tokenSaverUsageNotificationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                self.tokenSaverUsageNotificationTask = nil
                self.tokenSaverLastUsageNotificationAt = Date()
                NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
            }
        }
    }

    private func recordTokenSaverSidecarSavings(
        provider: AgentProvider,
        mode: String,
        inputTokens: Int,
        outputTokens: Int,
        savedTokens: Int,
        cacheState: String = "unknown",
        routeStage: TokenSaverRouteStage? = nil
    ) {
        guard SettingsStore(db: db).load().tokenSaverEnabled else { return }
        do {
            _ = try tokenSaverSavingsRepo.record(
                provider: provider.rawValue,
                mode: TokenSaverEngineLabel.mode(base: mode, stage: routeStage),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                savedTokens: savedTokens,
                cacheState: cacheState
            )
            NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
        } catch {
            NSLog("RemoteCode Token Saver sidecar savings persist failed: \(error)")
        }
    }

    private func recordTokenSaverSR1HumanizeSavings(sr1: String, humanized: String, provider: AgentProvider) {
        let estimate = TokenSaverSR1SavingsEstimator.estimate(sr1: sr1, humanized: humanized)
        recordTokenSaverSidecarSavings(
            provider: provider,
            mode: "sr1-humanize",
            inputTokens: estimate.inputTokens,
            outputTokens: estimate.outputTokens,
            savedTokens: estimate.savedTokens
        )
    }

    private var pendingSave: DispatchWorkItem?

    /// Serial utility queue for all event-log appends and snapshot writes.
    /// Keeping DB I/O off the main/publish thread avoids priority inversion
    /// during high-frequency event bursts. All writes must be dispatched here.
    public let backgroundWriterQueue = DispatchQueue(
        label: "io.remotecode.app.writer",
        qos: .utility
    )

    /// Cadence: prune the event log every N appends instead of on every append.
    /// Reducing prune frequency amortises the DELETE cost across many inserts.
    public static let eventLogPruneInterval: Int = 50

    /// Pure cadence gate: true iff `appendCount` is a positive multiple of
    /// `interval`. Zero-count never prunes (avoids prune-on-first-write).
    /// `interval` must be >= 1; values < 1 are treated as 1 (always prune).
    nonisolated public static func shouldPrune(appendCount: Int, interval: Int) -> Bool {
        let n = max(1, interval)
        return appendCount > 0 && appendCount % n == 0
    }

    /// Wire EventBus.shared.persister to append to the event log off-main,
    /// pruning on a counter cadence rather than on every append.
    /// In production AppDelegate overrides this after init; in tests (no
    /// AppDelegate) this persister is the active one and exercises the queue.
    ///
    /// The append counter is a local closure variable guarded by the serial
    /// backgroundWriterQueue, so no lock or @MainActor access is needed.
    public func wireBackgroundPersister() {
        let log = eventLog
        let queue = backgroundWriterQueue
        // Counter is local to the closure; only ever mutated on `queue` (serial).
        var appendCount = 0
        EventBus.shared.persister = { ev in
            // surface.output is high-frequency binary; never persisted (same
            // predicate as AppDelegate.shouldPersistEvent).
            guard ev.kind != "surface.output" else { return }
            let payloadData = (try? JSONEncoder().encode(ev.payload)) ?? Data("null".utf8)
            let json = String(data: payloadData, encoding: .utf8) ?? "null"
            queue.async {
                _ = try? log.append(seq: ev.seq, kind: ev.kind, payloadJSON: json)
                appendCount += 1
                // shouldPrune gate: in future, move the bounded-log DELETE out of
                // EventLogRepository.append and call it here when shouldPrune returns
                // true. The counter is live now so the cadence logic is in place.
                _ = AppContext.shouldPrune(appendCount: appendCount,
                                           interval: AppContext.eventLogPruneInterval)
            }
        }
    }

    public func apply(_ action: LayoutAction) throws {
        state = try reducer.reduce(state, action)
        // Every layout mutation (workspace create/close/select, surface
        // add/close/split/move, etc.) schedules a debounced snapshot
        // write so workspaces and tabs survive a restart even if the app
        // is killed before a clean quit.
        scheduleSnapshotSave()
    }

    public func scheduleSnapshotSave(delay: TimeInterval = 0.4) {
        pendingSave?.cancel()
        // Capture layout state on main, then write to DB off-main so the
        // debounced save does not block the main thread during event bursts.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snap = SessionSnapshot(layout: self.state)
            let repo = self.snapshotRepo
            self.backgroundWriterQueue.async { [weak self] in
                do {
                    try repo.save(snap)
                } catch {
                    Task { @MainActor [weak self] in
                        self?.recordPersistenceWriteError(error, operation: "Session layout")
                    }
                }
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func saveSnapshot() {
        pendingSave?.cancel()
        pendingSave = nil
        let snap = SessionSnapshot(layout: state)
        do {
            try snapshotRepo.save(snap)
        } catch {
            recordPersistenceWriteError(error, operation: "Session layout")
        }
    }

    func recordPersistenceWriteError(_ error: Error, operation: String) {
        let message = Self.persistenceWriteErrorMessage(operation: operation, error: error)
        persistenceWriteErrorMessage = message
        onPersistenceWriteError?(message)
    }

    static func persistenceWriteErrorMessage(operation: String, error: Error) -> String {
        "\(operation) could not be saved: \(error.localizedDescription)."
    }

    /// Drain backgroundWriterQueue synchronously. Use in tests that call
    /// saveSnapshot() / wireBackgroundPersister() and then immediately read
    /// back from a fresh AppContext; ensures all queued writes have landed
    /// before the assertion.
    public func flushWriterQueue() {
        backgroundWriterQueue.sync {}
    }

    @discardableResult
    public func reapIdleProviderSessions(now: Date = Date(), idleAge: TimeInterval = 6 * 60 * 60) throws -> ProviderSessionReaperResult {
        let cutoff = now.addingTimeInterval(-idleAge)
        let activeThreadIds = Set(
            try threadRepo.list().filter { thread in
                thread.status == .running
            }.map(\.id)
        )
        let reaper = ProviderSessionReaper(
            sessionRepo: providerSessionRuntimeRepo,
            pendingCallbackRepo: providerPendingCallbackRepo
        ) {
            activeThreadIds
        }
        let result = try reaper.reapIdleSessions(olderThan: cutoff)
        // Marking the session stopped in the DB does not free the underlying
        // provider process (codex app-server / node bridge). Release every
        // reaped thread's adapter session so the idle processes are actually
        // terminated. F19: use the lifecycle-silent release — routing this
        // through stopRun(threadId:) broadcast a spurious "Thread cancelled"
        // for threads that finished hours ago and could even respawn a provider
        // process for a dead thread via the recover-then-interrupt fallback.
        for threadId in result.stoppedThreadIds {
            coordinator.releaseProviderSession(threadId: threadId)
        }
        return result
    }

    /// A reap candidate, reduced to the only two facts that decide eligibility:
    /// the thread's last-activity timestamp and whether the thread is still
    /// active. Pure, DB-free, so the selection rule can be tested directly.
    public struct ReapCandidate: Sendable, Equatable {
        public let threadId: AgentThreadID
        public let lastActivityAt: Date
        public let isActive: Bool

        public init(threadId: AgentThreadID, lastActivityAt: Date, isActive: Bool) {
            self.threadId = threadId
            self.lastActivityAt = lastActivityAt
            self.isActive = isActive
        }
    }

    /// Pure selection mirroring ProviderSessionReaper.reapIdleSessions: a thread
    /// is reap-eligible iff it is idle strictly past the cutoff AND not active.
    /// The returned set is exactly the threads that get marked stopped AND have
    /// adapter.stopSession called on them.
    nonisolated public static func reapEligibleThreadIds(
        candidates: [ReapCandidate],
        idleCutoff: Date
    ) -> [AgentThreadID] {
        candidates
            .filter { !$0.isActive && $0.lastActivityAt < idleCutoff }
            .map(\.threadId)
    }
}
