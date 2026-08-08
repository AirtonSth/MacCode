import Foundation
import AppKit
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import Surfaces
import DistillCore
import os

private let appContextRuntimeLog = Logger(subsystem: "io.remotecode.agent", category: "app-context")

// MARK: - Token Saver per-lane kill switch + governance snapshot

/// WHY: Operators need a per-lane incident control point without full Token Saver
/// rollback. The same pure decision is reachable from the app and from child
/// `distill` processes via env (`RC_TOKEN_SAVER_DISABLED_LANES` /
/// `RC_TOKEN_SAVER_ENABLED_LANES`) and the shared DistillCLIState.json overlay.
/// New/experimental lanes default DISABLED until explicitly enabled.
public enum TokenSaverLaneKillSwitch: Sendable {
    public static let disabledEnvKey = "RC_TOKEN_SAVER_DISABLED_LANES"
    public static let enabledEnvKey = "RC_TOKEN_SAVER_ENABLED_LANES"

    /// Lanes that ship in factory defaults / production inventory. Everything
    /// else is experimental and defaults to DISABLED.
    public static let knownStableLanes: Set<String> = [
        "measurement",
        "provider_native",
        "deterministic_wrapper",
        "exact_repetition",
        "lexical_retrieval",
        "rollover_capsule",
        "session_learn",
        "semantic_prose",
        "adaptive_effort",
        "visual_artifact",
        "sr1-humanize",
        "sr1_humanize",
    ]

    public struct CLIStateOverlay: Sendable, Equatable {
        public var disabledLanes: Set<String>
        public var enabledLanes: Set<String>

        public static let empty = CLIStateOverlay(disabledLanes: [], enabledLanes: [])

        public init(disabledLanes: Set<String> = [], enabledLanes: Set<String> = []) {
            self.disabledLanes = disabledLanes
            self.enabledLanes = enabledLanes
        }
    }

    public static func parseLaneList(_ raw: String?) -> Set<String> {
        guard let raw else { return [] }
        return Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    /// Read optional `disabled_lanes` / `enabled_lanes` from DistillCLIState.json
    /// without requiring the sidecar writer to know about them yet.
    public static func loadCLIStateOverlay(from url: URL?) -> CLIStateOverlay {
        guard let url,
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        func set(from key: String) -> Set<String> {
            if let arr = obj[key] as? [String] {
                return Set(
                    arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
            }
            if let s = obj[key] as? String {
                return parseLaneList(s)
            }
            return []
        }
        return CLIStateOverlay(
            disabledLanes: set(from: "disabled_lanes"),
            enabledLanes: set(from: "enabled_lanes")
        )
    }

    /// Pure resolver: is `lane` disabled given env + CLI state overlay.
    public static func isDisabled(
        _ lane: String,
        environment: [String: String],
        cliState: CLIStateOverlay = .empty
    ) -> Bool {
        let laneKey = lane.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !laneKey.isEmpty else { return true }
        let envDisabled = parseLaneList(environment[disabledEnvKey])
        let envEnabled = parseLaneList(environment[enabledEnvKey])
        let disabled = envDisabled.union(cliState.disabledLanes)
        let enabled = envEnabled.union(cliState.enabledLanes)
        // Incident kill switch always wins over enable lists.
        if disabled.contains(laneKey) { return true }
        if enabled.contains(laneKey) { return false }
        if knownStableLanes.contains(laneKey) { return false }
        // New/experimental lanes default DISABLED.
        return true
    }

    /// Resolved disabled set for known + mentioned lanes (for child env export).
    public static func resolvedDisabledLanes(
        environment: [String: String],
        cliState: CLIStateOverlay = .empty
    ) -> Set<String> {
        let mentioned = parseLaneList(environment[disabledEnvKey])
            .union(parseLaneList(environment[enabledEnvKey]))
            .union(cliState.disabledLanes)
            .union(cliState.enabledLanes)
            .union(knownStableLanes)
        return Set(mentioned.filter { isDisabled($0, environment: environment, cliState: cliState) })
    }

    public static func resolvedEnabledLanes(
        environment: [String: String],
        cliState: CLIStateOverlay = .empty
    ) -> Set<String> {
        parseLaneList(environment[enabledEnvKey]).union(cliState.enabledLanes)
    }
}

/// Compact governance snapshot attached to measurement rows so ungating savings
/// from project admission stays auditable.
public struct TokenSaverGovernanceSnapshot: Sendable, Equatable, Codable {
    public var projectId: String?
    public var admissionAllowed: Bool
    public var admissionReason: String
    public var evidenceLevel: String?
    public var governedWrite: Bool

    public init(
        projectId: String?,
        admissionAllowed: Bool,
        admissionReason: String,
        evidenceLevel: String?,
        governedWrite: Bool
    ) {
        self.projectId = projectId
        self.admissionAllowed = admissionAllowed
        self.admissionReason = admissionReason
        self.evidenceLevel = evidenceLevel
        self.governedWrite = governedWrite
    }

    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case admissionAllowed = "admission_allowed"
        case admissionReason = "admission_reason"
        case evidenceLevel = "evidence_level"
        case governedWrite = "governed_write"
    }

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

/// Authoritative result for the Token Saver host lifecycle. UI callers use this
/// instead of treating a persisted preference as proof that paid runtime
/// prerequisites were admitted.
public enum TokenSaverLifecycleOutcome: Sendable, Equatable {
    case enabled
    case disabled
    case blocked(String)
    case failed(String)

    public var isEnabled: Bool {
        self == .enabled
    }
}

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
    /// Off-MainActor owner for `agent.checkpoint.list` metadata pages.
    public let checkpointListGateway: AgentTurnCheckpointListGateway
    /// Off-MainActor owner for connection-snapshot AgentThread list/decode.
    public let agentThreadListGateway: AgentThreadListGateway
    /// Off-MainActor owner for the authoritative HTTP workspace list read.
    public let workspaceListGateway: WorkspaceListGateway
    public let tokenSaverSavingsRepo: TokenSaverSavingsRepository
    public let tokenSaverDailyEconomyRepo: TokenSaverDailyEconomyRepository
    public let graphifyUsageRepo: GraphifyUsageRepository
    public let tokenSaverAttemptLedger: TokenSaverAttemptLedger
    public let tokenSaverSessionLearnRepo: TokenSaverSessionLearnRepository
    public let tokenSaverLaneStateRepo: TokenSaverLaneStateRepository
    public let tokenSaverRolloverRepo: TokenSaverRolloverCapsuleRepository
    public let tokenSaverProjectDataRepo: TokenSaverProjectDataRepository
    public let tokenSaverAuditEventsRepo: TokenSaverAuditEventRepository
    /// Shared orchestration receipt runtime for the coordinator and every
    /// Agent App surface. Subagent activity must read the same SQLite-backed
    /// receipts that provider launches write.
    public let orchestrationRuntime: AgentOrchestrationRuntime
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
    public var router: AppCommandRouter! {
        didSet { drainRecoveredForkPrunedThreadIDsIfPossible() }
    }
    private var pendingRecoveredForkPrunedThreadIDs: Set<AgentThreadID> = []
    public var socketServer: UnixSocketServer?
    private let tokenSaverAccountUsageRefresher: TokenSaverAccountUsageRefreshing
    private var tokenSaverAccountUsageRefreshTask: Task<Void, Never>?
    private var tokenSaverUsageNotificationTask: Task<Void, Never>?
    private var tokenSaverLastUsageNotificationAt: Date = .distantPast
    /// Per-run usage state. Claude can emit independent per-request charges
    /// followed by an authoritative cumulative result, while Codex and Grok emit
    /// cumulative snapshots. Keep both tracks so the effective run total is the
    /// larger of the incremental sum and cumulative snapshot.
    private struct PendingUsage {
        var provider: AgentProvider
        var incremental = AssistantTokenUsage(semantics: .incremental)
        var cumulative = AssistantTokenUsage(semantics: .cumulative)
        var evidencedIncremental = AssistantTokenUsage(semantics: .incremental)
        var evidencedCumulative = AssistantTokenUsage(semantics: .cumulative)
        var persisted = AssistantTokenUsage(semantics: .cumulative)
        var eligibleAtEventTime = false
        var eligibleRunRecorded = false
        var writeInFlight = false
        var finished = false
    }
    private struct UsageWriteSnapshot {
        var runId: AgentRunID
        var provider: AgentProvider
        var target: AssistantTokenUsage
        var delta: AssistantTokenUsage
        var deltaBilledTokenUnits: Double
        var eligibleRuns: Int
        var currentSessionTokens: Int
        var currentSessionLimitTokens: Int?
    }
    private var pendingUsageByRun: [AgentRunID: PendingUsage] = [:]
    /// Recently completed run baselines accept a late cumulative provider
    /// receipt without double-counting. The bounded tombstone set avoids keeping
    /// every run for the lifetime of a long-running app.
    private var completedUsageByRun: [AgentRunID: PendingUsage] = [:]
    private var completedUsageRunOrder: [AgentRunID] = []
    private static let completedUsageTombstoneLimit = 256
    private var sessionLearnInputTokensByRun: [AgentRunID: Int] = [:]
    private var pendingUsageFlushTask: Task<Void, Never>?
    /// Test seam used to deterministically fail a usage write before the real
    /// store mutation. Production never sets this.
    var beforeTokenSaverUsageWriteForTesting: (@Sendable () throws -> Void)?
    var tokenSaverUsageTombstoneLimitForTesting: Int?
    var completedUsageTombstoneCountForTesting: Int { completedUsageByRun.count }
    func hasCompletedUsageTombstoneForTesting(runId: AgentRunID) -> Bool {
        completedUsageByRun[runId] != nil
    }
    private var cachedDistillClientKey: String?
    private var cachedDistillClient: DistillServiceClient?
    private var tokenSaverPromptSkipSet: [DistillResultCacheKey: Date] = [:]
    /// Test seam: when set, used instead of resolving a client from the live
    /// sidecar status. Production code never sets this.
    var distillClientOverrideForTesting: DistillServiceClient?
    var queueDrainProviderIdleTimeout: TimeInterval = 10
    var queueDrainBeforeDispatchForTesting: (() async -> Void)?
    /// Test seam for the single warning deadline; queue progress is causal.
    var queueDrainSleepForTesting: ((AgentThreadID, Duration) async throws -> Duration)?
    var queueDrainSuppressionAcquiredForTesting: ((AgentThreadID) async -> Void)?
    private struct QueueDrainWaiter {
        let token: UUID
        let task: Task<Void, Never>
    }
    private var queueDrainWaiters: [AgentThreadID: QueueDrainWaiter] = [:]
    private var queueDrainSuppressionLeases: [AgentThreadID: Set<UUID>] = [:]
    private var queueDispatchAcceptancePermits: [AgentThreadID: AgentRunAcceptancePermit] = [:]
    private struct DeferredQueuePromotion {
        let ownerId: AgentQueuedMessageID
        let targetId: AgentQueuedMessageID
    }
    private var deferredQueuePromotions: [AgentThreadID: DeferredQueuePromotion] = [:]
    /// A transient thread readback failure cannot safely decide whether it may
    /// stop provider/queue ownership. Retain the exact deleted candidate until
    /// a later read proves it absent (retire) or present (drop the candidate).
    private struct PendingDeletedThreadRetirement {
        var retryLogged = false
    }
    private var pendingDeletedThreadRetirements: [AgentThreadID: PendingDeletedThreadRetirement] = [:]
    private var deletedThreadRetirementRetryTask: Task<Void, Never>?
    private static let deletedThreadRetirementRetryBaseDelayNanoseconds: UInt64 = 50_000_000
    private static let deletedThreadRetirementRetryMaximumDelayNanoseconds: UInt64 = 2_000_000_000
    private var isTerminating = false
    private struct TokenSaverAccountIdentity: Equatable {
        let userID: String?
        let subscribed: Bool
    }
    private var tokenSaverAccountObserver: NSObjectProtocol?
    private var tokenSaverEntitlementReconcileTask: Task<Void, Never>?
    private var lastTokenSaverAccountIdentity: TokenSaverAccountIdentity?
    private var tokenSaverRuntimeAdmitted = false
    /// Test seam for account-change readiness without installing multi-GB models.
    /// Production leaves this nil and validates the real on-disk manifests.
    var tokenSaverEntitlementModelValidationOverrideForTesting: TokenSaverModelValidation?
    var queueDrainWaiterCountForTesting: Int { queueDrainWaiters.count }
    var queueDrainSuppressedThreadCountForTesting: Int { queueDrainSuppressionLeases.count }
    #if DEBUG
    var deletedThreadRetirementRetryDelayNanosecondsForTesting: UInt64?
    var pendingDeletedThreadRetirementIDsForTesting: Set<AgentThreadID> {
        Set(pendingDeletedThreadRetirements.keys)
    }

    var deletedThreadQueueRuntimeResidueForTesting: Set<AgentThreadID> {
        Set(queueDrainWaiters.keys)
            .union(queueDrainSuppressionLeases.keys)
            .union(queueDispatchAcceptancePermits.keys)
            .union(deferredQueuePromotions.keys)
    }

    func seedDeletedThreadQueueRuntimeStateForTesting(_ threadId: AgentThreadID) {
        queueDrainWaiters[threadId] = QueueDrainWaiter(
            token: UUID(),
            task: Task<Void, Never> {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        )
        queueDrainSuppressionLeases[threadId] = [UUID()]
        queueDispatchAcceptancePermits[threadId] = AgentRunAcceptancePermit()
        deferredQueuePromotions[threadId] = DeferredQueuePromotion(
            ownerId: AgentQueuedMessageID(),
            targetId: AgentQueuedMessageID()
        )
    }
    #endif
    /// Test seam: sandbox the SessionLearn target instruction files so tests never write
    /// into the developer's real ~/.claude/CLAUDE.md or ~/.codex/AGENTS.md.
    var sessionLearnInstructionFilesOverrideForTesting: [URL]?
    /// Test seam: sandboxes the managed-skill/config install roots under a temp home so
    /// tests never write /distill state into the developer's real ~/.claude or
    /// ~/.codex. Production code never sets this (installs to the real provider dirs).
    var agentSkillsHomeOverrideForTesting: URL?
    /// Test seam for proving paid cleanup does not depend on legacy-home cleanup.
    /// Production leaves this nil and calls the ownership-safe installer scrub.
    var legacyDistillCleanupOverrideForTesting: (() throws -> Void)?
    var tokenSaverRolloverBeforeCommitForTesting: (() throws -> Void)?
    /// Prompts shorter than this are sent verbatim: distillation overhead/latency
    /// isn't worth it and tiny instructions have nothing to compress.
    // Raised from 600: below ~2k chars a model round-trip on the awaited prompt path
    // rarely nets out positive once MLX latency is counted (NetPositiveGate floor, G3).
    private static let tokenSaverMinCompressChars = 2_000
    private static let tokenSaverDistillStartupPolls = 300
    private static let tokenSaverPromptSkipSetTTL: TimeInterval = 1_800
    private static let tokenSaverUsageNotificationMinimumInterval: TimeInterval = 2
    /// Process-local once flag for empty lane_state diagnostic (silent-death condition).
    private static var didLogEmptyTokenSaverLaneState = false
    /// Debounce window for coalescing per-token usage writes into one disk write.
    private static let tokenSaverUsageDebounceInterval: TimeInterval = 0.75

    /// Releases host-owned state after a cap transaction has committed its
    /// deletes. This deliberately has no EventBus/UI side effect: callers retain
    /// the existing delete-before-create publication order. A failed read or a
    /// restored row is not permission to cancel queue/provider ownership.
    func retireDeletedAgentThreads(
        _ ids: [AgentThreadID],
        coordinatorAlreadyRetired _: Bool = false
    ) {
        var seen: Set<AgentThreadID> = []
        let ordered = ids
            .filter { seen.insert($0).inserted }
            .sorted { $0.value.uuidString < $1.value.uuidString }
        for threadId in ordered {
            if pendingDeletedThreadRetirements[threadId] == nil {
                pendingDeletedThreadRetirements[threadId] = PendingDeletedThreadRetirement()
            }
        }
        drainPendingDeletedThreadRetirements()
        schedulePendingDeletedThreadRetirementRetry()
    }

    /// Drain in a stable order so concurrent cap/fork lifecycle paths cannot
    /// produce nondeterministic teardown. The coordinator is the sole durable
    /// verifier; AppContext clears queue ownership only after terminal retirement.
    private func drainPendingDeletedThreadRetirements() {
        let ordered = pendingDeletedThreadRetirements.keys.sorted {
            $0.value.uuidString < $1.value.uuidString
        }
        for threadId in ordered {
            guard var pending = pendingDeletedThreadRetirements[threadId] else { continue }
            let outcome = coordinator.retireDeletedThreads(
                [threadId],
                scheduleRetries: false
            )[threadId] ?? .retryRequired
            switch outcome {
            case .retired:
                pendingDeletedThreadRetirements.removeValue(forKey: threadId)
                queueDrainWaiters.removeValue(forKey: threadId)?.task.cancel()
                queueDrainSuppressionLeases.removeValue(forKey: threadId)
                queueDispatchAcceptancePermits.removeValue(forKey: threadId)?.invalidate()
                deferredQueuePromotions.removeValue(forKey: threadId)
                appContextRuntimeLog.info(
                    "thread.retirement.outcome thread=\(threadId.value.uuidString, privacy: .public) outcome=retired"
                )
            case .confirmedPresent:
                // A restored row owns its queue/session state; only the stale
                // retirement candidate is terminally resolved.
                pendingDeletedThreadRetirements.removeValue(forKey: threadId)
                appContextRuntimeLog.info(
                    "thread.retirement.outcome thread=\(threadId.value.uuidString, privacy: .public) outcome=present"
                )
            case .retryRequired:
                if pending.retryLogged == false {
                    pending.retryLogged = true
                    pendingDeletedThreadRetirements[threadId] = pending
                    appContextRuntimeLog.info(
                        "thread.retirement.retry_pending thread=\(threadId.value.uuidString, privacy: .public)"
                    )
                }
            }
        }
    }

    private func schedulePendingDeletedThreadRetirementRetry() {
        guard deletedThreadRetirementRetryTask == nil,
              !pendingDeletedThreadRetirements.isEmpty else { return }
        deletedThreadRetirementRetryTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let delay = self?.deletedThreadRetirementRetryDelay(attempt: attempt) else {
                    return
                }
                try? await Task.sleep(nanoseconds: delay)
                guard let self, !Task.isCancelled else { return }
                self.drainPendingDeletedThreadRetirements()
                guard !self.pendingDeletedThreadRetirements.isEmpty else {
                    self.deletedThreadRetirementRetryTask = nil
                    return
                }
                attempt = min(attempt + 1, 5)
            }
        }
    }

    private func deletedThreadRetirementRetryDelay(attempt: Int) -> UInt64 {
        #if DEBUG
        let baseDelay = deletedThreadRetirementRetryDelayNanosecondsForTesting
            ?? Self.deletedThreadRetirementRetryBaseDelayNanoseconds
        #else
        let baseDelay = Self.deletedThreadRetirementRetryBaseDelayNanoseconds
        #endif
        return min(
            baseDelay * UInt64(1 << min(attempt, 5)),
            Self.deletedThreadRetirementRetryMaximumDelayNanoseconds
        )
    }

    func enqueueRecoveredForkPrunedThreadIDs(_ ids: [AgentThreadID]) {
        // reconcileForkIntent already retired coordinator state immediately after
        // its local graph commit. Do the host queue portion even before a router
        // or Agent App surface exists; lifecycle publication remains deferred.
        retireDeletedAgentThreads(ids, coordinatorAlreadyRetired: true)
        pendingRecoveredForkPrunedThreadIDs.formUnion(ids)
        drainRecoveredForkPrunedThreadIDsIfPossible()
    }

    private func drainRecoveredForkPrunedThreadIDsIfPossible() {
        guard let router, !pendingRecoveredForkPrunedThreadIDs.isEmpty else { return }
        let ids = pendingRecoveredForkPrunedThreadIDs.sorted {
            $0.value.uuidString < $1.value.uuidString
        }
        pendingRecoveredForkPrunedThreadIDs.removeAll()
        router.publishAgentThreadDeletions(ids)
    }

    /// Accumulates streaming tool body/output so Codex/Grok `itemDelta` paths still
    /// detect `graphify query|path|explain` (not only one-shot `itemStarted`).
    private struct GraphifyItemBuffer {
        var summary: String?
        var body: String = ""
        var output: String = ""
        var provider: String
        var createdAtMs: Int64
        var recordedInvocation: Bool = false
        var recordedExploration: Bool = false
    }
    private var graphifyItemBuffers: [String: GraphifyItemBuffer] = [:]
    private let graphifyItemBuffersLock = NSLock()

    public init(
        channel: ReleaseChannel = .debug,
        dbPathOverride: String? = nil,
        appSupportOverride: String? = nil,
        tokenSaverAccountUsageRefresher: TokenSaverAccountUsageRefreshing = TokenSaverAccountUsageRefresher(),
        agentSkillsHomeOverrideForTesting: URL? = nil,
        /// Interactive RemoteCode must reconcile abandoned runs on launch.
        /// Background helpers that share the same SQLite (Scheduled Task Agent)
        /// must NOT flip every live interactive run to `interrupted`.
        performLaunchRunReconciliation: Bool = true
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
        self.checkpointListGateway = AgentTurnCheckpointListGateway(db: db)
        self.agentThreadListGateway = AgentThreadListGateway(db: db)
        self.workspaceListGateway = WorkspaceListGateway(agentThreadListGateway: self.agentThreadListGateway)
        self.tokenSaverSavingsRepo = TokenSaverSavingsRepository(db: db)
        self.tokenSaverDailyEconomyRepo = TokenSaverDailyEconomyRepository(db: db)
        self.graphifyUsageRepo = GraphifyUsageRepository(db: db)
        self.tokenSaverAttemptLedger = TokenSaverAttemptLedger(db: db)
        self.tokenSaverSessionLearnRepo = TokenSaverSessionLearnRepository(db: db)
        self.tokenSaverLaneStateRepo = TokenSaverLaneStateRepository(db: db)
        self.tokenSaverRolloverRepo = TokenSaverRolloverCapsuleRepository(db: db)
        self.tokenSaverProjectDataRepo = TokenSaverProjectDataRepository(db: db)
        self.tokenSaverAuditEventsRepo = TokenSaverAuditEventRepository(db: db)
        do {
            _ = try self.tokenSaverProjectDataRepo.performLifecycleSweep()
        } catch {
            let reason = "lifecycle_sweep_failed: \((error as NSError).localizedDescription)"
            self.tokenSaverLifecycleDegradedReason = reason
            NSLog("RemoteCode Token Saver launch lifecycle sweep entered degraded verbatim mode: \(reason)")
        }
        // WHY: production installs historically had 0 token_saver_lane_state rows while
        // Token Saver was enabled — every project-admission governed write silently no-op'd.
        // Log once so the silent-death condition is visible in unified logs.
        Self.logEmptyLaneStateIfNeeded(
            tokenSaverEnabled: SettingsStore(db: db).load().tokenSaverEnabled,
            laneStateCount: (try? self.tokenSaverLaneStateRepo.countAll()) ?? 0
        )
        let privatePushTargetStore = PrivatePushTargetStore(repo: self.settingsRepo)
        let privateNotificationBridge = PrivateNotificationBridge(
            accountStore: PrivateAccountSessionStore(repo: self.settingsRepo),
            pushTargetStore: privatePushTargetStore
        )
        self.privateNotificationBridge = privateNotificationBridge
        let liveActivityIdentity = try LiveActivityIdentityStore.beginBoot(settings: self.settingsRepo)
        self.liveActivityHostIdentity = liveActivityIdentity
        // S-005a/S-006: Phase A silent wakes with silent_catchup.v1 wm/boot_epoch/since_seq.
        MaterialWakeCoordinator.shared.start(
            bridge: privateNotificationBridge,
            bootEpochProvider: { String(liveActivityIdentity.bootEpoch) },
            watermarkProvider: { String(EventBus.shared.currentSeq) }
        )
        // WHY: Mac relaunch invalidates every cached iOS surface/session view.
        // `host.boot_epoch` is the only `.silentForce` producer; without this
        // publish the force class has zero runtime coverage and suspended
        // phones never rebaseline on host restart.
        EventBus.shared.publish(
            kind: "host.boot_epoch",
            payload: .object([
                "boot_epoch": .number(Double(liveActivityIdentity.bootEpoch)),
                "server_id": .string(liveActivityIdentity.serverId),
            ])
        )
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
        do {
            _ = try privatePushTargetStore.pruneStaleActivityUpdateTargets()
        } catch {
            NSLog("Live Activity token prune failed during launch: \(error)")
        }
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
        self.orchestrationRuntime = AgentOrchestrationRuntime(
            repository: AgentOrchestrationRepository(db: db),
            costEstimator: AgentOrchestrationRuntime.productionCostEstimator
        )
        self.coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providerSessionRepo: providerSessionRuntimeRepo,
            checkpointRepo: turnCheckpointRepo,
            orchestrationRuntime: self.orchestrationRuntime,
            providerSnapshotSupplier: {
                await contextReference.value?.router?.listAgentProviderSnapshots() ?? []
            },
            providerAdapters: [.codex: codex, .claude: claude, .grok: grok]
        )
        self.coordinator.onRecoveredForkPrunedThreadIDs = { [weak contextReference] ids in
            await MainActor.run {
                contextReference?.value?.enqueueRecoveredForkPrunedThreadIDs(ids)
            }
        }
        // plan-final W0: durable terminal ledger write-before-UI (diagnostics dir).
        let diagnosticsDir = self.appSupportDirectory.appendingPathComponent("diagnostics", isDirectory: true)
        self.coordinator.terminalTransitionLedger = TerminalTransitionLedger(directory: diagnosticsDir)
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
        if performLaunchRunReconciliation {
            // Schedules run in-process. Prior-process provider sessions must be
            // interrupted on relaunch so scheduled_task_runs can finish instead of
            // being preserved forever as "foreign LaunchAgent" ownership.
            try coordinator.reconcileOnLaunch(preservingThreadIDs: [])
        } else {
            // Shared-DB background agents: never steal interactive ownership.
            // Publish an empty projection for this process only; leave durable
            // run/thread/session rows alone for the interactive host to own.
            coordinator.onActiveRunProjectionChanged?(
                ActiveRunProjection(runs: []),
                .launchReconciliation
            )
        }
        try? tokenSaverSavingsRepo.prune()
        self.coordinator.promptCompressor = { [weak self] prompt, provider, threadId, runId in
            guard let self else { return prompt }
            // task-08: cross-user raw-only before any SessionLearn/compress work.
            let sameUser = await MainActor.run { self.tokenSaverIsSameUser(threadId: threadId) }
            guard TokenSaverAdapterMatrix.tokenSaverCallbacksAllowed(isSameUser: sameUser, turn: .initial) else {
                return prompt
            }
            let scopedPrompt = await self.tokenSaverSessionLearnPrompt(
                prompt, provider: provider, threadId: threadId, runId: runId
            )
            return await self.tokenSaverCompress(prompt: scopedPrompt, provider: provider, threadId: threadId, runId: runId)
        }
        self.coordinator.followUpPromptCompressor = { [weak self] prompt, provider, threadId in
            guard let self else { return prompt }
            let sameUser = await MainActor.run { self.tokenSaverIsSameUser(threadId: threadId) }
            guard TokenSaverAdapterMatrix.tokenSaverCallbacksAllowed(isSameUser: sameUser, turn: .followUp) else {
                return prompt
            }
            let scopedPrompt = await self.tokenSaverSessionLearnPrompt(
                prompt, provider: provider, threadId: threadId, runId: nil
            )
            return await self.tokenSaverCompress(prompt: scopedPrompt, provider: provider, threadId: threadId, cacheState: "prompt_followup")
        }
        self.coordinator.finalResponseTranslator = { [weak self] response, provider, threadId, runId in
            guard let self else { return response }
            let sameUser = await MainActor.run { self.tokenSaverIsSameUser(threadId: threadId) }
            guard TokenSaverAdapterMatrix.tokenSaverCallbacksAllowed(isSameUser: sameUser, turn: .finalResponse) else {
                return response
            }
            return await self.tokenSaverHumanizeSR1Response(response, provider: provider, threadId: threadId, runId: runId)
        }
        // Recovered sessions rebuild their own request env in the coordinator, bypassing
        // providerEnvironment; feed them the same Token Saver env so distill survives resume.
        self.coordinator.recoveryEnvironmentProvider = { [weak self] provider, threadId in
            guard let self else { return [:] }
            let sameUser = await MainActor.run { self.tokenSaverIsSameUser(threadId: threadId) }
            guard TokenSaverAdapterMatrix.tokenSaverCallbacksAllowed(isSameUser: sameUser, turn: .recovery) else {
                return await MainActor.run {
                    self.subagentTelemetryEnvironment(provider: provider, threadId: threadId)
                }
            }
            var environment = await MainActor.run {
                self.subagentTelemetryEnvironment(provider: provider, threadId: threadId)
            }
            environment.merge(
                await self.tokenSaverAgentEnvironment(provider: provider, threadId: threadId)
            ) { _, new in new }
            return environment
        }
        self.coordinator.runEnvironmentProvider = { [weak self] provider, threadId, base in
            guard let self else { return [:] }
            let sameUser = await MainActor.run { self.tokenSaverIsSameUser(threadId: threadId) }
            guard TokenSaverAdapterMatrix.tokenSaverCallbacksAllowed(isSameUser: sameUser, turn: .initial) else {
                return await MainActor.run {
                    self.subagentTelemetryEnvironment(
                        provider: provider,
                        threadId: threadId,
                        baseEnvironment: base
                    )
                }
            }
            var environment = await MainActor.run {
                self.subagentTelemetryEnvironment(
                    provider: provider,
                    threadId: threadId,
                    baseEnvironment: base
                )
            }
            environment.merge(
                await self.tokenSaverAgentEnvironment(
                    provider: provider,
                    threadId: threadId,
                    baseEnvironment: base
                )
            ) { _, new in new }
            return environment
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
            let bootSettings = SettingsStore(db: db).load()
            if !bootSettings.tokenSaverEnabled {
                _ = applyTokenSaverLifecycle(
                    requestedEnabled: false,
                    persistPreference: false
                )
            } else {
                let bootSession = PrivateAccountSessionStore(repo: settingsRepo).load()
                if bootSession?.user.subscribed != true {
                    // Entitlement is known synchronously; no reason to hash
                    // multi-GB model files before failing closed.
                    _ = applyTokenSaverLifecycle(
                        requestedEnabled: true,
                        modelValidation: .init(
                            state: .missing,
                            reason: "model readiness not evaluated without subscription"
                        ),
                        persistPreference: false
                    )
                } else {
                    // Model validation may hash multi-GB weights on a cold cache.
                    // Revoke paid runtime synchronously, then admit it only after
                    // the full validation finishes off the main actor.
                    _ = applyTokenSaverLifecycle(
                        requestedEnabled: false,
                        persistPreference: false
                    )
                    let appSupport = appSupportDirectory
                    Task { @MainActor [weak self] in
                        let validation = await Task.detached(priority: .utility) {
                            TokenSaverModelInstaller(appSupportDirectory: appSupport)
                                .validateInstalledTokenSaverModels()
                        }.value
                        guard let self,
                              SettingsStore(db: self.db).load().tokenSaverEnabled else {
                            return
                        }
                        _ = self.applyTokenSaverLifecycle(
                            requestedEnabled: true,
                            modelValidation: validation,
                            persistPreference: false
                        )
                    }
                }
            }
        } else {
            // Still apply Graphify defaults outside distill reconcile gate (unit tests stay quiet).
            if !AppContext.isRunningUnitTests {
                reconcileGraphifyHost()
            }
        }

        // GAP-7: stream agent run lifecycle + timeline to the network
        // event bus so the iOS mirror renders agent output in real time
        // (kinds/payloads match the iOS MirrorEventReducer contract).
        func itemJSON(_ item: AssistantItem) -> JSONValue {
            // PERF: encode once, then JSONSerialization + JSONValue.from — avoids a
            // second full Codable walk via JSONDecoder on every agent.item.started
            // EventBus publish (same pattern as connectionSnapshotJSON).
            guard let data = try? JSONEncoder().encode(item),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                return .null
            }
            return JSONValue.from(object)
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
            // Bounded wire policy: never put a multi-MiB body into EventBus.
            EventBus.shared.publish(
                kind: "agent.message.appended",
                payload: AgentMessageTransport.appendedEventPayload(from: message)
            )
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
                self.recordGraphifyUsageFromAssistantItem(
                    item: item,
                    threadId: tid,
                    runId: runId
                )
            case .itemDelta(let itemId, let bodyAppend, let outputAppend, let summary):
                var p: [String: JSONValue] = ["thread_id": .string(t), "item_id": .string(itemId)]
                if let b = bodyAppend { p["body_append"] = .string(b) }
                if let o = outputAppend { p["output_append"] = .string(o) }
                if let s = summary { p["summary"] = .string(s) }
                EventBus.shared.publish(kind: "agent.item.delta", payload: .object(p))
                // Accumulate only — never finalize on partial stream chunks.
                self.recordGraphifyUsageFromItemDelta(
                    itemId: itemId,
                    bodyAppend: bodyAppend,
                    outputAppend: outputAppend,
                    summary: summary,
                    threadId: tid,
                    runId: runId,
                    finalize: false
                )
            case .itemState(let itemId, let state):
                if state != .streaming {
                    EventBus.shared.publish(kind: "agent.item.completed",
                                            payload: .object(["thread_id": .string(t), "item_id": .string(itemId)]))
                }
                // Fail only — do not finalize on itemState.completed (can race
                // before final output deltas). Success path: itemCompleted or
                // itemStarted(tool_result, state=completed, output set).
                if state == .failed || state == .cancelled {
                    self.failGraphifyUsageItem(itemId: itemId, runId: runId)
                }
            case .itemProgress(let itemId, let progress):
                var p: [String: JSONValue] = ["thread_id": .string(t), "item_id": .string(itemId)]
                if let progress { p["progress"] = .number(progress) }
                EventBus.shared.publish(kind: "agent.item.progress", payload: .object(p))
            case .itemCompleted(let itemId, let state):
                EventBus.shared.publish(kind: "agent.item.completed",
                                        payload: .object(["thread_id": .string(t), "item_id": .string(itemId), "state": .string(state.rawValue)]))
                if state == .failed || state == .cancelled {
                    self.failGraphifyUsageItem(itemId: itemId, runId: runId)
                } else if state == .completed {
                    self.finalizeGraphifyUsageItem(itemId: itemId, runId: runId)
                }
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
                // Visible push for main-agent approvals only (subagents stay quiet).
                self.postAgentUserActionPushIfNeeded(
                    threadId: tid,
                    runId: runId,
                    requestId: request.id,
                    actionTitle: "Approve: \(PetApprovalActionLabel.label(for: request.kind))"
                )
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
                self.postAgentUserActionPushIfNeeded(
                    threadId: tid,
                    runId: runId,
                    requestId: request.id,
                    actionTitle: request.isSecret ? "Secret input requested" : "Input requested"
                )
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
                    "total_tokens": .number(Double(usage.totalTokens)),
                    "semantics": .string(usage.resolvedSemantics.rawValue)
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
        coordinator.onRunFinished = { [weak self] tid, rid, status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let kind = (status == .completed) ? "agent.run.completed" : "agent.run.failed"
                EventBus.shared.publish(kind: kind, payload: agentRunPayload(threadId: tid, runId: rid, status: status))
                EventBus.shared.publish(kind: "agent.run.finished", payload: agentRunPayload(threadId: tid, runId: rid, status: status))
                // Flush any debounced usage for this run now that the run is done so
                // the final token batch is never stranded in the accumulator.
                self.finishPendingTokenSaverUsage(runId: rid)
                self.recordSessionLearnFromRun(runId: rid, status: status) // P5 SessionLearn (off by default)
                // Grok has no live `.accountUsage` stream (Claude/Codex do). Re-read
                // the local billing snapshot after each Grok run so the Token Saver
                // purple ring updates without waiting for the 5-minute periodic probe.
                if let run = try? self.runRepo.get(id: rid), run.provider == .grok {
                    self.refreshGrokTokenSaverAccountUsage(reason: "run_finished")
                }
                // Drain the next queued message after ANY terminal status. stopRun
                // can publish its host terminal before a provider-native interrupt
                // makes the adapter idle. Wait through that bounded cancellation
                // window; otherwise Force gets one premature drain and the promoted
                // message remains stranded with no later lifecycle callback.
                self.ensureQueueDrainWaiterIfNeeded(threadId: tid)
                // Main agent only: nested/subagent workers must not fire
                // system or private push banners (parent owns user-facing UX).
                if let content = RemoteCodeNotificationContent.threadOutcome(
                    threadId: tid.value.uuidString,
                    workspaceId: (try? self.threadRepo.get(id: tid)?.workspaceId)?.value.uuidString,
                    title: try? self.threadRepo.get(id: tid)?.title,
                    phase: status,
                    isNestedWorker: self.isNestedAgentWorker(runId: rid, threadId: tid)
                ) {
                    // Mac desktop toast always. Remote iOS banner is suppressed
                    // when Live Activity already covers Lock Screen (attention
                    // path still uses deliver(_:) and is never gated here).
                    SystemNotifier.shared.post(content)
                    Task {
                        await self.privateNotificationBridge.deliverThreadOutcomeRemote(
                            content,
                            phase: status
                        )
                    }
                }
            }
        }
        coordinator.onProviderIdle = { [weak self] threadId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Adapters finalize their resident-session status immediately
                // after returning from the terminal callback.
                await Task.yield()
                await self.providerBecameIdle(threadId: threadId)
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
                MainActor.assumeIsolated {
                    _ = self?.prepareForApplicationTermination()
                }
            }
        }

        lastTokenSaverAccountIdentity = currentTokenSaverAccountIdentity()
        tokenSaverAccountObserver = NotificationCenter.default.addObserver(
            forName: .rc2PrivateAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileTokenSaverLifecycleAfterAccountChange()
            }
        }

        // restore last snapshot if any
        if let snap = try snapshotRepo.latest() {
            self.state = snap.layout
        }
    }

    deinit {
        deletedThreadRetirementRetryTask?.cancel()
        tokenSaverEntitlementReconcileTask?.cancel()
        if let tokenSaverAccountObserver {
            NotificationCenter.default.removeObserver(tokenSaverAccountObserver)
        }
    }

    func ensureQueueDrainWaiterIfNeeded(threadId: AgentThreadID) {
        guard queueDrainAllowsWork(threadId: threadId) else { return }
        guard let queuedMessages = try? queuedMessageRepo.list(threadId: threadId),
              !queuedMessages.isEmpty else {
            cancelQueueDrainWaiterIfQueueEmpty(threadId: threadId)
            return
        }
        guard queueDrainWaiters[threadId] == nil else { return }
        let timeout = Duration.seconds(max(0.001, queueDrainProviderIdleTimeout))
        let token = UUID()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let queueDrainSleepForTesting = self.queueDrainSleepForTesting {
                    _ = try await queueDrainSleepForTesting(threadId, timeout)
                } else {
                    try await ContinuousClock().sleep(for: timeout)
                }
            } catch {
                return
            }
            guard self.queueDrainWaiters[threadId]?.token == token,
                  self.queueDrainAllowsWork(threadId: threadId),
                  self.coordinator.hasProviderSession(threadId: threadId) else { return }
            switch (try? self.threadRepo.get(id: threadId))?.status {
            case .completed, .failed, .cancelled, .interrupted:
                EventBus.shared.publish(kind: "agent.message.queue.failed", payload: .object([
                    "thread_id": .string(threadId.value.uuidString),
                    "message": .string("Provider is still stopping. The queued message remains safe and will start when the provider becomes idle.")
                ]))
            case .pending, .running, nil:
                break
            }
        }
        queueDrainWaiters[threadId] = QueueDrainWaiter(token: token, task: task)
        if !coordinator.hasProviderSession(threadId: threadId) {
            Task { @MainActor [weak self] in
                await self?.finishScheduledQueueDrain(threadId: threadId, token: token)
            }
        }
    }

    private func providerBecameIdle(threadId: AgentThreadID) async {
        guard let waiter = queueDrainWaiters[threadId],
              !coordinator.hasProviderSession(threadId: threadId) else { return }
        await finishScheduledQueueDrain(threadId: threadId, token: waiter.token)
    }

    private func finishScheduledQueueDrain(threadId: AgentThreadID, token: UUID) async {
        guard queueDrainWaiters[threadId]?.token == token,
              queueDrainAllowsWork(threadId: threadId),
              !Task.isCancelled else {
            removeQueueDrainWaiter(threadId: threadId, token: token)
            return
        }
        defer { removeQueueDrainWaiter(threadId: threadId, token: token) }
        if let queueDrainBeforeDispatchForTesting {
            await queueDrainBeforeDispatchForTesting()
        }
        guard queueDrainAllowsWork(threadId: threadId), !Task.isCancelled else { return }
        do {
            try await router?.drainNextQueuedAgentMessage(thread: threadId)
        } catch is CancellationError {
            return
        } catch {
            EventBus.shared.publish(kind: "agent.message.queue.failed", payload: .object([
                "thread_id": .string(threadId.value.uuidString),
                "message": .string(String(describing: error))
            ]))
        }
    }

    func cancelQueueDrainWaiterIfQueueEmpty(threadId: AgentThreadID) {
        guard ((try? queuedMessageRepo.list(threadId: threadId)) ?? []).isEmpty else { return }
        deferredQueuePromotions.removeValue(forKey: threadId)
        cancelQueueDrainWaiter(threadId: threadId)
    }

    func cancelQueueDrainWaiter(threadId: AgentThreadID) {
        queueDrainWaiters.removeValue(forKey: threadId)?.task.cancel()
    }

    func registerQueueDispatchAcceptancePermit(
        _ permit: AgentRunAcceptancePermit,
        threadId: AgentThreadID
    ) {
        queueDispatchAcceptancePermits[threadId]?.invalidate()
        queueDispatchAcceptancePermits[threadId] = permit
    }

    func unregisterQueueDispatchAcceptancePermit(
        _ permit: AgentRunAcceptancePermit,
        threadId: AgentThreadID
    ) {
        guard queueDispatchAcceptancePermits[threadId] === permit else { return }
        queueDispatchAcceptancePermits.removeValue(forKey: threadId)
    }

    func deferQueuePromotion(
        id: AgentQueuedMessageID,
        after ownerId: AgentQueuedMessageID,
        threadId: AgentThreadID
    ) {
        deferredQueuePromotions[threadId] = DeferredQueuePromotion(
            ownerId: ownerId,
            targetId: id
        )
    }

    func deferredQueuePromotion(
        threadId: AgentThreadID,
        ownerId: AgentQueuedMessageID
    ) -> AgentQueuedMessageID? {
        guard deferredQueuePromotions[threadId]?.ownerId == ownerId else { return nil }
        return deferredQueuePromotions[threadId]?.targetId
    }

    func clearDeferredQueuePromotion(
        threadId: AgentThreadID,
        ownerId: AgentQueuedMessageID
    ) {
        guard deferredQueuePromotions[threadId]?.ownerId == ownerId else { return }
        deferredQueuePromotions.removeValue(forKey: threadId)
    }

    func acquireQueueDrainSuppression(threadId: AgentThreadID) async -> UUID {
        await acquireQueueDrainSuppressions(threadIds: [threadId])[0].1
    }

    /// Installs every lease and invalidates every pending provider acceptance
    /// before awaiting any one drain task. This prevents an idle sibling thread
    /// from starting while a stuck sibling is still cancelling.
    func acquireQueueDrainSuppressions(
        threadIds: [AgentThreadID]
    ) async -> [(AgentThreadID, UUID)] {
        var seen: Set<AgentThreadID> = []
        let ordered = threadIds.filter { seen.insert($0).inserted }
        var leases: [(AgentThreadID, UUID)] = []
        var waiters: [Task<Void, Never>] = []
        var acceptanceAttempts: [(AgentThreadID, AgentRunAcceptanceAttempt)] = []
        for threadId in ordered {
            let lease = UUID()
            queueDrainSuppressionLeases[threadId, default: []].insert(lease)
            leases.append((threadId, lease))
            if let attempt = queueDispatchAcceptancePermits
                .removeValue(forKey: threadId)?
                .invalidate() {
                acceptanceAttempts.append((threadId, attempt))
            }
            if let waiter = queueDrainWaiters.removeValue(forKey: threadId) {
                waiter.task.cancel()
                waiters.append(waiter.task)
            }
        }
        // A claimed write linearized before suppression. Stop every affected
        // provider before awaiting any write completion so a stuck pipe cannot
        // delay cancellation of its siblings.
        for (threadId, _) in acceptanceAttempts {
            coordinator.stopRun(threadId: threadId)
        }
        if let queueDrainSuppressionAcquiredForTesting {
            for threadId in ordered {
                await queueDrainSuppressionAcquiredForTesting(threadId)
            }
        }
        let acceptanceWaiters = acceptanceAttempts.map { _, attempt in
            Task.detached {
                await attempt.wait()
            }
        }
        for waiter in waiters {
            await waiter.value
        }
        for waiter in acceptanceWaiters {
            await waiter.value
        }
        return leases
    }

    func releaseQueueDrainSuppression(threadId: AgentThreadID, lease: UUID) {
        guard var leases = queueDrainSuppressionLeases[threadId],
              leases.remove(lease) != nil else { return }
        if leases.isEmpty {
            queueDrainSuppressionLeases.removeValue(forKey: threadId)
            ensureQueueDrainWaiterIfNeeded(threadId: threadId)
        } else {
            queueDrainSuppressionLeases[threadId] = leases
        }
    }

    func queueDrainAllowsWork(threadId: AgentThreadID) -> Bool {
        !isTerminating && queueDrainSuppressionLeases[threadId]?.isEmpty != false
    }

    private func removeQueueDrainWaiter(threadId: AgentThreadID, token: UUID) {
        guard queueDrainWaiters[threadId]?.token == token else { return }
        queueDrainWaiters.removeValue(forKey: threadId)?.task.cancel()
    }

    private func cancelAllQueueDrainWaiters() -> [Task<Void, Never>] {
        let permits = queueDispatchAcceptancePermits
        queueDispatchAcceptancePermits.removeAll()
        var tasks = queueDrainWaiters.values.map(\.task)
        queueDrainWaiters.removeAll()
        for task in tasks { task.cancel() }
        for (threadId, permit) in permits {
            guard let attempt = permit.invalidate() else { continue }
            coordinator.stopRun(threadId: threadId)
            tasks.append(Task.detached {
                await attempt.wait()
            })
        }
        return tasks
    }

    @discardableResult
    func prepareForApplicationTermination() -> [Task<Void, Never>] {
        isTerminating = true
        flushPendingTokenSaverUsage()
        flushWriterQueue()
        return cancelAllQueueDrainWaiters()
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

    /// Distill + Token Saver environment for an agent run.
    /// Token economy is paid: Distill hint, managed-bin PATH, and Claude
    /// PostToolUse compression are emitted only while Token Saver is enabled.
    /// Workspace attribution still requires project admission when present.
    /// Single source for the normal run path and recovered-session path.
    ///
    /// Also emits a compact `TokenSaverExecutionReceipt` so nested orchestration
    /// workers inherit the same admitted lanes/capabilities as the root (provider-
    /// neutral; fail open when off/cross-user/sidecar-degraded for distill).
    func tokenSaverAgentEnvironment(
        provider: AgentProvider,
        threadId: AgentThreadID,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let sameUser = tokenSaverIsSameUser(threadId: threadId)
        // task-08: cross-user runs get no Token Saver env/hint/PATH managed bin.
        guard TokenSaverAdapterMatrix.tokenSaverCallbacksAllowed(
            isSameUser: sameUser,
            turn: .initial
        ) else {
            return [:]
        }
        let settings = SettingsStore(db: db).load()
        // Paid feature gate: no token-economy env while Token Saver is off.
        guard isTokenSaverRuntimeActive(settings: settings) else {
            return [:]
        }
        // Activate waves that have passed E2E live rollout (process-local).
        TokenSaverWaveLiveRollout.activateAll()
        // WHY: per-lane kill switch must reach child `distill` so an operator can
        // disable one compression lane during an incident without full rollback.
        // Exported even when managed install is degraded — the decision is independent.
        let cliState = TokenSaverLaneKillSwitch.loadCLIStateOverlay(
            from: tokenSaverDistillCLIStateURL
        )
        let disabled = TokenSaverLaneKillSwitch.resolvedDisabledLanes(
            environment: baseEnvironment,
            cliState: cliState
        )
        let enabled = TokenSaverLaneKillSwitch.resolvedEnabledLanes(
            environment: baseEnvironment,
            cliState: cliState
        )
        // Installation is not readiness. Prefer the controller's `.running`
        // event, but also accept a live DistillCLIState lease so a lagging
        // `.starting` / transient status mismatch cannot sticky-deny distill
        // for primary and nested runs after the sidecar is already serving.
        let sidecarAvailable: Bool
        if case .running = tokenSaverDistillServiceController.status {
            sidecarAvailable = true
        } else if Self.isRunningUnitTests,
                  distillClientOverrideForTesting != nil {
            // Unit tests that inject a live DistillServiceClient are exercising
            // environment admission, not the controller's process lifecycle.
            // Dedicated controller tests still cover failed/blocked readiness.
            switch tokenSaverDistillServiceController.status {
            case .failed, .blocked:
                sidecarAvailable = false
            default:
                sidecarAvailable = true
            }
        } else if Self.isRunningUnitTests,
                  tokenSaverDistillServiceController.status == .notStarted {
            // Pure environment-matrix tests have no sidecar process to start.
            // Treat the untouched test controller as an injected-ready seam;
            // explicit failed/blocked states remain fail-open below.
            sidecarAvailable = true
        } else if case .blocked = tokenSaverDistillServiceController.status {
            // Explicit eligibility block (subscription/model) must fail open.
            sidecarAvailable = false
        } else if TokenSaverSidecarLeaseProbe.isHealthy(stateFileURL: tokenSaverDistillCLIStateURL) {
            // Controller lag: ready lease on disk while status is still starting
            // or briefly notStarted after a restart.
            sidecarAvailable = true
        } else {
            sidecarAvailable = false
        }
        let live = TokenSaverWaveLiveRollout.liveWaves.map(\.rawValue).sorted().joined(separator: ",")
        let thread = try? threadRepo.get(id: threadId)
        let workspaceID = thread?.workspaceId?.value.uuidString
        let projectID = thread?.projectId?.value.uuidString ?? workspaceID
        let receipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: sidecarAvailable,
            provider: provider,
            threadId: threadId.value.uuidString,
            workspaceId: workspaceID,
            projectId: projectID,
            disabledLanes: disabled,
            enabledLanes: enabled,
            waveLive: live.isEmpty ? nil : live,
            graphifyActive: settings.isGraphifyRuntimeActive
        )
        var env = TokenSaverExecutionReceiptSeam.environment(from: receipt)
        // The begin/end worker bridge needs the same app database and neutral
        // provider identity; these are metadata only, never prompt content.
        env["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = appSupportDirectory.path
        env["REMOTE_CODE_AGENT_MODEL"] = thread?.model ?? "unknown"
        env["REMOTE_CODE_PROVIDER_INSTANCE_ID"] = thread?.providerInstanceId ?? provider.rawValue
        // Managed PATH is host-local (not inside the compact receipt JSON).
        if receipt.capabilities.managedPath == true {
            let installer = makeAgentSkillInstaller()
            // Automatic reinstall for any user on every admitted turn: missing
            // or dangling ~/.remote-code/bin/distill is repaired before PATH is
            // stamped (PostToolUse + `| distill` need a live binary).
            do {
                _ = try installer.ensureDistillCLI()
            } catch {
                NSLog(
                    "RemoteCode: ensureDistillCLI before agent turn failed: \(error.localizedDescription)"
                )
            }
            let managedBin = installer.managedCLIBinURL.path
            let currentPath = baseEnvironment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
            let pathParts = currentPath.split(separator: ":").map(String.init).filter { $0 != managedBin }
            env["PATH"] = ([managedBin] + pathParts).joined(separator: ":")
            env["RC_REMOTE_CODE_MANAGED_BIN"] = managedBin
        }
        // Claude PostToolUse needs the sidecar state file path (not a secret).
        if receipt.capabilities.postToolUse == true {
            env["REMOTE_CODE_DISTILL_STATE_PATH"] = appSupportDirectory
                .appendingPathComponent("Distill", isDirectory: true)
                .appendingPathComponent("DistillCLIState.json")
                .path
        }
        return env
    }

    /// Nested orchestration workers (subagents) carry a parent receipt. Main
    /// agent root runs have `parentReceiptId == nil` and `nodeId == "root"`.
    func isNestedAgentWorker(runId: AgentRunID, threadId: AgentThreadID) -> Bool {
        if let receipt = try? orchestrationRuntime.admissionReceipt(for: runId),
           RemoteCodeNotificationContent.AgentAppPushPolicy.isNestedWorker(
            parentReceiptId: receipt.parentReceiptId,
            nodeId: receipt.nodeId
           ) {
            return true
        }
        // Fall back when the event only carries the thread id of a nested worker.
        if let active = try? runRepo.latestActive(for: threadId),
           let receipt = try? orchestrationRuntime.admissionReceipt(for: active.id),
           RemoteCodeNotificationContent.AgentAppPushPolicy.isNestedWorker(
            parentReceiptId: receipt.parentReceiptId,
            nodeId: receipt.nodeId
           ) {
            return true
        }
        return false
    }

    /// System + private APNs banner when the main agent needs the user.
    /// Subagent / nested workers never produce push (parent owns UX).
    func postAgentUserActionPushIfNeeded(
        threadId: AgentThreadID,
        runId: AgentRunID,
        requestId: String,
        actionTitle: String
    ) {
        let nested = isNestedAgentWorker(runId: runId, threadId: threadId)
        guard let content = RemoteCodeNotificationContent.userActionNeeded(
            threadId: threadId.value.uuidString,
            workspaceId: (try? threadRepo.get(id: threadId)?.workspaceId)?.value.uuidString,
            threadTitle: try? threadRepo.get(id: threadId)?.title,
            actionTitle: actionTitle,
            requestId: requestId,
            isNestedWorker: nested
        ) else { return }
        SystemNotifier.shared.post(content)
        Task {
            await privateNotificationBridge.deliver(content)
        }
    }

    /// Always-on, content-free metadata for the provider-neutral Subagents
    /// lifecycle bridge. This is deliberately separate from Token Saver
    /// admission: turning Token Saver off removes every optimization lane, but
    /// must not make child activity disappear from the Agent App.
    func subagentTelemetryEnvironment(
        provider: AgentProvider,
        threadId: AgentThreadID,
        baseEnvironment: [String: String] = [:]
    ) -> [String: String] {
        let thread = try? threadRepo.get(id: threadId)
        var environment = baseEnvironment
        environment.merge([
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": appSupportDirectory.path,
            "RC_REMOTE_CODE_SUBAGENT_THREAD_ID": threadId.value.uuidString,
            "RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE": "1",
            "RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH": AppPaths.socketPath(for: channel),
            "REMOTE_CODE_AGENT_PROVIDER": provider.rawValue,
            "REMOTE_CODE_AGENT_MODEL": thread?.model ?? "unknown",
            "REMOTE_CODE_PROVIDER_INSTANCE_ID": thread?.providerInstanceId ?? provider.rawValue,
        ]) { _, new in new }
        let installer = makeAgentSkillInstaller()
        // Nested launches inherit managed bin; keep distill healthy whenever Token
        // Saver is admitted so child shells and PostToolUse hooks never see a gap.
        if tokenSaverRuntimeAdmitted {
            do {
                _ = try installer.ensureDistillCLI()
            } catch {
                NSLog(
                    "RemoteCode: ensureDistillCLI before subagent env failed: \(error.localizedDescription)"
                )
            }
        }
        let managedBin = installer.managedCLIBinURL.path
        let basePath = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        environment["PATH"] = AppCommandRouter.providerPathWithManagedWrappers(
            currentPath: basePath,
            managedBin: managedBin
        )
        environment["RC_REMOTE_CODE_MANAGED_BIN"] = managedBin
        environment.removeValue(forKey: "RC_REMOTE_CODE_AGENT_APP_COMMAND")
        if let agentAppCommand = installer.verifiedAgentAppMiddlewareURL() {
            environment["RC_REMOTE_CODE_AGENT_APP_COMMAND"] = agentAppCommand.path
        }

        let shellBridge = installer.providerShellBridgeURL
        let shellBridgeFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"]
        if shellBridgeFiles.allSatisfy({
            FileManager.default.fileExists(atPath: shellBridge.appendingPathComponent($0).path)
        }) {
            let originalZDOTDIR = environment["ZDOTDIR"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let providerHome = environment["HOME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let processHome = ProcessInfo.processInfo.environment["HOME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveHome = (providerHome?.isEmpty == false)
                ? providerHome!
                : ((processHome?.isEmpty == false)
                    ? processHome!
                    : FileManager.default.homeDirectoryForCurrentUser.path)
            let originalDirectory = (originalZDOTDIR?.isEmpty == false)
                ? originalZDOTDIR!
                : effectiveHome
            environment["RC_REMOTE_CODE_ORIGINAL_ZDOTDIR"] =
                originalDirectory == shellBridge.path
                ? effectiveHome
                : originalDirectory
            environment["RC_REMOTE_CODE_EFFECTIVE_ZDOTDIR"] =
                environment["RC_REMOTE_CODE_ORIGINAL_ZDOTDIR"]
            environment["RC_REMOTE_CODE_MANAGED_ZDOTDIR"] = shellBridge.path
            environment["ZDOTDIR"] = shellBridge.path
        } else {
            environment.removeValue(forKey: "RC_REMOTE_CODE_ORIGINAL_ZDOTDIR")
            environment.removeValue(forKey: "RC_REMOTE_CODE_EFFECTIVE_ZDOTDIR")
            environment.removeValue(forKey: "RC_REMOTE_CODE_MANAGED_ZDOTDIR")
        }
        if let workspaceID = thread?.workspaceId?.value.uuidString {
            environment["RC_REMOTE_CODE_WORKSPACE_ID"] = workspaceID
        }
        if let telemetryExecutable = Self.subagentTelemetryExecutableURL()?.path {
            environment["REMOTE_CODE_SUBAGENT_TELEMETRY_COMMAND"] = telemetryExecutable
        }
        return environment
    }

    private static func subagentTelemetryExecutableURL() -> URL? {
        let candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent("RemoteCodeDistillService"),
            URL(fileURLWithPath: CommandLine.arguments.first ?? "")
                .deletingLastPathComponent()
                .appendingPathComponent("RemoteCodeDistillService"),
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
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

    /// Configure Graphify host. Runtime is active only when Token Saver AND the
    /// Graphify preference are on (`AppSettings.isGraphifyRuntimeActive`). When
    /// inactive, fail-open: no ensure, no RC_GRAPHIFY_*, no FSEvents watchers.
    /// If CLI is missing while active, `ensureBinaryInstalledIfNeeded` may try
    /// `uv tool install graphifyy` once.
    public func reconcileGraphifyHost(settings: AppSettings? = nil) {
        let s = settings ?? SettingsStore(db: db).load()
        let active = isTokenSaverRuntimeActive(settings: s) && s.isGraphifyRuntimeActive
        let svc = GraphifyWorkspaceService.shared
        svc.enabled = active
        svc.autoEnsure = active && s.graphifyAutoEnsure
        svc.writeInRepo = s.graphifyWriteInRepo
        svc.pinnedRoots = s.graphifyPinnedRoots
        let path = s.graphifyBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        svc.binaryPathOverride = path.isEmpty ? nil : path
        guard active else {
            svc.stopWatchingAll()
            return
        }
        LoginShellEnvironment.prewarm()
        DispatchQueue.global(qos: .utility).async {
            _ = GraphifyWorkspaceService.shared.ensureBinaryInstalledIfNeeded()
        }
    }

    /// Apply the single Token Saver lifecycle used by launch, Settings, and the
    /// sidebar. A persisted preference is only a request: paid integration is
    /// admitted after both entitlement and local-model readiness pass.
    ///
    /// `persistPreference` is false at boot so a temporarily unavailable account
    /// does not erase the user's choice. Interactive toggles pass true so a
    /// rejected enable cannot leave the UI/store claiming Token Saver is active.
    @discardableResult
    public func applyTokenSaverLifecycle(
        requestedEnabled: Bool,
        modelValidation: TokenSaverModelValidation? = nil,
        persistPreference: Bool
    ) -> TokenSaverLifecycleOutcome {
        let settingsStore = SettingsStore(db: db)

        func settings(enabled: Bool) -> AppSettings {
            var value = settingsStore.load()
            value.tokenSaverEnabled = enabled
            return value
        }

        func disableRuntime() -> String? {
            tokenSaverRuntimeAdmitted = false
            if persistPreference {
                settingsStore.update { $0.tokenSaverEnabled = false }
            }
            // Revoke live capabilities before touching any legacy install. A
            // failed legacy scrub must never leave a resident paid sidecar,
            // Graphify watcher, CLI, wrapper, or retrieve MCP active.
            tokenSaverDistillServiceController.stop()
            reconcileGraphifyHost(settings: settings(enabled: false))
            return reconcileManagedDistillSkills(tokenSaverEnabled: false)
        }

        guard requestedEnabled else {
            if let error = disableRuntime() {
                return .failed(error)
            }
            return .disabled
        }

        let session = PrivateAccountSessionStore(repo: settingsRepo).load()
        let validation = modelValidation
            ?? TokenSaverModelInstaller(appSupportDirectory: appSupportDirectory)
                .validateInstalledTokenSaverModels()
        let enabledSettings = settings(enabled: true)
        let decision = TokenSaverDistillLaunchPlanner.decide(.init(
            hasPrivateAccount: session != nil,
            isSubscribed: session?.user.subscribed == true,
            tokenSaverEnabled: true,
            modelValidation: validation
        ))

        switch decision {
        case .skip(let reason):
            if let cleanupError = disableRuntime() {
                return .failed(cleanupError)
            }
            return .blocked(reason)
        case .requireModel(let reason):
            if let cleanupError = disableRuntime() {
                return .failed(cleanupError)
            }
            return .blocked(reason ?? "model download required")
        case .start:
            break
        }

        if let installError = reconcileManagedDistillSkills(tokenSaverEnabled: true) {
            _ = disableRuntime()
            return .failed(installError)
        }
        if persistPreference {
            settingsStore.update { $0.tokenSaverEnabled = true }
        }
        tokenSaverRuntimeAdmitted = true
        tokenSaverDistillServiceController.startIfEligible(
            session: session,
            settings: enabledSettings,
            modelValidation: validation
        )
        activatePreferredTokenSaverModelIfDownloaded(
            settings: enabledSettings,
            session: session
        )
        reconcileGraphifyHost(settings: enabledSettings)
        return .enabled
    }

    /// A stored ON preference is only a request. Runtime admission also requires
    /// a currently subscribed account and one successful lifecycle admission.
    /// Unit tests without a sandboxed integration root retain their historical
    /// direct-settings seam; production and lifecycle tests always use the real gate.
    func isTokenSaverRuntimeActive(settings: AppSettings? = nil) -> Bool {
        let stored = settings ?? SettingsStore(db: db).load()
        guard stored.tokenSaverEnabled else { return false }
        if Self.isRunningUnitTests, agentSkillsHomeOverrideForTesting == nil {
            return true
        }
        guard tokenSaverRuntimeAdmitted,
              PrivateAccountSessionStore(repo: settingsRepo).load()?.user.subscribed == true else {
            return false
        }
        return true
    }

    private func currentTokenSaverAccountIdentity() -> TokenSaverAccountIdentity {
        let session = PrivateAccountSessionStore(repo: settingsRepo).load()
        return TokenSaverAccountIdentity(
            userID: session?.user.id,
            subscribed: session?.user.subscribed == true
        )
    }

    /// Central account/session lifecycle hook. Subscription loss revokes paid
    /// capabilities synchronously while preserving the requested preference.
    /// Renewal validates models off the main actor before re-admitting anything.
    private func reconcileTokenSaverLifecycleAfterAccountChange() {
        let identity = currentTokenSaverAccountIdentity()
        guard identity != lastTokenSaverAccountIdentity else { return }
        lastTokenSaverAccountIdentity = identity
        tokenSaverEntitlementReconcileTask?.cancel()
        tokenSaverEntitlementReconcileTask = nil

        let requested = SettingsStore(db: db).load().tokenSaverEnabled
        guard requested else {
            _ = applyTokenSaverLifecycle(
                requestedEnabled: false,
                persistPreference: false
            )
            return
        }
        guard identity.subscribed else {
            _ = applyTokenSaverLifecycle(
                requestedEnabled: true,
                modelValidation: .init(
                    state: .missing,
                    reason: "model readiness not evaluated without subscription"
                ),
                persistPreference: false
            )
            return
        }

        // Revoke the previous account's capabilities before validating a renewed
        // or replacement subscription. The persisted request remains ON.
        _ = applyTokenSaverLifecycle(
            requestedEnabled: false,
            persistPreference: false
        )
        if let validation = tokenSaverEntitlementModelValidationOverrideForTesting {
            _ = applyTokenSaverLifecycle(
                requestedEnabled: true,
                modelValidation: validation,
                persistPreference: false
            )
            return
        }

        let appSupport = appSupportDirectory
        tokenSaverEntitlementReconcileTask = Task { @MainActor [weak self] in
            let validation = await Task.detached(priority: .utility) {
                TokenSaverModelInstaller(appSupportDirectory: appSupport)
                    .validateInstalledTokenSaverModels()
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.currentTokenSaverAccountIdentity() == identity,
                  SettingsStore(db: self.db).load().tokenSaverEnabled else {
                return
            }
            self.tokenSaverEntitlementReconcileTask = nil
            _ = self.applyTokenSaverLifecycle(
                requestedEnabled: true,
                modelValidation: validation,
                persistPreference: false
            )
        }
    }

    /// Quit-time lifecycle is cleanup-only. It never installs hooks or starts a
    /// process from a persisted bool: eligible state is left as-is, while an
    /// ineligible/off state is revoked before the app exits.
    @discardableResult
    public func prepareTokenSaverLifecycleForTermination() -> TokenSaverLifecycleOutcome {
        tokenSaverDistillServiceController.stop()
        let settingsStore = SettingsStore(db: db)
        let storedSettings = settingsStore.load()
        guard storedSettings.tokenSaverEnabled else {
            reconcileGraphifyHost(settings: storedSettings)
            if let error = reconcileManagedDistillSkills(tokenSaverEnabled: false) {
                return .failed(error)
            }
            return .disabled
        }

        let session = PrivateAccountSessionStore(repo: settingsRepo).load()
        let validation = TokenSaverModelInstaller(appSupportDirectory: appSupportDirectory)
            .validateInstalledTokenSaverModels()
        let decision = TokenSaverDistillLaunchPlanner.decide(.init(
            hasPrivateAccount: session != nil,
            isSubscribed: session?.user.subscribed == true,
            tokenSaverEnabled: true,
            modelValidation: validation
        ))
        switch decision {
        case .start:
            // Preserve the already-admitted on-disk integration. Do not
            // reconcile ON here: reconciliation can install missing paid hooks.
            return .enabled
        case .skip(let reason):
            var disabledSettings = storedSettings
            disabledSettings.tokenSaverEnabled = false
            reconcileGraphifyHost(settings: disabledSettings)
            if let error = reconcileManagedDistillSkills(tokenSaverEnabled: false) {
                return .failed(error)
            }
            return .blocked(reason)
        case .requireModel(let reason):
            var disabledSettings = storedSettings
            disabledSettings.tokenSaverEnabled = false
            reconcileGraphifyHost(settings: disabledSettings)
            if let error = reconcileManagedDistillSkills(tokenSaverEnabled: false) {
                return .failed(error)
            }
            return .blocked(reason ?? "model download required")
        }
    }

    /// Reconcile Distill integration after the lifecycle gate above (paid
    /// feature). The app-private skill package lives under Application Support
    /// only (never `~/.claude` / `~/.codex` skill trees). CLI, command wrappers,
    /// and retrieve
    /// MCP are installed only while Token Saver is enabled; disabled removes them
    /// so free/unsubscribed runs never get token-economy hooks.
    ///
    /// Nested provider PATH proxies (`grok`/`claude`/`codex`) are always installed
    /// when reconcile runs: they are not a Token Saver lane. They only intercept
    /// shell-launched bare provider names inside a thread-scoped environment;
    /// host top-level turns keep absolute resolved binaries via ProcessLocator.
    @discardableResult
    func reconcileManagedDistillSkills(tokenSaverEnabled: Bool) -> String? {
        let installer = makeAgentSkillInstaller()
        var failures: [String] = []

        func capture(_ label: String, _ operation: () throws -> Void) {
            do {
                try operation()
            } catch {
                failures.append("\(label): \((error as NSError).localizedDescription)")
            }
        }

        func removePaidIntegration() {
            // Keep these independent and first. One malformed provider config or
            // filesystem failure must not short-circuit the remaining removals.
            capture("command wrapper cleanup") {
                _ = try installer.uninstallCommandWrappers()
            }
            capture("Distill CLI cleanup") {
                _ = try installer.uninstallDistillCLI()
            }
            capture("retrieve MCP cleanup") {
                try installer.uninstallRetrieveMCP()
            }
        }

        if tokenSaverEnabled {
            // Install each paid integration independently. A skill-copy failure
            // must not leave `~/.remote-code/bin/distill` missing while npm/claude
            // wrappers remain (PostToolUse + `| distill` then fail open silently).
            // Resolve the service binary once so every user gets the same target
            // for distill + wrappers (including recovery from existing wrappers).
            let sharedBinary = AgentSkillInstaller.resolveServiceBinary()
            var appPrivateResult: AgentSkillInstallResult?
            capture("app-private Distill skill") {
                appPrivateResult = try installer.installAppPrivateDistillSkill(
                    sourceRevision: "github-main-remote-code-template-v2"
                )
            }
            capture("Distill CLI ensure") {
                _ = try installer.ensureDistillCLI(serviceBinaryURL: sharedBinary)
            }
            capture("command wrappers") {
                _ = try installer.installCommandWrappers(serviceBinaryURL: sharedBinary)
            }
            // Re-ensure after wrappers: recovers from catalog refresh races and
            // from hosts where only wrappers survived a prior partial install.
            capture("Distill CLI re-ensure") {
                _ = try installer.ensureDistillCLI(serviceBinaryURL: sharedBinary)
            }
            capture("retrieve MCP") {
                try installer.installRetrieveMCP()
            }
            LoginShellEnvironment.prewarm()
            if let appPrivateResult {
                managedDistillSkillInstallResults = [appPrivateResult]
            } else {
                managedDistillSkillInstallResults = []
            }
            // Loud residual when the managed distill binary is still unhealthy —
            // Token Saver techniques that depend on it will fail open.
            if !installer.isDistillCLIHealthy() {
                failures.append(
                    "Distill CLI unhealthy at \(installer.distillCLIURL().path) after Token Saver install"
                )
            }
        } else {
            removePaidIntegration()
            managedDistillSkillInstallResults = []
        }

        // Legacy provider-home cleanup is intentionally after paid OFF cleanup.
        // It is migration hygiene, never an authorization dependency.
        capture("legacy Distill cleanup") {
            if let override = legacyDistillCleanupOverrideForTesting {
                try override()
            } else {
                try installer.uninstallLegacyProviderDistillSkills()
            }
        }

        // Always-on subagent routing is independent of Token Saver. Install each
        // component separately so a failure cannot remove or suppress siblings.
        do {
            _ = try installer.installProviderProxies()
        } catch {
            NSLog("RemoteCode provider proxy install failed: \(error)")
        }
        do {
            _ = try installer.installAgentAppMiddleware()
        } catch {
            NSLog("RemoteCode Agent App middleware install failed: \(error)")
        }
        do {
            _ = try installer.installProviderShellBridge()
        } catch {
            NSLog("RemoteCode provider shell bridge install failed: \(error)")
        }

        let failure = failures.isEmpty ? nil : failures.joined(separator: "; ")
        managedDistillSkillInstallError = failure
        if let failure {
            NSLog("RemoteCode managed Distill reconcile incomplete: \(failure)")
        }
        return failure
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
                guard self.isTokenSaverRuntimeActive(),
                      let currentSession = PrivateAccountSessionStore(repo: self.settingsRepo).load(),
                      currentSession.user.subscribed else {
                    return
                }
                let currentSettings = SettingsStore(db: self.db).load()
                self.tokenSaverDistillServiceController.stop()
                self.tokenSaverDistillServiceController.startIfEligible(
                    session: currentSession,
                    settings: currentSettings,
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
            // WHY: live `.accountUsage` is emitted on the provider parse queue
            // (Codex handleLine → coordinator → this method). Synchronous
            // NotificationCenter.post waits for OperationQueue observers
            // (queue: .main UI reloads) via waitUntilFinished and can deadlock
            // the parse path against main/mirror locks (see hang evidence:
            // remotecode.codex-app-server.parse blocked 745s). Schedule so the
            // write returns without waiting on observers; MainActor Task +
            // debounce match the token-usage write completion path.
            scheduleTokenSaverUsageChangedNotification()
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
            // Same non-blocking path as recordTokenSaverAccountUsage — account-
            // usage store mutations must not wait on NotificationCenter observers.
            scheduleTokenSaverUsageChangedNotification()
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
        let enabled = globallyEnabled ?? isTokenSaverRuntimeActive()
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
              isTokenSaverRuntimeActive(),
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

    /// task-08: cross-user Token Saver is raw-only for every compressor turn kind.
    /// Unknown identity fails closed (disables Token Saver callbacks) while keeping provider raw.
    private func tokenSaverIsSameUser(threadId: AgentThreadID) -> Bool {
        guard let thread = try? threadRepo.get(id: threadId) else { return false }
        guard let runAs = thread.runAsUser else { return true }
        return runAs.uid == getuid()
    }

    private var tokenSaverDistillCLIStateURL: URL {
        appSupportDirectory
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
    }

    private func tokenSaverLaneIsDisabled(_ lane: String) -> Bool {
        let cliState = TokenSaverLaneKillSwitch.loadCLIStateOverlay(from: tokenSaverDistillCLIStateURL)
        return TokenSaverLaneKillSwitch.isDisabled(
            lane,
            environment: ProcessInfo.processInfo.environment,
            cliState: cliState
        )
    }

    /// WHY: Admission denials were previously silent early-returns — operators could not
    /// see that project_id NULL / empty lane_state blocked every governed write.
    private func recordTokenSaverAdmissionDenial(
        threadId: AgentThreadID,
        lane: String,
        decision: TokenSaverAdmissionDecision,
        count: Int = 1
    ) {
        guard !decision.allowed else { return }
        let projectID = (try? threadRepo.get(id: threadId))?.projectId?.value.uuidString
        NSLog(
            "RemoteCode Token Saver admission DENIED lane=\(lane) reason=\(decision.reason) thread=\(threadId.value.uuidString) project=\(projectID ?? "nil")"
        )
        try? tokenSaverAuditEventsRepo.append(
            eventKind: "token_saver_denial",
            projectID: projectID,
            threadID: threadId.value.uuidString,
            objectID: decision.reason,
            countValue: Int64(max(1, count)),
            reason: lane
        )
    }

    /// Build a compact governance snapshot for measurement rows (admission kept for audit).
    private func tokenSaverGovernanceSnapshot(
        threadId: AgentThreadID,
        lane: String,
        governedWrite: Bool
    ) -> TokenSaverGovernanceSnapshot {
        let thread = try? threadRepo.get(id: threadId)
        let projectID = thread?.projectId?.value.uuidString
        let admission = tokenSaverProjectAdmission(threadId: threadId, lane: lane)
        var evidence: String?
        if let projectID,
           let laneRow = try? tokenSaverLaneStateRepo.get(projectID: projectID, lane: lane) {
            evidence = laneRow.evidenceLevel
        }
        return TokenSaverGovernanceSnapshot(
            projectId: projectID,
            admissionAllowed: admission.allowed,
            admissionReason: admission.reason,
            evidenceLevel: evidence,
            governedWrite: governedWrite
        )
    }

    /// WHY: empty lane_state + Token Saver enabled is the silent-death condition observed
    /// on real installs (0 projects, 0 lane rows, all threads project_id NULL).
    static func logEmptyLaneStateIfNeeded(tokenSaverEnabled: Bool, laneStateCount: Int) {
        guard tokenSaverEnabled, laneStateCount == 0 else { return }
        guard !didLogEmptyTokenSaverLaneState else { return }
        didLogEmptyTokenSaverLaneState = true
        NSLog(
            "RemoteCode Token Saver ALERT: tokenSaverEnabled=true but token_saver_lane_state is EMPTY — project-admission governed writes will deny until lanes are promoted (silent-death condition). Measurement continues independently."
        )
    }

    func tokenSaverCompress(
        prompt: String,
        provider: AgentProvider,
        threadId: AgentThreadID,
        cacheState: String = "prompt",
        runId: AgentRunID? = nil
    ) async -> String {
        let turn: TokenSaverAdapterMatrix.CrossUserTurn =
            cacheState.contains("follow") ? .followUp : .initial
        guard TokenSaverAdapterMatrix.tokenSaverCallbacksAllowed(
            isSameUser: tokenSaverIsSameUser(threadId: threadId),
            turn: turn
        ) else {
            return prompt
        }
        // Operator per-lane kill switch (incident control) — same decision child env exports.
        if tokenSaverLaneIsDisabled("deterministic_wrapper") {
            recordTokenSaverAdmissionDenial(
                threadId: threadId,
                lane: "deterministic_wrapper",
                decision: .init(allowed: false, reason: "operator_lane_disabled")
            )
            return prompt
        }
        let admission = tokenSaverProjectAdmission(threadId: threadId, lane: "deterministic_wrapper")
        guard admission.allowed else {
            recordTokenSaverAdmissionDenial(
                threadId: threadId,
                lane: "deterministic_wrapper",
                decision: admission
            )
            return prompt
        }
        // NetPositiveGate (G3): there is no app-side cached prefix to preserve (resume sends
        // the full wrapped prompt), so this is a numeric decision — compress the new-turn
        // argv only when it is large enough AND the session is not a warm follow-up.
        // PERF: Character.count is O(n). Use utf8.count (O(1)) for definitive under-floor
        // skips and for sizes where Character count is guaranteed ≥ floor (UTF-8 ≤ 4
        // bytes/scalar). Only walk graphemes in the floor…4×floor boundary band.
        let floor = Self.tokenSaverMinCompressChars
        let utf8Count = prompt.utf8.count
        if utf8Count < floor {
            return prompt
        }
        let gate = NetPositiveGate(floorCharacters: floor, warmResumeTTLSeconds: 300)
        let secondsSinceLastTurn = secondsSinceLastTurn(threadId: threadId)
        let inputCharacters = utf8Count >= floor * 4 ? utf8Count : prompt.count
        guard gate.shouldCompress(inputCharacters: inputCharacters, secondsSinceLastTurn: secondsSinceLastTurn) else {
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
        // PERF: length comparisons for multi-KB prompts used Character.count (O(n)
        // grapheme walk) repeatedly. utf8.count is O(1) and matches byte-oriented
        // savings better than grapheme count; ASCII-heavy agent prompts are identical.
        let promptBytes = utf8Count
        let skipKey = DistillResultCacheKey(request: DistillRequest(
            mode: .longText,
            priority: .interactive,
            input: prompt,
            maxOutputCharacters: max(512, promptBytes)
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
            .filter { $0.utf8.count < promptBytes }
            .min { $0.utf8.count < $1.utf8.count }
            ?? prompt
        let deterministicBytes = deterministicCandidate.utf8.count

        // Adopt `candidate` only if it beats the ORIGINAL prompt; record honest end-to-end
        // savings (original -> final), tagged with the caller's cache_state AND the engine
        // that produced the win (deterministic pre-pass vs the model) so the Token Saver
        // breakdown attributes per technique.
        func adopt(_ candidate: String, stage: TokenSaverRouteStage) -> String {
            guard candidate.utf8.count < promptBytes else {
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
            return deterministicBytes < promptBytes ? adopt(deterministicCandidate, stage: .deterministic) : prompt
        }
        let request = DistillRequest(
            mode: .longText,
            priority: .interactive,
            input: deterministicCandidate,
            runMode: semanticPromoted ? .optimize : .audit,
            maxOutputCharacters: max(512, deterministicBytes)
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
            let modelWon = literalSafeModelOutput.utf8.count < deterministicBytes
            if !modelWon, deterministicBytes >= promptBytes {
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
                return deterministicBytes < promptBytes
                    ? adopt(deterministicCandidate, stage: .deterministic)
                    : prompt
            }
            return adopt(recoveredCandidate, stage: response.routeStage ?? .llmMLX)
        } catch {
            NSLog("RemoteCode Token Saver compression skipped (provider=\(provider.rawValue)): \(error)")
            // Fail-open to the deterministic pre-pass if it helped, else the original.
            return deterministicBytes < promptBytes ? adopt(deterministicCandidate, stage: .deterministic) : prompt
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
            // PERF: one UTF-8 materialization per payload for retrieve equality /
            // prepareOriginal (prompts can be multi-KB/MB on store-before-loss).
            let stageOriginalBytes = Data(stageOriginal.utf8)
            guard try store.retrieve(capability: capability, scope: scope) == stageOriginalBytes else {
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
                let originalBytes = Data(original.utf8)
                let preparedFull = try TokenSaverRuntimeRecoveryWorker(db: db).prepareOriginal(
                    originalBytes,
                    scope: scope,
                    operationID: "semantic-full-original:\(runId.value.uuidString)",
                    lane: "semantic_prose",
                    disk: disk
                )
                provisionals.append((preparedFull.capability, preparedFull.idempotencyKey))
                guard try store.retrieve(
                    capability: preparedFull.capability,
                    scope: scope
                ) == originalBytes else {
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
        guard settings.sessionLearnEnabled else { return prompt }
        // WHY: session_learn retains scoped text — keep project admission; make denials loud.
        if tokenSaverLaneIsDisabled("session_learn") {
            recordTokenSaverAdmissionDenial(
                threadId: threadId,
                lane: "session_learn",
                decision: .init(allowed: false, reason: "operator_lane_disabled")
            )
            return prompt
        }
        let sessionAdmission = tokenSaverProjectAdmission(threadId: threadId, lane: "session_learn")
        guard sessionAdmission.allowed else {
            recordTokenSaverAdmissionDenial(
                threadId: threadId,
                lane: "session_learn",
                decision: sessionAdmission
            )
            return prompt
        }
        guard let thread = try? threadRepo.get(id: threadId),
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
              let workspaceID = parent.workspaceId else {
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
        try threadRepo.preflightWorkspaceThreadInsertion(
            workspaceId: workspaceID,
            excludedVictimIDs: [parentThreadID]
        )
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
            _ = try tokenSaverProjectDataRepo.performLifecycleSweep()
            let prunedThreadIDs = try threadRepo.transactionallyUpsertEnforcingWorkspaceThreadLimit(
                child,
                excludedVictimIDs: [parentThreadID]
            ) {
                try messageRepo.append(.init(threadId: child.id, role: .system, content: capsule.text))
                try tokenSaverRolloverRepo.save(.init(
                    id: UUID().uuidString,
                    parentThreadID: parentThreadID.value.uuidString,
                    childThreadID: child.id.value.uuidString,
                    scopeTransitionJSON: nil,
                    capsuleSHA256: AgentSkillInstaller.sha256Hex(Data(capsule.text.utf8)),
                    capsuleText: capsule.text
                ))
            }
            retireDeletedAgentThreads(prunedThreadIDs)
            router?.publishAgentThreadDeletions(prunedThreadIDs)
            return child
        } catch {
            try? tokenSaverRolloverRepo.delete(childThreadID: child.id.value.uuidString)
            try? threadRepo.delete(id: child.id)
            throw error
        }
    }

    /// One-sentence Live Activity description, generated on-device.
    ///
    /// Returns nil whenever the local model cannot be used or does not produce
    /// usable prose — the caller then keeps its deterministic preview, so the
    /// Lock Screen never degrades because the model was busy, gated, or slow.
    /// Uses `.sr1Humanize`, the only public distill mode that emits free natural
    /// language; the other modes emit compressed S/C/D/R/O/N/P lines.
    ///
    /// No provider tokens are spent: this is the local Token Saver sidecar.
    func liveActivityDescriptionSummary(
        source: LiveActivitySummary.Source,
        threadId: AgentThreadID?
    ) async -> String? {
        guard isTokenSaverRuntimeActive() else { return nil }
        guard let client = currentDistillClient() else { return nil }

        let targetLanguage = threadId.map { inferredUserLanguage(threadId: $0) } ?? "English"
        let request = DistillRequest(
            mode: .sr1Humanize,
            priority: .background,
            input: LiveActivitySummary.prompt(source: source, targetLanguage: targetLanguage),
            maxOutputCharacters: LiveActivitySummary.maximumCharacters * 2
        )
        do {
            let output = try await client.distill(request).output
            return LiveActivitySummary.sanitized(output, source: source)
        } catch {
            NSLog("RemoteCode Live Activity summary skipped: \(error)")
            return nil
        }
    }

    func tokenSaverHumanizeSR1Response(_ response: String, provider: AgentProvider, threadId: AgentThreadID, runId: AgentRunID? = nil) async -> String {
        // Token Saver owns every SR1 rewrite, including the deterministic fallback.
        // Check the live paid-feature gate before detection, fallback construction,
        // or resolving a client that may still be alive during toggle teardown.
        guard isTokenSaverRuntimeActive() else {
            return response
        }
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
        guard isTokenSaverRuntimeActive() else {
            return nil
        }
        if let client = currentDistillClient() {
            return client
        }

        startTokenSaverDistillServiceIfEligible()
        for _ in 0..<Self.tokenSaverDistillStartupPolls {
            // The toggle can change while the sidecar is warming. Re-check before
            // every client resolution so a late ready event cannot reactivate SR1.
            guard isTokenSaverRuntimeActive() else {
                return nil
            }
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
        guard isTokenSaverRuntimeActive() else {
            return nil
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

        // Prefer O (outcome) as the user-facing answer. Do not rename every
        // prefix to Estado/Contexto — that is not human and wastes UI tokens.
        var outcomes: [String] = []
        var extras: [String] = []
        for raw in response.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            if lower == "sr1" || lower == "dict" || lower.hasPrefix("dict:")
                || lower.hasPrefix("s=state") || lower.hasPrefix("c=context") {
                continue
            }
            let segments = SR1ResponseDetector.parseSemanticSegments(line)
            if segments.isEmpty {
                if !line.hasPrefix("|") { extras.append(line) }
                continue
            }
            for seg in segments {
                let content = seg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { continue }
                if seg.prefix == "O" {
                    outcomes.append(content)
                } else if seg.prefix == "R" || seg.prefix == "P" {
                    // Keep risk/proof as short add-ons only when present.
                    extras.append(content)
                }
                // Drop S/C/D/N in fail-open UI — they are ops chrome.
            }
        }

        let pieces = outcomes.isEmpty ? extras : (outcomes + extras.prefix(2))
        if pieces.isEmpty {
            if portuguese { return "Nao consegui expandir a resposta comprimida." }
            if spanish { return "No pude expandir la respuesta comprimida." }
            return "I could not expand the compressed response."
        }
        let joined = pieces.joined(separator: "\n")
        return SR1ResponseDetector.expandVariables(in: joined, from: response)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        var pending: PendingUsage
        if let active = pendingUsageByRun[runId] {
            pending = active
        } else if let completed = completedUsageByRun.removeValue(forKey: runId) {
            completedUsageRunOrder.removeAll { $0 == runId }
            pending = completed
        } else {
            // Once a terminal baseline ages out of the bounded tombstone cache,
            // fail closed for accounting. Reconstructing it from zero would
            // double-count a replayed provider receipt.
            guard run.status == .pending || run.status == .running else { return }
            pending = PendingUsage(provider: run.provider)
        }
        // Incremental events have no provider event ID, so a replay after the
        // terminal callback cannot be distinguished from a new charge. Provider
        // lifecycles deliver legitimate increments before finish; ignore a late
        // incremental replay and continue accepting authoritative cumulative
        // receipts.
        if pending.finished, usage.resolvedSemantics == .incremental {
            archiveCompletedUsage(runId: runId, pending: pending)
            return
        }

        // Raw provider events stay append-only. Pareto input components are
        // normalized separately: cumulative snapshots contribute only growth,
        // while independent Claude requests contribute their full input.
        if tokenSaverProjectObservation(runId: runId, lane: "measurement").allowed {
            let previousEvidence = Self.effectiveEvidenceUsage(pending)
            switch usage.resolvedSemantics {
            case .incremental:
                pending.evidencedIncremental = Self.addingUsage(
                    pending.evidencedIncremental,
                    usage
                )
            case .cumulative:
                pending.evidencedCumulative = AssistantTokenUsage.merging(
                    pending.evidencedCumulative,
                    with: usage
                )
            }
            let currentEvidence = Self.effectiveEvidenceUsage(pending)
            appendTokenSaverProviderUsage(
                usage,
                inputGrowth: max(
                    0,
                    currentEvidence.inputTokens - previousEvidence.inputTokens
                ),
                runId: runId
            )
        }

        // The sidebar "used tokens" display reflects the real provider-billed count
        // and must be recorded for every Token-Saver-enabled thread — NOT gated on
        // the measurement lane (which requires a projectId + seeded lane rows).
        // Normal thread creation makes projectless threads, so an outer measurement
        // gate here left the sidebar showing 0 used tokens despite real billing. The
        // measurement/attribution ledger stays gated: `appendTokenSaverProviderUsage`
        // self-gates on the same measurement observation, and no other path below
        // writes measurement/savings rows.
        switch usage.resolvedSemantics {
        case .incremental:
            pending.incremental = Self.addingUsage(pending.incremental, usage)
        case .cumulative:
            pending.cumulative = AssistantTokenUsage.merging(
                pending.cumulative,
                with: usage
            )
        }
        let enabledAtEventTime = isTokenSaverRuntimeActive()
        pending.eligibleAtEventTime = pending.eligibleAtEventTime || enabledAtEventTime
        let effective = Self.effectiveUsage(pending)
        pendingUsageByRun[runId] = pending
        if tokenSaverProjectObservation(runId: runId, lane: "session_learn").allowed {
            sessionLearnInputTokensByRun[runId] = max(0, effective.inputTokens)
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
                "provider_input_cost",
            ]
        )
        do {
            try tokenSaverAttemptLedger.begin(record)
        } catch {
            NSLog("RemoteCode Token Saver attempt begin failed: \(error)")
        }
    }

    private func appendTokenSaverProviderUsage(
        _ usage: AssistantTokenUsage,
        inputGrowth: Int,
        runId: AgentRunID
    ) {
        guard tokenSaverProjectObservation(runId: runId, lane: "measurement").allowed else {
            return
        }
        beginTokenSaverAttempt(runId: runId)
        if inputGrowth > 0 {
            do {
                try tokenSaverAttemptLedger.appendInputComponent(
                    attemptID: runId.value.uuidString,
                    category: "unattributed_provider_input",
                    tokens: inputGrowth,
                    costMicros: 0
                )
            } catch {
                NSLog("RemoteCode Token Saver provider input attribution failed: \(error)")
            }
        }
        var payload: [String: Any] = [
            "semantics": usage.resolvedSemantics.rawValue,
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

        let snapshots: [UsageWriteSnapshot] = keysToFlush.compactMap { key in
            guard var pending = pendingUsageByRun[key],
                  !pending.writeInFlight else {
                return nil
            }
            let target = Self.effectiveUsage(pending)
            let delta = Self.usageGrowth(from: pending.persisted, to: target)
            let billedDelta = max(
                0,
                target.billedTotalTokenUnits - pending.persisted.billedTotalTokenUnits
            )
            guard delta.totalTokens > 0 || billedDelta > 0 else {
                if pending.finished {
                    archiveCompletedUsage(runId: key, pending: pending)
                }
                return nil
            }
            pending.writeInFlight = true
            pendingUsageByRun[key] = pending
            return UsageWriteSnapshot(
                runId: key,
                provider: pending.provider,
                target: target,
                delta: delta,
                deltaBilledTokenUnits: billedDelta,
                eligibleRuns: pending.eligibleAtEventTime && !pending.eligibleRunRecorded ? 1 : 0,
                currentSessionTokens: target.totalTokens,
                currentSessionLimitTokens: target.contextWindow
            )
        }
        guard !snapshots.isEmpty else { return }

        let appSupportDir = appSupportDirectory
        let beforeWrite = beforeTokenSaverUsageWriteForTesting
        backgroundWriterQueue.async { [weak self] in
            for snapshot in snapshots {
                let succeeded: Bool
                do {
                    try beforeWrite?()
                    // NO MEASURED BASELINE EXISTS FOR THIS PATH — read before "fixing".
                    //
                    // `estimatedRawTokens` deliberately receives the SAME value as
                    // `actualProviderTokens`, so `savedTokens` (which is
                    // `max(estimated - actual, 0)`) is always 0 here. That is not an
                    // oversight and must not be "repaired" by inventing a multiplier: the
                    // raw cost of this turn WITHOUT the dialect injected was never
                    // generated, so there is nothing to subtract. Any non-zero number
                    // produced here would be a counterfactual, which is exactly the
                    // mistake that made the sr1-humanize figure unfalsifiable (see
                    // TokenSaverSR1SavingsEstimator).
                    //
                    // A real baseline needs the same fixed corpus run with and without
                    // `distillAgentInstructionsBody` injected, compared against actual
                    // provider usage — see Tests/DistillCoreTests/TokenSaverActionCostHarness
                    // for the harness this feeds. Until that lands, the honest report for
                    // provider turns is "not measured", not a number.
                    _ = try TokenSaverUsageStore(appSupportDirectory: appSupportDir).record(
                        provider: snapshot.provider,
                        actualProviderTokens: snapshot.delta.totalTokens,
                        estimatedRawTokens: snapshot.delta.totalTokens,
                        actualProviderBilledTokenUnits: snapshot.deltaBilledTokenUnits,
                        estimatedRawBilledTokenUnits: snapshot.deltaBilledTokenUnits,
                        eligibleRuns: snapshot.eligibleRuns,
                        currentSessionTokens: snapshot.currentSessionTokens,
                        currentSessionLimitTokens: snapshot.currentSessionLimitTokens
                    )
                    succeeded = true
                } catch {
                    NSLog("RemoteCode Token Saver usage record failed: \(error)")
                    succeeded = false
                }
                DispatchQueue.main.async { [weak self] in
                    self?.completeTokenSaverUsageWrite(snapshot, succeeded: succeeded)
                }
            }
        }
    }

    private func finishPendingTokenSaverUsage(runId: AgentRunID) {
        if var pending = pendingUsageByRun[runId] {
            pending.finished = true
            pendingUsageByRun[runId] = pending
        } else if completedUsageByRun[runId] == nil,
                  let run = try? runRepo.get(id: runId) {
            var pending = PendingUsage(provider: run.provider)
            pending.finished = true
            archiveCompletedUsage(runId: runId, pending: pending)
        }
        flushPendingTokenSaverUsage(runId: runId)
        archiveCompletedUsageIfSettled(runId: runId)
    }

    private func completeTokenSaverUsageWrite(
        _ snapshot: UsageWriteSnapshot,
        succeeded: Bool
    ) {
        guard var pending = pendingUsageByRun[snapshot.runId],
              pending.writeInFlight else {
            return
        }
        pending.writeInFlight = false
        if succeeded {
            pending.persisted = AssistantTokenUsage.merging(
                pending.persisted,
                with: snapshot.target
            )
            if snapshot.eligibleRuns > 0 {
                pending.eligibleRunRecorded = true
            }
        }
        pendingUsageByRun[snapshot.runId] = pending

        if succeeded {
            recomputeTokenSaverDailyEconomyToday()
            scheduleTokenSaverUsageChangedNotification()
        }

        let target = Self.effectiveUsage(pending)
        let remainingTokens = target.totalTokens - pending.persisted.totalTokens
        let remainingBilledUnits =
            target.billedTotalTokenUnits - pending.persisted.billedTotalTokenUnits
        if remainingTokens > 0 || remainingBilledUnits > 0 {
            if succeeded {
                flushPendingTokenSaverUsage(runId: snapshot.runId)
            } else {
                schedulePendingUsageFlush()
            }
        } else if pending.finished {
            archiveCompletedUsage(runId: snapshot.runId, pending: pending)
        }
    }

    private func archiveCompletedUsageIfSettled(runId: AgentRunID) {
        guard let pending = pendingUsageByRun[runId],
              !pending.writeInFlight else {
            return
        }
        let target = Self.effectiveUsage(pending)
        guard target.totalTokens <= pending.persisted.totalTokens,
              target.billedTotalTokenUnits <= pending.persisted.billedTotalTokenUnits else {
            return
        }
        archiveCompletedUsage(runId: runId, pending: pending)
    }

    private func archiveCompletedUsage(runId: AgentRunID, pending: PendingUsage) {
        var tombstone = pending
        tombstone.writeInFlight = false
        tombstone.finished = true
        pendingUsageByRun.removeValue(forKey: runId)
        completedUsageByRun[runId] = tombstone
        completedUsageRunOrder.removeAll { $0 == runId }
        completedUsageRunOrder.append(runId)

        let limit = max(
            0,
            tokenSaverUsageTombstoneLimitForTesting
                ?? Self.completedUsageTombstoneLimit
        )
        while completedUsageRunOrder.count > limit {
            let evicted = completedUsageRunOrder.removeFirst()
            completedUsageByRun.removeValue(forKey: evicted)
        }
    }

    private nonisolated static func effectiveUsage(_ pending: PendingUsage) -> AssistantTokenUsage {
        AssistantTokenUsage.merging(pending.incremental, with: pending.cumulative)
    }

    private nonisolated static func effectiveEvidenceUsage(
        _ pending: PendingUsage
    ) -> AssistantTokenUsage {
        AssistantTokenUsage.merging(
            pending.evidencedIncremental,
            with: pending.evidencedCumulative
        )
    }

    private nonisolated static func addingUsage(
        _ lhs: AssistantTokenUsage,
        _ rhs: AssistantTokenUsage
    ) -> AssistantTokenUsage {
        func add(_ lhs: Int, _ rhs: Int) -> Int {
            let (sum, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
            return overflow ? Int.max : sum
        }
        func addOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
            guard lhs != nil || rhs != nil else { return nil }
            return add(lhs ?? 0, rhs ?? 0)
        }
        return AssistantTokenUsage(
            inputTokens: add(lhs.inputTokens, rhs.inputTokens),
            outputTokens: add(lhs.outputTokens, rhs.outputTokens),
            totalTokens: add(lhs.totalTokens, rhs.totalTokens),
            contextWindow: maxOptional(lhs.contextWindow, rhs.contextWindow),
            compactsAutomatically: rhs.compactsAutomatically ?? lhs.compactsAutomatically,
            uncachedInputTokens: addOptional(lhs.uncachedInputTokens, rhs.uncachedInputTokens),
            cacheCreationInputTokens: addOptional(
                lhs.cacheCreationInputTokens,
                rhs.cacheCreationInputTokens
            ),
            cacheReadInputTokens: addOptional(lhs.cacheReadInputTokens, rhs.cacheReadInputTokens),
            reportedCostMicros: addOptional(lhs.reportedCostMicros, rhs.reportedCostMicros),
            contextTokens: rhs.contextTokens ?? lhs.contextTokens,
            semantics: .incremental
        )
    }

    private nonisolated static func usageGrowth(
        from previous: AssistantTokenUsage,
        to latest: AssistantTokenUsage
    ) -> AssistantTokenUsage {
        func growth(_ old: Int?, _ new: Int?) -> Int? {
            guard old != nil || new != nil else { return nil }
            return max(0, (new ?? 0) - (old ?? 0))
        }
        return AssistantTokenUsage(
            inputTokens: max(0, latest.inputTokens - previous.inputTokens),
            outputTokens: max(0, latest.outputTokens - previous.outputTokens),
            totalTokens: max(0, latest.totalTokens - previous.totalTokens),
            contextWindow: latest.contextWindow,
            compactsAutomatically: latest.compactsAutomatically,
            uncachedInputTokens: growth(
                previous.uncachedInputTokens,
                latest.uncachedInputTokens
            ),
            cacheCreationInputTokens: growth(
                previous.cacheCreationInputTokens,
                latest.cacheCreationInputTokens
            ),
            cacheReadInputTokens: growth(
                previous.cacheReadInputTokens,
                latest.cacheReadInputTokens
            ),
            reportedCostMicros: growth(
                previous.reportedCostMicros,
                latest.reportedCostMicros
            ),
            contextTokens: latest.contextTokens,
            semantics: .incremental
        )
    }

    private nonisolated static func maxOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else { return nil }
        return max(lhs ?? 0, rhs ?? 0)
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
        // WHY: Measurement/accounting must not depend on project admission. Real installs
        // have project_id NULL on all threads and 0 lane_state rows, which made every
        // savings write (including sr1-humanize) silently dead. Lossy/governed paths
        // still use tokenSaverProjectAdmission; this path only needs paid feature + same-user.
        guard isTokenSaverRuntimeActive() else { return }
        guard tokenSaverIsSameUser(threadId: threadId) else { return }
        let laneForGovernance = mode == "sr1-humanize" ? "sr1-humanize" : "deterministic_wrapper"
        // Keep admission decision for audit snapshot (do not gate the write on it).
        let governance = tokenSaverGovernanceSnapshot(
            threadId: threadId,
            lane: laneForGovernance,
            governedWrite: false
        )
        do {
            // WHY: defaults are attributability="unknown" / delivered=false — the
            // displayedSavingsEligibilitySQL legacy escape hatch for PRE-MIGRATION
            // rows. New app-side rows must not land there or delivered can never
            // filter and forfeited/unknown rows look like attributed savings.
            // These are delivered compressions that are not proven prompt-bound.
            _ = try tokenSaverSavingsRepo.record(
                provider: provider.rawValue,
                mode: TokenSaverEngineLabel.mode(base: mode, stage: routeStage),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                savedTokens: savedTokens,
                cacheState: cacheState,
                attributability: "not_prompt_bound",
                delivered: true,
                governance: governance.jsonString(),
                threadID: threadId.value.uuidString
            )
            recomputeTokenSaverDailyEconomyToday()
            NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
        } catch {
            NSLog("RemoteCode Token Saver sidecar savings persist failed: \(error)")
        }
    }

    /// Persist today's credible total so Week = Σ(daily.total_credible).
    public func recomputeTokenSaverDailyEconomyToday(now: Date = Date()) {
        recomputeTokenSaverDailyEconomy(for: now, now: now)
    }

    /// Recompute the last `dayCount` calendar days (inclusive of today) so Week
    /// totals heal after formula changes (e.g. v5 permanent-amort → v6 day-scoped).
    /// Older formula rows would otherwise keep painting ~999M until each day ages out.
    public func recomputeTokenSaverDailyEconomyWindow(dayCount: Int = 7, now: Date = Date()) {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let count = max(1, min(dayCount, 14))
        for offset in 0..<count {
            guard let day = cal.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            recomputeTokenSaverDailyEconomy(for: day, now: now)
        }
    }

    /// Persist one calendar day's credible total (day-scoped amort + caps).
    private func recomputeTokenSaverDailyEconomy(for day: Date, now: Date) {
        let settings = SettingsStore(db: db).load()
        let usage = TokenSaverUsageStore(appSupportDirectory: appSupportDirectory).load()
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let windowUsage = usage.daily
            .filter { cal.isDate($0.dayStart, inSameDayAs: dayStart) }
            .reduce(0) { $0 + max(0, $1.actualProviderTokens) }
        // WHY: fail-closed — known day billed only; never substitute raw windowUsage.
        let windowBilled: Double? = {
            var total: Double = 0
            var saw = false
            for bucket in usage.daily where cal.isDate(bucket.dayStart, inSameDayAs: dayStart) {
                saw = true
                guard let billed = bucket.actualProviderBilledTokenUnits else { return nil }
                total += max(0, billed)
            }
            return saw ? total : 0
        }()
        let dayStartMs = tokenSaverDailyEconomyRepo.dayStartMs(for: day)
        let dayEndMs = tokenSaverDailyEconomyRepo.dayEndMsExclusive(for: day)
        do {
            let measured = try tokenSaverDailyEconomyRepo.measuredPipes(
                dayStartMs: dayStartMs,
                dayEndMsExclusive: dayEndMs
            )
            // Real Graphify CLI uses only — never invent signals from preference-on.
            let signalCount = try graphifyUsageRepo.signalCount(fromMs: dayStartMs, toMsExclusive: dayEndMs)
            let answerSum = try graphifyUsageRepo.answerTokensSum(fromMs: dayStartMs, toMsExclusive: dayEndMs)
            let nowMs = Int64(now.timeIntervalSince1970 * 1000)
            let medianExploration = try graphifyUsageRepo.medianExplorationTokens(
                nowMs: nowMs,
                minSamples: TokenSaverBareUserEstimator.minSamplesForLiveShare
            )
            if cal.isDate(dayStart, inSameDayAs: cal.startOfDay(for: now)) {
                try? graphifyUsageRepo.prune(nowMs: nowMs)
            }
            // Multi-turn cache impact from **day-window** savings only (not permanent
            // thread totals). Cap vs day measured so Week cannot invent ~999M fantasy.
            let threadInputs = (try? tokenSaverSavingsRepo.threadCacheAmortizationInputs(
                dayStartMs: dayStartMs,
                dayEndMsExclusive: dayEndMs
            )) ?? []
            let threadCacheAmort = TokenSaverBareUserEstimator.sumThreadCacheAmortization(
                inputs: threadInputs.map { (savedTokens: $0.savedTokens, runs: $0.runs) },
                windowMeasuredTokens: measured
            )
            let breakdown = TokenSaverBareUserEstimator.estimate(
                measuredToolOutputSaved: measured,
                tokenSaverEnabled: settings.tokenSaverEnabled,
                graphifyActive: settings.isGraphifyRuntimeActive,
                orchestrationActive: false,
                observation: TokenSaverBareUserObservation(
                    windowProviderTokens: windowUsage,
                    windowProviderBilledTokenUnits: windowBilled,
                    graphifySignalCount: signalCount,
                    graphifyAnswerTokens: answerSum,
                    medianExplorationTokens: medianExploration
                )
            )
            // Fold thread cache amort into total (estimate path has turnCount=0 here).
            let totalCredible = TokenSaverBareUserEstimator.saturatingAdd(
                breakdown.totalCredible,
                threadCacheAmort
            )
            let iso = ISO8601DateFormatter().string(from: now)
            _ = try tokenSaverDailyEconomyRepo.upsert(
                TokenSaverDailyEconomyRecord(
                    dayStartMs: dayStartMs,
                    measuredTokens: breakdown.measuredToolOutput,
                    dialectTokens: breakdown.estimatedDialect,
                    graphifyTokens: breakdown.estimatedGraphify,
                    orchestrationTokens: breakdown.estimatedOrchestration,
                    totalCredible: totalCredible,
                    windowUsageTokens: windowUsage,
                    formulaVersion: TokenSaverDailyEconomyRepository.formulaVersion,
                    appliedOutputShare: breakdown.appliedOutputShare,
                    graphifySignalCount: signalCount,
                    updatedAt: iso,
                    dialectRawTokens: breakdown.dialectRawTokens,
                    graphifyRawTokens: breakdown.graphifyRawTokens,
                    capBinding: breakdown.capBinding.rawValue,
                    // Persistence stores 0 when billed is unknown (field is non-optional).
                    // WHY: same fail-closed rule — do not write raw tokens as billed.
                    windowUsageBilledUnits: windowBilled ?? 0
                )
            )
        } catch {
            // Fail open: UI can still compute in-memory; persistence is best-effort.
            NSLog("RemoteCode Token Saver daily economy upsert failed: \(error)")
        }
    }

    /// Record Graphify CLI uses (and exploration samples) from assistant tool events.
    /// Fail-open: never blocks the event funnel. Writes on backgroundWriterQueue.
    /// Counts only succeed after a non-failed tool result (`ok=1`).
    func recordGraphifyUsageFromAssistantItem(
        item: AssistantItem,
        threadId: AgentThreadID,
        runId: AgentRunID
    ) {
        switch item.type {
        case .tool, .commandExecution, .mcpToolCall, .dynamicToolCall:
            break
        default:
            return
        }
        let settings = SettingsStore(db: db).load()
        guard isTokenSaverRuntimeActive(settings: settings),
              settings.isGraphifyRuntimeActive else { return }

        let provider = (try? threadRepo.get(id: threadId))?.provider.rawValue ?? "unknown"
        let runKey = runId.value.uuidString
        let createdAtMs = item.startedAtMs > 0
            ? item.startedAtMs
            : Int64(Date().timeIntervalSince1970 * 1000)
        let bufferKey = "\(runKey)|\(item.id)"

        // Seed / merge buffer for streaming providers.
        graphifyItemBuffersLock.lock()
        var buf = graphifyItemBuffers[bufferKey] ?? GraphifyItemBuffer(
            summary: item.summary,
            provider: provider,
            createdAtMs: createdAtMs
        )
        if let s = item.summary, !s.isEmpty { buf.summary = s }
        if !item.body.isEmpty { buf.body = item.body }
        if let o = item.output, !o.isEmpty { buf.output = o }
        graphifyItemBuffers[bufferKey] = buf
        graphifyItemBuffersLock.unlock()

        // Claude often delivers full tool_result in one itemStarted (output set).
        // Streaming providers finalize on itemCompleted instead.
        let finalizeNow = item.output != nil && item.state == .completed
        processGraphifyBuffer(
            bufferKey: bufferKey,
            itemId: item.id,
            runKey: runKey,
            finalizeOutput: finalizeNow
        )
    }

    /// Codex/Grok often stream command text and output via itemDelta only.
    /// `finalize` must stay false for deltas — only itemCompleted / completed
    /// itemStarted (Claude tool_result) may flip ok=1.
    func recordGraphifyUsageFromItemDelta(
        itemId: String,
        bodyAppend: String?,
        outputAppend: String?,
        summary: String?,
        threadId: AgentThreadID,
        runId: AgentRunID,
        finalize: Bool = false
    ) {
        let settings = SettingsStore(db: db).load()
        guard isTokenSaverRuntimeActive(settings: settings),
              settings.isGraphifyRuntimeActive else { return }
        guard bodyAppend != nil || outputAppend != nil || summary != nil else { return }

        let provider = (try? threadRepo.get(id: threadId))?.provider.rawValue ?? "unknown"
        let runKey = runId.value.uuidString
        let bufferKey = "\(runKey)|\(itemId)"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        graphifyItemBuffersLock.lock()
        var buf = graphifyItemBuffers[bufferKey] ?? GraphifyItemBuffer(
            summary: summary,
            provider: provider,
            createdAtMs: nowMs
        )
        if let s = summary, !s.isEmpty { buf.summary = s }
        if let b = bodyAppend { buf.body += b }
        if let o = outputAppend {
            // Claude streams tool *input* as input_json_delta → outputAppend.
            // Real tool stdout for Claude is delivered as tool_result itemStarted
            // (summary "result", output set) — not as mid-stream deltas on tool_use.
            // Fold all non-result stream chunks into body so we never finalize
            // with partial input JSON as "answer" tokens.
            let resultPhase = (summary == "result") || (buf.summary == "result")
            if resultPhase {
                buf.output += o
            } else {
                buf.body += o
            }
        }
        graphifyItemBuffers[bufferKey] = buf
        graphifyItemBuffersLock.unlock()

        processGraphifyBuffer(
            bufferKey: bufferKey,
            itemId: itemId,
            runKey: runKey,
            finalizeOutput: finalize
        )
    }

    /// Complete a successful tool item: mark pending graphify/exploration rows ok.
    func finalizeGraphifyUsageItem(itemId: String, runId: AgentRunID) {
        let runKey = runId.value.uuidString
        let bufferKey = "\(runKey)|\(itemId)"
        processGraphifyBuffer(
            bufferKey: bufferKey,
            itemId: itemId,
            runKey: runKey,
            finalizeOutput: true
        )
    }

    func failGraphifyUsageItem(itemId: String, runId: AgentRunID) {
        let runKey = runId.value.uuidString
        let bufferKey = "\(runKey)|\(itemId)"
        graphifyItemBuffersLock.lock()
        graphifyItemBuffers.removeValue(forKey: bufferKey)
        graphifyItemBuffersLock.unlock()
        backgroundWriterQueue.async { [weak self] in
            try? self?.graphifyUsageRepo.deleteItem(runId: runKey, itemId: itemId)
            DispatchQueue.main.async { [weak self] in
                self?.recomputeTokenSaverDailyEconomyToday()
            }
        }
    }

    private func processGraphifyBuffer(
        bufferKey: String,
        itemId: String,
        runKey: String,
        finalizeOutput: Bool
    ) {
        graphifyItemBuffersLock.lock()
        guard let buf = graphifyItemBuffers[bufferKey] else {
            graphifyItemBuffersLock.unlock()
            return
        }
        let summary = buf.summary
        let body = buf.body
        let output = buf.output
        let provider = buf.provider
        let createdAtMs = buf.createdAtMs
        let alreadyInvocation = buf.recordedInvocation
        let alreadyExploration = buf.recordedExploration
        graphifyItemBuffersLock.unlock()

        let combinedBody = GraphifyUsageDetector.commandText(fromBody: body)
        let haystackBody = [body, combinedBody].joined(separator: "\n")
        let invocations = GraphifyUsageDetector.detect(summary: summary, body: haystackBody)
        // Exploration name is known on tool_use; result summary is often "result".
        let exploration = GraphifyUsageDetector.isExplorationTool(summary: summary)
            || alreadyExploration

        // Pending insert (ok=0) so success path can flip ok=1; never count until then.
        if (!alreadyInvocation && !invocations.isEmpty) || (!alreadyExploration && exploration) {
            let willRecordInvocation = !alreadyInvocation && !invocations.isEmpty
            let willRecordExploration = !alreadyExploration && GraphifyUsageDetector.isExplorationTool(summary: summary)
            backgroundWriterQueue.async { [weak self] in
                guard let self else { return }
                if willRecordInvocation {
                    for inv in invocations {
                        try? self.graphifyUsageRepo.insert(
                            GraphifyUsageEvent(
                                createdAtMs: createdAtMs,
                                provider: provider,
                                runId: runKey,
                                itemId: itemId,
                                subcommand: inv.subcommand,
                                answerTokens: 0,
                                source: "event_stream",
                                ok: false
                            )
                        )
                    }
                }
                if willRecordExploration {
                    try? self.graphifyUsageRepo.insertExplorationSample(
                        createdAtMs: createdAtMs,
                        provider: provider,
                        runId: runKey,
                        itemId: itemId,
                        answerTokens: 0,
                        toolName: summary ?? "tool",
                        ok: false
                    )
                }
            }
            graphifyItemBuffersLock.lock()
            if var b = graphifyItemBuffers[bufferKey] {
                if willRecordInvocation { b.recordedInvocation = true }
                if willRecordExploration { b.recordedExploration = true }
                graphifyItemBuffers[bufferKey] = b
            }
            graphifyItemBuffersLock.unlock()
        }

        guard finalizeOutput else { return }

        // Re-read buffer after possible flag updates.
        graphifyItemBuffersLock.lock()
        let finalBuf = graphifyItemBuffers[bufferKey]
        let hadInterest = (finalBuf?.recordedInvocation == true)
            || (finalBuf?.recordedExploration == true)
            || !invocations.isEmpty
        let finalOutput = finalBuf?.output ?? output
        graphifyItemBuffersLock.unlock()

        guard hadInterest else {
            graphifyItemBuffersLock.lock()
            graphifyItemBuffers.removeValue(forKey: bufferKey)
            graphifyItemBuffersLock.unlock()
            return
        }

        // Claude emits itemCompleted on tool_use *before* tool_result. Keep the
        // buffer and leave ok=0 until we have real output (tool_result / stream end).
        if finalOutput.isEmpty {
            return
        }

        if GraphifyUsageDetector.looksLikeFailure(output: finalOutput) {
            graphifyItemBuffersLock.lock()
            graphifyItemBuffers.removeValue(forKey: bufferKey)
            graphifyItemBuffersLock.unlock()
            backgroundWriterQueue.async { [weak self] in
                try? self?.graphifyUsageRepo.deleteItem(runId: runKey, itemId: itemId)
                DispatchQueue.main.async { [weak self] in
                    self?.recomputeTokenSaverDailyEconomyToday()
                }
            }
            return
        }

        let answerTokens = GraphifyUsageDetector.tokensFromUTF8Count(finalOutput.utf8.count)
        // Enqueue after pending inserts (serial queue) so markSucceeded finds rows.
        backgroundWriterQueue.async { [weak self] in
            guard let self else { return }
            try? self.graphifyUsageRepo.markSucceeded(
                runId: runKey,
                itemId: itemId,
                answerTokens: answerTokens
            )
            DispatchQueue.main.async { [weak self] in
                self?.recomputeTokenSaverDailyEconomyToday()
            }
        }
        graphifyItemBuffersLock.lock()
        graphifyItemBuffers.removeValue(forKey: bufferKey)
        graphifyItemBuffersLock.unlock()
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
