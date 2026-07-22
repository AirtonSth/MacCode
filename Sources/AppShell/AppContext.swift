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

public enum TokenSaverRolloverError: Error, LocalizedError, Equatable {
    case missingProjectScope
    case laneUnavailable(String)
    case parentBusy(AgentRunStatus)
    case parentChanged

    public var errorDescription: String? {
        switch self {
        case .missingProjectScope:
            return "Token Saver rollover requires a workspace and project scope."
        case .laneUnavailable(let reason):
            return "Token Saver rollover is unavailable: \(reason)"
        case .parentBusy(let status):
            return "Token Saver rollover requires an inactive parent thread; current state is \(status.rawValue)."
        case .parentChanged:
            return "Token Saver rollover was cancelled because the parent thread changed during capsule creation."
        }
    }
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
        // PTY EOF closes the descriptor before the asynchronous reaper owns an
        // authoritative wait status. Keep the correlated run registered until
        // that reaper publishes either a status, a consumed PID, or a terminal
        // failure reason; otherwise a provisional EOF becomes a false failure.
        let awaitsReaperStatus = health.exitStatus == nil
            && health.childPID != nil
            && health.terminalDeadReason == "process_exited"
        guard !awaitsReaperStatus else { return nil }
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
    private final class WeakReference: @unchecked Sendable {
        weak var value: AppContext?
    }

    /// Single source of truth for constructing the `.claude` provider adapter
    /// from the resolved engine, so init and the Settings live-swap can never
    /// diverge. `.cli` is the dependency-minimal default; `.sdk` is the advanced
    /// opt-in that requires the Node runtime bridge.
    static func makeClaudeAdapter(engine: ClaudeEngine, binary: String?) -> AgentProviderAdapter {
        switch engine {
        case .cli: return ClaudeStreamingCLIAdapter(binaryNameOverride: binary)
        case .sdk: return ClaudeAgentSDKBridgeAdapter(binaryNameOverride: binary)
        }
    }

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
    public let tokenSaverAttemptLedger: TokenSaverAttemptLedger
    public let tokenSaverSessionLearnRepo: TokenSaverSessionLearnRepository
    public let tokenSaverLaneStateRepo: TokenSaverLaneStateRepository
    public let tokenSaverRolloverRepo: TokenSaverRolloverCapsuleRepository
    public let tokenSaverProjectDataRepo: TokenSaverProjectDataRepository
    public private(set) var tokenSaverLifecycleDegradedReason: String?
    public let privateNotificationBridge: PrivateNotificationBridge
    public let liveActivityHostIdentity: LiveActivityHostIdentity
    public let liveActivityAcceptanceOutbox: LiveActivityAcceptanceOutbox
    public let liveActivitySyncCoordinator: LiveActivitySyncCoordinator
    public let tokenSaverDistillServiceController: TokenSaverDistillServiceController
    let projectScriptRuns = ProjectScriptRunRegistry()
    public private(set) var remoteCodeOrchestrateInstallResult: RemoteCodeOrchestrateInstallResult?
    public private(set) var remoteCodeOrchestrateStatus: RemoteCodeOrchestrateStatus?
    public private(set) var remoteCodeOrchestrateInstallError: String?
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
    var tokenSaverRolloverBeforeCommitForTesting: (() throws -> Void)?
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
        TerminalSurface.replayPendingHistoryDeletes(repository: self.terminalOutputRepo)
        self.providerSessionRuntimeRepo = ProviderSessionRuntimeRepository(db: db)
        self.commandReceiptRepo = CommandReceiptRepository(db: db)
        self.providerPendingCallbackRepo = ProviderPendingCallbackRepository(db: db)
        self.proposedPlanRepo = AgentProposedPlanRepository(db: db)
        self.turnCheckpointRepo = AgentTurnCheckpointRepository(db: db)
        self.tokenSaverSavingsRepo = TokenSaverSavingsRepository(db: db)
        self.tokenSaverAttemptLedger = TokenSaverAttemptLedger(db: db)
        self.tokenSaverSessionLearnRepo = TokenSaverSessionLearnRepository(db: db)
        self.tokenSaverLaneStateRepo = TokenSaverLaneStateRepository(db: db)
        self.tokenSaverRolloverRepo = TokenSaverRolloverCapsuleRepository(db: db)
        self.tokenSaverProjectDataRepo = TokenSaverProjectDataRepository(db: db)
        do {
            _ = try self.tokenSaverProjectDataRepo.performLifecycleSweep()
        } catch {
            let reason = "lifecycle_sweep_failed: \((error as NSError).localizedDescription)"
            self.tokenSaverLifecycleDegradedReason = reason
            NSLog("RemoteCode Token Saver launch lifecycle sweep entered degraded verbatim mode: \(reason)")
        }
        let privatePushTargetStore = PrivatePushTargetStore(repo: self.settingsRepo)
        let privateNotificationBridge = PrivateNotificationBridge(
            accountStore: PrivateAccountSessionStore(repo: self.settingsRepo),
            pushTargetStore: privatePushTargetStore
        )
        self.privateNotificationBridge = privateNotificationBridge
        let liveActivityIdentity = try LiveActivityIdentityStore.beginBoot(settings: self.settingsRepo)
        self.liveActivityHostIdentity = liveActivityIdentity
        let settingsRepo = self.settingsRepo
        let liveActivityAcceptanceOutbox = LiveActivityAcceptanceOutbox(
            store: LiveActivityAcceptanceOutboxStore(settings: settingsRepo),
            onError: { error, delivery in
                NSLog("Live Activity outbox error key=\(delivery?.idempotencyKey ?? "unknown"): \(error)")
            }
        ) { record in
            try await privateNotificationBridge.sendLiveActivityAcceptance(record)
        }
        self.liveActivityAcceptanceOutbox = liveActivityAcceptanceOutbox
        // Survive Mac app updates/relaunches: keep stored iOS push-to-start
        // tokens bound to this host identity before the sync coordinator boots.
        let reboundPushToStart = (try? privatePushTargetStore.rebindDurableTokens(
            toHostServerId: liveActivityIdentity.serverId
        )) ?? []
        self.liveActivitySyncCoordinator = LiveActivitySyncCoordinator(
            serverId: liveActivityIdentity.serverId,
            bootEpoch: liveActivityIdentity.bootEpoch,
            initialActivityGeneration: liveActivityIdentity.activityGeneration,
            initialTokenTargets: try privatePushTargetStore.records(),
            registerToken: { target in
                try privatePushTargetStore.upsert(target)
                try await privateNotificationBridge.registerLiveActivityTokenV2(target)
            },
            onTokenRegistrationError: { error, target in
                NSLog("Live Activity token registration failed device=\(target.deviceId): \(error)")
            },
            onDeliveryError: { error, delivery in
                NSLog("Live Activity durable acceptance failed key=\(delivery.idempotencyKey): \(error)")
            }
        ) { delivery in
            try LiveActivityIdentityStore.persistActivityGeneration(
                delivery.activityGeneration,
                settings: settingsRepo
            )
            let targets = try privateNotificationBridge.acceptanceTargets(for: delivery)
            try liveActivityAcceptanceOutbox.accept(delivery, targets: targets)
        }
        // Re-publish push-to-start tokens to the backend so a post-update Mac can
        // open Live Activities without the user launching iOS first.
        for target in reboundPushToStart {
            do {
                _ = try liveActivitySyncCoordinator.submitTokenRegistration(target)
            } catch {
                NSLog("Live Activity durable token restore failed device=\(target.deviceId): \(error)")
            }
        }
        self.tokenSaverDistillServiceController = TokenSaverDistillServiceController(
            appSupportDirectory: self.appSupportDirectory
        )
        let codex = CodexAppServerAdapter(binaryNameOverride: try? settingsRepo.get("cli.codex.path"))
        let configuredClaudeBinary = try? settingsRepo.get("cli.claude.path")
        let claudeEngine = ClaudeEnginePolicy.resolve(
            setting: (try? settingsRepo.get(ClaudeEnginePolicy.settingsKey)).flatMap { $0 },
            envOverride: ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_ENABLED"]
        )
        let claude: AgentProviderAdapter = AppContext.makeClaudeAdapter(engine: claudeEngine, binary: configuredClaudeBinary)
        let grok = GrokACPAdapter(binaryNameOverride: try? settingsRepo.get("cli.grok.path"))
        let contextReference = WeakReference()
        self.coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providerSessionRepo: providerSessionRuntimeRepo,
            checkpointRepo: turnCheckpointRepo,
            orchestrationRuntime: AgentOrchestrationRuntime(
                repository: AgentOrchestrationRepository(db: db),
                costEstimator: AgentOrchestrationRuntime.productionCostEstimator
            ),
            providerSnapshotSupplier: {
                await contextReference.value?.router?.listAgentProviderSnapshots() ?? []
            },
            providerAdapters: [.codex: codex, .claude: claude, .grok: grok]
        )
        contextReference.value = self
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
        liveActivityAcceptanceOutbox.resumePending()
        try coordinator.reconcileOnLaunch()
        try? tokenSaverSavingsRepo.prune()
        self.coordinator.promptCompressor = { [weak self] prompt, provider, threadId, runId in
            guard let self else { return prompt }
            let scopedPrompt = await self.tokenSaverSessionLearnPrompt(
                prompt, provider: provider, threadId: threadId, runId: runId
            )
            return await self.tokenSaverCompress(prompt: scopedPrompt, provider: provider, threadId: threadId, runId: runId)
        }
        self.coordinator.followUpPromptCompressor = { [weak self] prompt, provider, threadId in
            guard let self else { return prompt }
            let scopedPrompt = await self.tokenSaverSessionLearnPrompt(
                prompt, provider: provider, threadId: threadId, runId: nil
            )
            return await self.tokenSaverCompress(prompt: scopedPrompt, provider: provider, threadId: threadId, cacheState: "prompt_followup")
        }
        self.coordinator.finalResponseTranslator = { [weak self] response, provider, threadId, runId in
            guard let self else { return response }
            return await self.tokenSaverHumanizeSR1Response(response, provider: provider, threadId: threadId, runId: runId)
        }
        // Recovered sessions rebuild their own request env in the coordinator, bypassing
        // providerEnvironment; feed them the same Token Saver env so distill survives resume.
        self.coordinator.recoveryEnvironmentProvider = { [weak self] provider, threadId in
            await self?.tokenSaverAgentEnvironment(provider: provider, threadId: threadId) ?? [:]
        }
        self.coordinator.runEnvironmentProvider = { [weak self] provider, threadId, base in
            await self?.tokenSaverAgentEnvironment(provider: provider, threadId: threadId, baseEnvironment: base) ?? [:]
        }
        self.coordinator.onRunPrepared = { [weak self] request, originalPrompt in
            await MainActor.run { [weak self] in
                self?.recordTokenSaverPreparedObservation(request: request, originalPrompt: originalPrompt)
            }
        }
        // T-003 Wave -1: persisted-history compaction used global raw-hash CCR
        // markers. Keep the stored event verbatim until scoped capabilities,
        // durable read-back, lifecycle limits, and an authorized reader ship.
        self.coordinator.streamPayloadCompactor = nil
        _ = try providerPendingCallbackRepo.markOpenStale(
            reason: "Provider callback state does not survive app restarts or recovered sessions. Restart the turn to continue."
        )
        // The orchestration package is app-private and independent of Token Saver. Keep
        // XCTest isolated unless a sandboxed skills home was injected explicitly.
        if !AppContext.isRunningUnitTests || agentSkillsHomeOverrideForTesting != nil {
            reconcileRemoteCodeOrchestrate()
        }
        // Managed Distill is app-private (Application Support/AgentSkills/distill) and
        // injected at runtime — never written into ~/.claude/skills or ~/.codex/skills.
        // Skip open-trigger reconcile under XCTest unless a sandboxed home was injected.
        if AppContext.shouldReconcileManagedDistillIntegration(
            isRunningUnitTests: AppContext.isRunningUnitTests,
            hasSkillsHomeOverride: agentSkillsHomeOverrideForTesting != nil,
            environment: ProcessInfo.processInfo.environment
        ) {
            reconcileManagedDistillSkills(tokenSaverEnabled: SettingsStore(db: db).load().tokenSaverEnabled)
        }
        // PERF (cold launch): do not start Distill/MLX during AppContext bootstrap.
        // Token Saver demand paths call `startTokenSaverDistillServiceIfEligible()`
        // (compress kick, SR1 wait helper, settings UI). Fail-open preserves the
        // original provider input when the sidecar is not ready yet.

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
            guard let data = try? JSONEncoder().encode(message),
                  let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .object(var object) = decoded else {
                return .null
            }
            let references = message.attachments.compactMap(AgentAttachmentReference.init)
            object["attachments"] = (try? JSONDecoder().decode(
                JSONValue.self,
                from: JSONEncoder().encode(references)
            )) ?? .array([])
            return .object(object)
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
            self?.beginTokenSaverAttempt(runId: runId)
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
            // Grok has no live `.accountUsage` stream (Claude/Codex do). Re-read
            // the local billing snapshot after each Grok run so the Token Saver
            // purple ring updates without waiting for the 5-minute periodic probe.
            if let run = try? self.runRepo.get(id: rid), run.provider == .grok {
                self.refreshGrokTokenSaverAccountUsage(reason: "run_finished")
            }
            // Drain the next queued message after ANY terminal status. A run that
            // ended .failed previously stranded queued messages (no run to pick
            // them up); drainNextQueuedAgentMessage re-checks the thread is not
            // running/pending before sending, so an unconditional drain is safe
            // and onRunFinished only fires on terminal statuses.
            Task { @MainActor in
                do {
                    try await self.router?.drainNextQueuedAgentMessage(thread: tid)
                } catch {
                    EventBus.shared.publish(kind: "agent.message.queue.failed", payload: .object([
                        "thread_id": .string(tid.value.uuidString),
                        "message": .string(String(describing: error))
                    ]))
                }
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

        // HC-1: stream terminal/surface frames to the mirror so iOS renders
        // a live terminal (not a poll). PTY bytes are base64; idle geometry
        // changes use the same monotonic per-surface sequence without bytes.
        SurfaceOutputBus.shared.sink = { frame in
            let key = frame.surfaceID.value.uuidString
            var payload: [String: JSONValue] = [
                "surface_id": .string(key),
                "seq": .number(Double(frame.sequence))
            ]
            if !frame.data.isEmpty {
                payload["base64"] = .string(frame.data.base64EncodedString())
            }
            if let rows = frame.rows, let cols = frame.cols {
                payload["rows"] = .number(Double(rows))
                payload["cols"] = .number(Double(cols))
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
                "partial_reason": health.outputPartialReason.map { .string($0) } ?? .null,
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

    /// Distill + Token Saver environment for an agent run. Distill language and
    /// `| distill` PATH are always-on for every provider (app-private skill model,
    /// same idea as remote-code-orchestrate). Workspace attribution still requires
    /// project admission when present. Single source for the normal run path and
    /// recovered-session path.
    func tokenSaverAgentEnvironment(
        provider: AgentProvider,
        threadId: AgentThreadID,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = [:]
        // Always expose managed distill CLI on PATH for every provider call.
        if managedDistillSkillInstallError == nil {
            env["RC_TOKEN_SAVER_DISTILL_HINT"] = "1"
            let managedBin = AgentSkillInstaller.defaultManagedCLIBinDirectory().path
            let currentPath = baseEnvironment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
            let pathParts = currentPath.split(separator: ":").map(String.init).filter { $0 != managedBin }
            env["PATH"] = ([managedBin] + pathParts).joined(separator: ":")
        }
        if tokenSaverProjectAdmission(threadId: threadId, lane: "deterministic_wrapper").allowed,
           let thread = try? threadRepo.get(id: threadId),
           let workspaceID = thread.workspaceId?.value.uuidString,
           let projectID = thread.projectId?.value.uuidString {
            env["RC_TOKEN_SAVER_WORKSPACE_ID"] = workspaceID
            env["RC_TOKEN_SAVER_PROJECT_ID"] = projectID
            env["RC_TOKEN_SAVER_THREAD_ID"] = threadId.value.uuidString
        }
        if provider == .claude {
            // Claude PostToolUse compression hook (sidecar HTTP). Always on when
            // managed distill installed so all Claude calls speak/compress distill.
            env["RC_TOKEN_SAVER_POST_TOOL_USE"] = "1"
            env["REMOTE_CODE_DISTILL_STATE_PATH"] = appSupportDirectory
                .appendingPathComponent("Distill", isDirectory: true)
                .appendingPathComponent("DistillCLIState.json")
                .path
        }
        return env
    }

    @discardableResult
    public func reconcileRemoteCodeOrchestrate() -> RemoteCodeOrchestrateStatus {
        let installer = makeAgentSkillInstaller()
        do {
            remoteCodeOrchestrateInstallResult = try installer.reconcileRemoteCodeOrchestrate()
            remoteCodeOrchestrateInstallError = nil
        } catch {
            NSLog("RemoteCode orchestrate package reconcile failed: \(error)")
            remoteCodeOrchestrateInstallResult = nil
            remoteCodeOrchestrateInstallError = (error as NSError).localizedDescription
        }
        let status = installer.remoteCodeOrchestrateStatus()
        remoteCodeOrchestrateStatus = status
        return status
    }

    /// Install Distill like `remote-code-orchestrate`: app-private under RemoteCode
    /// Application Support, never into `~/.claude/skills` / `~/.codex/skills` /
    /// `~/.grok/skills`. Always available for every provider call; Token Saver
    /// still owns the MLX sidecar separately.
    public func reconcileManagedDistillSkills(tokenSaverEnabled: Bool) {
        let installer = makeAgentSkillInstaller()
        do {
            // 1) App-private package (source of truth for the managed skill body).
            let appPrivate = try installer.installAppPrivateDistillSkill(
                sourceRevision: "github-main-remote-code-template-v2"
            )
            // 2) Remove any legacy per-provider home skill / AGENTS.md blocks.
            try installer.uninstallLegacyProviderDistillSkills()
            // 3) Keep the managed `distill` CLI on PATH so all-call instructions
            // that require `| distill` resolve for every provider.
            _ = try installer.installDistillCLI(appSupportDirectory: appSupportDirectory)
            try? installer.installCommandWrappers()
            try? installer.installRetrieveMCP()
            managedDistillSkillInstallResults = [appPrivate]
            managedDistillSkillInstallError = nil
            // Token Saver toggle no longer installs/uninstalls home skills.
            _ = tokenSaverEnabled
        } catch {
            NSLog("RemoteCode managed Distill skill reconcile failed: \(error)")
            managedDistillSkillInstallResults = []
            managedDistillSkillInstallError = (error as NSError).localizedDescription
        }
    }

    private func makeAgentSkillInstaller() -> AgentSkillInstaller {
        // App-private Distill + remote-code-orchestrate live under the same skills root.
        // Production uses the default Application Support path; unit tests with a
        // sandboxed home keep app-private packages under this AppContext's
        // appSupportDirectory so they never write into the developer's real tree.
        if let home = agentSkillsHomeOverrideForTesting {
            return AgentSkillInstaller(
                claudeSkillsRoot: home.appendingPathComponent(".claude/skills", isDirectory: true),
                codexSkillsRoot: home.appendingPathComponent(".codex/skills", isDirectory: true),
                claudeInstructionsURL: home.appendingPathComponent(".claude/CLAUDE.md"),
                codexInstructionsURL: home.appendingPathComponent(".codex/AGENTS.md"),
                cliBinDirectory: home.appendingPathComponent(".remote-code/bin", isDirectory: true),
                pathBinDirectory: home.appendingPathComponent(".local/bin", isDirectory: true),
                appPrivateSkillsRoot: appSupportDirectory.appendingPathComponent("AgentSkills", isDirectory: true)
            )
        }
        return AgentSkillInstaller()
    }

    nonisolated static func shouldReconcileManagedDistillIntegration(
        isRunningUnitTests: Bool,
        hasSkillsHomeOverride: Bool,
        environment: [String: String]
    ) -> Bool {
        guard environment["RC2_DISABLE_MANAGED_DISTILL_RECONCILE"] != "1" else { return false }
        return !isRunningUnitTests || hasSkillsHomeOverride
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
                // Partial success: providers that did not answer *and* have no
                // unexpired weekly window are inactive / signed-out / unreachable.
                // Clear their frozen weekly % so Claude does not stay locked at
                // 45% forever. Do not clear providers still inside a live weekly
                // window (especially Grok): a flaky billing-log scan must not
                // paint the purple ring as 0% while credits are mid-window.
                // Full empty/timeout leaves the cache alone — that is noise, not
                // proof every provider is inactive.
                if !usages.isEmpty {
                    let store = TokenSaverUsageStore(appSupportDirectory: self.appSupportDirectory)
                    let existing = store.load().providers
                    let toClear = TokenSaverUsageStore.providersToClearAfterPartialAccountUsageRefresh(
                        returned: usages.map(\.provider),
                        existing: existing
                    )
                    for provider in toClear {
                        self.clearTokenSaverAccountUsagePercentages(provider)
                    }
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

    private func clearTokenSaverAccountUsagePercentages(_ provider: AgentProvider) {
        do {
            _ = try TokenSaverUsageStore(appSupportDirectory: appSupportDirectory)
                .clearAccountUsagePercentages(provider: provider)
            NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
        } catch {
            NSLog("RemoteCode Token Saver account usage clear failed (\(provider.rawValue)): \(error)")
        }
    }

    /// Grok-only account-usage refresh from the local billing log.
    ///
    /// WHY: Claude/Codex push live `.accountUsage` during a turn. Grok ACP does
    /// not, so the purple weekly ring stayed stale until launch / 5-minute
    /// periodic / details-open. Call this after a Grok run finishes (or from
    /// tests) to re-read `~/.grok/logs/unified.jsonl` without spawning the slow
    /// Claude/Codex CLI probes. Independent of `tokenSaverAccountUsageRefreshTask`
    /// so a busy full refresh cannot skip Grok.
    ///
    /// - Parameters:
    ///   - reason: telemetry label (`run_finished`, tests, …)
    ///   - billingLogURL: override for tests; default is the user billing log
    public func refreshGrokTokenSaverAccountUsage(
        reason: String,
        billingLogURL: URL? = nil
    ) {
        guard PrivateAccountSessionStore(repo: settingsRepo).load() != nil else {
            publishTokenSaverAccountUsageRefresh(state: "skipped", reason: reason, detail: "signed_out")
            return
        }
        let url = billingLogURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok/logs/unified.jsonl")
        publishTokenSaverAccountUsageRefresh(state: "started", reason: reason, detail: "grok_billing_log")
        Task { [weak self] in
            let usage = await Task.detached {
                AssistantAccountUsageParser.grokFromBillingLogFile(at: url)
            }.value
            await MainActor.run {
                guard let self else { return }
                if let usage {
                    self.recordTokenSaverAccountUsage(usage)
                    EventBus.shared.publish(
                        kind: "agent.account.usage",
                        payload: .object(Self.accountUsagePayload(reason: reason, usage: usage))
                    )
                    self.publishTokenSaverAccountUsageRefresh(
                        state: "finished",
                        reason: reason,
                        detail: nil,
                        providers: [usage.provider.rawValue]
                    )
                } else {
                    self.publishTokenSaverAccountUsageRefresh(
                        state: "finished",
                        reason: reason,
                        detail: "empty",
                        providers: []
                    )
                }
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

    private func tokenSaverProjectAdmission(
        threadId: AgentThreadID,
        lane laneName: String,
        globallyEnabled: Bool? = nil
    ) -> TokenSaverAdmissionDecision {
        if tokenSaverLifecycleDegradedReason != nil {
            return .init(allowed: false, reason: "lifecycle_degraded")
        }
        let enabled = globallyEnabled ?? SettingsStore(db: db).load().tokenSaverEnabled
        guard let thread = try? threadRepo.get(id: threadId),
              let projectID = thread.projectId?.value.uuidString,
              thread.workspaceId != nil,
              let lane = try? tokenSaverLaneStateRepo.get(projectID: projectID, lane: laneName) else {
            return TokenSaverProjectRuntimeAdmissionPolicy.evaluate(.init(
                globallyEnabled: enabled,
                hasExactProjectScope: false,
                laneState: nil,
                evidenceLevel: nil,
                ownerRole: nil,
                optedOut: false,
                killSwitchActive: true,
                attributionJoined: false,
                reconciliationPassed: false,
                usageSemanticsAvailable: false,
                scorecardID: nil
            ))
        }
        return TokenSaverProjectRuntimeAdmissionPolicy.evaluate(.init(
            globallyEnabled: enabled,
            hasExactProjectScope: true,
            laneState: lane.state,
            evidenceLevel: lane.typedEvidenceLevel.rawValue,
            ownerRole: lane.ownerRole,
            optedOut: lane.optedOut,
            killSwitchActive: lane.killSwitchActive,
            attributionJoined: lane.attributionJoined,
            reconciliationPassed: lane.reconciliationPassed,
            usageSemanticsAvailable: lane.usageSemanticsAvailable,
            scorecardID: lane.scorecardID
        ))
    }

    private func tokenSaverProjectObservation(
        threadId: AgentThreadID,
        lane laneName: String
    ) -> TokenSaverAdmissionDecision {
        guard tokenSaverLifecycleDegradedReason == nil,
              SettingsStore(db: db).load().tokenSaverEnabled,
              let thread = try? threadRepo.get(id: threadId),
              let projectID = thread.projectId?.value.uuidString,
              thread.workspaceId != nil,
              let lane = try? tokenSaverLaneStateRepo.get(projectID: projectID, lane: laneName),
              ["shadow_only", "promoted"].contains(lane.state),
              !lane.optedOut,
              !lane.killSwitchActive else {
            return .init(allowed: false, reason: "observation_not_admitted")
        }
        return .init(allowed: true, reason: lane.state)
    }

    private func tokenSaverProjectObservation(runId: AgentRunID, lane: String) -> TokenSaverAdmissionDecision {
        guard let run = try? runRepo.get(id: runId) else {
            return .init(allowed: false, reason: "missing_run_scope")
        }
        return tokenSaverProjectObservation(threadId: run.threadId, lane: lane)
    }

    private func tokenSaverProjectAdmission(
        runId: AgentRunID,
        lane: String,
        globallyEnabled: Bool? = nil
    ) -> TokenSaverAdmissionDecision {
        guard let run = try? runRepo.get(id: runId) else {
            return .init(allowed: false, reason: "missing_run_scope")
        }
        return tokenSaverProjectAdmission(
            threadId: run.threadId,
            lane: lane,
            globallyEnabled: globallyEnabled
        )
    }

    func tokenSaverCompress(
        prompt: String,
        provider: AgentProvider,
        threadId: AgentThreadID,
        cacheState: String = "prompt",
        runId: AgentRunID? = nil
    ) async -> String {
        guard tokenSaverProjectAdmission(threadId: threadId, lane: "deterministic_wrapper").allowed else {
            return prompt
        }
        // NetPositiveGate (G3): there is no app-side cached prefix to preserve (resume sends
        // the full wrapped prompt), so this is a numeric decision — compress the new-turn
        // argv only when it is large enough AND the session is not a warm follow-up.
        let gate = NetPositiveGate(floorCharacters: Self.tokenSaverMinCompressChars, warmResumeTTLSeconds: 300)
        let secondsSinceLastTurn = secondsSinceLastTurn(threadId: threadId)
        guard gate.shouldCompress(inputCharacters: prompt.count, secondsSinceLastTurn: secondsSinceLastTurn) else {
            return prompt
        }
        let semanticObservation = tokenSaverProjectObservation(threadId: threadId, lane: "semantic_prose")
        let semanticPromoted: Bool = {
            guard tokenSaverProjectAdmission(threadId: threadId, lane: "semantic_prose").allowed,
                  let thread = try? threadRepo.get(id: threadId),
                  let projectID = thread.projectId?.value.uuidString,
                  let lane = try? tokenSaverLaneStateRepo.get(projectID: projectID, lane: "semantic_prose") else {
                return false
            }
            return lane.retentionDays > 0 && !lane.optedOut && !lane.killSwitchActive
        }()
        // A shadow/audit no-win must not suppress a later promoted optimize call for
        // the same prompt. The two paths have different recovery and adoption rights.
        let skipKey = DistillResultCacheKey(request: DistillRequest(
            mode: .longText,
            priority: .interactive,
            input: prompt,
            maxOutputCharacters: max(512, prompt.count)
        ), pipelineVersion: DistillResultCacheKey.pipelineVersion + (semanticPromoted ? "-optimize" : "-audit"))
        if tokenSaverPromptSkipSetContains(skipKey) {
            return prompt
        }
        // T-003 Wave -1: diff windowing is lossy and depended on a global raw
        // hash. Keep it off until scoped recovery is authorized and read back.
        let diffWindowed: String? = nil
        // Non-lossy dedup pre-pass (P4): collapse exact-duplicate large blocks within the
        // prompt to a model-readable "identical to block above" pointer. The model keeps
        // full information (content once + a pointer it understands), so this is safe to
        // send AND a win even if the model compression step is unavailable.
        let dedupeProbe = DistillBlockDeduper.dedupe(prompt)
        // The self-contained exact/volatile pointer keeps the first block and its
        // changed fields inline. Do not attach an unscoped recovery marker.
        let deduped = dedupeProbe.output
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
                threadId: threadId,
                mode: DistillMode.longText.rawValue,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                savedTokens: max(inputTokens - outputTokens, 0),
                cacheState: cacheState,
                routeStage: stage
            )
            return candidate
        }

        // Demand-start Distill without blocking this turn on MLX warmup. Kick the
        // sidecar for later turns / concurrent SR1; if not already `.running`,
        // fail open to deterministic/original input (Token Saver fail-open).
        if semanticObservation.allowed {
            startTokenSaverDistillServiceIfEligible()
        }
        guard semanticObservation.allowed,
              let client = currentDistillClient() else {
            if !semanticObservation.allowed {
                NSLog("RemoteCode Token Saver semantic observation skipped: \(semanticObservation.reason)")
            }
            // No model service: deterministic pre-passes still fail open and can save tokens.
            return deterministicCandidate.count < prompt.count ? adopt(deterministicCandidate, stage: .deterministic) : prompt
        }
        let request = DistillRequest(
            mode: .longText,
            priority: .interactive,
            input: deterministicCandidate,
            runMode: semanticPromoted ? .optimize : .audit,
            maxOutputCharacters: max(512, deterministicCandidate.count)
        )
        do {
            let response: DistillResponse
            if semanticPromoted,
               let runId,
               let thread = try? threadRepo.get(id: threadId),
               let workspaceID = thread.workspaceId?.value.uuidString,
               let projectID = thread.projectId?.value.uuidString {
                response = try await client.distill(
                    request,
                    recoveryContext: .init(
                        workspaceID: workspaceID,
                        projectID: projectID,
                        threadID: threadId.value.uuidString,
                        provider: provider.rawValue,
                        attemptID: runId.value.uuidString,
                        operationID: "semantic-prose:\(runId.value.uuidString)"
                    )
                )
            } else {
                response = try await client.distill(request)
            }
            let modelOutput = response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? deterministicCandidate : response.output
            let literalSafeModelOutput = LiteralPreservation.guarded(original: prompt, compressed: modelOutput).droppedLiteral == nil
                ? modelOutput
                : deterministicCandidate
            // The deterministic lane never adopts sidecar bytes. A semantic candidate
            // is live only after its own lane is promoted and exact-scope recovery was
            // durably stored and read back. Shadow runs observe it verbatim-only.
            let modelWon = literalSafeModelOutput.count < deterministicCandidate.count
            if !modelWon, deterministicCandidate.count >= prompt.count {
                tokenSaverPromptSkipSet[skipKey] = Date()
            }
            let semanticAdmitted = tokenSaverProjectAdmission(
                threadId: threadId,
                lane: "semantic_prose"
            ).allowed
            guard modelWon,
                  semanticAdmitted,
                  let recoveredCandidate = prepareSemanticCandidate(
                    original: prompt,
                    stageOriginal: deterministicCandidate,
                    candidate: literalSafeModelOutput,
                    capability: response.originalHandle,
                    idempotencyKey: response.recoveryIdempotencyKey,
                    provider: provider,
                    threadId: threadId,
                    runId: runId
                  ) else {
                // Distill may already have prepared a stage object before any later
                // pre-adoption gate. Abandon only that provisional when adoption fails.
                discardProvisionalSemanticRecovery(
                    capability: response.originalHandle,
                    idempotencyKey: response.recoveryIdempotencyKey,
                    provider: provider,
                    threadId: threadId,
                    runId: runId
                )
                return deterministicCandidate.count < prompt.count
                    ? adopt(deterministicCandidate, stage: .deterministic)
                    : prompt
            }
            return adopt(recoveredCandidate, stage: response.routeStage ?? .llmMLX)
        } catch {
            NSLog("RemoteCode Token Saver compression skipped (provider=\(provider.rawValue)): \(error)")
            // Fail-open to the deterministic pre-pass if it helped, else the original.
            return deterministicCandidate.count < prompt.count ? adopt(deterministicCandidate, stage: .deterministic) : prompt
        }
    }

    private func prepareSemanticCandidate(
        original: String,
        stageOriginal: String,
        candidate: String,
        capability: String?,
        idempotencyKey: String?,
        provider: AgentProvider,
        threadId: AgentThreadID,
        runId: AgentRunID?
    ) -> String? {
        guard let runId,
              let capability,
              let idempotencyKey,
              let thread = try? threadRepo.get(id: threadId),
              let workspaceID = thread.workspaceId?.value.uuidString,
              let projectID = thread.projectId?.value.uuidString,
              let lane = try? tokenSaverLaneStateRepo.get(projectID: projectID, lane: "semantic_prose"),
              lane.state == "promoted",
              lane.retentionDays > 0,
              !lane.optedOut,
              !lane.killSwitchActive else {
            return nil
        }
        let scope = TokenSaverPersistentScope(
            workspaceID: workspaceID,
            projectID: projectID,
            threadID: threadId.value.uuidString,
            provider: provider.rawValue,
            attemptID: runId.value.uuidString
        )
        var provisionals: [(capability: String, idempotencyKey: String)] = []
        let store = TokenSaverScopedRecoveryStore(db: db)
        func discardProvisionals() {
            for provisional in provisionals {
                _ = try? store.discardAbandoned(
                    capability: provisional.capability,
                    scope: scope,
                    idempotencyKey: provisional.idempotencyKey
                )
            }
        }
        do {
            guard try store.retrieve(capability: capability, scope: scope) == Data(stageOriginal.utf8) else {
                // Stage was prepared for this response; abandon it if content cannot be used.
                _ = try? store.discardAbandoned(
                    capability: capability,
                    scope: scope,
                    idempotencyKey: idempotencyKey
                )
                return nil
            }
            provisionals.append((capability, idempotencyKey))

            var recoveryMarkers = ["[[rc:\(capability)]]"]
            var fullOriginal: TokenSaverPreparedRecovery?
            if stageOriginal != original {
                let diskAttributes = try FileManager.default.attributesOfFileSystem(
                    forPath: appSupportDirectory.path
                )
                let disk = TokenSaverRecoveryDiskSnapshot(
                    freeBytes: (diskAttributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0,
                    totalBytes: (diskAttributes[.systemSize] as? NSNumber)?.int64Value ?? 0
                )
                let preparedFull = try TokenSaverRuntimeRecoveryWorker(db: db).prepareOriginal(
                    Data(original.utf8),
                    scope: scope,
                    operationID: "semantic-full-original:\(runId.value.uuidString)",
                    lane: "semantic_prose",
                    disk: disk
                )
                provisionals.append((preparedFull.capability, preparedFull.idempotencyKey))
                guard try store.retrieve(
                    capability: preparedFull.capability,
                    scope: scope
                ) == Data(original.utf8) else {
                    discardProvisionals()
                    return nil
                }
                fullOriginal = preparedFull
                recoveryMarkers.append("[[rc:\(preparedFull.capability)]]")
            }

            // Final marker-inclusive net-positive gate before durable delivery/ack.
            let recoverable = candidate + "\n" + recoveryMarkers.joined(separator: "\n")
            guard recoverable.utf8.count < original.utf8.count else {
                discardProvisionals()
                return nil
            }

            // Atomic multi-object finalization: stage (+ optional full-original) in one
            // SQLite transaction. On failure both remain provisional and are discarded.
            let fullMember = fullOriginal.map {
                TokenSaverSemanticRecoveryMember(
                    capability: $0.capability,
                    idempotencyKey: $0.idempotencyKey
                )
            }
            guard try store.finalizeSemanticRecoverySet(
                stage: TokenSaverSemanticRecoveryMember(
                    capability: capability,
                    idempotencyKey: idempotencyKey
                ),
                fullOriginal: fullMember,
                scope: scope
            ) else {
                discardProvisionals()
                return nil
            }
            return recoverable
        } catch {
            NSLog("RemoteCode Token Saver semantic recovery preparation failed: \(error)")
            discardProvisionals()
            return nil
        }
    }

    private func discardProvisionalSemanticRecovery(
        capability: String?,
        idempotencyKey: String?,
        provider: AgentProvider,
        threadId: AgentThreadID,
        runId: AgentRunID?
    ) {
        guard let runId,
              let capability,
              let idempotencyKey,
              let thread = try? threadRepo.get(id: threadId),
              let workspaceID = thread.workspaceId?.value.uuidString,
              let projectID = thread.projectId?.value.uuidString else {
            return
        }
        let scope = TokenSaverPersistentScope(
            workspaceID: workspaceID,
            projectID: projectID,
            threadID: threadId.value.uuidString,
            provider: provider.rawValue,
            attemptID: runId.value.uuidString
        )
        _ = try? TokenSaverScopedRecoveryStore(db: db).discardAbandoned(
            capability: capability,
            scope: scope,
            idempotencyKey: idempotencyKey
        )
    }

    private func tokenSaverPromptSkipSetContains(_ key: DistillResultCacheKey) -> Bool {
        guard let insertedAt = tokenSaverPromptSkipSet[key] else { return false }
        if Date().timeIntervalSince(insertedAt) > Self.tokenSaverPromptSkipSetTTL {
            tokenSaverPromptSkipSet.removeValue(forKey: key)
            return false
        }
        return true
    }

    /// Stores only bounded, exact-thread private learning. The production read path
    /// uses the same scope and never mutates provider-global instruction files.
    func recordSessionLearnFromRun(runId: AgentRunID, status: AgentRunStatus) {
        let settings = SettingsStore(db: db).load()
        guard settings.sessionLearnEnabled,
              tokenSaverProjectObservation(runId: runId, lane: "session_learn").allowed,
              let run = try? runRepo.get(id: runId),
              let thread = try? threadRepo.get(id: run.threadId),
              let workspaceID = thread.workspaceId?.value.uuidString,
              let projectID = thread.projectId?.value.uuidString,
              let lane = try? tokenSaverLaneStateRepo.get(projectID: projectID, lane: "session_learn"),
              lane.retentionDays > 0 else {
            sessionLearnInputTokensByRun.removeValue(forKey: runId)
            return
        }
        let expensive = (sessionLearnInputTokensByRun.removeValue(forKey: runId) ?? 0) >= 64_000
        guard status == .failed || expensive else { return }
        let source = run.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = Self.utf8SafePrefix(
            (source?.isEmpty == false ? source! : "High-input run required repeated context."),
            maxBytes: 512
        )
        guard !text.isEmpty else { return }
        do {
            try tokenSaverSessionLearnRepo.save(
                text: text,
                scope: .init(
                    workspaceID: workspaceID,
                    projectID: projectID,
                    threadID: run.threadId.value.uuidString,
                    provider: run.provider.rawValue
                ),
                attemptID: runId.value.uuidString,
                expiresAt: Date().addingTimeInterval(TimeInterval(lane.retentionDays) * 86_400)
            )
        } catch {
            NSLog("RemoteCode Token Saver SessionLearn save failed: \(error)")
        }
    }

    private func tokenSaverSessionLearnPrompt(
        _ prompt: String,
        provider: AgentProvider,
        threadId: AgentThreadID,
        runId: AgentRunID?
    ) -> String {
        let settings = SettingsStore(db: db).load()
        guard settings.sessionLearnEnabled,
              tokenSaverProjectAdmission(threadId: threadId, lane: "session_learn").allowed,
              let thread = try? threadRepo.get(id: threadId),
              let workspaceID = thread.workspaceId?.value.uuidString,
              let projectID = thread.projectId?.value.uuidString else {
            return prompt
        }
        let scope = TokenSaverSessionLearnScope(
            workspaceID: workspaceID,
            projectID: projectID,
            threadID: threadId.value.uuidString,
            provider: provider.rawValue
        )
        let recoveryScope = TokenSaverRecoveryScope(
            workspaceID: workspaceID,
            projectID: projectID,
            threadID: threadId.value.uuidString,
            provider: provider.rawValue,
            attemptID: runId?.value.uuidString ?? "followup"
        )
        do {
            let records = try tokenSaverSessionLearnRepo.topK(scope: scope, byteBudget: 2_048, limit: 20)
            let candidates = records.map {
                DistillCore.TokenSaverSessionLearnRecord(id: $0.id, scope: recoveryScope, text: $0.text)
            }
            let selected = TokenSaverSessionLearnSelector.select(
                records: candidates,
                scope: recoveryScope,
                query: prompt,
                topK: 3,
                byteBudget: 512
            )
            guard !selected.isEmpty else { return prompt }
            let bounded = selected.map { "- \($0.text)" }.joined(separator: "\n")
            return prompt + "\n\nSESSION_LEARN_EXACT_SCOPE:\n" + bounded
        } catch {
            NSLog("RemoteCode Token Saver SessionLearn prompt read failed: \(error)")
            return prompt
        }
    }

    private static func utf8SafePrefix(_ text: String, maxBytes: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            let value = String(character)
            let bytes = value.utf8.count
            guard used + bytes <= maxBytes else { break }
            result.append(value)
            used += bytes
        }
        return result
    }

    public func tokenSaverRolloverAdmission(
        parentThreadID: AgentThreadID
    ) -> TokenSaverAdmissionDecision {
        let admission = tokenSaverProjectAdmission(
            threadId: parentThreadID,
            lane: "rollover_capsule"
        )
        guard admission.allowed else { return admission }
        guard let parent = try? threadRepo.get(id: parentThreadID),
              let projectID = parent.projectId?.value.uuidString,
              parent.workspaceId != nil,
              let lane = try? tokenSaverLaneStateRepo.get(
                projectID: projectID,
                lane: "rollover_capsule"
              ),
              lane.retentionDays > 0 else {
            return .init(allowed: false, reason: "retention_not_positive")
        }
        return admission
    }

    public func createTokenSaverRollover(
        parentThreadID: AgentThreadID,
        maxBytes: Int = 8_192
    ) throws -> AgentThread {
        guard let parent = try threadRepo.get(id: parentThreadID),
              let projectID = parent.projectId?.value.uuidString,
              parent.workspaceId != nil else {
            throw TokenSaverRolloverError.missingProjectScope
        }
        guard parent.status != .pending, parent.status != .running else {
            throw TokenSaverRolloverError.parentBusy(parent.status)
        }
        try tokenSaverLaneStateRepo.ensureDefaults(projectID: projectID)
        let admission = tokenSaverRolloverAdmission(parentThreadID: parentThreadID)
        guard admission.allowed else {
            throw TokenSaverRolloverError.laneUnavailable(admission.reason)
        }
        _ = try tokenSaverProjectDataRepo.performLifecycleSweep()
        let child = AgentThread(
            projectId: parent.projectId,
            workspaceId: parent.workspaceId,
            title: "Rollover: \(parent.title)",
            provider: parent.provider,
            providerInstanceId: parent.providerInstanceId,
            model: parent.model,
            permissionMode: parent.permissionMode,
            reasoningEffort: parent.reasoningEffort,
            executionMode: parent.executionMode,
            baseBranch: parent.baseBranch,
            worktreePath: parent.worktreePath,
            serviceTier: parent.serviceTier,
            modelSelection: parent.modelSelection,
            interactionMode: parent.effectiveInteractionMode,
            runAsUser: parent.runAsUser
        )
        let parentMessages = try messageRepo.list(threadId: parentThreadID)
        let messages = parentMessages.map {
            TokenSaverCapsuleMessage(role: $0.role.rawValue, text: $0.content)
        }
        let capsule = try TokenSaverRolloverCapsuleBuilder.build(
            parentThreadID: parentThreadID.value.uuidString,
            childThreadID: child.id.value.uuidString,
            messages: messages,
            maxBytes: maxBytes
        )
        do {
            try tokenSaverRolloverBeforeCommitForTesting?()
            guard let currentParent = try threadRepo.get(id: parentThreadID),
                  currentParent.status != .pending,
                  currentParent.status != .running,
                  currentParent.updatedAt == parent.updatedAt,
                  try messageRepo.list(threadId: parentThreadID) == parentMessages else {
                throw TokenSaverRolloverError.parentChanged
            }
            try threadRepo.upsert(child)
            try messageRepo.append(.init(threadId: child.id, role: .system, content: capsule.text))
            try tokenSaverRolloverRepo.save(.init(
                id: UUID().uuidString,
                parentThreadID: parentThreadID.value.uuidString,
                childThreadID: child.id.value.uuidString,
                scopeTransitionJSON: nil,
                capsuleSHA256: AgentSkillInstaller.sha256Hex(Data(capsule.text.utf8)),
                capsuleText: capsule.text
            ))
            _ = try tokenSaverProjectDataRepo.performLifecycleSweep()
            return child
        } catch {
            try? tokenSaverRolloverRepo.delete(childThreadID: child.id.value.uuidString)
            try? threadRepo.delete(id: child.id)
            throw error
        }
    }

    func tokenSaverHumanizeSR1Response(_ response: String, provider: AgentProvider, threadId: AgentThreadID, runId: AgentRunID? = nil) async -> String {
        guard SR1ResponseDetector.isSR1(response) else { return response }

        let targetLanguage = inferredUserLanguage(threadId: threadId)
        let fallback = Self.fallbackHumanizeSR1(response, targetLanguage: targetLanguage)
        guard let client = await currentDistillClientWaitingForStartup() else {
            NSLog("RemoteCode Token Saver SR1 humanize fallback used (provider=\(provider.rawValue)): distill client unavailable (status=\(Self.describe(tokenSaverDistillServiceController.status)))")
            recordTokenSaverSR1HumanizeSavings(sr1: response, humanized: fallback, provider: provider, threadId: threadId)
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
            recordTokenSaverSR1HumanizeSavings(sr1: response, humanized: humanized, provider: provider, threadId: threadId)
            return humanized
        } catch {
            NSLog("RemoteCode Token Saver SR1 humanize fallback used (provider=\(provider.rawValue)): \(error)")
            recordTokenSaverSR1HumanizeSavings(sr1: response, humanized: fallback, provider: provider, threadId: threadId)
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

    private func recordTokenSaverPreparedObservation(request: AgentRunRequest, originalPrompt: String) {
        guard tokenSaverProjectObservation(threadId: request.threadId, lane: "measurement").allowed,
              let thread = try? threadRepo.get(id: request.threadId),
              let workspaceID = thread.workspaceId?.value.uuidString,
              let projectID = thread.projectId?.value.uuidString else {
            return
        }
        let attemptID = request.runId.value.uuidString
        beginTokenSaverAttempt(runId: request.runId)
        appendTokenSaverObservationEvent(
            attemptID: attemptID,
            kind: "treatment_join",
            payload: [
                "workspace_id": workspaceID,
                "project_id": projectID,
                "thread_id": request.threadId.value.uuidString,
                "provider": request.provider.rawValue,
                "input_attribution": "pending_provider_usage",
                "input_bytes": originalPrompt.utf8.count,
                "treatment": "verbatim_shadow",
                "provider_bytes_changed": false,
            ]
        )

        if tokenSaverProjectObservation(threadId: request.threadId, lane: "semantic_prose").allowed {
            let contentType: TokenSaverSemanticContentType
            if originalPrompt.contains("diff --git") { contentType = .diff }
            else if originalPrompt.contains("```") { contentType = .code }
            else { contentType = .prose }
            let language = Self.looksPortuguese(originalPrompt) ? "pt" : (Self.looksSpanish(originalPrompt) ? "es" : "en")
            appendTokenSaverObservationEvent(
                attemptID: attemptID,
                kind: "shadow_policy",
                payload: [
                    "lane": "semantic_prose",
                    "result": "unavailable",
                    "reason": "production_model_manifest_unavailable",
                    "content_type": contentType.rawValue,
                    "language": language,
                    "provider_bytes_changed": false,
                ]
            )
        }
        if tokenSaverProjectObservation(threadId: request.threadId, lane: "adaptive_effort").allowed {
            let lower = originalPrompt.lowercased()
            let mechanicalMarkers = ["rename ", "format ", "run the tests", "run tests", "update version", "fix lint"]
            let markerCount = mechanicalMarkers.filter { lower.contains($0) }.count
            let taskClass: TokenSaverAdaptiveTaskClass = markerCount > 0 ? .mechanical : .reasoning
            let confidence = markerCount > 0 ? 0.96 : 0.65
            let decision = TokenSaverAdaptiveEffortPolicy.evaluate(
                taskClass: taskClass,
                confidence: confidence,
                persistentUserOverride: request.reasoningEffort?.rawValue
            )
            appendTokenSaverObservationEvent(
                attemptID: attemptID,
                kind: "shadow_policy",
                payload: [
                    "lane": "adaptive_effort",
                    "result": decision.action.rawValue,
                    "task_class": taskClass.rawValue,
                    "confidence": confidence,
                    "persistent_override_present": request.reasoningEffort != nil,
                    "provider_bytes_changed": false,
                ]
            )
        }
        if tokenSaverProjectObservation(threadId: request.threadId, lane: "visual_artifact").allowed {
            let images = request.attachments.filter { $0.kind == .image }
            let knownBytes = images.compactMap(\.sizeBytes).reduce(0, +)
            appendTokenSaverObservationEvent(
                attemptID: attemptID,
                kind: "shadow_policy",
                payload: [
                    "lane": "visual_artifact",
                    "result": "unavailable",
                    "reason": images.isEmpty ? "no_visual_attachment" : "provider_visual_tokens_unavailable",
                    "image_attachment_count": images.count,
                    "known_image_bytes": knownBytes,
                    "all_image_sizes_known": images.allSatisfy { $0.sizeBytes != nil },
                    "provider_bytes_changed": false,
                ]
            )
        }
        if tokenSaverProjectObservation(threadId: request.threadId, lane: "provider_native").allowed {
            let decision = TokenSaverProviderNativePolicy.evaluate(
                provider: request.provider.rawValue,
                providerVersionKnown: false,
                toolSearchExposedByActiveAdapter: false,
                promptCacheBehaviorProven: false,
                recoveryProven: false
            )
            appendShadowPolicyEvent(attemptID: attemptID, lane: "provider_native", result: decision.state.rawValue)
        }
        let sessionLearnObservation = tokenSaverProjectObservation(threadId: request.threadId, lane: "session_learn")
        if sessionLearnObservation.allowed {
            let persistentScope = TokenSaverSessionLearnScope(
                workspaceID: workspaceID,
                projectID: projectID,
                threadID: request.threadId.value.uuidString,
                provider: request.provider.rawValue
            )
            let recoveryScope = TokenSaverRecoveryScope(
                workspaceID: workspaceID,
                projectID: projectID,
                threadID: request.threadId.value.uuidString,
                provider: request.provider.rawValue,
                attemptID: attemptID
            )
            do {
                let records = try tokenSaverSessionLearnRepo.topK(scope: persistentScope, byteBudget: 2_048, limit: 20)
                let candidates = records.map {
                    DistillCore.TokenSaverSessionLearnRecord(id: $0.id, scope: recoveryScope, text: $0.text)
                }
                let selected = TokenSaverSessionLearnSelector.select(
                    records: candidates,
                    scope: recoveryScope,
                    query: originalPrompt,
                    topK: 3,
                    byteBudget: 512
                )
                appendTokenSaverObservationEvent(
                    attemptID: attemptID,
                    kind: "session_learn_retrieval",
                    payload: [
                        "selected_count": selected.count,
                        "selected_bytes": selected.reduce(0) { $0 + $1.text.utf8.count },
                        "provider_bytes_changed": sessionLearnObservation.reason == "promoted" && !selected.isEmpty,
                    ]
                )
            } catch {
                NSLog("RemoteCode Token Saver SessionLearn read failed: \(error)")
            }
        }
    }

    private func appendShadowPolicyEvent(attemptID: String, lane: String, result: String) {
        appendTokenSaverObservationEvent(
            attemptID: attemptID,
            kind: "shadow_policy",
            payload: ["lane": lane, "result": result, "provider_bytes_changed": false]
        )
    }

    private func appendTokenSaverObservationEvent(attemptID: String, kind: String, payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let payloadJSON = String(data: data, encoding: .utf8) else {
            return
        }
        do {
            try tokenSaverAttemptLedger.appendEvent(attemptID: attemptID, kind: kind, payloadJSON: payloadJSON)
        } catch {
            NSLog("RemoteCode Token Saver observation ledger failed kind=\(kind): \(error)")
        }
    }

    private func recordTokenSaverUsage(_ usage: AssistantTokenUsage, runId: AgentRunID) {
        guard usage.totalTokens > 0,
              let run = try? runRepo.get(id: runId) else {
            return
        }
        if tokenSaverProjectObservation(runId: runId, lane: "session_learn").allowed {
            sessionLearnInputTokensByRun[runId, default: 0] += max(0, usage.inputTokens)
        }
        guard tokenSaverProjectObservation(runId: runId, lane: "measurement").allowed else { return }
        appendTokenSaverProviderUsage(usage, runId: runId)
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

    private func beginTokenSaverAttempt(runId: AgentRunID) {
        let attemptID = runId.value.uuidString
        guard (try? tokenSaverAttemptLedger.attempt(id: attemptID)) == nil,
              let run = try? runRepo.get(id: runId),
              tokenSaverProjectObservation(runId: runId, lane: "measurement").allowed else {
            return
        }
        let record = TokenSaverAttemptRecord(
            id: attemptID,
            runID: attemptID,
            provider: run.provider.rawValue,
            adapterVersion: "unavailable",
            providerVersion: "unavailable",
            model: run.model,
            cacheState: "unavailable",
            language: "unavailable",
            hardwareClass: "unavailable",
            workload: "interactive_agent",
            taskClass: "observational_shadow",
            evidenceLevel: "provider_usage",
            unavailableFields: [
                "adapter_version",
                "provider_version",
                "cache_state",
                "language",
                "hardware_class",
                "provider_usage_semantics",
                "provider_input_cost",
            ]
        )
        do {
            try tokenSaverAttemptLedger.begin(record)
        } catch {
            NSLog("RemoteCode Token Saver attempt begin failed: \(error)")
        }
    }

    private func appendTokenSaverProviderUsage(_ usage: AssistantTokenUsage, runId: AgentRunID) {
        guard tokenSaverProjectObservation(runId: runId, lane: "measurement").allowed else {
            return
        }
        beginTokenSaverAttempt(runId: runId)
        if usage.inputTokens > 0 {
            do {
                try tokenSaverAttemptLedger.appendInputComponent(
                    attemptID: runId.value.uuidString,
                    category: "unattributed_provider_input",
                    tokens: usage.inputTokens,
                    costMicros: 0
                )
            } catch {
                NSLog("RemoteCode Token Saver provider input attribution failed: \(error)")
            }
        }
        var payload: [String: Any] = [
            "semantics": "unavailable",
            "input_tokens": max(0, usage.inputTokens),
            "output_tokens": max(0, usage.outputTokens),
            "total_tokens": max(0, usage.totalTokens),
            "billed_token_units": max(0, usage.billedTotalTokenUnits),
        ]
        if let value = usage.contextWindow { payload["context_window"] = max(0, value) }
        if let value = usage.uncachedInputTokens { payload["uncached_input_tokens"] = max(0, value) }
        if let value = usage.cacheCreationInputTokens { payload["cache_creation_input_tokens"] = max(0, value) }
        if let value = usage.cacheReadInputTokens { payload["cache_read_input_tokens"] = max(0, value) }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let payloadJSON = String(data: data, encoding: .utf8) else {
            return
        }
        do {
            try tokenSaverAttemptLedger.appendEvent(
                attemptID: runId.value.uuidString,
                kind: "provider_usage",
                payloadJSON: payloadJSON
            )
        } catch {
            NSLog("RemoteCode Token Saver provider usage ledger failed: \(error)")
        }
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
        threadId: AgentThreadID,
        mode: String,
        inputTokens: Int,
        outputTokens: Int,
        savedTokens: Int,
        cacheState: String = "unknown",
        routeStage: TokenSaverRouteStage? = nil
    ) {
        guard tokenSaverProjectAdmission(threadId: threadId, lane: "deterministic_wrapper").allowed else { return }
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

    private func recordTokenSaverSR1HumanizeSavings(
        sr1: String,
        humanized: String,
        provider: AgentProvider,
        threadId: AgentThreadID
    ) {
        let estimate = TokenSaverSR1SavingsEstimator.estimate(sr1: sr1, humanized: humanized)
        recordTokenSaverSidecarSavings(
            provider: provider,
            threadId: threadId,
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
