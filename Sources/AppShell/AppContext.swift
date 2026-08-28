import Foundation
import AppKit
import NaturalLanguage
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import Surfaces
import DistillCore
import os

private let appContextRuntimeLog = Logger(subsystem: "io.remotecode.agent", category: "app-context")

public extension Notification.Name {
    static let rc2TokenSaverConfigurationChanged = Notification.Name("rc2TokenSaverConfigurationChanged")
}

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
        "wire-encode",
        "wire-render-english",
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
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
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

    // PERF: every Token Saver savings row encodes this snapshot. JSONEncoder is
    // not thread-safe — share one process-wide encoder under a short lock so
    // concurrent compress/savings paths avoid per-call codec construction
    // (default formatting unchanged for governance JSON columns).
    private static let encodeLock = NSLock()
    private static let encoder = JSONEncoder()

    public func jsonString() -> String {
        Self.encodeLock.lock()
        let data = try? Self.encoder.encode(self)
        Self.encodeLock.unlock()
        guard let data,
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
    public let botStore: BotStore
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
    lazy var botPeerHandoffAuthority = BotPeerHandoffAuthority(
        botStore: botStore,
        threadRepo: threadRepo,
        runRepo: runRepo,
        messageRepo: messageRepo,
        queuedMessageRepo: queuedMessageRepo,
        checkpointRepo: turnCheckpointRepo,
        settingsRepo: settingsRepo,
        coordinator: coordinator,
        appSupportDirectory: appSupportDirectory,
        orchestrationRuntime: orchestrationRuntime
    )
    lazy var botDraftPersistenceAuthority = BotDraftPersistenceAuthority()
    private var tokenSaverCodexAdapter: CodexAppServerAdapter
    public var router: AppCommandRouter! {
        didSet {
            botPeerHandoffAuthority.router = router
            drainRecoveredForkPrunedThreadIDsIfPossible()
            refreshActiveAgentWorkspaceProjection()
            startBotBrowserPendingOpenObserver()
            try? router?.reconcileBotBrowserOpens()
            router?.reconcileBotComputerActions()
        }
    }
    private var botBrowserOpenObserver: NSObjectProtocol?
    private struct ActiveAgentThreadContext {
        let workspaceID: WorkspaceID
        let title: String
    }

    /// Main-actor cache of coordinator-owned work. Workspace chrome reads the
    /// grouped projection instead of synchronously querying durable thread rows on
    /// every SwiftUI render. The per-thread cache ensures each newly active thread
    /// needs at most one lifecycle-time lookup even during large orchestrated bursts.
    private var activeAgentThreadContextByID: [AgentThreadID: ActiveAgentThreadContext] = [:]
    private var activeAgentThreadTitlesByWorkspace: [WorkspaceID: [String]] = [:]
    /// Last count fanned out to sidebar chrome (Active Threads badge). Tracks
    /// host snapshot size, not the workspace-title map size.
    private var lastPublishedActiveThreadCount: Int = 0
    private var pendingRecoveredForkPrunedThreadIDs: Set<AgentThreadID> = []
    public var socketServer: UnixSocketServer?
    private let tokenSaverAccountUsageRefresher: TokenSaverAccountUsageRefreshing
    private var tokenSaverAccountUsageRefreshTask: Task<Void, Never>?
    private var tokenSaverPeriodicGrokAccountUsageRefreshTask: Task<Void, Never>?
    private var tokenSaverGrokAccountUsageRefreshGeneration: UInt64 = 0
    private struct TokenSaverPeriodicAccountUsageCycle {
        let id: UInt64
        var grokFinished = false
        var grokSucceeded = false
        var otherProvidersFinished = false
        var otherProvidersSucceeded = false
        var reconciledMiss = false
    }
    private var tokenSaverPeriodicAccountUsageCycleID: UInt64 = 0
    private var tokenSaverPeriodicAccountUsageCycle: TokenSaverPeriodicAccountUsageCycle?
    private var tokenSaverUsageNotificationTask: Task<Void, Never>?
    private var tokenSaverLastUsageNotificationAt: Date = .distantPast
    // PERF: daily economy upsert formats updatedAt. ISO8601DateFormatter
    // construction is expensive; share one MainActor-isolated formatter.
    private let iso8601Formatter = ISO8601DateFormatter()
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
    /// Test seam: shared settings+usage.json loads for daily-economy heal.
    /// One window(7) must increment this once, not once per day.
    var tokenSaverDailyEconomySharedSnapshotLoadsForTesting = 0
    var completedUsageTombstoneCountForTesting: Int { completedUsageByRun.count }
    func hasCompletedUsageTombstoneForTesting(runId: AgentRunID) -> Bool {
        completedUsageByRun[runId] != nil
    }
    private var cachedDistillClientKey: String?
    private var cachedDistillClient: DistillServiceClient?
    /// Test seam: when set, used instead of resolving a client from the live
    /// sidecar status. Production code never sets this.
    var distillClientOverrideForTesting: DistillServiceClient?
    /// Immutable exact-counter + envelope bundle. Production construction
    /// leaves this nil so the typed selector stays uninstalled.
    private let tokenSaverExactRuntimeCapabilityLock = NSLock()
    private var tokenSaverExactRuntimeCapability: TokenSaverExactRuntimeCapability?
    private var tokenSaverRCW1FinalizeInvocations = 0
    private var tokenSaverRCW1DiscardInvocations = 0
    var tokenSaverExactRuntimeCapabilityForTesting: TokenSaverExactRuntimeCapability? {
        tokenSaverExactRuntimeCapabilityLock.withLock { tokenSaverExactRuntimeCapability }
    }
    var tokenSaverRCW1FinalizeInvocationsForTesting: Int { tokenSaverRCW1FinalizeInvocations }
    var tokenSaverRCW1DiscardInvocationsForTesting: Int { tokenSaverRCW1DiscardInvocations }
    private var tokenSaverDistillPrepareInvocations = 0
    var tokenSaverDistillPrepareInvocationsForTesting: Int { tokenSaverDistillPrepareInvocations }
    /// Test seam: replace the host-owned Auto RCW1 transform. Production never sets this.
    var tokenSaverAutoWireTransformForTesting: (@Sendable (String, AgentOrchestrationRoute) throws -> String)?
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
    private var tokenSaverBootModelValidationTask: Task<Void, Never>?
    private var tokenSaverEntitlementReconcileTask: Task<Void, Never>?
    private var tokenSaverEntitlementReconcileTaskID: UUID?
    private var tokenSaverPreferredModelActivationTask: Task<Void, Never>?
    private var lastTokenSaverAccountIdentity: TokenSaverAccountIdentity?
    private var tokenSaverRuntimeAdmitted = false
    /// Test seam for account-change readiness without installing multi-GB models.
    /// Production leaves this nil and validates the real on-disk manifests.
    var tokenSaverEntitlementModelValidationOverrideForTesting: TokenSaverModelValidation?
    var beforeTokenSaverBackgroundModelValidationForTesting: (@Sendable () -> Void)?
    var tokenSaverBackgroundModelValidationOverrideForTesting: (@Sendable () -> TokenSaverModelValidation)?
    var tokenSaverEntitlementReconcileInFlightForTesting: Bool {
        tokenSaverEntitlementReconcileTask != nil
    }
    var tokenSaverPreferredModelActivationEligibilityOverrideForTesting: Bool?
    var tokenSaverPreferredModelActivationDownloadForTesting: (@Sendable () async throws -> Void)?
    var beforeTokenSaverPreferredModelValidationForTesting: (() -> Void)?
    var beforeTokenSaverPreferredModelRestartForTesting: (() -> Void)?
    var tokenSaverPreferredModelActivationInFlightForTesting: Bool {
        tokenSaverPreferredModelActivationTask != nil
    }
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
    private static let tokenSaverUsageNotificationMinimumInterval: TimeInterval = 2
    /// Process-local once flag for empty lane_state diagnostic (silent-death condition).
    private static var didLogEmptyTokenSaverLaneState = false
    /// Debounce window for coalescing per-token usage writes into one disk write.
    private static let tokenSaverUsageDebounceInterval: TimeInterval = 0.75

    // PERF: agent.item.started EventBus publish encodes AssistantItem on every
    // tool/assistant item during agent runs. Encode once then JSONSerialization +
    // JSONValue.from (avoids a second Codable walk). JSONEncoder is not
    // thread-safe — share one under a short lock instead of allocating per item.
    private static let assistantItemJSONEncodeLock = NSLock()
    private static let assistantItemJSONEncoder = JSONEncoder()

    private static func assistantItemJSON(_ item: AssistantItem) -> JSONValue {
        assistantItemJSONEncodeLock.lock()
        let data = try? assistantItemJSONEncoder.encode(item)
        assistantItemJSONEncodeLock.unlock()
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .null
        }
        return JSONValue.from(object)
    }

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

        /// After the pending row exists, later command-text chunks are unused
        /// until finalize (detect already ran; answer tokens come from output).
        var isCommandBodyClosed: Bool {
            recordedInvocation
                && (recordedExploration
                    || !GraphifyUsageDetector.isExplorationTool(summary: summary))
        }
    }
    private var graphifyItemBuffers: [String: GraphifyItemBuffer] = [:]
    private let graphifyItemBuffersLock = NSLock()
    /// Graphify usage recording gate. `SettingsStore(db:)` is a new instance
    /// (empty cache) so itemDelta used to SQLite-load settings at stream rate.
    private var graphifyUsageAdmissionCache: (
        admitted: Bool,
        settingsRevision: UInt64,
        runtimeAdmitted: Bool
    )?
    /// Test seam: SettingsStore loads performed for the Graphify usage gate.
    var graphifyUsageSettingsLoadCountForTesting = 0
    /// Thread provider labels for Graphify usage rows. itemDelta used to
    /// SQLite-get the thread on every chunk when Graphify was admitted.
    private var graphifyProviderByThread: [AgentThreadID: String] = [:]
    private static let graphifyProviderByThreadLimit = 128
    /// Test seam: threadRepo.get calls for Graphify provider labels.
    var graphifyProviderLookupCountForTesting = 0
    /// Test seam: GraphifyUsageDetector.detect / commandText runs.
    var graphifyDetectCountForTesting = 0

    /// Test seam: accumulated command-body bytes for one Graphify item buffer.
    func graphifyBufferBodyUTF8CountForTesting(runId: AgentRunID, itemId: String) -> Int {
        let key = "\(runId.value.uuidString)|\(itemId)"
        graphifyItemBuffersLock.lock()
        defer { graphifyItemBuffersLock.unlock() }
        return graphifyItemBuffers[key]?.body.utf8.count ?? 0
    }

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
        self.botStore = BotStore(db: db)
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
        self.tokenSaverCodexAdapter = codex
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
        self.coordinator.tokenSaverContextSeedPreparer = TokenSaverHumanContextSeedPreparer()
        self.tokenSaverCodexAdapter.contextSeedPreparer = self.coordinator.tokenSaverContextSeedPreparer
        self.tokenSaverCodexAdapter.contextSeedReceipts = self.runRepo.contextSelectionReceipts()
        contextReference.value = self
        let liveActivitySyncCoordinator = self.liveActivitySyncCoordinator
        coordinator.onActiveRunProjectionChanged = { [weak contextReference] projection, cause in
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
            // Scheduled runs intentionally do not select/bind an Agent App tab. Keep
            // workspace-level chrome in parity with user-started runs by projecting
            // coordinator ownership independently of per-tab busy state.
            Task { @MainActor [weak contextReference] in
                contextReference?.value?.refreshActiveAgentWorkspaceProjection()
            }
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
        self.coordinator.followUpPromptCompressor = { [weak self] prompt, provider, threadId, runId in
            guard let self else { return prompt }
            let sameUser = await MainActor.run { self.tokenSaverIsSameUser(threadId: threadId) }
            guard TokenSaverAdapterMatrix.tokenSaverCallbacksAllowed(isSameUser: sameUser, turn: .followUp) else {
                return prompt
            }
            let scopedPrompt = await self.tokenSaverSessionLearnPrompt(
                prompt, provider: provider, threadId: threadId, runId: runId
            )
            return await self.tokenSaverCompress(
                prompt: scopedPrompt,
                provider: provider,
                threadId: threadId,
                cacheState: "prompt_followup",
                runId: runId
            )
        }
        self.coordinator.finalResponseTranslator = { [weak self] response, provider, threadId, runId in
            guard let self else { return response }
            let sameUser = await MainActor.run { self.tokenSaverIsSameUser(threadId: threadId) }
            guard TokenSaverAdapterMatrix.tokenSaverCallbacksAllowed(isSameUser: sameUser, turn: .finalResponse) else {
                return response
            }
            return await self.tokenSaverRenderWireResponse(response, provider: provider, threadId: threadId, runId: runId)
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
            reconcileComputerUseMCP()
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
                } else if !Self.tokenSaverUsesLocalModel(settings: bootSettings) {
                    // API targets have no local readiness work. The lifecycle
                    // planner admits a valid API immediately and fails an invalid
                    // API loudly without ever falling back to local validation.
                    _ = applyTokenSaverLifecycle(
                        requestedEnabled: true,
                        modelValidation: .installed,
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
                    tokenSaverBootModelValidationTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer {
                            self.tokenSaverBootModelValidationTask = nil
                        }
                        let validation = await Self.tokenSaverBackgroundModelValidation(
                            appSupportDirectory: appSupport,
                            settings: bootSettings,
                            beforeValidation: self.beforeTokenSaverBackgroundModelValidationForTesting,
                            validationOverride: self.tokenSaverBackgroundModelValidationOverrideForTesting
                        )
                        let currentSettings = SettingsStore(db: self.db).load()
                        guard !Task.isCancelled,
                              let validation,
                              currentSettings.tokenSaverEnabled,
                              Self.tokenSaverUsesLocalModel(settings: currentSettings) else {
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
                if let timing = try? runRepo.timing(of: runId) {
                    let startedAtMs = Int64(timing.startedAt.timeIntervalSince1970 * 1000)
                    payload["started_at_ms"] = .number(Double(startedAtMs))
                    payload["started_at"] = .number(Double(startedAtMs))
                    if let finishedAt = timing.finishedAt {
                        let finishedAtMs = Int64(finishedAt.timeIntervalSince1970 * 1000)
                        payload["finished_at_ms"] = .number(Double(finishedAtMs))
                        payload["duration_ms"] = .number(Double(max(0, finishedAtMs - startedAtMs)))
                    }
                }
            }
            if let wid = try? threadRepo.workspaceId(of: threadId) {
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
                                        payload: .object(["thread_id": .string(t), "item": Self.assistantItemJSON(item)]))
                self.recordGraphifyUsageFromAssistantItem(
                    item: item,
                    threadId: tid,
                    runId: runId
                )
            case .itemDelta(let itemId, let bodyAppend, let outputAppend, let summary):
                var p: [String: JSONValue] = ["thread_id": .string(t), "item_id": .string(itemId)]
                p["run_id"] = .string(runId.value.uuidString.lowercased())
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
            case .itemHostMetadata(let turnId, let itemId, let distillApplied, _):
                var p: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "turn_id": .string(turnId),
                    "item_id": .string(itemId),
                ]
                if let distillApplied { p["distill_applied"] = .bool(distillApplied) }
                EventBus.shared.publish(kind: "agent.item.delta", payload: .object(p))
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
                p["run_id"] = .string(runId.value.uuidString.lowercased())
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
            case .wireTranslation(let translation):
                var payload: [String: JSONValue] = [
                    "thread_id": .string(t),
                    "original_text": .string(AssistantTimelineState.cappedText(translation.originalText)),
                    "rewritten_text": .string(AssistantTimelineState.cappedText(translation.rewrittenText)),
                    "protocol_version": .string(translation.protocolVersion)
                ]
                if let itemId = translation.itemId { payload["item_id"] = .string(itemId) }
                if let messageId = translation.messageId { payload["message_id"] = .string(messageId) }
                if let fallbackReason = translation.fallbackReason { payload["fallback_reason"] = .string(fallbackReason) }
                if let wireRequestText = translation.wireRequestText {
                    payload["wire_request_text"] = .string(AssistantTimelineState.cappedText(wireRequestText))
                }
                EventBus.shared.publish(kind: "agent.wire.translation", payload: .object(payload))
            case .sr1Translation(let translation):
                // Historical replay only: paired clients still need to render
                // persisted pre-RCW1 transcript rows. Texts remain capped.
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
                // purple ring updates without waiting for the next periodic probe.
                if (try? self.runRepo.provider(of: rid)) == .grok {
                    self.refreshGrokTokenSaverAccountUsage(reason: "run_finished")
                }
                // Drain the next queued message after ANY terminal status. stopRun
                // can publish its host terminal before a provider-native interrupt
                // makes the adapter idle. Wait through that bounded cancellation
                // window; otherwise Force gets one premature drain and the promoted
                // message remains stranded with no later lifecycle callback.
                self.cancelQueueDrainWaiter(threadId: tid)
                self.ensureQueueDrainWaiterIfNeeded(threadId: tid)
                // Main agent only: nested/subagent workers must not fire
                // system or private push banners (parent owns user-facing UX).
                let chrome = (try? self.threadRepo.listChrome(ids: [tid]))?[tid]
                if let content = RemoteCodeNotificationContent.threadOutcome(
                    threadId: tid.value.uuidString,
                    workspaceId: chrome?.workspaceId?.value.uuidString,
                    title: chrome?.title,
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
            // Late iOS WS subscribers: re-push Token Saver glanceable card.
            NotificationCenter.default.addObserver(
                forName: EventBus.subscriberAddedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Prefer cached body (no disk). If never published this
                    // process, build once from disk so first connect still works.
                    if TokenSaverWidgetDigest.lastCachedBody() != nil {
                        TokenSaverWidgetDigest.republishLast()
                    } else {
                        self.publishTokenSaverWidgetDigestFromDisk()
                    }
                }
            }
            // Seed sticky digest at launch so the first remote subscriber has
            // something to replay even before the sidebar opens.
            Task { @MainActor [weak self] in
                self?.publishTokenSaverWidgetDigestFromDisk()
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

    /// Settings CLI-path commits replace the live Codex adapter through this owner.
    func replaceCodexProviderAdapter(_ adapter: CodexAppServerAdapter) {
        applyContextSeedHooks(to: adapter)
        tokenSaverCodexAdapter = adapter
        coordinator.replaceProviderAdapter(.codex, adapter: adapter)
    }

    private func applyContextSeedHooks(to adapter: CodexAppServerAdapter) {
        adapter.contextSeedPreparer = coordinator.tokenSaverContextSeedPreparer
        adapter.contextSeedReceipts = runRepo.contextSelectionReceipts()
    }

    deinit {
        deletedThreadRetirementRetryTask?.cancel()
        tokenSaverBootModelValidationTask?.cancel()
        tokenSaverEntitlementReconcileTask?.cancel()
        tokenSaverPreferredModelActivationTask?.cancel()
        if let tokenSaverAccountObserver {
            NotificationCenter.default.removeObserver(tokenSaverAccountObserver)
        }
    }

    /// True while this process's shared coordinator owns any run in the workspace.
    /// Unlike AgentAppSurface.isBusy, this is deliberately workspace-wide so a
    /// headless scheduled thread and an interactively selected thread drive the
    /// same workspace spinner without making unrelated Agent App tabs spin.
    public func hasActiveAgentRun(in workspaceID: WorkspaceID) -> Bool {
        activeAgentThreadTitlesByWorkspace[workspaceID] != nil
    }

    /// Titles for workspace-level busy help/VoiceOver copy. The cache is refreshed
    /// once per coordinator lifecycle transition, never from a SwiftUI body read.
    public func activeAgentThreadTitles(in workspaceID: WorkspaceID) -> [String] {
        activeAgentThreadTitlesByWorkspace[workspaceID] ?? []
    }

    private func refreshActiveAgentWorkspaceProjection() {
        let activeThreadIDs = coordinator.activeThreadIdsSnapshot()
        let activeCount = activeThreadIDs.count
        let previousActiveCount = lastPublishedActiveThreadCount
        let cachedThreadIDs = Set(activeAgentThreadContextByID.keys)

        for threadID in cachedThreadIDs.subtracting(activeThreadIDs) {
            activeAgentThreadContextByID.removeValue(forKey: threadID)
        }
        let newlyActiveThreadIDs = activeThreadIDs.subtracting(cachedThreadIDs).sorted {
            $0.value.uuidString < $1.value.uuidString
        }
        if !newlyActiveThreadIDs.isEmpty {
            let chromeByID = (try? threadRepo.listChrome(ids: newlyActiveThreadIDs)) ?? [:]
            for threadID in newlyActiveThreadIDs {
                guard let chrome = chromeByID[threadID],
                      let workspaceID = chrome.workspaceId else { continue }
                activeAgentThreadContextByID[threadID] = ActiveAgentThreadContext(
                    workspaceID: workspaceID,
                    title: chrome.title
                )
            }
        }

        var projected: [WorkspaceID: [String]] = [:]
        let orderedThreadIDs = activeAgentThreadContextByID.keys.sorted {
            $0.value.uuidString < $1.value.uuidString
        }
        for threadID in orderedThreadIDs {
            guard let context = activeAgentThreadContextByID[threadID] else { continue }
            projected[context.workspaceID, default: []].append(context.title)
        }
        // WHY: Active Threads sidebar badge uses host snapshot count, not the
        // workspace-title map. Threads without workspaceId never enter the map,
        // so count-only transitions must still refresh sidebar chrome.
        let titlesChanged = projected != activeAgentThreadTitlesByWorkspace
        let countChanged = previousActiveCount != activeCount
        guard titlesChanged || countChanged else { return }
        if titlesChanged {
            activeAgentThreadTitlesByWorkspace = projected
        }
        lastPublishedActiveThreadCount = activeCount
        router?.windowController?.refreshSurfaceRuntimeState()
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
            switch try? self.threadRepo.status(of: threadId) {
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
        flushEventPersistence()
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
        let identity = try? threadRepo.identity(of: threadId)
        let sameUser = tokenSaverIsSameUser(identity: identity)
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
        // Token Saver ON admits DISTILL_HINT and PATH wrappers. Sidecar
        // blocked/failed/starting is Distill fail-open, not interceptor denial:
        // Bot Desk compress demand-starts Distill, and stampIdentity would
        // otherwise scrub the same turn.
        let live = TokenSaverWaveLiveRollout.liveWaves.map(\.rawValue).sorted().joined(separator: ",")
        let scope = tokenSaverPersistentScope(threadId: threadId, identity: identity)
        let workspaceID = scope?.workspaceID
        let projectID = scope?.projectID
        let receipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: true,
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
        env["REMOTE_CODE_AGENT_MODEL"] = identity?.model ?? "unknown"
        env["REMOTE_CODE_PROVIDER_INSTANCE_ID"] = identity?.providerInstanceId ?? provider.rawValue
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
            do {
                let searchDirectories = ProcessLocator.expandedPath(
                    environmentPath: baseEnvironment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"],
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
                )
                .split(separator: ":")
                .map(String.init)
                _ = try installer.installCommandWrappers(
                    searchDirectoriesOverride: searchDirectories
                )
            } catch {
                NSLog(
                    "RemoteCode: command wrapper refresh before agent turn failed: \(error.localizedDescription)"
                )
            }
            do {
                try installer.installBotSelfConfigMCP()
            } catch {
                NSLog(
                    "RemoteCode: installBotSelfConfigMCP before agent turn failed: \(error.localizedDescription)"
                )
            }
            do {
                try installer.installBotBrowserMCP()
            } catch {
                NSLog(
                    "RemoteCode: installBotBrowserMCP before agent turn failed: \(error.localizedDescription)"
                )
            }
            do {
                try installer.installBotComputerMCP()
            } catch {
                NSLog(
                    "RemoteCode: installBotComputerMCP before agent turn failed: \(error.localizedDescription)"
                )
            }
            do {
                try installer.installBotWebMCP()
            } catch {
                NSLog(
                    "RemoteCode: installBotWebMCP before agent turn failed: \(error.localizedDescription)"
                )
            }
            let managedBin = installer.managedCLIBinURL.path
            let currentPath = baseEnvironment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
            let pathParts = currentPath.split(separator: ":").map(String.init).filter { $0 != managedBin }
            env["PATH"] = ([managedBin] + pathParts).joined(separator: ":")
            env["RC_REMOTE_CODE_MANAGED_BIN"] = managedBin
        }
        // Every Distill entry point needs the exact sidecar lease. PostToolUse
        // remains Claude-only, while Codex/Grok consume this through the managed
        // PATH wrapper and explicit `distill` CLI.
        if receipt.capabilities.distill == true {
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
        let chrome = (try? threadRepo.listChrome(ids: [threadId]))?[threadId]
        guard let content = RemoteCodeNotificationContent.userActionNeeded(
            threadId: threadId.value.uuidString,
            workspaceId: chrome?.workspaceId?.value.uuidString,
            threadTitle: chrome?.title,
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
        let identity = try? threadRepo.identity(of: threadId)
        var environment = baseEnvironment
        environment.removeValue(forKey: AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey)
        environment.merge([
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": appSupportDirectory.path,
            "RC_REMOTE_CODE_SUBAGENT_THREAD_ID": threadId.value.uuidString,
            "RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE": "1",
            "RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH": AppPaths.socketPath(for: channel),
            "REMOTE_CODE_AGENT_PROVIDER": provider.rawValue,
            "REMOTE_CODE_AGENT_MODEL": identity?.model ?? "unknown",
            "REMOTE_CODE_PROVIDER_INSTANCE_ID": identity?.providerInstanceId ?? provider.rawValue,
        ]) { _, new in new }
        if let conversation = try? botStore.conversationLinked(to: threadId) {
            environment[BotSelfConfigCatalog.callerEnvironmentKey] =
                conversation.botID.value.uuidString.lowercased()
            if let bot = try? botStore.get(id: conversation.botID),
               let revisionID = bot.currentRevisionID,
               let revision = try? botStore.getRevision(id: revisionID) {
                if revision.desktopKind == .logicalExecutionSpace {
                    // This is a per-run admission signal. Provider-global MCP
                    // config must never make Docker/VM/remote runs host-capable.
                    environment[AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey] = "1"
                }
            }
        }
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
        do {
            try installer.installBotSelfConfigMCP()
        } catch {
            NSLog(
                "RemoteCode: installBotSelfConfigMCP before subagent env failed: \(error.localizedDescription)"
            )
        }
        do {
            try installer.installBotBrowserMCP()
        } catch {
            NSLog(
                "RemoteCode: installBotBrowserMCP before subagent env failed: \(error.localizedDescription)"
            )
        }
        do {
            try installer.installBotComputerMCP()
        } catch {
            NSLog(
                "RemoteCode: installBotComputerMCP before subagent env failed: \(error.localizedDescription)"
            )
        }
        do {
            try installer.installBotWebMCP()
        } catch {
            NSLog(
                "RemoteCode: installBotWebMCP before subagent env failed: \(error.localizedDescription)"
            )
        }
        let managedBin = installer.managedCLIBinURL.path
        let basePath = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        if tokenSaverRuntimeAdmitted {
            let searchDirectories = ProcessLocator.expandedPath(
                environmentPath: basePath,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
            .split(separator: ":")
            .map(String.init)
            do {
                _ = try installer.installCommandWrappers(
                    searchDirectoriesOverride: searchDirectories
                )
            } catch {
                NSLog("RemoteCode: command wrapper refresh before subagent env failed: \(error.localizedDescription)")
            }
        }
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
        if let workspaceID = identity?.workspaceId?.value.uuidString {
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
        let wasActive = svc.enabled
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
        if !wasActive {
            // Settings/Token Saver enable path: dirty schedules after disable.
            svc.resumeAfterDisable()
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
    nonisolated static func tokenSaverUsesLocalModel(settings: AppSettings) -> Bool {
        if case .local = settings.tokenSaverGenerateTarget { return true }
        return false
    }

    nonisolated static func tokenSaverModelValidation(
        settings: AppSettings,
        localValidation: () -> TokenSaverModelValidation
    ) -> TokenSaverModelValidation {
        guard tokenSaverUsesLocalModel(settings: settings) else { return .installed }
        return localValidation()
    }

    nonisolated static func tokenSaverBackgroundModelValidation(
        appSupportDirectory: URL,
        settings: AppSettings,
        beforeValidation: (@Sendable () -> Void)? = nil,
        validationOverride: (@Sendable () -> TokenSaverModelValidation)? = nil
    ) async -> TokenSaverModelValidation? {
        guard tokenSaverUsesLocalModel(settings: settings) else { return .installed }
        let child = Task.detached(priority: .utility) { () throws -> TokenSaverModelValidation in
            beforeValidation?()
            try Task.checkCancellation()
            if let validationOverride { return validationOverride() }
            return try TokenSaverModelInstaller(appSupportDirectory: appSupportDirectory)
                .validateInstalledTokenSaverModelsCooperatively {
                    try Task.checkCancellation()
                }
        }
        return await withTaskCancellationHandler {
            try? await child.value
        } onCancel: {
            child.cancel()
        }
    }

    public func tokenSaverConfigurationDidChange() {
        let settings = SettingsStore(db: db).load()
        if !settings.tokenSaverEnabled || !Self.tokenSaverUsesLocalModel(settings: settings) {
            cancelTokenSaverLocalAsyncWork()
            NotificationCenter.default.post(name: .rc2TokenSaverConfigurationChanged, object: self)
        }
    }

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
            cancelTokenSaverLocalAsyncWork()
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

        let enabledSettings = settings(enabled: true)
        if !Self.tokenSaverUsesLocalModel(settings: enabledSettings) {
            cancelTokenSaverLocalAsyncWork()
        }
        let session = PrivateAccountSessionStore(repo: settingsRepo).load()
        let validation = Self.tokenSaverModelValidation(settings: enabledSettings) {
            modelValidation
                ?? TokenSaverModelInstaller(appSupportDirectory: appSupportDirectory)
                    .validateInstalledTokenSaverModels()
        }
        let target = enabledSettings.tokenSaverGenerateTarget
        let decision = TokenSaverDistillLaunchPlanner.decide(.init(
            hasPrivateAccount: session != nil,
            isSubscribed: session?.user.subscribed == true,
            tokenSaverEnabled: true,
            modelValidation: validation,
            allowsExternalGenerate: target.usesExternalGenerate,
            externalGenerateError: target.configurationError
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

    /// Restart the Distill sidecar so Settings model / API / training changes take effect.
    public func restartTokenSaverDistillIfRunning() {
        let settings = SettingsStore(db: db).load()
        if !settings.tokenSaverEnabled || !Self.tokenSaverUsesLocalModel(settings: settings) {
            cancelTokenSaverLocalAsyncWork()
        }
        guard settings.tokenSaverEnabled, tokenSaverRuntimeAdmitted else { return }
        let session = PrivateAccountSessionStore(repo: settingsRepo).load()
        let validation = Self.tokenSaverModelValidation(settings: settings) {
            TokenSaverModelInstaller(appSupportDirectory: appSupportDirectory)
                .validateInstalledTokenSaverModels()
        }
        tokenSaverDistillServiceController.stop()
        tokenSaverDistillServiceController.startIfEligible(
            session: session,
            settings: settings,
            modelValidation: validation
        )
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

        let storedSettings = SettingsStore(db: db).load()
        guard storedSettings.tokenSaverEnabled else {
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
        guard Self.tokenSaverUsesLocalModel(settings: storedSettings) else {
            _ = applyTokenSaverLifecycle(
                requestedEnabled: true,
                modelValidation: .installed,
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
        let validationID = UUID()
        tokenSaverEntitlementReconcileTaskID = validationID
        tokenSaverEntitlementReconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.tokenSaverEntitlementReconcileTaskID == validationID {
                    self.tokenSaverEntitlementReconcileTask = nil
                    self.tokenSaverEntitlementReconcileTaskID = nil
                }
            }
            let validation = await Self.tokenSaverBackgroundModelValidation(
                appSupportDirectory: appSupport,
                settings: storedSettings,
                beforeValidation: self.beforeTokenSaverBackgroundModelValidationForTesting,
                validationOverride: self.tokenSaverBackgroundModelValidationOverrideForTesting
            )
            let currentSettings = SettingsStore(db: self.db).load()
            guard !Task.isCancelled,
                  let validation,
                  self.currentTokenSaverAccountIdentity() == identity,
                  currentSettings.tokenSaverEnabled,
                  Self.tokenSaverUsesLocalModel(settings: currentSettings) else {
                return
            }
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
        let currentSettings = SettingsStore(db: db).load()
        let validation = Self.tokenSaverModelValidation(settings: currentSettings) {
            TokenSaverModelInstaller(appSupportDirectory: appSupportDirectory)
                .validateInstalledTokenSaverModels()
        }
        let target = currentSettings.tokenSaverGenerateTarget
        let decision = TokenSaverDistillLaunchPlanner.decide(.init(
            hasPrivateAccount: session != nil,
            isSubscribed: session?.user.subscribed == true,
            tokenSaverEnabled: true,
            modelValidation: validation,
            allowsExternalGenerate: target.usesExternalGenerate,
            externalGenerateError: target.configurationError
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
            capture("Grok PreToolUse pipe hook cleanup") {
                _ = try installer.uninstallGrokPreToolPipeHook()
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
                let searchDirectories = ProcessLocator.expandedPath(
                    environmentPath: ProcessInfo.processInfo.environment["PATH"],
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
                )
                .split(separator: ":")
                .map(String.init)
                _ = try installer.installCommandWrappers(
                    serviceBinaryURL: sharedBinary,
                    searchDirectoriesOverride: searchDirectories
                )
            }
            // Re-ensure after wrappers: recovers from catalog refresh races and
            // from hosts where only wrappers survived a prior partial install.
            capture("Distill CLI re-ensure") {
                _ = try installer.ensureDistillCLI(serviceBinaryURL: sharedBinary)
            }
            capture("retrieve MCP") {
                try installer.installRetrieveMCP()
            }
            capture("Grok PreToolUse pipe hook") {
                try installer.installGrokPreToolPipeHook()
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
        let activeServiceBinary = AgentSkillInstaller.resolveServiceBinary()
        do {
            _ = try installer.installProviderProxies(
                serviceBinaryURL: activeServiceBinary
            )
        } catch {
            NSLog("RemoteCode provider proxy install failed: \(error)")
        }
        do {
            _ = try installer.installAgentAppMiddleware(
                serviceBinaryURL: activeServiceBinary
            )
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

    func startBotBrowserPendingOpenObserver() {
        guard botBrowserOpenObserver == nil else { return }
        botBrowserOpenObserver = DistributedNotificationCenter.default().addObserver(
            forName: BotBrowserHost.pendingOpenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            try? self?.router?.reconcileBotBrowserOpens()
        }
        DistributedNotificationCenter.default().addObserver(
            forName: BotBrowserHost.pendingActionNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.router?.reconcileBotBrowserActions() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: BotComputerHost.pendingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.router?.reconcileBotComputerActions()
        }
    }

    func reconcileComputerUseMCP() {
        let installer = makeAgentSkillInstaller()
        do {
            try installer.uninstallLegacyExternalHostArtifacts()
        } catch {
            NSLog("RemoteCode: legacy external host artifact cleanup failed: \(error.localizedDescription)")
        }
        // Remove any pre-native managed host entry once. Runtime admission is
        // process-local; never re-add this global Claude/Codex configuration.
        do {
            try installer.uninstallComputerUseMCP()
        } catch {
            NSLog("RemoteCode: legacy computer-use MCP cleanup failed: \(error.localizedDescription)")
        }
        do {
            try installer.installBotSelfConfigMCP()
        } catch {
            NSLog("RemoteCode: installBotSelfConfigMCP failed: \(error.localizedDescription)")
        }
        do {
            try installer.installBotBrowserMCP()
        } catch {
            NSLog("RemoteCode: installBotBrowserMCP failed: \(error.localizedDescription)")
        }
        do {
            try installer.installBotComputerMCP()
        } catch {
            NSLog("RemoteCode: installBotComputerMCP failed: \(error.localizedDescription)")
        }
        do {
            try installer.installBotWebMCP()
        } catch {
            NSLog("RemoteCode: installBotWebMCP failed: \(error.localizedDescription)")
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
        let modelValidation = Self.tokenSaverModelValidation(settings: settings) {
            TokenSaverModelInstaller(appSupportDirectory: appSupportDirectory)
                .validateInstalledTokenSaverModels()
        }
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
    func activatePreferredTokenSaverModelIfDownloaded(settings: AppSettings, session: PrivateAccountSession?) {
        guard settings.tokenSaverEnabled,
              Self.tokenSaverUsesLocalModel(settings: settings) else {
            cancelTokenSaverLocalAsyncWork()
            return
        }
        guard tokenSaverPreferredModelActivationTask == nil else { return }
        let installer = TokenSaverModelInstaller(appSupportDirectory: appSupportDirectory)
        let eligible = tokenSaverPreferredModelActivationEligibilityOverrideForTesting ?? (
            installer.validateInstalledModel(requireSelectedModel: true).state != .installed
                && installer.validateInstalledModel(requireSelectedModel: false).state == .installed
                && installer.modelArtifactsPresent()
        )
        guard eligible else {
            return
        }
        let appSupport = appSupportDirectory
        tokenSaverPreferredModelActivationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.tokenSaverPreferredModelActivationTask = nil
            }
            let installer = TokenSaverModelInstaller(appSupportDirectory: appSupport)
            do {
                // Writes the selected model's manifest; the already-present files are skipped via
                // their cached checksums, so this does not re-download multiple GB.
                if let download = self.tokenSaverPreferredModelActivationDownloadForTesting {
                    try await download()
                } else {
                    _ = try await TokenSaverModelDownloader(installer: installer).downloadRequiredModels { _ in }
                }
                try Task.checkCancellation()
                let currentSettings = SettingsStore(db: self.db).load()
                guard currentSettings.tokenSaverEnabled,
                      Self.tokenSaverUsesLocalModel(settings: currentSettings),
                      self.isTokenSaverRuntimeActive(settings: currentSettings),
                      let currentSession = PrivateAccountSessionStore(repo: self.settingsRepo).load(),
                      currentSession.user.subscribed else {
                    return
                }
                try Task.checkCancellation()
                self.beforeTokenSaverPreferredModelValidationForTesting?()
                let validation = installer.validateInstalledTokenSaverModels()
                try Task.checkCancellation()
                self.beforeTokenSaverPreferredModelRestartForTesting?()
                self.tokenSaverDistillServiceController.stop()
                self.tokenSaverDistillServiceController.startIfEligible(
                    session: currentSession,
                    settings: currentSettings,
                    modelValidation: validation
                )
                NSLog("RemoteCode Token Saver: activated preferred model \(TokenSaverApprovedModels.selected().id)")
            } catch is CancellationError {
                return
            } catch {
                NSLog("RemoteCode Token Saver preferred-model activation failed: \(error)")
            }
        }
    }

    private func cancelTokenSaverPreferredModelActivation() {
        tokenSaverPreferredModelActivationTask?.cancel()
    }

    private func cancelTokenSaverLocalAsyncWork() {
        cancelTokenSaverPreferredModelActivation()
        tokenSaverBootModelValidationTask?.cancel()
        tokenSaverEntitlementReconcileTask?.cancel()
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

    public func refreshTokenSaverAccountUsage(reason: String, includeGrok: Bool = true) {
        guard PrivateAccountSessionStore(repo: settingsRepo).load() != nil else {
            publishTokenSaverAccountUsageRefresh(state: "skipped", reason: reason, detail: "signed_out")
            return
        }
        guard tokenSaverAccountUsageRefreshTask == nil else {
            publishTokenSaverAccountUsageRefresh(state: "skipped", reason: reason, detail: "busy")
            return
        }
        let grokRefreshGeneration: UInt64?
        if includeGrok {
            tokenSaverGrokAccountUsageRefreshGeneration &+= 1
            grokRefreshGeneration = tokenSaverGrokAccountUsageRefreshGeneration
            tokenSaverPeriodicAccountUsageCycle = nil
        } else {
            grokRefreshGeneration = nil
            if var cycle = tokenSaverPeriodicAccountUsageCycle {
                cycle.otherProvidersFinished = false
                tokenSaverPeriodicAccountUsageCycle = cycle
            }
        }
        let periodicCycleID = includeGrok ? nil : tokenSaverPeriodicAccountUsageCycle?.id
        tokenSaverAccountUsageRefreshCount += 1
        publishTokenSaverAccountUsageRefresh(state: "started", reason: reason, detail: nil)

        let codexBinary = (try? settingsRepo.get("cli.codex.path"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let claudeBinary = (try? settingsRepo.get("cli.claude.path"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let grokBinary = (try? settingsRepo.get("cli.grok.path"))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = TokenSaverAccountUsageRefreshRequest(
            codexBinary: codexBinary?.isEmpty == false ? codexBinary! : "codex",
            claudeBinary: claudeBinary?.isEmpty == false ? claudeBinary! : "claude",
            grokBinary: grokBinary?.isEmpty == false ? grokBinary! : "grok",
            grokAuthFileURL: Self.defaultGrokAuthFileURL,
            claudeAuthFileURL: Self.defaultClaudeAuthFileURL,
            codexAuthFileURL: Self.defaultCodexAuthFileURL,
            includeGrok: includeGrok,
            cwd: state.workspaces.values.first?.cwd ?? NSHomeDirectory(),
            environment: [:]
        )
        let refresher = tokenSaverAccountUsageRefresher

        tokenSaverAccountUsageRefreshTask = Task { [weak self] in
            let usages = await Self.refreshAccountUsageWithTimeout(refresher: refresher, request: request)
            await MainActor.run {
                guard let self else { return }
                let acceptsGrok = includeGrok
                    && grokRefreshGeneration == self.tokenSaverGrokAccountUsageRefreshGeneration
                let acceptedUsages = usages.filter { $0.provider != .grok || acceptsGrok }
                for usage in acceptedUsages {
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
                if !acceptedUsages.isEmpty {
                    let store = TokenSaverUsageStore(appSupportDirectory: self.appSupportDirectory)
                    let existing = store.load().providers
                    let toClear = TokenSaverUsageStore.providersToClearAfterPartialAccountUsageRefresh(
                        returned: acceptedUsages.map(\.provider),
                        existing: existing
                    ).filter { acceptsGrok || $0 != .grok }
                    for provider in toClear {
                        self.clearTokenSaverAccountUsagePercentages(provider)
                    }
                }
                self.publishTokenSaverAccountUsageRefresh(
                    state: "finished",
                    reason: reason,
                    detail: acceptedUsages.isEmpty ? "empty" : nil,
                    providers: acceptedUsages.map(\.provider.rawValue)
                )
                if let periodicCycleID,
                   self.tokenSaverPeriodicAccountUsageCycle?.id == periodicCycleID {
                    self.tokenSaverPeriodicAccountUsageCycle?.otherProvidersFinished = true
                    if !acceptedUsages.isEmpty {
                        self.tokenSaverPeriodicAccountUsageCycle?.otherProvidersSucceeded = true
                    }
                    _ = self.reconcilePeriodicGrokMissIfReady(cycleID: periodicCycleID)
                }
                self.publishTokenSaverWidgetDigestFromDisk(isRefreshing: false)
                self.tokenSaverAccountUsageRefreshTask = nil
            }
        }
    }

    /// Keep the Grok ring fresh even when Codex/Claude are slow, without
    /// duplicating the Grok credits request inside the full refresh.
    public func refreshPeriodicTokenSaverAccountUsage() {
        let cycleFinished = tokenSaverPeriodicAccountUsageCycle.map {
            $0.grokFinished && $0.otherProvidersFinished
        } ?? true
        if tokenSaverPeriodicGrokAccountUsageRefreshTask == nil, cycleFinished {
            tokenSaverPeriodicAccountUsageCycleID &+= 1
            tokenSaverPeriodicAccountUsageCycle = TokenSaverPeriodicAccountUsageCycle(
                id: tokenSaverPeriodicAccountUsageCycleID
            )
        }
        refreshGrokTokenSaverAccountUsage(reason: "periodic", coalescePeriodic: true)
        refreshTokenSaverAccountUsage(reason: "periodic", includeGrok: false)
    }

    @discardableResult
    private func reconcilePeriodicGrokMissIfReady(cycleID: UInt64) -> Bool {
        guard var cycle = tokenSaverPeriodicAccountUsageCycle,
              cycle.id == cycleID,
              cycle.grokFinished,
              !cycle.grokSucceeded,
              cycle.otherProvidersSucceeded,
              !cycle.reconciledMiss else { return false }
        let store = TokenSaverUsageStore(appSupportDirectory: appSupportDirectory)
        let shouldClearGrok = TokenSaverUsageStore.providersToClearAfterPartialAccountUsageRefresh(
            returned: [],
            existing: store.load().providers,
            managed: [.grok]
        ).contains(.grok)
        if shouldClearGrok {
            clearTokenSaverAccountUsagePercentages(.grok)
        }
        cycle.reconciledMiss = true
        tokenSaverPeriodicAccountUsageCycle = cycle
        return shouldClearGrok
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

    /// Grok-only account-usage refresh from the live CLI credits API, with the
    /// local billing log as fallback.
    ///
    /// WHY: Claude/Codex push live `.accountUsage` during a turn. Grok ACP does
    /// not, so the purple weekly ring stayed stale until launch / periodic /
    /// details-open. Independent of `tokenSaverAccountUsageRefreshTask`
    /// so a busy full refresh cannot skip Grok.
    ///
    /// - Parameters:
    ///   - reason: telemetry label (`run_finished`, tests, …)
    ///   - billingLogURL: override for tests; default is the user billing log.
    ///     When set, the live credits API is skipped so tests stay offline.
    ///   - coalescePeriodic: coalesce only timer ticks; run-finished refreshes
    ///     remain immediate so a new local billing record is never delayed.
    public func refreshGrokTokenSaverAccountUsage(
        reason: String,
        billingLogURL: URL? = nil,
        coalescePeriodic: Bool = false
    ) {
        guard PrivateAccountSessionStore(repo: settingsRepo).load() != nil else {
            publishTokenSaverAccountUsageRefresh(state: "skipped", reason: reason, detail: "signed_out")
            return
        }
        if coalescePeriodic, tokenSaverPeriodicGrokAccountUsageRefreshTask != nil {
            publishTokenSaverAccountUsageRefresh(state: "skipped", reason: reason, detail: "grok_busy")
            return
        }
        if !coalescePeriodic {
            tokenSaverPeriodicAccountUsageCycle = nil
        } else if var cycle = tokenSaverPeriodicAccountUsageCycle {
            cycle.grokFinished = false
            tokenSaverPeriodicAccountUsageCycle = cycle
        }
        tokenSaverGrokAccountUsageRefreshGeneration &+= 1
        let refreshGeneration = tokenSaverGrokAccountUsageRefreshGeneration
        let logURL = billingLogURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok/logs/unified.jsonl")
        let request = TokenSaverAccountUsageRefreshRequest(
            grokBillingLogURL: logURL,
            grokAuthFileURL: billingLogURL == nil ? Self.defaultGrokAuthFileURL : nil,
            cwd: state.workspaces.values.first?.cwd ?? NSHomeDirectory(),
            environment: [:]
        )
        let detail = billingLogURL == nil ? "grok_credits_api" : "grok_billing_log"
        publishTokenSaverAccountUsageRefresh(state: "started", reason: reason, detail: detail)
        let refresher = tokenSaverAccountUsageRefresher
        let task = Task { [weak self] in
            let usage = await refresher.grokAccountUsage(request)
            await MainActor.run {
                guard let self else { return }
                defer {
                    if coalescePeriodic {
                        self.tokenSaverPeriodicGrokAccountUsageRefreshTask = nil
                    }
                }
                guard refreshGeneration == self.tokenSaverGrokAccountUsageRefreshGeneration else {
                    return
                }
                var shouldPublishWidgetDigest = false
                if let usage {
                    self.recordTokenSaverAccountUsage(usage)
                    shouldPublishWidgetDigest = true
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
                if coalescePeriodic,
                   var cycle = self.tokenSaverPeriodicAccountUsageCycle {
                    cycle.grokFinished = true
                    cycle.grokSucceeded = cycle.grokSucceeded || usage != nil
                    self.tokenSaverPeriodicAccountUsageCycle = cycle
                    shouldPublishWidgetDigest = self.reconcilePeriodicGrokMissIfReady(cycleID: cycle.id)
                        || shouldPublishWidgetDigest
                }
                if shouldPublishWidgetDigest,
                   !coalescePeriodic || self.tokenSaverAccountUsageRefreshTask == nil {
                    self.publishTokenSaverWidgetDigestFromDisk(isRefreshing: false)
                }
            }
        }
        if coalescePeriodic {
            tokenSaverPeriodicGrokAccountUsageRefreshTask = task
        }
    }

    static var defaultGrokAuthFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
    }

    static var defaultClaudeAuthFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    static var defaultCodexAuthFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
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

    /// Disk-backed Token Saver glanceable publish for remote iOS clients.
    @MainActor
    public func publishTokenSaverWidgetDigestFromDisk(isRefreshing: Bool = false) {
        let enabled = SettingsStore(db: db).load().tokenSaverEnabled
        let subscribed = PrivateAccountSessionStore(repo: settingsRepo).load()?.user.subscribed == true
        TokenSaverWidgetDigest.publishFromDisk(
            appSupportDirectory: appSupportDirectory,
            economyRepo: tokenSaverDailyEconomyRepo,
            tokenSaverEnabled: enabled,
            subscribed: subscribed,
            isRefreshing: isRefreshing,
            updatedAt: Date()
        )
    }

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
    /// sidecar/recovery path is unavailable, literal preservation fails, or
    /// the final marker-inclusive payload cannot prove substantial net savings.
    /// Ineligible and non-profitable prompts always fail open to exact Human text.

    private func tokenSaverProjectAdmission(
        threadId: AgentThreadID,
        lane laneName: String,
        globallyEnabled: Bool? = nil
    ) -> TokenSaverAdmissionDecision {
        if tokenSaverLifecycleDegradedReason != nil {
            return .init(allowed: false, reason: "lifecycle_degraded")
        }
        let enabled = globallyEnabled ?? isTokenSaverRuntimeActive()
        guard let scope = tokenSaverPersistentScope(threadId: threadId),
              let lane = try? tokenSaverLaneStateRepo.get(projectID: scope.projectID, lane: laneName) else {
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

    /// Agent App workspace threads do not always have a nested project row. The
    /// workspace UUID is still a stable, exact local boundary, so use it as the
    /// project component instead of silently disabling governed Token Saver on
    /// every top-level workspace thread.
    ///
    /// Bot Desk/peer threads stay workspace-less so they never appear on Agent
    /// App rails. The linked bot conversation is their exact local boundary.
    private func tokenSaverPersistentScope(
        threadId: AgentThreadID
    ) -> (workspaceID: String, projectID: String)? {
        tokenSaverPersistentScope(
            threadId: threadId,
            identity: try? threadRepo.identity(of: threadId)
        )
    }

    private func tokenSaverPersistentScope(
        threadId: AgentThreadID,
        identity: AgentThreadRepository.IdentityChrome?
    ) -> (workspaceID: String, projectID: String)? {
        guard let identity else { return nil }
        if let workspaceID = identity.workspaceId?.value.uuidString {
            return (workspaceID, identity.projectId?.value.uuidString ?? workspaceID)
        }
        if let projectID = identity.projectId?.value.uuidString {
            return (projectID, projectID)
        }
        guard let conversation = try? botStore.conversationLinked(to: threadId) else {
            return nil
        }
        let botScope = conversation.botID.value.uuidString
        return (botScope, botScope)
    }

    private func tokenSaverProjectObservation(
        threadId: AgentThreadID,
        lane laneName: String
    ) -> TokenSaverAdmissionDecision {
        guard tokenSaverLifecycleDegradedReason == nil,
              isTokenSaverRuntimeActive(),
              let identity = try? threadRepo.identity(of: threadId),
              let projectID = identity.projectId?.value.uuidString,
              identity.workspaceId != nil,
              let lane = try? tokenSaverLaneStateRepo.get(projectID: projectID, lane: laneName),
              ["shadow_only", "promoted"].contains(lane.state),
              !lane.optedOut,
              !lane.killSwitchActive else {
            return .init(allowed: false, reason: "observation_not_admitted")
        }
        return .init(allowed: true, reason: lane.state)
    }

    private func tokenSaverProjectObservation(runId: AgentRunID, lane: String) -> TokenSaverAdmissionDecision {
        guard let threadId = try? runRepo.threadId(of: runId) else {
            return .init(allowed: false, reason: "missing_run_scope")
        }
        return tokenSaverProjectObservation(threadId: threadId, lane: lane)
    }

    private func tokenSaverProjectAdmission(
        runId: AgentRunID,
        lane: String,
        globallyEnabled: Bool? = nil
    ) -> TokenSaverAdmissionDecision {
        guard let threadId = try? runRepo.threadId(of: runId) else {
            return .init(allowed: false, reason: "missing_run_scope")
        }
        return tokenSaverProjectAdmission(
            threadId: threadId,
            lane: lane,
            globallyEnabled: globallyEnabled
        )
    }

    /// task-08: cross-user Token Saver is raw-only for every compressor turn kind.
    /// Unknown identity fails closed (disables Token Saver callbacks) while keeping provider raw.
    private func tokenSaverIsSameUser(threadId: AgentThreadID) -> Bool {
        tokenSaverIsSameUser(identity: try? threadRepo.identity(of: threadId))
    }

    private func tokenSaverIsSameUser(identity: AgentThreadRepository.IdentityChrome?) -> Bool {
        guard let identity else { return false }
        guard let runAs = identity.runAsUser else { return true }
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
        let projectID = tokenSaverPersistentScope(threadId: threadId)?.projectID
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
        let projectID = tokenSaverPersistentScope(threadId: threadId)?.projectID
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

    static func providerSessionSupportsWire(_ runtimePayloadJSON: String?) -> Bool {
        guard let runtimePayloadJSON,
              let data = runtimePayloadJSON.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data),
              let object = decoded as? [String: Any] else {
            return false
        }
        return object["wireProtocolVersion"] as? String == RCWireProtocol.version
    }

    /// Installs the typed request selector only when a complete exact bundle is
    /// present. Passing nil restores the default unset selector.
    @discardableResult
    func installTokenSaverExactRuntimeCapability(
        _ capability: TokenSaverExactRuntimeCapability?
    ) -> Bool {
        tokenSaverExactRuntimeCapabilityLock.lock()
        tokenSaverExactRuntimeCapability = capability
        tokenSaverExactRuntimeCapabilityLock.unlock()
        if capability != nil {
            coordinator.tokenSaverOutboundSelector = { [weak self] request in
                guard let self else {
                    return await TokenSaverBestOfThreeSelector.select(
                        canonicalHuman: request.canonicalHuman,
                        humanOutboundPrompt: request.admittedRequest.prompt,
                        humanEffectiveEnvelope: request.admittedRequest.prompt,
                        target: TokenSaverBestOfThreeSelector.Target(
                            provider: request.admittedRequest.provider.rawValue,
                            resolvedModel: request.admittedRequest.model,
                            counterID: "unavailable",
                            counterRevision: "unavailable",
                            encoding: "unavailable"
                        ),
                        candidates: [],
                        counter: nil
                    )
                }
                return await self.selectTokenSaverOutbound(request)
            }
            coordinator.tokenSaverContextSeedPreparer = self.makeContextSeedPreparer()
            applyContextSeedHooks(to: tokenSaverCodexAdapter)
            return true
        }
        coordinator.tokenSaverOutboundSelector = nil
        coordinator.tokenSaverContextSeedPreparer = TokenSaverHumanContextSeedPreparer()
        applyContextSeedHooks(to: tokenSaverCodexAdapter)
        return false
    }

    private func makeContextSeedPreparer() -> TokenSaverContextSeedPreparing {
        guard let capability = snapshotTokenSaverExactRuntimeCapability() else {
            return TokenSaverHumanContextSeedPreparer()
        }
        let compactSpanLaneURL = tokenSaverDistillCLIStateURL
        return TokenSaverExactContextSeedPreparer(
            target: capability.target,
            counter: capability.counterCapability,
            project: { format, payload in
                if format == .rcs1,
                   TokenSaverLaneKillSwitch.isDisabled(
                    "compact-span",
                    environment: ProcessInfo.processInfo.environment,
                    cliState: TokenSaverLaneKillSwitch.loadCLIStateOverlay(from: compactSpanLaneURL)
                   ) {
                    return nil
                }
                guard let envelope = capability.projectEnvelope(
                    format,
                    payload,
                    TokenSaverOutboundSelectionRequest(
                        canonicalHuman: payload,
                        admittedRequest: AgentRunRequest(
                            threadId: AgentThreadID(),
                            provider: .codex,
                            model: capability.target.resolvedModel,
                            cwd: "/",
                            prompt: payload
                        ),
                        autoRoute: nil,
                        admittedEnvironment: TokenSaverOutboundSelectionRequest.environment(
                            [:],
                            for: format
                        )
                    )
                ) else {
                    return nil
                }
                return TokenSaverContextSeedBuilder.ProjectedEnvelope(
                    payload: envelope.payload,
                    abi: envelope.abi,
                    effectiveEnvelope: envelope.effectiveEnvelope
                )
            }
        )
    }

    private func snapshotTokenSaverExactRuntimeCapability() -> TokenSaverExactRuntimeCapability? {
        tokenSaverExactRuntimeCapabilityLock.withLock { tokenSaverExactRuntimeCapability }
    }

    func selectTokenSaverOutbound(
        _ request: TokenSaverOutboundSelectionRequest
    ) async -> TokenSaverBestOfThreeSelector.Decision {
        let canonical = request.canonicalHuman
        let humanOutbound = request.admittedRequest.prompt
        let sourceSHA256 = TokenSaverExactRuntimeSupport.sha256Hex(canonical)

        func decide(
            target: TokenSaverBestOfThreeSelector.Target,
            humanEnvelope: String,
            rcw1: TokenSaverBestOfThreeSelector.Candidate,
            rcs1: TokenSaverBestOfThreeSelector.Candidate = TokenSaverExactRuntimeSupport.disabledRCS1Candidate(
                sourceSHA256: sourceSHA256
            ),
            counter: TokenSaverBestOfThreeSelector.CounterCapability?
        ) async -> TokenSaverBestOfThreeSelector.Decision {
            await TokenSaverBestOfThreeSelector.select(
                canonicalHuman: canonical,
                humanOutboundPrompt: humanOutbound,
                humanEffectiveEnvelope: humanEnvelope,
                target: target,
                candidates: [rcw1, rcs1],
                counter: counter
            )
        }

        func contentFreeHuman() async -> TokenSaverBestOfThreeSelector.Decision {
            await TokenSaverBestOfThreeSelector.select(
                canonicalHuman: canonical,
                humanOutboundPrompt: humanOutbound,
                humanEffectiveEnvelope: humanOutbound,
                target: TokenSaverBestOfThreeSelector.Target(
                    provider: request.admittedRequest.provider.rawValue,
                    resolvedModel: request.admittedRequest.model,
                    counterID: "unavailable",
                    counterRevision: "unavailable",
                    encoding: "unavailable"
                ),
                candidates: [],
                counter: nil
            )
        }

        guard isTokenSaverRuntimeActive(),
              TokenSaverAdapterMatrix.tokenSaverCallbacksAllowed(
                isSameUser: tokenSaverIsSameUser(threadId: request.admittedRequest.threadId),
                turn: .initial
              ) else {
            return await contentFreeHuman()
        }

        let capability = snapshotTokenSaverExactRuntimeCapability()
        guard let capability else {
            return await decide(
                target: TokenSaverBestOfThreeSelector.Target(
                    provider: request.admittedRequest.provider.rawValue,
                    resolvedModel: request.admittedRequest.model,
                    counterID: "unavailable",
                    counterRevision: "unavailable",
                    encoding: "unavailable"
                ),
                humanEnvelope: humanOutbound,
                rcw1: TokenSaverExactRuntimeSupport.disabledRCW1Candidate(sourceSHA256: sourceSHA256),
                counter: nil
            )
        }

        let requestTarget = TokenSaverBestOfThreeSelector.Target(
            provider: request.admittedRequest.provider.rawValue,
            resolvedModel: request.admittedRequest.model,
            counterID: capability.target.counterID,
            counterRevision: capability.target.counterRevision,
            encoding: capability.target.encoding
        )
        if requestTarget != capability.target {
            return await decide(
                target: requestTarget,
                humanEnvelope: humanOutbound,
                rcw1: TokenSaverExactRuntimeSupport.disabledRCW1Candidate(sourceSHA256: sourceSHA256),
                counter: capability.counterCapability
            )
        }

        guard let humanProjection = capability.projectEnvelope(.human, humanOutbound, request) else {
            return await contentFreeHuman()
        }

        let compactSpanEnabled = !tokenSaverLaneIsDisabled("compact-span")
        var provisional: TokenSaverProvisionalRCW1Recovery?
        var rcw1 = TokenSaverExactRuntimeSupport.disabledRCW1Candidate(sourceSHA256: sourceSHA256)
        let rcw1Environment = request.environment(for: .rcw1)
        let rcw1Capable = rcw1Environment[TokenSaverExecutionReceiptSeam.wireCapabilityEnvKey] == "1"
            && rcw1Environment["RC_TOKEN_SAVER_WIRE_VERSION"] == "1"
        if rcw1Capable,
           let prepared = await encodeProvisionalRCW1(
            prompt: canonical,
            provider: request.admittedRequest.provider,
            threadId: request.admittedRequest.threadId,
            runId: request.admittedRequest.runId
           ) {
            let rankedPayload: String
            if let route = request.autoRoute {
                do {
                    rankedPayload = try applyAutoWireConstraint(to: prepared.payload, route: route)
                } catch {
                    discardProvisionalRCW1Recovery(prepared)
                    return await contentFreeHuman()
                }
            } else {
                rankedPayload = prepared.payload
            }
            if let projected = capability.projectEnvelope(.rcw1, rankedPayload, request) {
                provisional = prepared
                rcw1 = TokenSaverBestOfThreeSelector.Candidate(
                    format: .rcw1,
                    sourceSHA256: sourceSHA256,
                    payload: projected.payload,
                    abi: projected.abi,
                    effectiveEnvelope: projected.effectiveEnvelope,
                    handle: prepared.handle,
                    producerID: "remotecode-rcw1",
                    producerRevision: "1",
                    abiRevision: "1",
                    generation: .passed,
                    structural: .passed,
                    semantic: .passed,
                    recovery: .passed
                )
            } else {
                discardProvisionalRCW1Recovery(prepared)
            }
        }

        var rcs1 = TokenSaverExactRuntimeSupport.disabledRCS1Candidate(sourceSHA256: sourceSHA256)
        if compactSpanEnabled,
           canonical == humanOutbound,
           let item = RemoteCodeCompactSpan.encode(canonical),
           let recovered = RemoteCodeCompactSpan.decode(item),
           recovered == canonical,
           let projected = capability.projectEnvelope(.rcs1, item, request),
           RemoteCodeCompactSpan.decode(projected.payload) == canonical {
            rcs1 = TokenSaverBestOfThreeSelector.Candidate(
                format: .rcs1,
                sourceSHA256: sourceSHA256,
                payload: projected.payload,
                abi: projected.abi,
                effectiveEnvelope: projected.effectiveEnvelope,
                handle: nil,
                producerID: TokenSaverRequestSelectionReceipt.rcs1ProducerID,
                producerRevision: "1",
                abiRevision: "1",
                generation: .passed,
                structural: .passed,
                semantic: .passed,
                recovery: .passed
            )
        }

        let decision = await decide(
            target: requestTarget,
            humanEnvelope: humanProjection.effectiveEnvelope,
            rcw1: rcw1,
            rcs1: rcs1,
            counter: capability.counterCapability
        )
        if decision.selectedFormat == .rcw1, let provisional {
            if finalizeProvisionalRCW1Recovery(provisional) != nil {
                return decision
            }
            return decision.fallingBackToHuman(
                payload: humanOutbound,
                reason: .candidateError,
                canonicalHuman: canonical
            )
        }
        if let provisional {
            discardProvisionalRCW1Recovery(provisional)
        }
        return decision
    }

    private func applyAutoWireConstraint(
        to wirePrompt: String,
        route: AgentOrchestrationRoute
    ) throws -> String {
        if let override = tokenSaverAutoWireTransformForTesting {
            return try override(wirePrompt, route)
        }
        return try AgentOrchestrationRuntime.autoOrchestrateProviderWirePrompt(
            wirePrompt: wirePrompt,
            admittedRoute: route
        )
    }

    private func encodeProvisionalRCW1(
        prompt: String,
        provider: AgentProvider,
        threadId: AgentThreadID,
        runId: AgentRunID
    ) async -> TokenSaverProvisionalRCW1Recovery? {
        guard !prompt.isEmpty else { return nil }
        guard TokenSaverAdapterMatrix.tokenSaverCallbacksAllowed(
            isSameUser: tokenSaverIsSameUser(threadId: threadId),
            turn: .initial
        ) else { return nil }
        guard !tokenSaverLaneIsDisabled("wire-encode"),
              !tokenSaverLaneIsDisabled("wire-render-english") else {
            return nil
        }
        guard let persistentScope = tokenSaverPersistentScope(threadId: threadId) else {
            return nil
        }
        try? tokenSaverLaneStateRepo.ensureDefaults(projectID: persistentScope.projectID)
        let encodeAdmission = tokenSaverProjectAdmission(threadId: threadId, lane: "wire-encode")
        let renderAdmission = tokenSaverProjectAdmission(threadId: threadId, lane: "wire-render-english")
        guard encodeAdmission.allowed, renderAdmission.allowed else { return nil }
        if let session = try? providerSessionRuntimeRepo.get(threadId: threadId),
           !Self.providerSessionSupportsWire(session.runtimePayloadJSON) {
            return nil
        }
        return await distillPrepareProvisionalRCW1(
            original: prompt,
            stageOriginal: prompt,
            provider: provider,
            threadId: threadId,
            runId: runId,
            profitabilityGate: { _ in true },
            trace: { _ in }
        )
    }

    func tokenSaverCompress(
        prompt: String,
        provider: AgentProvider,
        threadId: AgentThreadID,
        cacheState: String = "prompt",
        runId: AgentRunID? = nil
    ) async -> String {
        func trace(_ checkpoint: String) {
            NSLog("RemoteCode RCW1 admission checkpoint=\(checkpoint) provider=\(provider.rawValue) cache=\(cacheState)")
        }
        trace("entered")
        guard !prompt.isEmpty else {
            trace("empty_prompt")
            return prompt
        }
        let inputTokens = TokenEstimator.estimate(prompt)
        guard inputTokens >= 80 else {
            trace("below_profitability_floor")
            return prompt
        }
        let turn: TokenSaverAdapterMatrix.CrossUserTurn =
            cacheState.contains("follow") ? .followUp : .initial
        guard TokenSaverAdapterMatrix.tokenSaverCallbacksAllowed(
            isSameUser: tokenSaverIsSameUser(threadId: threadId),
            turn: turn
        ) else {
            trace("denied_user_or_turn")
            return prompt
        }
        guard !tokenSaverLaneIsDisabled("wire-encode"),
              !tokenSaverLaneIsDisabled("wire-render-english") else {
            trace("lane_disabled")
            return prompt
        }
        guard let persistentScope = tokenSaverPersistentScope(threadId: threadId) else {
            recordTokenSaverAdmissionDenial(
                threadId: threadId,
                lane: "wire-encode",
                decision: .init(allowed: false, reason: "missing_project_scope")
            )
            trace("missing_scope")
            return prompt
        }
        // Workspace-only threads use their stable workspace UUID as the project
        // component. Seed both rows before the atomic two-direction admission.
        try? tokenSaverLaneStateRepo.ensureDefaults(projectID: persistentScope.projectID)
        let encodeAdmission = tokenSaverProjectAdmission(threadId: threadId, lane: "wire-encode")
        let renderAdmission = tokenSaverProjectAdmission(threadId: threadId, lane: "wire-render-english")
        guard encodeAdmission.allowed, renderAdmission.allowed else {
            let deniedLane = encodeAdmission.allowed ? "wire-render-english" : "wire-encode"
            let denial = encodeAdmission.allowed ? renderAdmission : encodeAdmission
            recordTokenSaverAdmissionDenial(
                threadId: threadId,
                lane: deniedLane,
                decision: denial
            )
            trace("governance_denied")
            return prompt
        }
        // A provider session created before the trusted RCW1 capability was
        // installed must remain human-text fail-open. Sending a self-describing
        // control contract inside user content is both less trusted and was
        // rejected by real Claude resume sessions. New sessions record the
        // capability at creation, so later follow-ups can safely use wire.
        if let session = try? providerSessionRuntimeRepo.get(threadId: threadId),
           !Self.providerSessionSupportsWire(session.runtimePayloadJSON) {
            trace("legacy_session")
            return prompt
        }
        trace("admitted")
        // Wire encoding is one atomic semantic transform. If the local encoder
        // is unavailable or rejected, the exact human prompt must reach the
        // provider; an unrelated prose/dedupe transform is not a valid fallback.
        let deterministicCandidate = prompt

        let grammarTokens = TokenEstimator.estimate(AgentSkillInstaller.rcWireAgentInstructionsTemplate)
        func isProfitableWire(_ candidate: String) -> Bool {
            let outputTokens = TokenEstimator.estimate(candidate)
            guard RCWireProtocol.isWire(candidate) else { return false }
            return outputTokens <= (inputTokens * 45) / 100
                && candidate.utf8.count < prompt.utf8.count
                && outputTokens + grammarTokens < inputTokens
        }

        // Recovery is finalized only after the marker-inclusive payload passes
        // every profitability condition, so a rejected frame cannot leave a live
        // exact-content capability behind.
        func adopt(_ candidate: String, stage: TokenSaverRouteStage) -> String {
            let outputTokens = TokenEstimator.estimate(candidate)
            recordTokenSaverSidecarSavings(
                provider: provider,
                threadId: threadId,
                mode: DistillMode.wireEncode.rawValue,
                inputTokens: inputTokens,
                outputTokens: outputTokens + grammarTokens,
                savedTokens: inputTokens - outputTokens - grammarTokens,
                cacheState: cacheState,
                routeStage: stage
            )
            return candidate
        }

        // Demand-start Distill without blocking this turn on MLX warmup. Kick the
        // sidecar for later turns; if not already `.running`, fail open to the
        // exact original input (Token Saver fail-open).
        guard let provisional = await distillPrepareProvisionalRCW1(
            original: prompt,
            stageOriginal: deterministicCandidate,
            provider: provider,
            threadId: threadId,
            runId: runId,
            profitabilityGate: isProfitableWire,
            trace: trace
        ) else {
            return prompt
        }
        guard let recoveredCandidate = finalizeProvisionalRCW1Recovery(provisional) else {
            return prompt
        }
        return adopt(recoveredCandidate, stage: .deterministic)
    }

    private func distillPrepareProvisionalRCW1(
        original: String,
        stageOriginal: String,
        provider: AgentProvider,
        threadId: AgentThreadID,
        runId: AgentRunID?,
        profitabilityGate: (String) -> Bool,
        trace: (String) -> Void
    ) async -> TokenSaverProvisionalRCW1Recovery? {
        tokenSaverDistillPrepareInvocations += 1
        startTokenSaverDistillServiceIfEligible()
        guard let client = currentDistillClient() else {
            trace("sidecar_not_ready")
            return nil
        }
        let inputByteCount = stageOriginal.utf8.count
        let wireOutputBudget: Int
        if inputByteCount > (Int.max - 1_024) / 2 {
            wireOutputBudget = Int.max
        } else {
            wireOutputBudget = max(512, inputByteCount * 2 + 1_024)
        }
        let request = DistillRequest(
            mode: .wireEncode,
            priority: .interactive,
            input: stageOriginal,
            runMode: .optimize,
            maxOutputCharacters: wireOutputBudget
        )
        let scopedRecoveryAvailable = runId != nil
            && tokenSaverPersistentScope(threadId: threadId) != nil
        NSLog(
            "RemoteCode RCW1 encode started provider=\(provider.rawValue) scoped_recovery=\(scopedRecoveryAvailable)"
        )
        do {
            let response: DistillResponse
            if let runId,
               let scope = tokenSaverPersistentScope(threadId: threadId) {
                response = try await client.distill(
                    request,
                    recoveryContext: .init(
                        workspaceID: scope.workspaceID,
                        projectID: scope.projectID,
                        threadID: threadId.value.uuidString,
                        provider: provider.rawValue,
                        attemptID: runId.value.uuidString,
                        operationID: "wire-encode:\(runId.value.uuidString)"
                    )
                )
            } else {
                response = try await client.distill(request)
            }
            let responseStage = response.routeStage?.rawValue ?? "unknown"
            NSLog(
                "RemoteCode RCW1 encode returned provider=\(provider.rawValue) wire=\(RCWireProtocol.isWire(response.output)) recovery_handle=\(response.originalHandle != nil) stage=\(responseStage)"
            )
            let modelOutput = response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stageOriginal : response.output
            let wireFrames = try? RCWireProtocol.parse(modelOutput)
            let isValidRequestWire = wireFrames?.allSatisfy { $0.direction == .request } == true
            let literalSafeModelOutput: String? = response.routeStage == .deterministic
                && isValidRequestWire
                && RCWireProtocol.preservesProtectedSemantics(original: original, wire: modelOutput)
                && RCWireProtocol.preservesRequestMeaning(original: original, wire: modelOutput)
                && LiteralPreservation.guarded(original: original, compressed: modelOutput).droppedLiteral == nil
                ? modelOutput
                : nil
            guard let literalSafeModelOutput,
                  let provisional = prepareProvisionalRCW1Recovery(
                    original: original,
                    stageOriginal: stageOriginal,
                    candidate: literalSafeModelOutput,
                    capability: response.originalHandle,
                    idempotencyKey: response.recoveryIdempotencyKey,
                    provider: provider,
                    threadId: threadId,
                    runId: runId,
                    profitabilityGate: profitabilityGate
                  ) else {
                discardProvisionalWireRecovery(
                    capability: response.originalHandle,
                    idempotencyKey: response.recoveryIdempotencyKey,
                    provider: provider,
                    threadId: threadId,
                    runId: runId
                )
                return nil
            }
            return provisional
        } catch {
            NSLog("RemoteCode Token Saver compression skipped (provider=\(provider.rawValue)): \(error)")
            return nil
        }
    }

    private func prepareProvisionalRCW1Recovery(
        original: String,
        stageOriginal: String,
        candidate: String,
        capability: String?,
        idempotencyKey: String?,
        provider: AgentProvider,
        threadId: AgentThreadID,
        runId: AgentRunID?,
        profitabilityGate: (String) -> Bool
    ) -> TokenSaverProvisionalRCW1Recovery? {
        guard let runId,
              let capability,
              let idempotencyKey,
              let resolvedScope = tokenSaverPersistentScope(threadId: threadId),
              !tokenSaverLaneIsDisabled("wire-encode") else {
            return nil
        }
        let scope = TokenSaverPersistentScope(
            workspaceID: resolvedScope.workspaceID,
            projectID: resolvedScope.projectID,
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
                    operationID: "wire-full-original:\(runId.value.uuidString)",
                    lane: "wire-encode",
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

            var recoverable = candidate
            for marker in recoveryMarkers {
                recoverable = try RCWireProtocol.addingExactRecord(marker, to: recoverable)
            }
            guard profitabilityGate(recoverable) else {
                discardProvisionals()
                return nil
            }

            let fullMember = fullOriginal.map {
                TokenSaverSemanticRecoveryMember(
                    capability: $0.capability,
                    idempotencyKey: $0.idempotencyKey
                )
            }
            return TokenSaverProvisionalRCW1Recovery(
                payload: recoverable,
                handle: capability,
                scope: scope,
                stage: TokenSaverSemanticRecoveryMember(
                    capability: capability,
                    idempotencyKey: idempotencyKey
                ),
                fullOriginal: fullMember
            )
        } catch {
            NSLog("RemoteCode Token Saver wire recovery preparation failed: \(error)")
            discardProvisionals()
            return nil
        }
    }

    private func finalizeProvisionalRCW1Recovery(
        _ provisional: TokenSaverProvisionalRCW1Recovery
    ) -> String? {
        do {
            guard try TokenSaverScopedRecoveryStore(db: db).finalizeSemanticRecoverySet(
                stage: provisional.stage,
                fullOriginal: provisional.fullOriginal,
                scope: provisional.scope
            ) else {
                discardProvisionalRCW1Recovery(provisional)
                return nil
            }
            tokenSaverRCW1FinalizeInvocations += 1
            return provisional.payload
        } catch {
            NSLog("RemoteCode Token Saver wire recovery finalization failed: \(error)")
            discardProvisionalRCW1Recovery(provisional)
            return nil
        }
    }

    private func discardProvisionalRCW1Recovery(_ provisional: TokenSaverProvisionalRCW1Recovery) {
        tokenSaverRCW1DiscardInvocations += 1
        let store = TokenSaverScopedRecoveryStore(db: db)
        for member in provisional.members {
            _ = try? store.discardAbandoned(
                capability: member.capability,
                scope: provisional.scope,
                idempotencyKey: member.idempotencyKey
            )
        }
    }

    private func discardProvisionalWireRecovery(
        capability: String?,
        idempotencyKey: String?,
        provider: AgentProvider,
        threadId: AgentThreadID,
        runId: AgentRunID?
    ) {
        guard let runId,
              let capability,
              let idempotencyKey,
              let resolvedScope = tokenSaverPersistentScope(threadId: threadId) else {
            return
        }
        let scope = TokenSaverPersistentScope(
            workspaceID: resolvedScope.workspaceID,
            projectID: resolvedScope.projectID,
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

    /// Stores only bounded, exact-thread private learning. The production read path
    /// uses the same scope and never mutates provider-global instruction files.
    func recordSessionLearnFromRun(runId: AgentRunID, status: AgentRunStatus) {
        let settings = SettingsStore(db: db).load()
        // Thread id + identity only. A leftover 10-column `get` (including
        // `error_message`) hitchs every SessionLearn-enabled finish before
        // failed/expensive even decides whether the blob is needed.
        guard settings.sessionLearnEnabled,
              let threadId = try? runRepo.threadId(of: runId),
              tokenSaverProjectObservation(threadId: threadId, lane: "session_learn").allowed,
              let identity = try? threadRepo.identity(of: threadId),
              let workspaceID = identity.workspaceId?.value.uuidString,
              let projectID = identity.projectId?.value.uuidString,
              let lane = try? tokenSaverLaneStateRepo.get(projectID: projectID, lane: "session_learn"),
              lane.retentionDays > 0 else {
            sessionLearnInputTokensByRun.removeValue(forKey: runId)
            return
        }
        let expensive = (sessionLearnInputTokensByRun.removeValue(forKey: runId) ?? 0) >= 64_000
        guard status == .failed || expensive else { return }
        let source = (try? runRepo.errorMessage(of: runId))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
                    threadID: threadId.value.uuidString,
                    provider: (try? runRepo.provider(of: runId))?.rawValue ?? AgentProvider.codex.rawValue
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
        guard let identity = try? threadRepo.identity(of: threadId),
              let workspaceID = identity.workspaceId?.value.uuidString,
              let projectID = identity.projectId?.value.uuidString else {
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
        guard let identity = try? threadRepo.identity(of: parentThreadID),
              let projectID = identity.projectId?.value.uuidString,
              identity.workspaceId != nil,
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
    /// Uses the local natural-language mode; wire rendering is reserved for
    /// provider responses that carry the exact RCW1 sentinel.
    ///
    /// No provider tokens are spent: this is the local Token Saver sidecar.
    func liveActivityDescriptionSummary(
        source: LiveActivitySummary.Source,
        threadId: AgentThreadID?
    ) async -> String? {
        guard isTokenSaverRuntimeActive() else { return nil }
        guard let client = currentDistillClient() else { return nil }

        let targetLanguage = threadId.map { inferredUserLanguageIdentifier(threadId: $0) } ?? "en"
        let request = DistillRequest(
            mode: .naturalLanguage,
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

    func tokenSaverRenderWireResponse(_ response: String, provider _: AgentProvider, threadId _: AgentThreadID, runId _: AgentRunID? = nil) async -> String {
        guard RCWireProtocol.isWire(response) else {
            return response
        }
        guard let frames = try? RCWireProtocol.parse(response),
              frames.allSatisfy({ $0.direction == .response }) else {
            return "Token Saver could not decode the provider response. The original response was preserved below the Token Saver optimized disclosure."
        }
        let fallback = RCWireProtocol.renderEnglish(frames)
        guard !fallback.isEmpty else {
            return "Token Saver decoded an empty provider response. The original response was preserved below the Token Saver optimized disclosure."
        }
        // RCW1 -> Human is a total, deterministic projection of the provider's
        // records. A prose model could omit or invert an ordinary assertion that
        // contains no regex-protected literal, so it is never allowed to rewrite
        // the canonical Human view.
        return fallback
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

    private func inferredUserLanguageIdentifier(threadId: AgentThreadID) -> String {
        let recent = (try? messageRepo.listRecent(threadId: threadId, limit: 20)) ?? []
        let latestUserText = recent.last(where: { $0.role == .user })?.content ?? ""
        return Self.inferredUserLanguageIdentifier(
            text: latestUserText,
            preferredLanguages: Locale.preferredLanguages
        )
    }

    static func inferredUserLanguageIdentifier(
        text: String,
        preferredLanguages: [String]
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksPortuguese(trimmed) { return "pt-BR" }
        if looksSpanish(trimmed) { return "es" }
        if !trimmed.isEmpty,
           let language = NLLanguageRecognizer.dominantLanguage(for: trimmed),
           language != .undetermined {
            return language.rawValue
        }
        if let preferred = preferredLanguages.first?
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty,
           preferred.utf8.count <= 35,
           preferred.unicodeScalars.allSatisfy({
               CharacterSet.alphanumerics.contains($0) || $0.value == 45
           }) {
            return preferred
        }
        return "en"
    }

    // PERF: language sniff for wire rendering/Live Activity recompiled character-class
    // regexes per call. CharacterSet membership is O(n) over scalars without
    // regex compile (same accent/marker contract as before).
    private static let portugueseAccentScalars = CharacterSet(charactersIn: "áàâãçéêíóôõú")
    private static let spanishMarkerScalars = CharacterSet(charactersIn: "¿¡ñ")

    private static func looksPortuguese(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        if lower.unicodeScalars.contains(where: { portugueseAccentScalars.contains($0) }) {
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
        if lower.unicodeScalars.contains(where: { spanishMarkerScalars.contains($0) }) {
            return true
        }
        let markers = [" por favor ", " gracias ", " respuesta ", " usuario ", " prueba "]
        return markers.contains { lower.contains($0) }
    }

    private func recordTokenSaverPreparedObservation(request: AgentRunRequest, originalPrompt: String) {
        guard tokenSaverProjectObservation(threadId: request.threadId, lane: "measurement").allowed,
              let identity = try? threadRepo.identity(of: request.threadId),
              let workspaceID = identity.workspaceId?.value.uuidString,
              let projectID = identity.projectId?.value.uuidString else {
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
        guard usage.totalTokens > 0 else { return }
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
            guard let status = try? runRepo.status(of: runId),
                  status == .pending || status == .running,
                  let provider = try? runRepo.provider(of: runId) else { return }
            pending = PendingUsage(provider: provider)
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
              tokenSaverProjectObservation(runId: runId, lane: "measurement").allowed,
              let provider = try? runRepo.provider(of: runId),
              let model = try? runRepo.model(of: runId) else {
            return
        }
        let record = TokenSaverAttemptRecord(
            id: attemptID,
            runID: attemptID,
            provider: provider.rawValue,
            adapterVersion: "unavailable",
            providerVersion: "unavailable",
            model: model,
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
                    // mistake that made the old response-translation figure unfalsifiable.
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
                  let provider = try? runRepo.provider(of: runId) {
            var pending = PendingUsage(provider: provider)
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
        // savings writes silently dead. Lossy/governed paths
        // still use tokenSaverProjectAdmission; this path only needs paid feature + same-user.
        guard isTokenSaverRuntimeActive() else { return }
        guard tokenSaverIsSameUser(threadId: threadId) else { return }
        let laneForGovernance = mode == "wire-render-english" ? "wire-render-english" : "deterministic_wrapper"
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

    private struct TokenSaverDailyEconomySharedSnapshot {
        let settings: AppSettings
        let usage: TokenSaverUsageSnapshot
    }

    /// Persist today's credible total so Week = Σ(daily.total_credible).
    public func recomputeTokenSaverDailyEconomyToday(now: Date = Date()) {
        let snapshot = loadTokenSaverDailyEconomySharedSnapshot()
        recomputeTokenSaverDailyEconomy(for: now, now: now, snapshot: snapshot)
    }

    /// Recompute the last `dayCount` calendar days (inclusive of today) so Week
    /// totals heal after formula changes (e.g. v5 permanent-amort → v6 day-scoped).
    /// Older formula rows would otherwise keep painting ~999M until each day ages out.
    public func recomputeTokenSaverDailyEconomyWindow(dayCount: Int = 7, now: Date = Date()) {
        let snapshot = loadTokenSaverDailyEconomySharedSnapshot()
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let count = max(1, min(dayCount, 14))
        for offset in 0..<count {
            guard let day = cal.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            recomputeTokenSaverDailyEconomy(for: day, now: now, snapshot: snapshot)
        }
    }

    /// Settings + usage.json are identical for every day in a window. A new
    /// `SettingsStore` has an empty cache, so the previous per-day path did
    /// 7 SQLite loads + 7 usage.json decode passes on the MainActor.
    private func loadTokenSaverDailyEconomySharedSnapshot() -> TokenSaverDailyEconomySharedSnapshot {
        tokenSaverDailyEconomySharedSnapshotLoadsForTesting += 1
        return TokenSaverDailyEconomySharedSnapshot(
            settings: SettingsStore(db: db).load(),
            usage: TokenSaverUsageStore(appSupportDirectory: appSupportDirectory).load()
        )
    }

    /// Persist one calendar day's credible total (day-scoped amort + caps).
    private func recomputeTokenSaverDailyEconomy(
        for day: Date,
        now: Date,
        snapshot: TokenSaverDailyEconomySharedSnapshot
    ) {
        let settings = snapshot.settings
        let usage = snapshot.usage
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
            // Permanent thread stack, never capped against day-measured pipes.
            let threadInputs = (try? tokenSaverSavingsRepo.threadCacheAmortizationInputs(
                dayStartMs: dayStartMs,
                dayEndMsExclusive: dayEndMs
            )) ?? []
            let threadCacheAmort = TokenSaverBareUserEstimator.sumThreadCacheAmortization(
                inputs: threadInputs.map { (savedTokens: $0.savedTokens, runs: $0.runs) }
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
            let iso = iso8601Formatter.string(from: now)
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

    /// Token Saver ∧ Graphify must both be on. Cached until settings revision
    /// or runtime admission changes so itemDelta (~30 Hz) does not SQLite-load
    /// a fresh SettingsStore on every chunk.
    func isGraphifyUsageRecordingAdmitted() -> Bool {
        let revision = SettingsStore.revision
        if let cached = graphifyUsageAdmissionCache,
           cached.settingsRevision == revision,
           cached.runtimeAdmitted == tokenSaverRuntimeAdmitted {
            return cached.admitted
        }
        graphifyUsageSettingsLoadCountForTesting += 1
        let settings = SettingsStore(db: db).load()
        let admitted = isTokenSaverRuntimeActive(settings: settings)
            && settings.isGraphifyRuntimeActive
        graphifyUsageAdmissionCache = (
            admitted: admitted,
            settingsRevision: revision,
            runtimeAdmitted: tokenSaverRuntimeAdmitted
        )
        return admitted
    }

    /// Provider label for Graphify usage rows. Thread identity is stable for a
    /// run; itemDelta must not SQLite-get the thread on every stream chunk.
    /// First miss probes listChrome (provider only), never the 26-column get.
    func graphifyProviderLabel(for threadId: AgentThreadID) -> String {
        if let cached = graphifyProviderByThread[threadId] { return cached }
        graphifyProviderLookupCountForTesting += 1
        let label = (try? threadRepo.listChrome(ids: [threadId]))?[threadId]?.provider.rawValue
            ?? "unknown"
        if graphifyProviderByThread.count >= Self.graphifyProviderByThreadLimit {
            graphifyProviderByThread.removeAll(keepingCapacity: true)
        }
        graphifyProviderByThread[threadId] = label
        return label
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
        guard isGraphifyUsageRecordingAdmitted() else { return }

        let runKey = runId.value.uuidString
        let createdAtMs = item.startedAtMs > 0
            ? item.startedAtMs
            : Int64(Date().timeIntervalSince1970 * 1000)
        let bufferKey = "\(runKey)|\(item.id)"

        // Seed / merge buffer for streaming providers.
        graphifyItemBuffersLock.lock()
        var buf = graphifyItemBuffers[bufferKey] ?? GraphifyItemBuffer(
            summary: item.summary,
            provider: graphifyProviderLabel(for: threadId),
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
        guard isGraphifyUsageRecordingAdmitted() else { return }
        guard bodyAppend != nil || outputAppend != nil || summary != nil else { return }

        let runKey = runId.value.uuidString
        let bufferKey = "\(runKey)|\(itemId)"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        graphifyItemBuffersLock.lock()
        if var existing = graphifyItemBuffers[bufferKey] {
            if let s = summary, !s.isEmpty { existing.summary = s }
            let resultPhase = (summary == "result") || (existing.summary == "result")
            let bodyClosed = existing.isCommandBodyClosed
            // Mid-stream command text is only needed until detect records a
            // pending row. After that, += copies a growing multi-KB body on
            // every itemDelta and processGraphifyBuffer copies it again just
            // to return. Result-phase output still accumulates for finalize.
            if !bodyClosed {
                if let b = bodyAppend { existing.body += b }
                if let o = outputAppend, !resultPhase { existing.body += o }
            }
            if let o = outputAppend, resultPhase { existing.output += o }
            graphifyItemBuffers[bufferKey] = existing
            graphifyItemBuffersLock.unlock()
            if bodyClosed, !finalize { return }
            processGraphifyBuffer(
                bufferKey: bufferKey,
                itemId: itemId,
                runKey: runKey,
                finalizeOutput: finalize
            )
            return
        }
        graphifyItemBuffersLock.unlock()

        // First chunk for this item: need a provider label once per thread.
        let provider = graphifyProviderLabel(for: threadId)
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

        // After a pending row is recorded, mid-stream deltas only grow the
        // body. Re-running commandText (JSON parse) + detect on a multi-KB
        // tool payload at itemDelta rate is wasted until finalize.
        if alreadyInvocation, !finalizeOutput {
            if alreadyExploration
                || !GraphifyUsageDetector.isExplorationTool(summary: summary) {
                return
            }
        }

        graphifyDetectCountForTesting += 1
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

    /// Wire an EventBus persister to encode and append on the serial writer
    /// queue. Serial submission preserves event sequence while keeping payload
    /// encoding and SQLite transactions off the producer/delivery path.
    public func wireBackgroundPersister(eventBus: EventBus = .shared) {
        let log = eventLog
        let queue = backgroundWriterQueue
        eventBus.persistenceCommitFence = {
            queue.sync {}
        }
        eventBus.persister = { ev in
            guard AppDelegate.shouldPersistEvent(ev) else { return }
            queue.async {
                let json = EventBus.encodePayloadForPersistence(ev.payload)
                _ = try? log.append(seq: ev.seq, kind: ev.kind, payloadJSON: json)
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

    /// Drain EventBus delivery first, then its serial persistence queue. The
    /// ordering closes the graceful-exit race where an accepted publish had not
    /// submitted its writer work when a plain writer barrier was inserted.
    public func flushEventPersistence(eventBus: EventBus = .shared) {
        eventBus.flushPersistenceSubmissions()
        flushWriterQueue()
    }

    @discardableResult
    public func reapIdleProviderSessions(now: Date = Date(), idleAge: TimeInterval = 6 * 60 * 60) throws -> ProviderSessionReaperResult {
        let cutoff = now.addingTimeInterval(-idleAge)
        let activeThreadIds = try threadRepo.runningThreadIds()
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
