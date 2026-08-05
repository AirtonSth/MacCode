import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import CoreModel
import Persistence
import AgentRuntime
import DesignSystemKit
import os

// QA-MAC_AGENT-010: surface-side lifecycle logging (approvals, queue depth) so
// field issues and flakes are diagnosable beyond transient UI strings.
private let agentSurfaceLog = Logger(subsystem: "io.remotecode.agent", category: "surface")

/// PERF: pure id -> (turnIndex, itemIndex) index for AssistantTimelineState.turns.
///
/// Opening a long thread replays every persisted event through `timeline.apply`;
/// each `itemDelta`/`itemState` resolves its item via `mutateItem`, an O(turns x items)
/// linear scan over the whole timeline (AssistantEvents.swift mutateItem). At the
/// ~5000-event prune cap that is O(events x items) on the main actor.
///
/// This is the pure, isolation-testable structure: build from `turns`, look up an id
/// in O(1), and update on insert as items/turns are appended during replay. It mirrors
/// `mutateItem`'s "first occurrence wins" semantics so a fast-path lookup is byte-for-byte
/// equivalent to the linear scan. `nonisolated`/value-typed so it needs no MainActor.
struct TimelineItemIndex: Sendable, Equatable {
    struct Location: Sendable, Equatable {
        let turnIndex: Int
        let itemIndex: Int
    }

    private var map: [String: Location] = [:]

    /// Build from a timeline's turns. First occurrence of an id wins, matching
    /// `mutateItem`, which returns on its first match.
    init(turns: [AssistantTurnSnapshot]) {
        map.reserveCapacity(turns.reduce(0) { $0 + $1.items.count })
        for ti in turns.indices {
            for ii in turns[ti].items.indices {
                let id = turns[ti].items[ii].id
                if map[id] == nil {
                    map[id] = Location(turnIndex: ti, itemIndex: ii)
                }
            }
        }
    }

    /// O(1) location lookup. Returns nil for an unknown id (e.g. an itemDelta that
    /// arrived before its itemStarted), so the caller can buffer the delta instead
    /// of mutating the wrong item.
    func location(of id: String) -> Location? {
        map[id]
    }

    /// Record a newly appended item. First-occurrence-wins is preserved: an id
    /// already present is not overwritten.
    mutating func insert(id: String, turnIndex: Int, itemIndex: Int) {
        if map[id] == nil {
            map[id] = Location(turnIndex: turnIndex, itemIndex: itemIndex)
        }
    }
}

/// F1: the composer's live text on its OWN ObservableObject. A keystroke publishes
/// to this object (observed by the composer subtree) and NOT to AgentAppViewModel —
/// which owns the transcript (messages/timeline) and whose `body` would otherwise
/// re-evaluate the whole transcript on every keypress on a long thread.
@MainActor
public final class AgentComposerState: ObservableObject {
    @Published public var prompt: String = ""
}

/// F1: scopes @ObservedObject observation to the composer subtree. A change to the
/// composer text re-renders only this wrapper (and the `composer` it rebuilds),
/// WITHOUT invalidating the enclosing AgentAppView body that owns the transcript.
/// View-model-driven changes still reach the composer because AgentAppView re-creates
/// this wrapper (with a fresh `content`) whenever the view model publishes.
private struct ComposerReactiveScope<Content: View>: View {
    @ObservedObject var composerState: AgentComposerState
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}

/// Thread mutations performed by the macOS UI itself (create/rename/pin/color/
/// reorder/delete/auto-title). Surfaces must stay free of SocketServer imports,
/// so the VM reports these through a dependency-free callback and the host
/// (AppCommandRouter) publishes the matching mirror events. Without this, only
/// RPC-driven mutations reached connected mirrors and mac-side thread CRUD was
/// invisible on iOS until a full thread-list refetch.
public enum AgentThreadLifecycleEvent {
    case created(AgentThread)
    case updated(AgentThread)
    case reordered(WorkspaceID, [AgentThreadID])
    case deleted([AgentThreadID])
}

public enum AgentErrorRecoveryAction: String, Sendable, Equatable {
    case signIn
    case retry
    case startFresh

    public var title: String {
        switch self {
        case .signIn: return "Sign in"
        case .retry: return "Retry"
        case .startFresh: return "Start fresh"
        }
    }
}

public enum AgentModelPopoverTransition: Equatable {
    case none
    case fadeAndSlide
}

public struct AgentModelPopoverPresentation: Equatable {
    public static let autoDisclaimer = "Remote Code will automatically orchestrate the model to maximize quality while using the fewest tokens."
    public static let autoStatus = "Orchestration active"
    public static let autoAccessibilityLabel = "Automatic model routing"
    public static let autoAccessibilityHint = "Turns automatic model routing on or off."

    public let mode: AgentRoutingMode
    public let reduceMotion: Bool
    public let autoRoutingLoading: Bool

    public init(mode: AgentRoutingMode, reduceMotion: Bool, autoRoutingLoading: Bool = false) {
        self.mode = mode
        self.reduceMotion = reduceMotion
        self.autoRoutingLoading = autoRoutingLoading
    }

    public var showsModelControls: Bool { mode != .auto }
    public var showsReasoningControls: Bool { mode != .auto }
    public var showsServiceTierControls: Bool { mode != .auto }
    public var showsDisclaimer: Bool { mode == .auto }
    public var showsAutoLoadingIndicator: Bool { autoRoutingLoading }
    public var autoToggleEnabled: Bool { !autoRoutingLoading }
    public var transition: AgentModelPopoverTransition {
        reduceMotion ? .none : .fadeAndSlide
    }
    public var accessibilityLabel: String { Self.autoAccessibilityLabel }
    public var accessibilityValue: String { mode == .auto ? "On" : "Off" }
    public var accessibilityHint: String { Self.autoAccessibilityHint }
    public var disclaimer: String { Self.autoDisclaimer }

}

@MainActor
public final class AgentAppViewModel: ObservableObject, AgentRunObserver {
    @Published public var threads: [AgentThread] = []
    @Published public var selectedThreadId: AgentThreadID?
    @Published public var messages: [AgentMessage] = []
    @Published public var timeline = AssistantTimelineState()
    @Published public var timelineUpdateTick: Int = 0
    @Published public var userInputSelections: [String: Set<String>] = [:]
    @Published public var userInputDrafts: [String: String] = [:]
    @Published public var focusTick: Int = 0
    /// P1/F4: number of hidden pre-run transcript items revealed read-only.
    /// Reset to zero on each new run and paged so one tap cannot render a huge history.
    @Published public var transcriptHistoryRevealCount: Int = 0
    /// F1: composer text lives on `composerState` so keystrokes don't republish the
    /// transcript-bearing view model. This proxy keeps every existing `vm.prompt`
    /// read/write working unchanged; because it is a computed (non-@Published)
    /// property, mutating it fires `composerState.objectWillChange`, NOT this VM's.
    public let composerState = AgentComposerState()
    public var prompt: String {
        get { composerState.prompt }
        set { composerState.prompt = newValue }
    }
    // UX-XPLAT-009: UTF-16 cursor offset reported by PromptComposerEditor so
    // suggestions anchor at the actual insertion point, not text.endIndex.
    // nil means "not yet reported by the editor" -- suggestions fall back to
    // the endIndex anchor so programmatic prompt mutations (tests, /clear) work.
    @Published public var composerCursorOffset: Int? = nil
    @Published public var provider: AgentProvider = .codex
    @Published public var providerInstanceId: String = AgentProvider.codex.rawValue
    /// macOS account that will execute the next provider process (`sudo -u`).
    /// Nil / current-account means no privileged trampoline.
    @Published public var runAsUser: AgentRunAsUser? = AgentRunAsUser.current()
    @Published public var availableRunAsUsers: [AgentRunAsUser] = MacOSLocalUserCatalog.listEligibleUsers()
    @Published public var model: String = AgentDefaultModelSelection.codexBuiltInDefault
    /// Last model the user chose per provider (new threads + provider switches).
    /// Inject a suite-backed store in tests; production uses the shared defaults.
    public var lastModelStore: AgentLastModelStore = .shared
    public let newThreadDefaultsStore: AgentNewThreadDefaultsStore?
    /// When true, unlocked snapshot refresh must not auto-rebind away from the
    /// user's explicit Source choice (including an unrunnable row for recovery).
    /// Implicit default selection stays unpinned so missing Codex can rebind.
    public var sourceSelectionUserPinned: Bool = false
    @Published public var availableModels: [AgentModelDescriptor] = []
    @Published public var providerSnapshots: [AgentProviderSnapshot] = []
    @Published public var permissionMode: AgentPermissionMode = .supervised
    @Published public var reasoningEffort: AgentReasoningEffort = .medium
    @Published public var serviceTier: AgentServiceTier = .auto
    @Published public private(set) var routingMode: AgentRoutingMode = .manual
    @Published public var executionMode: AgentExecutionMode = .local
    @Published public var baseBranch: String = ""
    @Published public var worktreePath: String?
    @Published public private(set) var customModelsByProvider: [AgentProvider: [String]] = [:]
    @Published public var status: AgentRunStatus = .pending
    @Published public var statusMessage: String = ""
    private static let deletedThreadDraftRecoveryMessage =
        "Thread removed; your unsent draft was kept in a fresh composer."
    /// Informational replay state is separate from statusMessage so a bounded
    /// history window cannot be presented as a provider/persistence error.
    @Published public private(set) var historyReplayNotice: String?
    public static let historyReplayNoticeText = "Showing the recent Agent history window. Earlier transcript events remain outside the hot replay budget."

    public static func replayNoticeText(isPartial: Bool) -> String? {
        isPartial ? historyReplayNoticeText : nil
    }
    /// CLAUDE-BG-LIFECYCLE: how many CLI-owned background shells / async
    /// subagents the provider last reported as still running, from the
    /// `claude.session.snapshot` runtime event. Mirrors the Claude CLI's own
    /// `1 shell` status-line indicator, which the app previously had no
    /// equivalent of — the pending set never left the adapter. Reset on thread
    /// switch; read through `backgroundShellCount`, which also gates on a live
    /// run so a finished run cannot leave a stale count on screen.
    @Published public private(set) var liveBackgroundShellCount: Int = 0
    /// Thread footer display figure (credible total: measured + dialect + …).
    /// 0 when Token Saver is off, not subscribed, or no savings yet.
    @Published public private(set) var tokenSaverThreadSavedTokens: Int = 0
    /// Ledger-only delivered total for the thread (floor for honesty / copy).
    @Published public private(set) var tokenSaverThreadMeasuredTokens: Int = 0
    /// True when Token Saver is enabled **and** the account is subscribed.
    @Published public private(set) var tokenSaverFooterEnabled: Bool = false
    private weak var tokenSaverSavingsRepo: TokenSaverSavingsRepository?
    private var tokenSaverFooterEligibleCheck: (@Sendable () -> Bool)?
    private var tokenSaverGraphifyActiveCheck: (@Sendable () -> Bool)?
    private var tokenSaverFooterObserver: NSObjectProtocol?
    private var tokenSaverFooterAccountObserver: NSObjectProtocol?
    private var tokenSaverFooterStatusObserver: NSObjectProtocol?
    /// PERF: cancel-and-coalesce off-main ledger reads (same pattern as sidebar
    /// PERF-MAC-100). A burst of `rc2TokenSaverUsageChanged` collapses to one read.
    private var tokenSaverFooterReloadTask: Task<Void, Never>?
    @Published public var currentRunId: AgentRunID?
    @Published public var hasUnreadActivity: Bool = false
    @Published public var showPlanSidebar: Bool = false
    /// Provider-neutral Subagents activity derived from admission receipts +
    /// coordinator active runs. Empty until the first refresh; never invents rows.
    @Published public private(set) var subagentActivity: SubagentActivitySnapshot = .empty
    @Published public var interactionMode: AgentInteractionMode = .default
    @Published public var planNotes: String = ""
    /// C1: git branch + working-tree summary of the agent's dir, for the
    /// composer context strip ("N files changed +A −B").
    @Published public var gitBranch: String?
    @Published public var gitSummary: GitSummary?
    /// Wired by AppCommandRouter — "Review here" opens a Git/Diff surface.
    public var onReviewRequested: (() -> Void)?
    /// A3: fired when a run starts/ends so the tab + workspace chrome can
    /// show/hide a spinner (AppKit tab strip / sidebar don't observe VM).
    public var onRunStateChange: (() -> Void)?
    /// Fired when a run completes so the workspace can move up in its
    /// pinned/unpinned group.
    public var onRunCompleted: (() -> Void)?
    /// Fired when local Agent App controls persist thread run config so
    /// remote mirrors can receive the same thread metadata.
    public var onThreadConfigPersisted: ((AgentThread) -> Void)?
    /// Fired after macOS-UI thread lifecycle mutations are persisted (post
    /// repo write + reloadThreads) so the host can mirror them to remote
    /// clients. Wired by AppCommandRouter like onThreadConfigPersisted.
    public var onThreadLifecycle: ((AgentThreadLifecycleEvent) -> Void)?
    /// Post-commit process-global retirement for automatic cap victims. The
    /// boolean is true only when AgentRunCoordinator's native fork producer
    /// already retired its coordinator state and the host only needs queue state.
    public var retireDeletedThreadRuntime: (([AgentThreadID], Bool) -> Void)?
    /// When non-nil, Stop for LaunchAgent-owned scheduled runs is routed here
    /// (path B). Return true if the request was accepted / already terminal.
    public var stopScheduledThread: ((AgentThreadID, AgentRunID?) async -> Bool)?
    /// True when a thread has an active scheduled occurrence in SQLite even if
    /// this process's coordinator has no session (LaunchAgent owns the run).
    public var isScheduledThreadRunning: ((AgentThreadID) -> Bool)?
    /// Fired when this surface's bound (selected) thread changes, so the host
    /// can persist it into the surface descriptor metadata (`selected_thread`)
    /// for per-surface restore. nil means the surface returned to the
    /// fresh-composer state (e.g. its bound thread was deleted elsewhere).
    /// This is the per-surface binding that fixes the new-tab-clone bug:
    /// selection is owned by the surface, not auto-adopted from the workspace.
    public var onSelectedThreadChanged: ((AgentThreadID?) -> Void)?
    /// Fired only after a macOS TextEditor save is durable, so AppCommandRouter
    /// can publish the same realtime event as the mirror-driven RPC path.
    public var onPlanNotesPersisted: ((AgentThreadID, String) -> Void)?
    /// Canonical host mutation used when local selection acknowledges unread work.
    public var markThreadRead: ((AgentThreadID) throws -> Void)?
    public var onQueuedMessageEvent: ((String, AgentQueuedMessage) -> Void)?
    /// Canonical host queue mutation. Local Force must cross the same acceptance
    /// permit and durable dispatch state machine as RPC/iOS Force.
    public var forceQueuedMessage: ((AgentQueuedMessageID) async throws -> AgentMessageSendResult)?
    /// Host lifecycle gate used while destructive thread deletion awaits provider
    /// termination. AppContext owns queue draining, so the surface requests the
    /// same suppression used by mirror-driven deletion.
    public var acquireQueueDrainSuppression: ((AgentThreadID) async -> UUID)?
    public var acquireQueueDrainSuppressions: (([AgentThreadID]) async -> [(AgentThreadID, UUID)])?
    public var releaseQueueDrainSuppression: ((AgentThreadID, UUID) -> Void)?
    /// UX-MAC_AGENT-OPEN-SPLIT: wired by AppCommandRouter. A clicked file mention
    /// (absolute path, already resolved) opens — or reuses — a Files split panel
    /// to the right of this surface.
    public var onOpenFileInSplit: ((String) -> Void)?
    /// UX-MAC_AGENT-OPEN-SPLIT: wired by AppCommandRouter. A clicked web link
    /// opens — or reuses — a Browser split panel to the right of this surface.
    public var onOpenURLInSplit: ((URL) -> Void)?
    public var providerSnapshotLoader: (() async throws -> [AgentProviderSnapshot])?
    public var modelListLoader: ((AgentProvider) async throws -> [AgentModelDescriptor])?
    public var providerLaunchConfig: ((AgentProvider, String?) -> (binary: String?, environment: [String: String]))?
    public var providerRecoveryAction: ((AgentProvider, String?) async throws -> String)?
    /// Opens the provider's interactive login command in a host-owned Terminal.
    /// The VM never executes provider authentication out of process itself.
    public var providerSignInAction: ((AgentProvider) throws -> Void)?
    /// Forces an uncached auth probe after the user completes the interactive
    /// Terminal flow. A normal snapshot load may still contain a short-lived
    /// provider-probe cache and cannot prove that login just completed.
    public var providerAuthenticationRefresher: ((AgentProvider) async -> [AgentProviderSnapshot])?
    public var pullRequestThreadPreparer: ((String, AgentProvider, String, AgentPermissionMode, AgentReasoningEffort, AgentServiceTier, AgentModelSelection?, String?) async throws -> AgentThread)?
    @Published public var providerRecoveryActionRunning = false
    @Published public var providerRecoveryStatusMessage: String?
    @Published private var dismissedProviderStatusSignature: String?
    @Published public private(set) var providerSnapshotsLoading = false
    @Published public var modelListLoading = false
    @Published public var modelListStatusMessage: String?
    /// True when the current Claude model list is the static built-in fallback
    /// (live discovery failed or was not attempted). The picker uses this to
    /// show a "using built-in defaults" hint and offer a manual refresh.
    @Published public var availableModelsAreFallback: Bool = false
    @Published public var providerSnapshotStatusMessage: String?
    private var pendingSignInProvider: AgentProvider?
    private var pendingSignInSnapshotID: String?
    @Published public private(set) var providerThreadSnapshotStatusMessage: String?
    @Published public private(set) var providerThreadSnapshotLastConfirmedAt: Date?
    @Published public var pullRequestURL: String = ""
    @Published public var pullRequestPreparing = false
    @Published public var pullRequestStatusMessage: String?
    @Published public var checkpoints: [AgentTurnCheckpointSummary] = []
    @Published public var selectedCheckpointTurnCount: Int?
    @Published public var selectedCheckpointPath: String?
    @Published public var checkpointDiffPreview: String = ""
    @Published public var checkpointStatusMessage: String?
    /// B3: durable, managed attachments attached to the next message.
    @Published public var attachments: [AgentAttachment] = []
    private var attachmentInputError: String?
    /// P1: tracks whether the last submitted message included attachments so
    /// retryLastPrompt can warn the user they will not be re-sent.
    @Published public var lastSentAttachmentCount: Int = 0
    public struct AttachmentRetryConfirmation: Equatable {
        public let prompt: String
        public let retryableAttachments: [AgentAttachment]
        public let unavailableAttachmentNames: [String]
    }
    @Published public private(set) var pendingAttachmentRetryConfirmation: AttachmentRetryConfirmation?
    @Published public var queuedMessages: [AgentQueuedMessage] = []
    @Published public var queueStatusMessage: String?
    private var queueStatusByThread: [AgentThreadID: String] = [:]
    @Published public var editingQueuedMessage: AgentQueuedMessage?
    @Published public var queuedMessageDraft: String = ""
    /// When the active run started — drives the "Working for Xs" line.
    @Published public var runStartedAt: Date?
    /// Thread whose turn is being prepared: transcript load, Graphify root
    /// resolution, prompt compression, provider spawn — all before a run id
    /// exists to track. Without this the transcript sits silent for seconds
    /// after the user bubble appears, which read as the app having hung.
    /// Drives the "Loading…" line; `workingStatus` takes over the instant the
    /// run is tracked. Thread-scoped so switching tabs mid-prepare cannot show
    /// a sibling thread as loading.
    @Published public private(set) var preparingRunThreadId: AgentThreadID?
    /// UX-MAC_AGENT-009: true while the last surfaced error is recoverable, so
    /// the transcript can offer a Retry of the last prompt instead of forcing a
    /// retype. Cleared when a run starts or any non-error event arrives.
    @Published public private(set) var lastErrorRecoverable: Bool = false
    /// P2: search/filter query for the thread rail. Empty = show all threads.
    @Published public var threadSearchQuery: String = ""
    /// UX-MAC_AGENT-STOP: true between the user clicking Stop and the run
    /// actually reaching a terminal state. Prevents repeated Stop clicks and
    /// shows a "Stopping..." label so the user knows the interrupt was sent.
    @Published public var isStopping: Bool = false
    /// UX-MAC_AGENT-CONTINUE: true when the selected thread was interrupted by
    /// an app relaunch and has a recoverable provider session. Drives the inline
    /// Continue action. Cleared when a run starts or the selected thread changes.
    @Published public private(set) var selectedThreadHasRecoverableContext: Bool = false
    /// UX-SR1-BADGE: ids of assistant messages that were SR1-translated.
    /// Populated live by the coordinator callback and rebuilt from persisted stream
    /// events on thread open so the badge survives restarts.
    @Published public private(set) var sr1TranslatedMessageIds: Set<AgentMessageID> = []
    @Published public private(set) var sr1OriginalTextsByMessageId: [AgentMessageID: String] = [:]
    /// The UI holds only a bounded recent message page. Older durable messages
    /// remain in SQLite and are intentionally outside the hot screen-memory set.
    @Published public private(set) var messageHistoryIsPartial = false
    /// True while an older-page keyset load is in flight (UI disable / spinner).
    /// Derived from `loadingOlderGeneration != 0` for ownership-safe clears.
    @Published public private(set) var isLoadingOlderMessages = false
    /// Monotonic owner token for the active older-page load (0 = idle).
    /// Stale Tasks must not clear a newer load's flag (SSHRemoteView pattern).
    private var loadingOlderGeneration: UInt64 = 0
    /// After the user sends a follow-up (including a queued one), ignore
    /// `activePlanUpdated` events from the prior turn so the stale checklist
    /// cannot reappear under the new user bubble. Cleared when the next run
    /// actually starts and may publish a fresh plan.
    private var suppressStaleActivePlanUpdates = false

    public let workspaceID: WorkspaceID
    public let cwd: String
    public let coordinator: AgentRunCoordinator
    public let threadRepo: AgentThreadRepository
    public let messageRepo: AgentMessageRepository
    public let draftRepo: AgentThreadDraftRepository?
    public let attachmentStore: AgentAttachmentStore?
    public let queuedMessageRepo: AgentQueuedMessageRepository?
    public let providerSessionRepo: ProviderSessionRuntimeRepository?
    public let pendingCallbackRepo: ProviderPendingCallbackRepository?
    public let proposedPlanRepo: AgentProposedPlanRepository?
    public let checkpointRepo: AgentTurnCheckpointRepository?
    public let promptHistoryStore: PromptHistoryStore?
    public let customModelStore: AgentCustomModelStore?
    public let planNotesStore: PlanNotesStore?
    private let orchestrationRuntime: AgentOrchestrationRuntime
    private var promptHistory: [String] = []
    private var promptHistoryCursor: Int?
    private var terminalRunIds = Set<AgentRunID>()
    private var timelineUpdateTickTask: Task<Void, Never>?
    // UX-XPLAT-DELETE-UNDO: drops the transient delete snapshot when the undo
    // window lapses. Cancelled on a new delete, on undo, or on teardown.
    private var threadDeletionUndoExpiryTask: Task<Void, Never>?
    // UX-XPLAT-REVERT-UNDO: drops the transient checkpoint-revert undo toast when
    // the undo window lapses. Cancelled on a new revert, on undo, or on teardown.
    private var checkpointRevertUndoExpiryTask: Task<Void, Never>?
    private var messageHistoryLoadTask: Task<Void, Never>?
    /// PERF: tracks thread ids whose placeholder titles have already been repaired
    /// so reloadThreads never issues a full messageRepo.list for the same thread twice.
    private var repairedThreadIds: Set<AgentThreadID> = []
    /// Programmatic loads and mirror updates also trigger SwiftUI's onChange.
    /// Consume the matching callback once so they never echo as a second save.
    private var ignoredPlanNotesSave: (threadId: AgentThreadID, notes: String)?

    // Monotonic ticket for user callback actions (approval responses, user-input
    // answers). respondToPendingRequest resolves async; this seq lets its failure
    // path detect a newer callback action and avoid clobbering the more-recent
    // visible error, restoring the pre-async most-recent-action-wins ordering.
    private var callbackActionSeq: UInt64 = 0

    // PERF-MAC_AGENT-009: cache thread->workspace membership so didChangeStatus
    // does not issue a DB read per status event of every thread. Populated on
    // every reloadThreads() call; threads from other workspaces arrive via the
    // coordinator's multi-workspace broadcast but are filtered out cheaply here.
    private var threadWorkspaceCache: [AgentThreadID: WorkspaceID] = [:]

    #if DEBUG
    /// Test seam for the partial-failure boundary after cap enforcement.
    private var reloadThreadListForTesting: (() throws -> [AgentThread])?
    #endif

    // PERF-MAC_AGENT-010: batch streaming events into one main-actor hop per
    // tick. Fast token streams produce thousands of events/sec; without batching
    // every event allocates an independent Task, each of which pays the Swift
    // concurrency scheduler overhead. Accumulate events here (protected by a
    // lock for nonisolated callers) and drain the whole buffer in one hop when
    // the first event of each tick schedules the flush Task.
    private let streamEventBatch = StreamEventBatch()
    /// True when the hot UI event queue refused at least one already-durable
    /// stream event. Cleared after a durable replay rebuilds the live timeline.
    private var streamUIBackpressured = false

    // QA-MAC_AGENT-CLOCK: injectable clock so "Working for Xs" elapsed math
    // and adaptive-sidebar debounce timestamps are deterministically testable.
    // Default is real wall time; tests inject a fixed/advancing fake clock via
    // setClockForTests(_:). @MainActor isolation serialises all reads/writes.
    private var clock: @Sendable () -> Date = { Date() }

    /// Returns the current instant from the injected clock.
    /// Used by the view for elapsed-time and debounce calculations so tests
    /// can control "now" without racing against wall time.
    public func currentTime() -> Date { clock() }

    /// QA-MAC_AGENT-CLOCK: inject a fixed or advancing clock so time-dependent
    /// view logic is deterministic. Must not be called in production code.
    public func setClockForTests(_ clock: @escaping @Sendable () -> Date) {
        self.clock = clock
    }

    public func sr1OriginalText(for id: AgentMessageID) -> String? {
        sr1OriginalTextsByMessageId[id]
    }

    public init(
        workspaceID: WorkspaceID,
        cwd: String,
        coordinator: AgentRunCoordinator,
        threadRepo: AgentThreadRepository,
        messageRepo: AgentMessageRepository,
        draftRepo: AgentThreadDraftRepository? = nil,
        attachmentStore: AgentAttachmentStore? = nil,
        queuedMessageRepo: AgentQueuedMessageRepository? = nil,
        providerSessionRepo: ProviderSessionRuntimeRepository? = nil,
        pendingCallbackRepo: ProviderPendingCallbackRepository? = nil,
        proposedPlanRepo: AgentProposedPlanRepository? = nil,
        checkpointRepo: AgentTurnCheckpointRepository? = nil,
        promptHistoryStore: PromptHistoryStore? = nil,
        customModelStore: AgentCustomModelStore? = nil,
        planNotesStore: PlanNotesStore? = nil,
        initialThreadId: AgentThreadID? = nil,
        lastModelStore: AgentLastModelStore = .shared,
        initialRoutingMode: AgentRoutingMode = .manual,
        newThreadDefaultsStore: AgentNewThreadDefaultsStore? = nil,
        orchestrationRuntime: AgentOrchestrationRuntime = AgentOrchestrationRuntime()
    ) {
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.coordinator = coordinator
        self.threadRepo = threadRepo
        self.messageRepo = messageRepo
        self.draftRepo = draftRepo
        self.attachmentStore = attachmentStore
        self.queuedMessageRepo = queuedMessageRepo
        self.providerSessionRepo = providerSessionRepo
        self.pendingCallbackRepo = pendingCallbackRepo
        self.proposedPlanRepo = proposedPlanRepo
        self.checkpointRepo = checkpointRepo
        self.promptHistoryStore = promptHistoryStore
        self.customModelStore = customModelStore
        self.planNotesStore = planNotesStore
        self.lastModelStore = lastModelStore
        self.routingMode = initialRoutingMode
        self.newThreadDefaultsStore = newThreadDefaultsStore
        self.orchestrationRuntime = orchestrationRuntime
        self.promptHistory = promptHistoryStore?.load(workspaceID: workspaceID) ?? []
        self.promptHistoryStore?.onWriteError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.statusMessage = Self.promptHistoryWriteErrorMessage(error)
            }
        }
        reloadCustomModels()
        self.coordinator.addObserver(self)
        self.coordinator.onSR1TranslatedMessageId = { [weak self] msgId in
            Task { @MainActor [weak self] in
                self?.sr1TranslatedMessageIds.insert(msgId)
            }
        }
        // XCTest: same-stack rail load so selectThread(initial) sees rows.
        // Production: first cap+list off MainActor so opening a tab does not hitch.
        let pendingInitialThreadId = initialThreadId
        if Self.isRunningUnitTests {
            reloadThreadsImmediate()
            applyNewThreadDefaultsFromRailIfNeeded()
            if let pendingInitialThreadId, threads.contains(where: { $0.id == pendingInitialThreadId }) {
                selectThread(pendingInitialThreadId)
            } else {
                publishInterestedThreadId(selectedThreadId)
            }
        } else {
            publishInterestedThreadId(nil)
            Task { @MainActor [weak self] in
                guard let self, !self.isDisposed else { return }
                let snapshot = await self.loadRailSnapshotOffMainActor()
                self.applyRailSnapshot(snapshot)
                self.applyNewThreadDefaultsFromRailIfNeeded()
                if let pendingInitialThreadId,
                   self.threads.contains(where: { $0.id == pendingInitialThreadId }) {
                    self.selectThread(pendingInitialThreadId)
                } else {
                    self.publishInterestedThreadId(self.selectedThreadId)
                }
            }
        }
        loadGitBranch()
        AgentWorkspaceRailReloadCoordinator.shared.register(self)
    }

    private func applyNewThreadDefaultsFromRailIfNeeded() {
        guard let newThreadDefaultsStore else { return }
        if let saved = newThreadDefaultsStore.load() {
            restoreNewThreadDefaults(saved)
        } else if let latest = threads.max(by: { $0.updatedAt < $1.updatedAt }) {
            let routing = latest.effectiveRoutingConfiguration
            restoreNewThreadDefaults(AgentNewThreadDefaults(
                routingMode: routing.mode,
                runAsUser: latest.runAsUser,
                provider: routing.manualSelection.provider,
                providerInstanceId: routing.manualProviderInstanceId ?? routing.manualSelection.provider.rawValue,
                model: routing.manualSelection.effectiveModel,
                reasoningEffort: routing.manualSelection.reasoningEffort
            ))
            rememberNewThreadDefaults()
        }
    }

    public func reloadCustomModels() {
        guard let customModelStore else { return }
        var next: [AgentProvider: [String]] = [:]
        for provider in AgentProvider.allCases {
            next[provider] = customModelStore.list(provider: provider)
        }
        customModelsByProvider = next
    }

    public func loadGitBranch() {
        let cwd = self.cwd
        DispatchQueue.global().async { [weak self] in
            let b = GitDiff.branches(in: cwd).current
            let s = GitDiff.summary(in: cwd)
            DispatchQueue.main.async {
                self?.gitBranch = b
                self?.gitSummary = s.isGitRepo ? s : nil
            }
        }
    }

    // PERF-MAC_AGENT-008: per-finish git refresh shelled out a subprocess every
    // completion; when several threads finish together this multiplied. Coalesce
    // bursts into a single refresh after a short trailing delay.
    private var pendingGitRefresh: Task<Void, Never>?
    private var providerSnapshotLoadCount = 0
    /// When the last successful `loadProviderSnapshots` finished. Used with
    /// `ModelListTTLDecision` so send/auto-admit reuses a fresh catalog instead
    /// of re-probing on every keystroke-to-send.
    private var providerSnapshotsLoadedAt: Date?

    public func loadGitBranchThrottled() {
        guard pendingGitRefresh == nil else { return }
        pendingGitRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.pendingGitRefresh = nil
            self.loadGitBranch()
        }
    }

    /// Maps an in-flight run back to its thread so a completion can mark
    /// the right thread unread even after the user navigated away (B6).
    private var runThreads: [AgentRunID: AgentThreadID] = [:]

    /// Cross-thread mirror of `selectedThreadId` so nonisolated stream delivery
    /// can drop events for other surfaces without a MainActor hop. Updated on
    /// every select/clear and on dispose. Lives in a lock-backed box so it is
    /// not MainActor-isolated like the rest of the view-model.
    private let interestedThread = InterestedThreadBox()

    /// Coalesces reloadThreads fan-out when many Agent App tabs share a workspace
    /// and each receives the same coordinator status/finish broadcast.
    private var pendingThreadReloadTask: Task<Void, Never>?

    /// Set by `dispose()` when the hosting surface closes so late coordinator
    /// callbacks become no-ops even if a weak observer slot is briefly live.
    private var isDisposed = false

    private func publishInterestedThreadId(_ id: AgentThreadID?) {
        interestedThread.set(id)
    }

    nonisolated private func currentInterestedThreadId() -> AgentThreadID? {
        interestedThread.get()
    }

    /// Debounced thread-list refresh. Many open Agent Apps in one workspace each
    /// observe every run status change; without coalescing, N tabs each hit the
    /// DB on the main actor for the same event and the UI freezes under load.
    func scheduleReloadThreads(delayMilliseconds: UInt64 = 50) {
        guard !isDisposed else { return }
        guard pendingThreadReloadTask == nil else { return }
        pendingThreadReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard let self, !Task.isCancelled, !self.isDisposed else { return }
            self.pendingThreadReloadTask = nil
            self.reloadThreads()
        }
    }

    /// Release coordinator observation and cancel in-flight UI work when the
    /// tab closes. Without this, multi-tab sessions keep routing stream batches
    /// onto closed VMs until ARC collects the weak observer.
    public func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        AgentWorkspaceRailReloadCoordinator.shared.unregister(self)
        stopScheduledLivePoll()
        pendingGitRefresh?.cancel()
        pendingGitRefresh = nil
        pendingThreadReloadTask?.cancel()
        pendingThreadReloadTask = nil
        timelineUpdateTickTask?.cancel()
        timelineUpdateTickTask = nil
        threadDeletionUndoExpiryTask?.cancel()
        threadDeletionUndoExpiryTask = nil
        checkpointRevertUndoExpiryTask?.cancel()
        checkpointRevertUndoExpiryTask = nil
        messageHistoryLoadTask?.cancel()
        messageHistoryLoadTask = nil
        cancelOlderMessageLoad()
        if let tokenSaverFooterObserver {
            NotificationCenter.default.removeObserver(tokenSaverFooterObserver)
            self.tokenSaverFooterObserver = nil
        }
        if let tokenSaverFooterAccountObserver {
            NotificationCenter.default.removeObserver(tokenSaverFooterAccountObserver)
            self.tokenSaverFooterAccountObserver = nil
        }
        if let tokenSaverFooterStatusObserver {
            NotificationCenter.default.removeObserver(tokenSaverFooterStatusObserver)
            self.tokenSaverFooterStatusObserver = nil
        }
        tokenSaverFooterReloadTask?.cancel()
        tokenSaverFooterReloadTask = nil
        tokenSaverSavingsRepo = nil
        tokenSaverFooterEligibleCheck = nil
        tokenSaverGraphifyActiveCheck = nil
        _ = streamEventBatch.drain()
        streamUIBackpressured = false
        publishInterestedThreadId(nil)
        coordinator.removeObserver(self)
        // Drop the heavy transcript payload so closed tabs free memory promptly.
        messages = []
        messageHistoryIsPartial = false
        timeline = AssistantTimelineState()
        sr1TranslatedMessageIds = []
        sr1OriginalTextsByMessageId = [:]
    }

    /// Used by the multi-surface rail reload hub (EventBus fan-out).
    var isDisposedForReloadCoordination: Bool { isDisposed }

    /// Cap + list off MainActor so multi-tab EventBus storms do not block UI.
    func loadRailSnapshotOffMainActor() async -> AgentWorkspaceRailReloadCoordinator.RailSnapshot {
        let repo = threadRepo
        let coordinator = coordinator
        let workspaceID = workspaceID
        #if DEBUG
        let listOverride = reloadThreadListForTesting
        #endif
        return await Task.detached(priority: .userInitiated) {
            _ = coordinator.reconcileStaleActiveOwnershipWithDurableState()
            do {
                let pruned = try repo.enforceWorkspaceThreadLimit(workspaceId: workspaceID)
                let listed: [AgentThread]
                #if DEBUG
                if let listOverride {
                    listed = try listOverride()
                } else {
                    listed = try repo.list(workspaceId: workspaceID)
                }
                #else
                listed = try repo.list(workspaceId: workspaceID)
                #endif
                return AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                    workspaceID: workspaceID,
                    threads: listed,
                    prunedThreadIDs: pruned
                )
            } catch {
                return AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                    workspaceID: workspaceID,
                    threads: [],
                    prunedThreadIDs: [],
                    errorDescription: String(describing: error)
                )
            }
        }.value
    }

    /// Applies a coalesced rail snapshot produced once per workspace debounce window.
    func applyRailSnapshot(_ snapshot: AgentWorkspaceRailReloadCoordinator.RailSnapshot) {
        guard !isDisposed, snapshot.workspaceID == workspaceID else { return }
        if let errorDescription = snapshot.errorDescription {
            let reloadFailure = "Could not reload threads: \(errorDescription)"
            if statusMessage.contains(Self.deletedThreadDraftRecoveryMessage) {
                statusMessage = "\(Self.deletedThreadDraftRecoveryMessage) \(reloadFailure)"
            } else {
                statusMessage = reloadFailure
            }
            return
        }
        let knownLocalThreadIDs = Set(threads.map(\.id)).union(
            threadWorkspaceCache.compactMap { id, workspace in
                workspace == workspaceID ? id : nil
            }
        )
        retireCommittedThreadPrunes(snapshot.prunedThreadIDs)
        applyAuthoritativeThreadDeletions(Set(snapshot.prunedThreadIDs))
        if !snapshot.prunedThreadIDs.isEmpty {
            onThreadLifecycle?(.deleted(snapshot.prunedThreadIDs))
        }
        let missingKnownThreadIDs = knownLocalThreadIDs.subtracting(snapshot.threads.map(\.id))
        evictThreadCaches(missingKnownThreadIDs)
        threads = snapshot.threads
        recoverDeletedSelectionIfNeeded(missingKnownThreadIDs)
        pruneStaleRunThreadProjections()
        if isStopping,
           let selectedThreadId,
           trackedRunId(for: selectedThreadId) == nil,
           isScheduledThreadRunning?(selectedThreadId) != true {
            isStopping = false
        }
        for t in threads {
            if let wid = t.workspaceId {
                threadWorkspaceCache[t.id] = wid
            }
        }
        repairPlaceholderThreadTitles()
        if let sel = selectedThreadId, !threads.contains(where: { $0.id == sel }) {
            recoverDeletedSelectionIfNeeded([sel])
        }
        refreshSubagentActivity()
    }

    /// Unit tests need a same-stack rail snapshot; production must never block
    /// MainActor on cap+list against a multi-GB SQLite file.
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    public func reloadThreads() {
        guard !isDisposed else { return }
        if Self.isRunningUnitTests {
            reloadThreadsImmediate()
            return
        }
        // Production: always leave MainActor for cap+list via the workspace hub.
        AgentWorkspaceRailReloadCoordinator.shared.requestCoalescedReload(workspaceID: workspaceID)
    }

    /// Immediate rail reload (init + XCTest). Cap+list stay on the caller thread.
    private func reloadThreadsImmediate() {
        _ = coordinator.reconcileStaleActiveOwnershipWithDurableState()
        let knownLocalThreadIDs = Set(threads.map(\.id)).union(
            threadWorkspaceCache.compactMap { id, workspace in
                workspace == workspaceID ? id : nil
            }
        )
        do {
            let prunedThreadIDs = try threadRepo.enforceWorkspaceThreadLimit(workspaceId: workspaceID)
            let reloadedThreads: [AgentThread]
            #if DEBUG
            if let reloadThreadListForTesting {
                reloadedThreads = try reloadThreadListForTesting()
            } else {
                reloadedThreads = try threadRepo.list(workspaceId: workspaceID)
            }
            #else
            reloadedThreads = try threadRepo.list(workspaceId: workspaceID)
            #endif
            // Preserve pre-reload known set for eviction of missing IDs.
            let snapshot = AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                workspaceID: workspaceID,
                threads: reloadedThreads,
                prunedThreadIDs: prunedThreadIDs
            )
            // Temporarily re-seed known locals for apply by setting threads first
            // is unnecessary; applyRailSnapshot computes missing from current
            // threads, so inject known set via the existing path:
            applyRailSnapshotPreservingKnownLocals(snapshot, knownLocalThreadIDs: knownLocalThreadIDs)
        } catch {
            applyRailSnapshot(
                AgentWorkspaceRailReloadCoordinator.RailSnapshot(
                    workspaceID: workspaceID,
                    threads: [],
                    prunedThreadIDs: [],
                    errorDescription: String(describing: error)
                )
            )
        }
    }

    private func applyRailSnapshotPreservingKnownLocals(
        _ snapshot: AgentWorkspaceRailReloadCoordinator.RailSnapshot,
        knownLocalThreadIDs: Set<AgentThreadID>
    ) {
        guard !isDisposed, snapshot.workspaceID == workspaceID else { return }
        if let errorDescription = snapshot.errorDescription {
            let reloadFailure = "Could not reload threads: \(errorDescription)"
            if statusMessage.contains(Self.deletedThreadDraftRecoveryMessage) {
                statusMessage = "\(Self.deletedThreadDraftRecoveryMessage) \(reloadFailure)"
            } else {
                statusMessage = reloadFailure
            }
            return
        }
        retireCommittedThreadPrunes(snapshot.prunedThreadIDs)
        applyAuthoritativeThreadDeletions(Set(snapshot.prunedThreadIDs))
        if !snapshot.prunedThreadIDs.isEmpty {
            onThreadLifecycle?(.deleted(snapshot.prunedThreadIDs))
        }
        let missingKnownThreadIDs = knownLocalThreadIDs.subtracting(snapshot.threads.map(\.id))
        evictThreadCaches(missingKnownThreadIDs)
        threads = snapshot.threads
        recoverDeletedSelectionIfNeeded(missingKnownThreadIDs)
        pruneStaleRunThreadProjections()
        if isStopping,
           let selectedThreadId,
           trackedRunId(for: selectedThreadId) == nil,
           isScheduledThreadRunning?(selectedThreadId) != true {
            isStopping = false
        }
        for t in threads {
            if let wid = t.workspaceId {
                threadWorkspaceCache[t.id] = wid
            }
        }
        repairPlaceholderThreadTitles()
        if let sel = selectedThreadId, !threads.contains(where: { $0.id == sel }) {
            recoverDeletedSelectionIfNeeded([sel])
        }
        refreshSubagentActivity()
    }

    /// Rebuild Subagents snapshot from persisted admission receipts and the
    /// coordinator's current active-run set. Fail open to empty on read errors.
    ///
    /// Scoped to the selected thread plus parent-chain descendants (middleware
    /// nested Agent App workers). Sibling threads without a parent link are
    /// excluded so the badge never aggregates the whole workspace.
    public func refreshSubagentActivity() {
        guard !isDisposed else { return }
        guard let selectedThreadId else {
            if subagentActivity != .empty {
                subagentActivity = .empty
            }
            return
        }
        // Thread-scoped fetch (selected rows + bounded nested-worker window) so
        // the 2s MainActor poll does not JSON-decode the global 10k ledger.
        let receipts = (try? orchestrationRuntime.activityReceipts(
            threadIds: [selectedThreadId],
            limit: SubagentActivityProjection.defaultReceiptFetchLimit
        )) ?? []
        // Nested middleware children execute on their own thread ids; include
        // every live coordinator run so unknown lifecycle can still refine to
        // Working for descendants that appear via parent-chain attribution.
        let activeRunIds = Set(
            coordinator.activeThreadIdsSnapshot().compactMap { threadId in
                coordinator.activeRunId(threadId: threadId)
            }
        )
        subagentActivity = SubagentActivityProjection.project(
            receipts: receipts,
            threadIds: [selectedThreadId],
            activeRunIds: activeRunIds,
            now: clock()
        )
    }

    /// Drop surface `runThreads` entries that no longer match a live coordinator
    /// or durable active run for the same runId. Generation-safe: never clears
    /// by threadId alone (a newer run B on the same thread stays mapped).
    ///
    /// WHY: the rail spinner is driven by `trackedRunId` → `runThreads`, which
    /// can survive a missed workspace-filtered didFinish and leave "Threads · N
    /// active" after the work is done.
    private func pruneStaleRunThreadProjections() {
        let snapshot = runThreads
        guard !snapshot.isEmpty else { return }
        var clearedSelected = false
        for (runId, threadId) in snapshot {
            if coordinator.activeRunId(threadId: threadId) == runId {
                continue
            }
            if let durable = try? coordinator.durableActiveRun(threadId: threadId),
               durable.id == runId {
                continue
            }
            if isScheduledThreadRunning?(threadId) == true,
               let durable = try? coordinator.durableActiveRun(threadId: threadId),
               durable.id == runId {
                continue
            }
            runThreads[runId] = nil
            if currentRunId == runId {
                currentRunId = nil
                if selectedThreadId == threadId {
                    clearedSelected = true
                }
            }
        }
        if clearedSelected, let sel = selectedThreadId, !isThreadStartingOrRunning(sel) {
            runStartedAt = nil
            if let durableStatus = threads.first(where: { $0.id == sel })?.status {
                status = durableStatus
            }
            isStopping = false
        }
    }

    /// Pure helper: indices of threads that still need a placeholder-title repair.
    /// A thread is excluded when its id is in `alreadyRepaired` (already fixed this
    /// session) or when its title is not a placeholder (no repair needed).
    /// `nonisolated static` so it is testable without a MainActor context.
    nonisolated static func indicesNeedingRepair(
        in threads: [AgentThread],
        alreadyRepaired: Set<AgentThreadID>
    ) -> [Int] {
        threads.indices.filter { i in
            !alreadyRepaired.contains(threads[i].id) &&
            AgentThreadTitle.isPlaceholder(threads[i].title)
        }
    }

    private func repairPlaceholderThreadTitles() {
        let toRepair = Self.indicesNeedingRepair(in: threads, alreadyRepaired: repairedThreadIds)
        for index in toRepair {
            // Mark as visited regardless of whether a user message exists — a thread
            // with no user messages won't get a better title on the next call either.
            // F13: fetch only the earliest user message (LIMIT 1) instead of loading
            // the whole thread history + content blobs on the main actor per thread.
            let firstUserMessage: AgentMessage
            do {
                guard let message = try messageRepo.firstUserMessage(threadId: threads[index].id) else {
                    repairedThreadIds.insert(threads[index].id)
                    continue
                }
                firstUserMessage = message
            } catch {
                statusMessage = "Could not repair thread title: \(error)"
                continue
            }
            var thread = threads[index]
            thread.title = AgentThreadTitle.titleFromFirstMessage(firstUserMessage.content)
            // PERSISTENCE-DATA-002: a cosmetic title repair must NOT bump
            // updatedAt — doing so reorders the rail (updated_at is the visible
            // tiebreak) and made repaired threads jump to the top. Preserve the
            // thread's real activity time so only genuine activity reorders it.
            do {
                try threadRepo.upsert(thread)
            } catch {
                statusMessage = "Could not repair thread title: \(error)"
                continue
            }
            repairedThreadIds.insert(thread.id)
            threads[index] = thread
            // Mirror the repaired title so remote thread lists don't keep
            // showing the placeholder. Loop-safe: repairedThreadIds plus the
            // now-non-placeholder title prevent re-entry on the reloadThreads
            // the host's event subscription triggers.
            onThreadLifecycle?(.updated(thread))
        }
    }

    /// IMP-MAC_AGENT-011: unsent composer state, keyed by thread and persisted
    /// so text, attachments, and interaction mode survive switching/relaunch.
    private var composerDraftsByThread: [AgentThreadID: [String: AgentThreadDraft]] = [:]
    private var providerThreadSnapshotConfirmedAtByThread: [AgentThreadID: Date] = [:]

    private func persistComposerDraft(for threadId: AgentThreadID) {
        let draft = AgentThreadDraft(
            threadId: threadId,
            providerInstanceId: providerInstanceId,
            text: prompt,
            attachments: attachments,
            interactionMode: interactionMode
        )
        composerDraftsByThread[threadId, default: [:]][providerInstanceId] = draft
        do {
            try draftRepo?.upsert(draft)
        } catch {
            statusMessage = "Draft save failed: \(error)"
        }
    }

    private func restoreComposerDraft(for thread: AgentThread) {
        restoreComposerDraft(
            threadId: thread.id,
            providerInstanceId: providerInstanceId,
            fallbackInteractionMode: thread.effectiveInteractionMode
        )
    }

    private func restoreComposerDraft(
        threadId: AgentThreadID,
        providerInstanceId: String,
        fallbackInteractionMode: AgentInteractionMode
    ) {
        let durable = try? draftRepo?.get(threadId: threadId, providerInstanceId: providerInstanceId)
        let draft = composerDraftsByThread[threadId]?[providerInstanceId] ?? durable ?? nil
        prompt = draft?.text ?? ""
        attachments = draft?.attachments ?? []
        interactionMode = draft?.interactionMode ?? fallbackInteractionMode
        if let draft { composerDraftsByThread[threadId, default: [:]][providerInstanceId] = draft }
    }

    private func clearComposerDraft(threadId: AgentThreadID, providerInstanceId: String) throws {
        try draftRepo?.delete(threadId: threadId, providerInstanceId: providerInstanceId)
        clearComposerDraftMemory(threadId: threadId, providerInstanceId: providerInstanceId)
    }

    private func clearComposerDraftMemory(threadId: AgentThreadID, providerInstanceId: String) {
        composerDraftsByThread[threadId]?.removeValue(forKey: providerInstanceId)
        if composerDraftsByThread[threadId]?.isEmpty == true {
            composerDraftsByThread.removeValue(forKey: threadId)
        }
    }

    /// PERF: O(1) id -> (turn,item) index over `timeline.turns`, rebuilt once after a
    /// thread's replay. Lets post-replay item-location lookups avoid the O(turns x items)
    /// scan that AssistantTimelineState.mutateItem performs. Behavior-preserving: it is a
    /// derived view of `timeline.turns`, never a source of timeline content.
    private(set) var timelineItemIndex = TimelineItemIndex(turns: [])

    /// O(1) location of a timeline item by id, equivalent to a linear scan of
    /// `timeline.turns`. Returns nil when the id is not present.
    func timelineItemLocation(_ id: String) -> TimelineItemIndex.Location? {
        timelineItemIndex.location(of: id)
    }

    /// Wire Token Saver thread-savings footer. Host calls after init with the
    /// shared ledger + eligibility (enabled && subscribed) + graphify gate.
    /// Safe to call once per surface.
    ///
    /// `isEligible` / `isGraphifyActive` are invoked **off the main actor** inside
    /// the coalesced reload task — implementors must be thread-safe (fresh
    /// SettingsStore per call is fine; avoid MainActor-only UI state).
    public func bindTokenSaverThreadFooter(
        savingsRepo: TokenSaverSavingsRepository,
        isEligible: @escaping @Sendable () -> Bool,
        isGraphifyActive: @escaping @Sendable () -> Bool = { false }
    ) {
        tokenSaverSavingsRepo = savingsRepo
        tokenSaverFooterEligibleCheck = isEligible
        tokenSaverGraphifyActiveCheck = isGraphifyActive
        if tokenSaverFooterObserver == nil {
            let handler: (Notification) -> Void = { [weak self] _ in
                self?.reloadTokenSaverThreadSavings()
            }
            // Savings ledger changes.
            tokenSaverFooterObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("rc2TokenSaverUsageChanged"),
                object: nil,
                queue: .main,
                using: handler
            )
            // B-6 residual: toggle / account change must hide the chip immediately,
            // not wait for the next turn or thread switch.
            tokenSaverFooterAccountObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("rc2PrivateAccountChanged"),
                object: nil,
                queue: .main,
                using: handler
            )
            tokenSaverFooterStatusObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("rc2TokenSaverDistillStatusChanged"),
                object: nil,
                queue: .main,
                using: handler
            )
        }
        reloadTokenSaverThreadSavings()
    }

    /// Schedule a coalesced reload: eligibility + ledger + estimate all off-main.
    public func reloadTokenSaverThreadSavings() {
        guard !isDisposed else { return }
        tokenSaverFooterReloadTask?.cancel()
        let eligibleCheck = tokenSaverFooterEligibleCheck
        let graphifyCheck = tokenSaverGraphifyActiveCheck
        let threadId = selectedThreadId
        let repo = tokenSaverSavingsRepo
        // Capture assistant size + turn/usage on MainActor (UI/timeline state).
        let assistantChars = messages
            .filter { $0.role == .assistant }
            .reduce(0) { $0 + $1.content.utf8.count }
        let turnCount = max(timeline.turns.count, messages.filter { $0.role == .user }.count)
        let usage = timeline.tokenUsage
        let cacheRead = usage?.cacheReadInputTokens ?? 0
        let providerRaw = usage.map { max(0, $0.inputTokens) + max(0, $0.outputTokens) } ?? 0
        let providerBilled = usage.map { $0.billedTotalTokenUnits } ?? 0
        let autoRouting = routingMode == .auto
        tokenSaverFooterReloadTask = Task { [weak self] in
            // Eligibility/settings reads off-main so a savings burst does not
            // stack cold SettingsStore performSync on the MainActor.
            let eligible = eligibleCheck?() == true
            let graphifyActive = graphifyCheck?() == true
            let measured: Int
            if eligible, let threadId, let repo {
                let id = threadId.value.uuidString
                measured = await Task.detached(priority: .utility) {
                    (try? repo.savedTokens(forThreadID: id)) ?? 0
                }.value
            } else {
                measured = 0
            }
            guard !Task.isCancelled else { return }
            let display = AgentAppView.tokenSaverThreadFooterDisplayTokens(
                measuredDelivered: measured,
                assistantChars: assistantChars,
                tokenSaverEnabled: eligible,
                graphifyActive: graphifyActive,
                turnCount: turnCount,
                cacheReadInputTokens: cacheRead,
                providerRawTokens: providerRaw,
                providerBilledTokenUnits: providerBilled > 0 ? providerBilled : nil,
                autoRoutingActive: autoRouting
            )
            await MainActor.run { [weak self] in
                guard let self, !self.isDisposed, !Task.isCancelled else { return }
                self.tokenSaverFooterEnabled = eligible
                self.tokenSaverThreadMeasuredTokens = measured
                self.tokenSaverThreadSavedTokens = display
            }
        }
    }

    public func selectThread(_ id: AgentThreadID, markRead: Bool = true) {
        guard !isDisposed else { return }
        let selectedThread: AgentThread
        do {
            guard let persistedThread = try threadRepo.get(id: id) else {
                if statusMessage.isEmpty {
                    statusMessage = "Could not open thread: The thread is no longer available."
                }
                return
            }
            selectedThread = persistedThread
        } catch {
            statusMessage = "Could not open thread: \(error)"
            return
        }
        guard let selectedWorkspaceID = selectedThread.workspaceId,
              selectedWorkspaceID == workspaceID else {
            if statusMessage.isEmpty {
                statusMessage = "Could not open thread: The thread belongs to another workspace."
            }
            return
        }
        threadWorkspaceCache[id] = selectedWorkspaceID
        if statusMessage.contains(Self.deletedThreadDraftRecoveryMessage) {
            statusMessage = ""
        }
        historyReplayNotice = nil
        let isThreadSwitch = selectedThreadId != id
        if isThreadSwitch {
            // IMP-MAC_AGENT-011: stash the leaving thread's draft before swapping,
            // then restore the opened thread's draft (an in-progress prompt on a
            // re-select of the same thread is left untouched).
            if let previous = selectedThreadId { persistComposerDraft(for: previous) }
            selectedThreadId = id
            publishInterestedThreadId(id)
            providerThreadSnapshotStatusMessage = nil
            providerThreadSnapshotLastConfirmedAt = providerThreadSnapshotConfirmedAtByThread[id]
            // F6: the SR1 translation maps are per-thread state. Reset them on a
            // thread switch so they don't accumulate the union of every translated
            // message (and its full original text) across every thread visited this
            // session. refreshSR1TranslationStateFromTimeline() below rebuilds them
            // from the opened thread's replayed timeline.
            sr1TranslatedMessageIds = []
            sr1OriginalTextsByMessageId = [:]
            // Per-thread provider state: the opened thread republishes its own
            // count on its next snapshot, so carrying the previous thread's
            // shell count over would advertise work that isn't this thread's.
            liveBackgroundShellCount = 0
            // Plan-suppression is per open thread session: do not carry a queued
            // follow-up suppress flag onto a different thread's durable plan.
            suppressStaleActivePlanUpdates = false
        } else {
            selectedThreadId = id
            publishInterestedThreadId(id)
        }
        // Persist the per-surface binding so app restart restores THIS surface
        // to THIS thread (not threads.first). Only fires on an actual change;
        // wired by the host after init, so restore-time selects don't re-persist.
        if isThreadSwitch { onSelectedThreadChanged?(id) }
        reloadQueuedMessages()
        let routing = selectedThread.effectiveRoutingConfiguration
        routingMode = routing.mode
        let manual = routing.manualSelection
        provider = manual.provider
        providerInstanceId = routing.manualProviderInstanceId ?? manual.provider.rawValue
        runAsUser = selectedThread.runAsUser ?? AgentRunAsUser.current()
        model = manual.effectiveModel
        permissionMode = selectedThread.permissionMode
        reasoningEffort = manual.reasoningEffort
        serviceTier = manual.serviceTier
        executionMode = selectedThread.executionMode
        baseBranch = selectedThread.baseBranch ?? gitBranch ?? "main"
        worktreePath = selectedThread.worktreePath
        status = selectedThread.status
        if isThreadSwitch { restoreComposerDraft(for: selectedThread) }
        if let trackedRunId = trackedRunId(for: id) {
            // UX-XPLAT-008: use the host's persisted run start time so
            // "Working for Xs" reflects real elapsed time even after
            // selectThread is called mid-run (e.g. after app relaunch or
            // switching away and back). Fallback to Date() only when the
            // run record is not yet committed (race on the very first tick).
            runStartedAt = AgentAppViewModel.resolvedRunStartedAt(
                current: runStartedAt,
                persisted: try? coordinator.runStartedAt(threadId: id)
            )
            // RUN-LIFECYCLE-STREAM-004: resync currentRunId to THIS thread's
            // active run. Without this, switching to an already-running
            // thread left a stale currentRunId from the previous thread, so
            // Stop could cancel the wrong thread's run.
            currentRunId = trackedRunId
            stopScheduledLivePoll()
        } else if isScheduledThreadRunning?(id) == true {
            // Path B: LaunchAgent owns the provider process. This process has
            // no coordinator session, so the old branch cleared runStartedAt
            // and the UI stuck on "Working for 0s" even while tools ran.
            // Shared SQLite still has agent_runs.started_at + stream events.
            bindScheduledOwnedRun(threadId: id)
        } else {
            currentRunId = nil
            runStartedAt = nil
            stopScheduledLivePoll()
        }
        normalizeInteractionModeForSelectedProvider()
        // UX-MAC_AGENT-CONTINUE: check whether the newly selected thread was
        // interrupted by a relaunch and has a recoverable provider session.
        selectedThreadHasRecoverableContext = coordinator.hasRecoverableContext(threadId: id)
        // B6: the host owns the one throwing persistence + publication mutation.
        // Reflect success locally without re-querying; retain persisted rail state
        // when the mutation fails.
        if markRead, let markThreadRead {
            do {
                try markThreadRead(id)
                if let idx = threads.firstIndex(where: { $0.id == id }) {
                    threads[idx].hasUnread = false
                }
            } catch {
                reloadThreads()
            }
        }
        loadAllMessages(id)
        timeline = AssistantTimelineState()
        streamUIBackpressured = false
        _ = streamEventBatch.drain()
        let persistedEvents = coordinator.latestStreamEvents(threadId: id)
        if coordinator.hotReplayIsPartial(threadId: id) {
            historyReplayNotice = Self.replayNoticeText(isPartial: true)
        }
        // PERF: the provider-thread snapshot read (coordinator.readThread) used to
        // block thread-open for up to a provider round-trip (codex app-server),
        // freezing the UI on every open/switch. Open instantly from persisted
        // events (snapshot: nil), then fetch the provider snapshot off the main
        // run loop and recompute the SAME full replay (chooseReplayEvents over
        // persisted + snapshot, identical merge + order) and re-apply it. Final
        // timeline state is identical to the pre-async path; only the provider
        // snapshot portion is now deferred instead of blocking.
        let persistedReplay = Self.chooseReplayEvents(persisted: persistedEvents, snapshot: nil)
        for event in persistedReplay {
            timeline.apply(event)
        }
        timeline.enforceAggregateHotTextBudget()
        lastErrorRecoverable = Self.displayedErrorIsRecoverable(in: persistedReplay)
        rehydrateDurableActiveState(threadId: id)
        // A pending follow-up means the user already superseded the prior Active
        // plan; keep it cleared across select/reopen until the next run starts.
        // Queued text stays in the queue UI only until drain starts the turn.
        restoreQueuedFollowupTranscriptPresentation(threadId: id)
        refreshSR1TranslationStateFromTimeline(preservingExisting: true)
        // PERF: rebuild the O(1) item index once over the fully-replayed timeline so
        // subsequent item-location lookups skip the O(turns x items) linear scan.
        timelineItemIndex = TimelineItemIndex(turns: timeline.turns)
        guard Self.shouldReadProviderSnapshot(
            hasRecoverableContext: selectedThreadHasRecoverableContext
        ) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.providerThreadSnapshotEvents(threadId: id)
                // Drop the result if the user switched threads while we were reading.
                guard self.selectedThreadId == id else { return }
                let confirmedAt = Date()
                self.providerThreadSnapshotConfirmedAtByThread[id] = confirmedAt
                self.providerThreadSnapshotLastConfirmedAt = confirmedAt
                self.providerThreadSnapshotStatusMessage = nil
                guard !snapshot.isEmpty else { return }
                let replayEvents = Self.chooseReplayEvents(
                    persisted: persistedEvents,
                    snapshot: self.mergePersistedContextTelemetry(snapshot: snapshot, persisted: persistedEvents)
                )
                self.timeline = AssistantTimelineState()
                for event in replayEvents {
                    self.timeline.apply(event)
                }
                self.timeline.enforceAggregateHotTextBudget()
                self.rehydrateDurableActiveState(threadId: id)
                self.restoreQueuedFollowupTranscriptPresentation(threadId: id)
                self.lastErrorRecoverable = Self.displayedErrorIsRecoverable(in: replayEvents)
                self.refreshSR1TranslationStateFromTimeline(preservingExisting: true)
                self.timelineItemIndex = TimelineItemIndex(turns: self.timeline.turns)
            } catch {
                guard self.selectedThreadId == id else { return }
                let threadHasProviderContext = self.threads.first(where: { $0.id == id })?.providerThreadId?.isEmpty == false
                    || !persistedEvents.isEmpty
                guard threadHasProviderContext else { return }
                self.providerThreadSnapshotStatusMessage = Self.providerThreadSnapshotFailureMessage(
                    lastConfirmedAt: self.providerThreadSnapshotConfirmedAtByThread[id]
                )
            }
        }
        rehydrateProposedPlans(threadId: id)
        rehydratePendingCallbacks(threadId: id)
        reloadCheckpoints()
        suppressPersistedFinalDuplicatedByTimeline()
        resetTimelineUpdateTick()
        // Do NOT auto-implement on select/reopen (pet, sidebar, restore). Opening a
        // thread is a view action — Full Access only auto-implements when a plan
        // arrives mid-stream, a run finishes with a pending plan, or the user
        // switches into full access on an already-open thread.
        // Restore persisted plan notes for the opened thread. A failed read must
        // not masquerade as absent notes and then overwrite the durable value.
        do {
            setPlanNotesWithoutSaving(try planNotesStore?.load(threadId: id) ?? "", threadId: id)
        } catch {
            setPlanNotesWithoutSaving("", threadId: id)
            statusMessage = "Could not load plan notes: \(error)"
        }
        // UX-MAC_AGENT-001: route first-responder to the composer on every
        // open/switch so the user can type without a manual click.
        focusTick &+= 1
        // Subagents is thread-scoped chrome: rebuild immediately so switching
        // threads never briefly shows another thread's Active/Done counts.
        refreshSubagentActivity()
        // Token Saver footer is per-thread; re-read the permanent total on open.
        reloadTokenSaverThreadSavings()
    }

    /// Called by the plan sidebar whenever planNotes changes to persist the
    /// current text keyed by the active thread.
    public func savePlanNotes() {
        guard let id = selectedThreadId, let planNotesStore else { return }
        if let ignoredPlanNotesSave {
            self.ignoredPlanNotesSave = nil
            if ignoredPlanNotesSave.threadId == id, ignoredPlanNotesSave.notes == planNotes {
                return
            }
        }
        do {
            try planNotesStore.save(planNotes, threadId: id)
            onPlanNotesPersisted?(id, planNotes)
        } catch {
            statusMessage = "Could not save plan notes: \(error)"
        }
    }

    /// Applies host-authoritative notes without re-entering the local save path
    /// when SwiftUI observes the programmatic property change.
    public func applyMirroredPlanNotes(_ notes: String, threadId: AgentThreadID) {
        guard selectedThreadId == threadId else { return }
        setPlanNotesWithoutSaving(notes, threadId: threadId)
    }

    private func setPlanNotesWithoutSaving(_ notes: String, threadId: AgentThreadID) {
        ignoredPlanNotesSave = (threadId, notes)
        planNotes = notes
    }

    public func reloadQueuedMessages() {
        guard let selectedThreadId, let queuedMessageRepo else {
            queuedMessages = []
            queueStatusMessage = nil
            return
        }
        queuedMessages = (try? queuedMessageRepo.list(threadId: selectedThreadId)) ?? []
        if let status = queueStatusByThread[selectedThreadId] {
            queueStatusMessage = status
        } else if queuedMessages.first?.durableState == .prepared {
            queueStatusMessage = Self.preparedQueueStatusMessage
        } else {
            queueStatusMessage = nil
        }
    }

    private static let preparedQueueStatusMessage =
        "Start confirmation is pending. Check status before deciding whether to remove this queue record."

    private func setQueueStatus(_ message: String?, threadId: AgentThreadID) {
        if let message {
            queueStatusByThread[threadId] = message
        } else {
            queueStatusByThread.removeValue(forKey: threadId)
        }
        if selectedThreadId == threadId {
            queueStatusMessage = message
        }
    }

    public func canForceQueuedMessage(_ message: AgentQueuedMessage) -> Bool {
        true
    }

    public func queuedMessageForceLabel(_ message: AgentQueuedMessage) -> String {
        switch message.durableState ?? .queued {
        case .queued:
            return "Force"
        case .prepared:
            return "Check status"
        case .dispatched:
            return "Finish cleanup"
        }
    }

    public func queuedMessagePrimaryActionAccessibilityLabel(
        _ message: AgentQueuedMessage
    ) -> String {
        switch message.durableState ?? .queued {
        case .queued:
            return "Force queued message \(message.position) now"
        case .prepared:
            return "Check queued message \(message.position) provider status"
        case .dispatched:
            return "Finish queued message \(message.position) cleanup"
        }
    }

    public func queuedMessageDurableStatus(_ message: AgentQueuedMessage) -> String? {
        switch message.durableState ?? .queued {
        case .queued:
            return nil
        case .prepared:
            return "Provider acceptance is unresolved. The message is retained to prevent duplicate work."
        case .dispatched:
            return "Provider start was confirmed. Queue acknowledgement is being recovered."
        }
    }

    public func editQueuedMessage(_ message: AgentQueuedMessage) {
        editingQueuedMessage = message
        queuedMessageDraft = message.text
        setQueueStatus(nil, threadId: message.threadId)
    }

    public func saveQueuedMessageEdit() {
        guard let editingQueuedMessage, let queuedMessageRepo else { return }
        let text = queuedMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !editingQueuedMessage.attachments.isEmpty else { return }
        do {
            if let updated = try queuedMessageRepo.update(id: editingQueuedMessage.id, text: text, attachments: editingQueuedMessage.attachments) {
                setQueueStatus(nil, threadId: editingQueuedMessage.threadId)
                self.editingQueuedMessage = nil
                queuedMessageDraft = ""
                // Queue edits stay in the queue UI only. The transcript bubble is
                // created when the message drains and the provider turn starts.
                reloadQueuedMessages()
                onQueuedMessageEvent?(AgentQueueEventKinds.updated, updated)
            } else {
                self.editingQueuedMessage = nil
                queuedMessageDraft = ""
                reloadQueuedMessages()
                setQueueStatus("Already processing.", threadId: editingQueuedMessage.threadId)
            }
        } catch {
            setQueueStatus(
                "Queue edit failed: \(error)",
                threadId: editingQueuedMessage.threadId
            )
        }
    }

    public func forceQueuedMessageNow(_ message: AgentQueuedMessage) async {
        guard let forceQueuedMessage else {
            setQueueStatus(
                "Queue action is unavailable while the app router is not ready.",
                threadId: message.threadId
            )
            return
        }
        let statusBeforeAction = queueStatusByThread[message.threadId]
        do {
            let result = try await forceQueuedMessage(message.id)
            reloadQueuedMessages()
            if result.status == .queued {
                setQueueStatus(
                    "Stopping current run to start this now.",
                    threadId: message.threadId
                )
            } else {
                setQueueStatus(nil, threadId: message.threadId)
            }
        } catch {
            let hostStatus = queueStatusByThread[message.threadId]
            reloadQueuedMessages()
            if hostStatus != statusBeforeAction, let hostStatus {
                setQueueStatus(hostStatus, threadId: message.threadId)
                return
            }
            let prefix = message.durableState == .queued
                ? "Queue force failed"
                : "Queue status check failed"
            setQueueStatus("\(prefix): \(error)", threadId: message.threadId)
        }
    }

    public func cancelQueuedMessage(_ message: AgentQueuedMessage) {
        removeQueuedMessage(message)
    }

    public func removeQueuedMessage(_ message: AgentQueuedMessage) {
        guard let queuedMessageRepo else { return }
        do {
            let removed: AgentQueuedMessage?
            switch message.durableState ?? .queued {
            case .queued:
                removed = try queuedMessageRepo.delete(id: message.id)
            case .prepared:
                removed = try queuedMessageRepo.abandonPrepared(id: message.id)
            case .dispatched:
                setQueueStatus(
                    "Provider start was confirmed. Use Finish cleanup instead of removing this message.",
                    threadId: message.threadId
                )
                return
            }
            if let cancelled = removed {
                if editingQueuedMessage?.id == message.id {
                    editingQueuedMessage = nil
                    queuedMessageDraft = ""
                }
                // Defensive: remove any leftover in-memory mirror from older
                // builds that mirrored queued text into the transcript. Only
                // drop when not yet durable under that id (drain/start persist).
                let mirrorId = AgentMessageID(cancelled.id.value)
                if (try? messageRepo.get(id: mirrorId)) == nil,
                   let idx = messages.firstIndex(where: { $0.id == mirrorId }) {
                    messages.remove(at: idx)
                }
                if queuedMessages.count <= 1 {
                    // Last queued follow-up cancelled: allow plan events again
                    // for the still-running turn (if any).
                    suppressStaleActivePlanUpdates = false
                }
                reloadQueuedMessages()
                onQueuedMessageEvent?(AgentQueueEventKinds.cancelled, cancelled)
            } else {
                reloadQueuedMessages()
                setQueueStatus(
                    "Queue state changed before removal. Check status and try again.",
                    threadId: message.threadId
                )
            }
        } catch {
            setQueueStatus(
                "Queue removal failed: \(error)",
                threadId: message.threadId
            )
        }
    }

    /// Pure reorder helper: moves the element at `from` to `to` within `queue`.
    /// Out-of-bounds indices or a single-item queue are no-ops.
    /// Positions in returned elements are NOT updated — caller persists as needed.
    /// public: reused by AppCommandRouter's agent.message.queue.reorder RPC so
    /// the mirror path performs the same mutation as the mac drag-reorder.
    nonisolated public static func reorderQueue(
        _ queue: [AgentQueuedMessage],
        from: Int,
        to: Int
    ) -> [AgentQueuedMessage] {
        guard queue.count > 1,
              queue.indices.contains(from),
              queue.indices.contains(to),
              from != to else { return queue }
        var result = queue
        let item = result.remove(at: from)
        result.insert(item, at: to)
        return result
    }

    /// Reorders a queued message from one index to another, persisting new positions.
    public func reorderQueuedMessage(from: IndexSet, to: Int) {
        guard let queuedMessageRepo, let fromIndex = from.first else { return }
        // SwiftUI List onMove passes destination after removal; normalise to an
        // inclusive target index so the pure helper contract is simple.
        let dest = fromIndex < to ? to - 1 : to
        let reordered = AgentAppViewModel.reorderQueue(queuedMessages, from: fromIndex, to: dest)
        do {
            let now = Date()
            for (index, var message) in reordered.enumerated() {
                message.position = index + 1
                message.updatedAt = now
                try queuedMessageRepo.upsert(message)
            }
            reloadQueuedMessages()
            for queued in queuedMessages {
                onQueuedMessageEvent?(AgentQueueEventKinds.updated, queued)
            }
        } catch {
            if let selectedThreadId {
                setQueueStatus("Queue reorder failed: \(error)", threadId: selectedThreadId)
            }
        }
    }


    public func reloadCheckpoints() {
        guard let selectedThreadId, let checkpointRepo else {
            checkpoints = []
            selectedCheckpointTurnCount = nil
            selectedCheckpointPath = nil
            checkpointDiffPreview = ""
            return
        }
        let loaded = (try? checkpointRepo.list(threadId: selectedThreadId)) ?? []
        checkpoints = loaded.reversed()
        if let selected = selectedCheckpointTurnCount,
           let checkpoint = checkpoints.first(where: { $0.checkpointTurnCount == selected }) {
            selectCheckpoint(checkpoint, path: selectedCheckpointPath)
        } else if let first = checkpoints.first {
            selectCheckpoint(first, path: nil)
        } else {
            selectedCheckpointTurnCount = nil
            selectedCheckpointPath = nil
            checkpointDiffPreview = ""
        }
    }

    public func selectCheckpoint(_ checkpoint: AgentTurnCheckpointSummary, path: String?) {
        selectedCheckpointTurnCount = checkpoint.checkpointTurnCount
        selectedCheckpointPath = path
        checkpointStatusMessage = nil
        if let path {
            checkpointDiffPreview = checkpoint.fileDiffs.first(where: { $0.path == path })?.patch ?? ""
        } else {
            checkpointDiffPreview = checkpoint.diffPatch ?? checkpoint.fileDiffs.map(\.patch).joined(separator: "\n\n")
        }
        if checkpointDiffPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            checkpointDiffPreview = checkpoint.errorMessage ?? "No diff captured for this checkpoint."
        }
    }

    nonisolated public static func canRevertCheckpoint(
        status: AgentTurnCheckpointStatus,
        capabilities: AgentProviderCapabilities
    ) -> Bool {
        status == .ready && capabilities.supportsRollback
    }

    public var selectedProviderCapabilities: AgentProviderCapabilities {
        selectedProviderSnapshot?.effectiveCapabilities ?? .conservative
    }

    public var supportsPlanInteractionForSelectedProvider: Bool {
        if let snapshot = selectedProviderSnapshot {
            return snapshot.interactionModes.contains(.plan)
        }
        // Startup may briefly precede snapshot discovery. Codex and Claude
        // have native Plan contracts; Grok stays fail-closed until its ACP
        // session advertises a Plan mode and discovery can surface it.
        return provider != .grok
    }

    public var planInteractionUnavailableReason: String? {
        guard !supportsPlanInteractionForSelectedProvider else { return nil }
        return "\(providerDisplayName(provider)) does not support Plan mode for this session."
    }

    public var supportedPermissionModesForSelectedProvider: [AgentPermissionMode] {
        if let snapshot = selectedProviderSnapshot {
            return snapshot.effectivePermissionModes
        }
        // Pre-discovery: Grok CLI/ACP supports the full permission set even when
        // session/new omits modes. Keep parity with Codex/Claude until a snapshot
        // narrows the negotiated subset.
        return AgentPermissionMode.allCases
    }

    public func permissionModeUnavailableReason(_ mode: AgentPermissionMode) -> String? {
        guard !supportedPermissionModesForSelectedProvider.contains(mode) else { return nil }
        let label: String
        switch mode {
        case .supervised: label = "Supervised"
        case .autoAcceptEdits: label = "Auto-edit"
        case .fullAccess: label = "Full access"
        }
        return "\(providerDisplayName(provider)) does not support \(label) for this session."
    }

    public var threadForkUnavailableReason: String? {
        guard !selectedProviderCapabilities.supportsFork else { return nil }
        return "\(providerDisplayName(provider)) does not support provider-side fork for this session."
    }

    public var checkpointRevertUnavailableReason: String? {
        guard !selectedProviderCapabilities.supportsRollback else { return nil }
        return "\(providerDisplayName(provider)) does not support provider-side rollback for this session."
    }

    public func revertSelectedCheckpoint() {
        guard let selectedThreadId, let turnCount = selectedCheckpointTurnCount else { return }
        guard selectedProviderCapabilities.supportsRollback else {
            checkpointStatusMessage = checkpointRevertUnavailableReason
            return
        }
        Task { @MainActor in
            do {
                _ = try await coordinator.revertThreadToCheckpoint(threadId: selectedThreadId, checkpointTurnCount: turnCount, cwd: cwd)
                // PERF-MAC_AGENT-006/012: revert deleted assistant rows — drop both caches.
                lastPersistedAssistantContentByThread.removeValue(forKey: selectedThreadId)
                lastPersistedFinalIdByThread.removeValue(forKey: selectedThreadId)
                checkpointStatusMessage = "Reverted to checkpoint \(turnCount)."
                loadAllMessages(selectedThreadId)
                reloadCheckpoints()
                reloadThreads()
                armCheckpointRevertUndo(CheckpointRevertUndoToast(
                    threadId: selectedThreadId,
                    cwd: cwd,
                    checkpointTurnCount: turnCount,
                    capturedAt: currentTime()
                ))
            } catch {
                checkpointStatusMessage = "Revert failed: \(error.localizedDescription)"
            }
        }
    }

    private func providerThreadSnapshotEvents(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        try await coordinator.readThread(threadId: threadId)
    }

    nonisolated public static func providerThreadSnapshotFailureMessage(lastConfirmedAt: Date?) -> String {
        let confirmed = lastConfirmedAt.map {
            $0.formatted(date: .omitted, time: .standard)
        } ?? "not yet confirmed this session"
        return "Provider snapshot unavailable. Showing persisted local state; last provider confirmation: \(confirmed)."
    }

    /// An interrupted session must remain disconnected until the user chooses
    /// Continue. Auto-recovering it for a background snapshot races the explicit
    /// resume and can create two app-server clients for one local thread.
    nonisolated public static func shouldReadProviderSnapshot(hasRecoverableContext: Bool) -> Bool {
        !hasRecoverableContext
    }

    public func retryProviderThreadSnapshotRead() {
        guard let selectedThreadId else { return }
        selectThread(selectedThreadId, markRead: false)
    }

    private func mergePersistedContextTelemetry(snapshot: [AssistantEvent], persisted: [AssistantEvent]) -> [AssistantEvent] {
        var merged = snapshot
        if !snapshot.contains(where: { if case .tokenUsage = $0 { return true }; return false }),
           let usage = persisted.reversed().compactMap({ event -> AssistantTokenUsage? in
               if case .tokenUsage(let usage) = event { return usage }
               return nil
           }).first {
            merged.append(.tokenUsage(usage))
        }
        if !snapshot.contains(where: { if case .contextCompaction = $0 { return true }; return false }),
           let summary = persisted.reversed().compactMap({ event -> String?? in
               if case .contextCompaction(let summary) = event { return .some(summary) }
               return nil
           }).first {
            merged.append(.contextCompaction(summary: summary))
        }
        return merged
    }

    /// Pick the replay source that reconstructs MORE of the thread. The provider snapshot
    /// (Codex `thread/read`) is context-compacted: once the model auto-compacts, it drops the
    /// older turns and returns only the recent tail — so for a long thread it shows the thread
    /// "cortado". Our persisted stream events are the full local record (pruned only at ~5000).
    /// Displaying whichever is fuller means reopening a compacted thread shows 100% of its
    /// turns, while threads imported from an external provider session (no/thin persisted
    /// history) still fall back to the snapshot.
    nonisolated static func chooseReplayEvents(persisted: [AssistantEvent], snapshot: [AssistantEvent]?) -> [AssistantEvent] {
        guard let snapshot else { return persisted }
        return renderableItemCount(persisted) > renderableItemCount(snapshot) ? persisted : snapshot
    }

    nonisolated static func renderableItemCount(_ events: [AssistantEvent]) -> Int {
        events.reduce(0) { count, event in
            if case .itemStarted = event { return count + 1 }
            return count
        }
    }

    private func rehydrateProposedPlans(threadId: AgentThreadID) {
        guard let proposedPlanRepo,
              let records = try? proposedPlanRepo.list(threadId: threadId) else { return }
        for record in records {
            timeline.apply(.proposedPlan(record.plan))
        }
    }

    private func rehydratePendingCallbacks(threadId: AgentThreadID) {
        guard let pendingCallbackRepo,
              let callbacks = try? pendingCallbackRepo.listVisible(threadId: threadId) else { return }
        let decoder = JSONDecoder()
        for callback in callbacks {
            guard let data = callback.payloadJSON.data(using: .utf8) else { continue }
            switch callback.kind {
            case .approval:
                guard var request = try? decoder.decode(AssistantPendingRequest.self, from: data) else { continue }
                request.state = callback.state
                request.resolvedAtMs = callback.resolvedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                timeline.apply(.requestOpened(request))
            case .userInput:
                guard var request = try? decoder.decode(AssistantUserInputRequest.self, from: data) else { continue }
                request.state = callback.state
                request.resolvedAtMs = callback.resolvedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                timeline.apply(.userInputRequested(request))
            }
        }
    }

    private func rehydrateDurableActiveState(threadId: AgentThreadID) {
        // A user send superseded the prior plan until the next run starts.
        guard !suppressStaleActivePlanUpdates else { return }
        guard let state = coordinator.durableActiveThreadState(threadId: threadId),
              let activePlan = state.activePlan else { return }
        // Chat contract: never resurrect a fully completed prior checklist.
        guard !AgentAppView.activePlanIsFullyCompleted(activePlan) else { return }
        timeline.apply(.activePlanUpdated(activePlan))
    }

    // MARK: Bounded message history
    /// Hot transcript body budget for the UI process. Durable history stays in
    /// SQLite; only this many UTF-8 body bytes stay resident in `messages`.
    /// (Was 96 MB — too large for huge threads; older rows load via keyset pages.)
    /// First-paint / hot UI body budget. Lower than durable retention so opening
    /// a fat thread does not re-render multi-MiB of markdown on MainActor.
    nonisolated static let fullLoadBodyBudgetBytes = 768 * 1024
    /// Hot message page (newest first). Older durable rows remain outside the
    /// hot UI window (`messageHistoryIsPartial`) and load on demand via scroll.
    nonisolated static let messageHistoryPageLimit = 40

    private func loadAllMessages(_ id: AgentThreadID) {
        // SQLite access remains on the app's established DB actor, but the query is
        // keyset/row/byte bounded: opening a multi-year thread no longer scans every
        // historical shell or hydrates an unbounded array on MainActor.
        messageHistoryLoadTask?.cancel()
        // Same-thread reloads must NOT wipe the visible array first. A concurrent
        // finish/select reload used to set messages=[] and drop the optimistic
        // user-message mirror (and system notes) before the durable row existed.
        // Only clear when switching threads so the prior thread's rows do not flash.
        if messages.contains(where: { $0.threadId != id }) {
            messages = []
            messageHistoryIsPartial = false
        }
        // Invalidate any in-flight older-page load (thread switch or re-select).
        // Bumping generation makes stale Task defers no-ops; UI flag clears now.
        cancelOlderMessageLoad()
        let repository = messageRepo
        messageHistoryLoadTask = Task { @MainActor [weak self] in
            let loaded = await Self.loadMessagePageOffMain(repository: repository, threadId: id)
            guard let self, !Task.isCancelled, !self.isDisposed,
                  self.selectedThreadId == id else { return }
            let loadedRows = loaded?.rows ?? []
            // Rows appended in-memory while the page was being read (system
            // notes, the send() user-message mirror) must survive the swap —
            // the page snapshot predates them. Optimistic mirrors share the
            // durable id, so id-merge collapses once the run/queue row lands.
            self.messages = Self.mergeLoadedMessagesWithInMemoryMirrors(
                loadedRows: loadedRows,
                inMemory: self.messages,
                threadId: id
            )
            self.messageHistoryIsPartial = loaded?.hasMoreOlder ?? false
            // Queue rows are not transcript bubbles; only re-apply plan
            // suppression after the durable message merge.
            self.restoreQueuedFollowupTranscriptPresentation(threadId: id)
            if self.messageHistoryIsPartial {
                NSLog("[AgentApp] recent message page loaded: \(self.messages.count) rows; older durable messages remain outside the hot UI window")
            }
        }
    }

    /// Pure merge used by load completion and tests: durable page first, then any
    /// same-thread in-memory rows whose id is not already in the page.
    /// Optimistic queue/start mirrors use the durable run/queue UUID so drain
    /// and coordinator persist collapse to one row by id (not by content — two
    /// legitimate identical prompts must remain two bubbles).
    nonisolated static func mergeLoadedMessagesWithInMemoryMirrors(
        loadedRows: [AgentMessage],
        inMemory: [AgentMessage],
        threadId: AgentThreadID
    ) -> [AgentMessage] {
        let loadedIds = Set(loadedRows.map(\.id))
        let mirrors = inMemory.filter { candidate in
            candidate.threadId == threadId && !loadedIds.contains(candidate.id)
        }
        return loadedRows + mirrors
    }

    /// Shared UX for an outgoing user turn that is actually starting now:
    /// show the bubble, drop the previous turn's Active plan, and re-pin the
    /// transcript to the bottom. `messageId` must be the durable identity
    /// (`AgentMessageID(runId)` / `AgentMessageID(queued.id)` on drain) so later
    /// persist does not double the bubble. Mid-run queue inserts must not call
    /// this — they stay in the queue UI until the turn starts.
    private func presentOutgoingUserMessage(
        threadId: AgentThreadID,
        messageId: AgentMessageID,
        display: String,
        attachments: [AgentAttachment],
        bumpFocus: Bool = true
    ) {
        let capped = AssistantTimelineState.cappedText(display)
        timeline.clearActivePlan()
        suppressStaleActivePlanUpdates = true
        resetTimelineUpdateTick()
        if let idx = messages.firstIndex(where: { $0.id == messageId }) {
            // Re-present under the stable id (e.g. resume / already mirrored).
            messages[idx] = AgentMessage(
                id: messageId,
                threadId: threadId,
                role: .user,
                content: capped,
                createdAt: messages[idx].createdAt,
                attachments: attachments
            )
        } else {
            messages.append(AgentMessage(
                id: messageId,
                threadId: threadId,
                role: .user,
                content: capped,
                attachments: attachments
            ))
            if bumpFocus { focusTick &+= 1 }
        }
    }

    /// After a durable message-page load / timeline rehydrate, re-apply the
    /// user-visible contract for pending queue rows: keep the prior Active plan
    /// cleared. Queued text itself stays out of the transcript until drain.
    private func restoreQueuedFollowupTranscriptPresentation(threadId: AgentThreadID) {
        guard queuedMessages.contains(where: { $0.threadId == threadId }) else { return }
        suppressStaleActivePlanUpdates = true
        timeline.clearActivePlan()
    }

    /// Test seam: awaits the off-main message-history page kicked off by
    /// selectThread, so tests can assert on `messages` deterministically.
    func waitForMessageHistoryLoad() async {
        await messageHistoryLoadTask?.value
    }

    nonisolated static func loadMessagePageOffMain(
        repository: AgentMessageRepository,
        threadId: AgentThreadID,
        before: AgentMessageCursor? = nil
    ) async -> AgentMessageBodyBudgetResult? {
        await Task.detached(priority: .userInitiated) {
            try? repository.listPageWithinBodyBudget(
                threadId: threadId,
                limit: messageHistoryPageLimit,
                before: before,
                budget: fullLoadBodyBudgetBytes,
                contentLimit: AssistantTimelineState.liveTextLimit
            )
        }.value
    }

    /// Pure merge: older page prepended before current hot rows (dedupe by id).
    /// WHY: keyset `before` pages must expand the hot window without dropping
    /// in-memory mirrors or reordering the newest suffix.
    nonisolated static func mergeOlderMessagePage(
        older: [AgentMessage],
        current: [AgentMessage]
    ) -> [AgentMessage] {
        guard !older.isEmpty else { return current }
        var seen = Set(current.map(\.id))
        var prefix: [AgentMessage] = []
        prefix.reserveCapacity(older.count)
        for message in older where !seen.contains(message.id) {
            seen.insert(message.id)
            prefix.append(message)
        }
        return prefix + current
    }

    /// Invalidate ownership of any in-flight older-page load and clear UI flag.
    private func cancelOlderMessageLoad() {
        loadingOlderGeneration &+= 1
        if isLoadingOlderMessages { isLoadingOlderMessages = false }
    }

    /// Load the next older keyset page into `messages` when history is partial.
    /// Durable SQLite rows remain; this only expands the hot UI window.
    ///
    /// Ownership uses a generation token (not a bare bool): only the live load
    /// may clear loading. A stale Task after thread switch / newer load is a no-op.
    public func loadOlderMessages() {
        guard !isDisposed, !isLoadingOlderMessages, messageHistoryIsPartial,
              let threadId = selectedThreadId,
              let oldest = messages.first else { return }
        loadingOlderGeneration &+= 1
        let myGeneration = loadingOlderGeneration
        isLoadingOlderMessages = true
        let repository = messageRepo
        let cursor = AgentMessageCursor(createdAt: oldest.createdAt, id: oldest.id)
        let expectedThread = threadId
        Task { @MainActor [weak self] in
            defer {
                // Only the live owner clears. Stale gens leave a newer load alone.
                if let self,
                   Self.shouldClearLoadingOlderMessages(
                    myGeneration: myGeneration,
                    currentGeneration: self.loadingOlderGeneration
                   ) {
                    self.loadingOlderGeneration = 0
                    self.isLoadingOlderMessages = false
                }
            }
            let loaded = await Self.loadMessagePageOffMain(
                repository: repository,
                threadId: expectedThread,
                before: cursor
            )
            guard let self, !self.isDisposed,
                  self.selectedThreadId == expectedThread,
                  Self.shouldClearLoadingOlderMessages(
                    myGeneration: myGeneration,
                    currentGeneration: self.loadingOlderGeneration
                  ) else { return }
            guard let loaded else { return }
            self.messages = Self.mergeOlderMessagePage(
                older: loaded.rows,
                current: self.messages
            )
            self.messageHistoryIsPartial = loaded.hasMoreOlder
            if !loaded.hasMoreOlder {
                NSLog("[AgentApp] older message pages exhausted for thread \(expectedThread.value.uuidString)")
            }
        }
    }

    /// Pure ownership gate (SSHRemoteView `shouldClearLoading` pattern).
    /// True only when this Task still owns the active older-page load.
    nonisolated static func shouldClearLoadingOlderMessages(
        myGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        myGeneration == currentGeneration && myGeneration != 0
    }

    /// Safety valve for a pathological thread: keep the NEWEST bodies in full and blank
    /// the oldest (content -> "") until total text is under `budget`. Returns the rows and
    /// how many were blanked. Pure + testable. For a normal thread nothing is blanked.
    nonisolated static func applyBodyBudget(_ rows: [AgentMessage], budget: Int = fullLoadBodyBudgetBytes) -> (rows: [AgentMessage], blanked: Int) {
        var total = 0
        for r in rows { total += r.content.utf8.count }
        guard total > budget else { return (rows, 0) }
        var result = rows
        var running = total
        var blanked = 0
        var i = 0
        while running > budget && i < result.count {
            let bytes = result[i].content.utf8.count
            if bytes > 0 {
                result[i].content = ""
                running -= bytes
                blanked += 1
            }
            i += 1
        }
        return (result, blanked)
    }

    /// F5: cap each message body AND enforce the memory budget in a SINGLE pass over
    /// the rows (the common, under-budget case does no second pass), instead of mapping
    /// a cap over all rows and then summing them again. Output is identical to
    /// `applyBodyBudget(raw.map { cappedText($0.content) })`.
    nonisolated static func cappedRowsWithinBudget(_ raw: [AgentMessage], budget: Int = fullLoadBodyBudgetBytes) -> (rows: [AgentMessage], blanked: Int) {
        var rows: [AgentMessage] = []
        rows.reserveCapacity(raw.count)
        var total = 0
        for message in raw {
            var capped = message
            capped.content = AssistantTimelineState.cappedText(message.content)
            total += capped.content.utf8.count
            rows.append(capped)
        }
        guard total > budget else { return (rows, 0) }
        var running = total
        var blanked = 0
        var i = 0
        while running > budget && i < rows.count {
            let bytes = rows[i].content.utf8.count
            if bytes > 0 {
                rows[i].content = ""
                running -= bytes
                blanked += 1
            }
            i += 1
        }
        return (rows, blanked)
    }

    private func suppressPersistedFinalDuplicatedByTimeline() {
        // Persisted assistant rows are the durable completed answer. The view
        // suppresses matching live timeline text instead so partial replay
        // cannot hide the final response.
    }

    /// B7: count of threads with an in-flight run, for the rail header.
    public var activeThreadCount: Int {
        threads.filter { isThreadStartingOrRunning($0.id) }.count
    }

    /// Chrome spinner for this Agent App tab only.
    ///
    /// Spins when the selected thread has tracked in-flight work, or when this
    /// surface still owns a live run in `runThreads` (user switched threads
    /// mid-run). Does **not** roll up every workspace thread — multiple Agent
    /// App tabs share the same thread list, and a workspace-wide check made
    /// every tab spin whenever any one of them was running.
    public var hasRunningWorkForChrome: Bool {
        if selectedThreadRunIsStartingOrRunning { return true }
        return runThreads.values.contains { threadId in
            coordinator.activeRunId(threadId: threadId) != nil
        }
    }

    /// UX-MAC_AGENT-BG-AWAIT: the most recent final answer for the selected
    /// thread, used to detect a background-await stall for the status badge /
    /// Continue affordance. Prefers the live timeline's last turn, falling back to
    /// the last persisted assistant message after a reload.
    public var latestFinalAssistantMessage: String? {
        if let final = timeline.turns.last?.finalAssistantMessage, !final.isEmpty { return final }
        return messages.last(where: { $0.role == .assistant })?.content
    }

    /// UX-MAC_AGENT-BG-AWAIT / incomplete-turn: true when the selected thread
    /// finished while still incomplete — either waiting on a background job or
    /// stopped mid multi-phase workflow (e.g. "Next: Phase 3 — Review"). Surfaced
    /// as an "awaiting" badge plus a Continue button instead of a misleading green
    /// "completed".
    public var isAwaitingBackgroundWork: Bool {
        status == .completed
            && IncompleteTurnContinuation.isIncompleteTurn(latestFinalAssistantMessage)
    }

    /// CLAUDE-BG-LIFECYCLE: background shells/subagents to advertise right now.
    ///
    /// Gated on a live run on purpose. The adapter clears its pending set inside
    /// `emitTerminal` WITHOUT emitting a further snapshot, so the last count the
    /// UI ever receives for a run can be non-zero; without this gate a finished
    /// thread would keep claiming shells are running. While a run is live the
    /// snapshots are authoritative (an empty `tasks` list replaces the set).
    /// Complements `isAwaitingBackgroundWork`, which covers the *after* case —
    /// this covers *during*.
    public var backgroundShellCount: Int {
        Self.visibleBackgroundShellCount(
            reported: liveBackgroundShellCount,
            runIsLive: selectedThreadRunIsStartingOrRunning
        )
    }

    /// Pure seam for the staleness gate above.
    nonisolated static func visibleBackgroundShellCount(reported: Int, runIsLive: Bool) -> Int {
        runIsLive ? reported : 0
    }

    /// Reason for the incomplete-turn chrome, if any (drives Continue prompt).
    public var incompleteTurnReason: IncompleteTurnContinuationReason? {
        guard status == .completed else { return nil }
        return IncompleteTurnContinuation.classify(latestFinalAssistantMessage)
    }

    /// UX-MAC_AGENT-BG-AWAIT: composer placeholder. When the selected thread ended
    /// while still incomplete (awaiting a background job, or paused mid multi-phase
    /// workflow), the placeholder reflects that state instead of the neutral
    /// "Ask <Provider> for changes…" — otherwise the composer reads as a finished,
    /// idle turn even though the run is not done (the reported defect). Typing and
    /// sending stay enabled: a send redirects the thread; the co-visible
    /// `backgroundAwaitBanner` directly above carries the Continue (resume) action.
    /// Copy is deliberately short and positionless — the editor draws the
    /// placeholder without wrapping, so long/position-coupled copy would clip. The
    /// `!selectedThreadRunIsStartingOrRunning` guard keeps the neutral copy during
    /// the brief window a resume run is starting.
    public var composerPlaceholder: String {
        let defaultPlaceholder = "Ask \(provider.rawValue.capitalized) for changes…"
        guard !selectedThreadRunIsStartingOrRunning,
              let reason = incompleteTurnReason else { return defaultPlaceholder }
        switch reason {
        case .backgroundAwait:
            return "Waiting on a background task — send to redirect…"
        case .workflowHandoff:
            return "Paused mid-workflow — send to redirect…"
        case .uncalledToolInvocation:
            return "Tool call was not executed — send to redirect…"
        }
    }

    /// P2: threads visible in the rail after applying the search query.
    /// Empty query returns all non-subagent threads (nested workers stay off-rail).
    public var filteredThreads: [AgentThread] {
        AgentAppViewModel.filterThreads(threads, query: threadSearchQuery)
    }

    /// Pure helper: drops orchestrated nested-worker rows, then applies search.
    /// Empty query keeps every non-subagent thread.
    /// WHY: "Subagent · …" rows are AgentAppMiddleware nested workers; product
    /// rule is Subagents-under-parent chrome, not first-class rail entries.
    nonisolated public static func filterThreads(_ threads: [AgentThread], query: String) -> [AgentThread] {
        let rail = threads.filter { !AgentThreadTitle.isSubagentThreadTitle($0.title) }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return rail }
        return rail.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.model.localizedCaseInsensitiveContains(q)
        }
    }

    /// C7: the most recent plan the agent proposed in this thread's
    /// timeline (t3code PlanSidebar — proposed-plan tracking).
    public var latestPlanText: String? {
        if let plan = timeline.proposedPlans.last?.markdown.trimmingCharacters(in: .whitespacesAndNewlines),
           !plan.isEmpty {
            return plan
        }
        for turn in timeline.turns.reversed() {
            if let plan = turn.items.last(where: { $0.type == .plan }) {
                let t = plan.body.isEmpty ? (plan.summary ?? "") : plan.body
                return t.isEmpty ? nil : t
            }
        }
        return nil
    }
    public var latestProposedPlan: AssistantProposedPlan? {
        timeline.proposedPlans.last { !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Full access is an autonomous mode: tools and plan implementation run without
    /// a human review gate. Proposed-plan Approve/Reject must not appear.
    public var suppressesProposedPlanReview: Bool {
        permissionMode == .fullAccess
    }

    /// Proposed plan cards that still need a human decision (supervised / auto-edits).
    public var reviewableProposedPlan: AssistantProposedPlan? {
        guard !suppressesProposedPlanReview else { return nil }
        return latestProposedPlan
    }

    /// Plan IDs already scheduled for full-access auto-implement (dedupe flush + finish).
    private var fullAccessAutoImplementPlanIds: Set<String> = []

    /// Under full access, auto-implement the latest unimplemented proposed plan
    /// (queue if a turn is still open — never ask the user to Approve).
    public func scheduleFullAccessPlanAutoImplementIfNeeded() {
        guard suppressesProposedPlanReview else { return }
        guard let plan = latestProposedPlan, plan.showsImplementationActions else { return }
        // Dedupe concurrent flush+finish schedules only after a successful start/queue
        // (failed enqueue must remain retryable).
        guard !fullAccessAutoImplementPlanIds.contains(plan.id) else { return }
        fullAccessAutoImplementPlanIds.insert(plan.id)
        Task {
            await self.implementLatestPlan(newThread: false)
            // implementLatestPlan marks implemented only on success; release the
            // latch so a later finish/reopen can retry a failed admission.
            if self.latestProposedPlan?.id == plan.id,
               self.latestProposedPlan?.showsImplementationActions == true {
                self.fullAccessAutoImplementPlanIds.remove(plan.id)
            }
        }
    }

    @discardableResult
    public func saveLatestProposedPlan(to url: URL) throws -> URL {
        guard let plan = latestProposedPlan else {
            throw NSError(domain: "RemoteCode.AgentApp", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "No proposed plan is available to save."
            ])
        }
        try plan.markdown.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    public var activePlan: AssistantActivePlan? {
        timeline.activePlan
    }

    public var openPendingRequests: [AssistantPendingRequest] {
        timeline.pendingRequests.filter { $0.state == .pending }
    }

    public var openPendingUserInputs: [AssistantUserInputRequest] {
        timeline.pendingUserInputs.filter { $0.state == .pending }
    }

    public var visiblePendingRequests: [AssistantPendingRequest] {
        timeline.pendingRequests.filter { $0.state == .pending || $0.state == .stale }
    }

    public var visiblePendingUserInputs: [AssistantUserInputRequest] {
        timeline.pendingUserInputs.filter { $0.state == .pending || $0.state == .stale }
    }

    /// Builds the decline payload for a supervised-mode approval decision.
    /// A non-empty reason is included so the agent can steer future requests;
    /// blank/nil reason produces a plain decline with no annotation.
    nonisolated public static func declinePayload(reason: String?) -> AgentProviderRequestResponse {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .decline(trimmed.flatMap { $0.isEmpty ? nil : $0 })
    }

    public func respondToPendingRequest(_ request: AssistantPendingRequest, response: AgentProviderRequestResponse) {
        guard let threadId = selectedThreadId else { return }
        respondToPendingRequest(request, response: response, originThreadId: threadId)
    }

    public func respondToPendingRequest(
        _ request: AssistantPendingRequest,
        response: AgentProviderRequestResponse,
        originThreadId threadId: AgentThreadID
    ) {
        guard request.state == .pending else { return }
        guard threads.contains(where: { $0.id == threadId }) else { return }
        let state: AssistantRequestState
        switch response {
        case .approve, .approveForSession: state = .approved
        case .decline: state = .declined
        case .cancel: state = .cancelled
        }
        // coordinator.respondToRequest is now async (its codex app-server
        // permission-promotion no longer blocks the caller on a semaphore).
        // respondToPendingRequest stays a synchronous SwiftUI action; drive the
        // resolution off the main run loop, preserving the same success/failure
        // side-effects, ordering, and the trailing timeline tick.
        //
        // The async hop means a later, synchronous callback action (e.g.
        // answerPendingUserInput) can run BEFORE this Task resolves. To preserve
        // the pre-async "most-recent callback action's error is the visible one"
        // ordering, stamp this action and refuse to clobber timeline.error if a
        // newer callback action has been issued in the meantime.
        callbackActionSeq &+= 1
        let issuedSeq = callbackActionSeq
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.coordinator.respondToRequest(threadId: threadId, requestId: request.id, response: response)
                // QA-MAC_AGENT-010: record approval outcomes for diagnostics.
                agentSurfaceLog.info("approval.resolved thread=\(threadId.value.uuidString, privacy: .public) request=\(request.id, privacy: .public) state=\(state.rawValue, privacy: .public)")
                // Dynamic permission callbacks already carry the provider's
                // exact requested profile and session scope. Never translate
                // that narrow grant into the thread-wide Full Access mode.
                if response == .approveForSession, request.kind != .dynamic {
                    let thread = self.threads.first { $0.id == threadId }
                    let snapshot = thread.flatMap { thread in
                        self.providerSnapshots.first { $0.id == thread.providerInstanceId }
                            ?? self.providerSnapshots.first { $0.provider == thread.provider }
                    }
                    let supported = snapshot?.effectivePermissionModes
                        ?? AgentPermissionMode.allCases
                    if supported.contains(.fullAccess) {
                        self.setPermissionMode(.fullAccess, for: threadId)
                    }
                }
                // The async response belongs to the card's origin thread. A user
                // can switch threads while it is in flight; never resolve a same-id
                // callback in the newly selected thread's timeline.
                if self.selectedThreadId == threadId {
                    self.timeline.apply(.requestResolved(requestId: request.id, state: state))
                }
            } catch {
                // Always retain the stale diagnostic + clear the dead button, but
                // only surface this error message if it is still the most recent
                // callback action (no newer action stomped it via a sync write).
                if self.selectedThreadId == threadId {
                    if issuedSeq == self.callbackActionSeq {
                        self.timeline.apply(.error(message: "Provider request response failed: \(error)", recoverable: true))
                        self.lastErrorRecoverable = false
                    }
                    self.timeline.apply(.requestResolved(requestId: request.id, state: .stale))
                }
            }
            self.scheduleTimelineUpdateTick()
        }
    }

    public func answerPendingUserInput(_ request: AssistantUserInputRequest, answer: String) {
        guard request.state == .pending else { return }
        guard let threadId = selectedThreadId else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Newest callback action -- see respondToPendingRequest: bumping this seq
        // stops an in-flight async approval failure from overwriting this (more
        // recent) user-input error, preserving most-recent-action-wins ordering.
        clearVisibleErrorForNewUserMessage()
        callbackActionSeq &+= 1
        let stateKey = userInputStateKey(request, threadId: threadId)
        userInputSelections[stateKey] = nil
        userInputDrafts[stateKey] = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.coordinator.respondToUserInput(threadId: threadId, requestId: request.id, text: trimmed)
                if self.selectedThreadId == threadId {
                    self.timeline.apply(.userInputResolved(requestId: request.id, answer: trimmed))
                }
            } catch {
                if self.selectedThreadId == threadId {
                    self.timeline.apply(.error(message: "Provider user-input response failed: \(error)", recoverable: true))
                    if let idx = self.timeline.pendingUserInputs.firstIndex(where: { $0.id == request.id }) {
                        self.timeline.pendingUserInputs[idx].state = .stale
                        self.timeline.pendingUserInputs[idx].resolvedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                    }
                    // Response-failure, not a prompt failure — no prompt Retry offered.
                    self.lastErrorRecoverable = false
                }
            }
            self.scheduleTimelineUpdateTick()
        }
    }

    public func cancelPendingUserInput(_ request: AssistantUserInputRequest) {
        guard request.state == .pending else { return }
        if let snapshot = selectedProviderSnapshot,
           !snapshot.effectiveCapabilities.supportsUserInput {
            statusMessage = "\(providerDisplayName(provider)) does not support interactive questions for this session."
            return
        }
        guard let threadId = selectedThreadId else { return }
        clearVisibleErrorForNewUserMessage()
        callbackActionSeq &+= 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.coordinator.cancelUserInput(threadId: threadId, requestId: request.id)
                if self.selectedThreadId == threadId {
                    self.timeline.apply(.userInputResolved(requestId: request.id, answer: nil))
                }
            } catch {
                if self.selectedThreadId == threadId {
                    self.timeline.apply(.error(message: "Provider user-input cancellation failed: \(error)", recoverable: true))
                    if let index = self.timeline.pendingUserInputs.firstIndex(where: { $0.id == request.id }) {
                        self.timeline.pendingUserInputs[index].state = .stale
                        self.timeline.pendingUserInputs[index].resolvedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                    }
                    self.lastErrorRecoverable = false
                }
            }
            self.scheduleTimelineUpdateTick()
        }
    }

    public func toggleUserInputOption(_ option: String, for request: AssistantUserInputRequest) {
        let key = userInputStateKey(request)
        var selection = userInputSelections[key] ?? []
        if selection.contains(option) { selection.remove(option) }
        else { selection.insert(option) }
        userInputSelections[key] = selection
    }

    public func selectedUserInputAnswer(for request: AssistantUserInputRequest) -> String {
        (userInputSelections[userInputStateKey(request)] ?? [])
            .filter { request.options.contains($0) }
            .sorted()
            .joined(separator: "\n")
    }

    /// AG-043: provider request ids are only unique inside one thread. All local
    /// draft and selection state therefore uses the callback's owning thread plus
    /// request id, preventing same-id cards in A/B from sharing user input.
    public func userInputStateKey(
        _ request: AssistantUserInputRequest,
        threadId: AgentThreadID? = nil
    ) -> String {
        let owner = threadId ?? selectedThreadId
        let ownerDescription = owner?.value.uuidString ?? "unbound"
        return "\(ownerDescription)\u{1}\(request.id)"
    }

    // MARK: Structured AskUserQuestion cards
    //
    // A structured request carries one or more questions, each with its own
    // options and single/multi-select mode. Selections and the per-question "Other"
    // freeform draft are keyed by (request, question) so multiple questions on one
    // card stay independent. Submitting builds one `{question text: answer}` map and
    // resolves the provider callback once — the Claude SDK expects answers keyed by
    // the question text, with multi-select answers comma-joined.
    public func askUserQuestionKey(_ request: AssistantUserInputRequest, _ question: AssistantUserInputQuestion) -> String {
        "\(userInputStateKey(request))\u{1}\(question.id)"
    }

    public func askUserQuestionOptionIsSelected(_ option: String, question: AssistantUserInputQuestion, request: AssistantUserInputRequest) -> Bool {
        userInputSelections[askUserQuestionKey(request, question)]?.contains(option) == true
    }

    public func selectAskUserQuestionOption(_ option: String, question: AssistantUserInputQuestion, request: AssistantUserInputRequest) {
        let key = askUserQuestionKey(request, question)
        var selection = userInputSelections[key] ?? []
        if question.allowsMultipleSelection {
            if selection.contains(option) { selection.remove(option) } else { selection.insert(option) }
        } else {
            selection = selection.contains(option) ? [] : [option]
        }
        userInputSelections[key] = selection
        // Options and the freeform "Other" field are mutually exclusive: interacting
        // with options always drops any "Other" text so a stale draft can't survive a
        // toggle-off and make the question look answered with old text.
        userInputDrafts[key] = nil
    }

    /// Sets the per-question freeform "Other" text. Editing the Other field claims the
    /// (exclusive) selection, so it clears any option selection — mirroring
    /// `selectAskUserQuestionOption`, which clears the draft unconditionally. Clearing
    /// is unconditional (not gated on non-empty text) so the option radio and the Other
    /// radio can never both read as selected, even for whitespace-only text that later
    /// trims empty.
    public func setAskUserQuestionOther(_ text: String, question: AssistantUserInputQuestion, request: AssistantUserInputRequest) {
        let key = askUserQuestionKey(request, question)
        userInputDrafts[key] = text
        userInputSelections[key] = nil
    }

    /// Whether "Other" is the active choice for the question — true once its radio
    /// has been picked or any text typed, even before the text is non-empty, so the
    /// Other radio can render filled and the option radios empty. A present draft
    /// (including an empty one) is the marker; `selectAskUserQuestionOption` clears it.
    public func askUserQuestionOtherIsSelected(question: AssistantUserInputQuestion, request: AssistantUserInputRequest) -> Bool {
        userInputDrafts[askUserQuestionKey(request, question)] != nil
    }

    /// Toggles the per-question "Other" radio. Selecting Other makes it the single
    /// choice (clearing any option selection); clicking it again clears Other, mirroring
    /// how the listed options toggle off. An empty Other selection stays unsubmittable
    /// until the user types text (see `askUserQuestionAnswer`).
    public func selectAskUserQuestionOther(question: AssistantUserInputQuestion, request: AssistantUserInputRequest) {
        let key = askUserQuestionKey(request, question)
        if userInputDrafts[key] != nil {
            userInputDrafts[key] = nil
        } else {
            userInputDrafts[key] = ""
            userInputSelections[key] = nil
        }
    }

    /// The answer for one question: a non-empty freeform "Other" draft wins,
    /// otherwise the selected option label(s) (comma-joined for multi-select).
    /// `nil` when the question is unanswered.
    public func askUserQuestionAnswer(for question: AssistantUserInputQuestion, in request: AssistantUserInputRequest) -> String? {
        let key = askUserQuestionKey(request, question)
        let draft = (userInputDrafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty { return draft }
        let labels = Set(question.options.map(\.label))
        let selected = (userInputSelections[key] ?? [])
            .filter { labels.contains($0) }
            .sorted()
        guard !selected.isEmpty else { return nil }
        return selected.joined(separator: ", ")
    }

    public func askUserQuestionIsComplete(_ request: AssistantUserInputRequest) -> Bool {
        !request.questions.isEmpty && request.questions.allSatisfy { askUserQuestionAnswer(for: $0, in: request) != nil }
    }

    public func submitAskUserQuestion(_ request: AssistantUserInputRequest) {
        guard askUserQuestionIsComplete(request) else { return }
        var answers: [String: String] = [:]
        for question in request.questions {
            if let answer = askUserQuestionAnswer(for: question, in: request) {
                answers[question.prompt] = answer
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        for question in request.questions {
            let key = askUserQuestionKey(request, question)
            userInputSelections[key] = nil
            userInputDrafts[key] = nil
        }
        answerPendingUserInput(request, answer: json)
    }

    public func loadModels() async {
        modelListLoading = true
        // F35: progress is signalled by `modelListLoading` alone. Reusing the
        // error-styled status message rendered a red duplicate "Loading
        // models..." plus a Retry row while the fetch was still in flight.
        modelListStatusMessage = nil
        defer { modelListLoading = false }
        do {
            let m: [AgentModelDescriptor]
            let isFallback: Bool
            if let modelListLoader {
                m = try await modelListLoader(provider)
                isFallback = false
            } else if provider == .claude {
                let result = await ClaudeRunner().listModelsResult()
                m = result.models
                isFallback = result.isFallback
            } else if provider == .grok {
                let launchConfig = providerLaunchConfig?(provider, providerInstanceId)
                let result = await GrokACPAdapter(
                    binaryNameOverride: launchConfig?.binary,
                    discoveryCwd: cwd,
                    discoveryEnvironment: launchConfig?.environment ?? [:]
                ).listModelsResult()
                m = result.models
                isFallback = result.isFallback
            } else {
                // F33: this is CodexRunner's baked-in list, not live discovery
                // (live codex models arrive via the provider-snapshot path), so
                // flag it as a fallback instead of presenting it as live.
                m = await CodexRunner().listModels()
                isFallback = true
            }
            await MainActor.run {
                self.availableModels = m
                self.availableModelsAreFallback = isFallback
                self.modelListStatusMessage = m.isEmpty ? "No models returned for \(self.providerDisplayName(self.provider)). Retry from the model menu." : nil
                // B8: a provider switch must leave a model valid for that
                // provider — never a stale id from the other provider.
                // F8: validate against the union of this fetch and the list
                // the picker actually displays (snapshot rows win), and never
                // rewrite a pinned model against a fallback list — built-in
                // defaults are no evidence the model is gone. Empty or
                // provably other-provider selections still reset (B8).
                if !self.modelSelectionIsValid(self.model, in: m + self.modelOptionsForSelectedProvider) {
                    if !isFallback || self.model.isEmpty || self.modelIsFromAnotherProvider(self.model) {
                        self.model = m.first?.id ?? self.model
                    }
                }
                self.normalizeSelectedModelOptions()
            }
        } catch {
            await MainActor.run {
                self.modelListStatusMessage = "Model list failed. Retry from the model menu."
                self.availableModelsAreFallback = false
            }
        }
    }

    public func loadProviderSnapshots(forceCatalogRefresh: Bool = false) async {
        providerSnapshotLoadCount += 1
        providerSnapshotsLoading = true
        defer {
            providerSnapshotLoadCount = max(0, providerSnapshotLoadCount - 1)
            providerSnapshotsLoading = providerSnapshotLoadCount > 0
        }
        // Capture MainActor-only inputs, then verify provenance off the main
        // actor so Process/URLSession catalog probes cannot beachball send().
        let launchConfig = providerLaunchConfig
        let cwdSnapshot = cwd
        do {
            let loadedSnapshots: [AgentProviderSnapshot]
            if let providerSnapshotLoader {
                loadedSnapshots = try await providerSnapshotLoader()
            } else {
                loadedSnapshots = await Self.localFallbackProviderSnapshots()
            }
            let snapshots = await Self.snapshotsWithVerifiedCatalogProvenance(
                loadedSnapshots,
                cwd: cwdSnapshot,
                launchConfig: launchConfig,
                forceRefresh: forceCatalogRefresh
            )
            self.providerSnapshotStatusMessage = nil
            self.applyProviderSnapshots(snapshots)
            self.providerSnapshotsLoadedAt = Date()
        } catch {
            // Fail open for composer usability: keep a resolved binary fallback so
            // send is not stuck on missingSnapshot after a transient probe failure.
            let fallback = await Self.localFallbackProviderSnapshots()
            self.providerSnapshotStatusMessage = "Provider snapshot failed. Retry from the model menu."
            if self.providerSnapshots.isEmpty {
                self.applyProviderSnapshots(fallback)
            }
        }
    }

    /// True when a successful snapshot load finished inside the catalog TTL.
    /// Send and Auto-admit use this so a fresh cache is not re-probed per message.
    private var providerSnapshotsAreFresh: Bool {
        !ModelListTTLDecision.shouldRefetch(
            lastFetchedAt: providerSnapshotsLoadedAt,
            ttl: ModelListTTLDecision.defaultCatalogTTL,
            now: Date()
        )
    }

    private func applyProviderSnapshots(_ snapshots: [AgentProviderSnapshot]) {
        providerSnapshots = snapshots
        let previousProvider = provider
        let previousInstanceId = providerInstanceId
        // No provider is mandatory. Default is Codex for historical reasons,
        // but a missing Codex CLI must not trap the empty Agent App: rebind to
        // the first runnable Claude/Grok (or other) snapshot when unlocked.
        // After the first real message the source stays fixed (providerLocked).
        // Explicit Source picks (sourceSelectionUserPinned) stay sticky so the
        // user can inspect recovery on an unrunnable row without thrash.
        if !providerLocked {
            if sourceSelectionUserPinned {
                if snapshots.first(where: { $0.id == providerInstanceId }) == nil {
                    providerInstanceId = snapshots.first(where: { $0.provider == provider && $0.enabled })?.id
                        ?? snapshots.first(where: { $0.provider == provider })?.id
                        ?? providerInstanceId
                }
            } else if let preferred = AgentProviderRunnableSelection.resolve(
                snapshots: snapshots,
                preferredProvider: provider,
                preferredInstanceId: providerInstanceId
            ) {
                providerInstanceId = preferred.id
                provider = preferred.provider
            } else if snapshots.first(where: { $0.id == providerInstanceId }) == nil {
                providerInstanceId = snapshots.first(where: { $0.provider == provider && $0.enabled })?.id
                    ?? snapshots.first(where: { $0.provider == provider })?.id
                    ?? snapshots.first(where: \.enabled)?.id
                    ?? snapshots.first?.id
                    ?? provider.rawValue
            }
        } else if snapshots.first(where: { $0.id == providerInstanceId }) == nil {
            // Locked thread: still map stale ids ("codex" → "codex-cli").
            providerInstanceId = snapshots.first(where: { $0.provider == provider && $0.enabled })?.id
                ?? snapshots.first(where: { $0.provider == provider })?.id
                ?? snapshots.first(where: \.enabled)?.id
                ?? snapshots.first?.id
                ?? provider.rawValue
        }
        if let current = selectedProviderSnapshot {
            providerInstanceId = current.id
            provider = current.provider
            // F10/F33: keep the fallback flag coherent when snapshot rows
            // replace the VM's own fetch — a snapshot bringing a different
            // list is live discovery, so the warning must clear; an identical
            // list means the fallback was substituted again.
            if current.modelDiscoverySource != nil {
                availableModelsAreFallback = current.modelListIsFallback
            } else if availableModelsAreFallback {
                availableModelsAreFallback = current.models.map(\.id) == availableModels.map(\.id)
            }
            availableModels = current.models
            let sourceChanged = current.provider != previousProvider
                || current.id != previousInstanceId
            if sourceChanged {
                // SC-ux-1: auto-rebind must reset model like setProvider — do not
                // keep a Codex id (e.g. gpt-5.6-sol) after switching to Claude.
                applyPreferredModelForCurrentProvider(availableModels: current.models)
            } else if !modelSelectionIsValid(model, in: current.models) {
                // F9: never silently swap a pinned model for the snapshot's
                // first alias — a fallback snapshot may simply omit a
                // live-discovered model. Fill only an empty selection (post
                // provider switch) or evict an id from another provider; a
                // kept-but-missing pin is explained by
                // selectedModelUnavailableNotice in the picker.
                if model.isEmpty || modelIsFromAnotherProvider(model) {
                    applyPreferredModelForCurrentProvider(availableModels: current.models)
                }
            }
            normalizeSelectedModelOptions()
            normalizeInteractionModeForSelectedProvider()
        }
    }

    private func normalizeInteractionModeForSelectedProvider() {
        if interactionMode == .plan, !supportsPlanInteractionForSelectedProvider {
            interactionMode = .default
        }
        if !supportedPermissionModesForSelectedProvider.contains(permissionMode) {
            permissionMode = supportedPermissionModesForSelectedProvider.first ?? .supervised
        }
    }

    /// F11: the picker's rows come from provider snapshots, so an explicit
    /// "Refresh model list" must reload the snapshots too (`loadModels` alone
    /// only rewrites `availableModels`, which the picker ignores while
    /// snapshot rows exist) and must bypass the 1h discovery TTL — otherwise
    /// a refresh within the TTL just serves the cached list back.
    public func refreshModelList() async {
        if provider == .claude {
            _ = await AnthropicModelDiscovery.refresh()
        }
        await loadProviderSnapshots(forceCatalogRefresh: true)
        await loadModels()
    }

    public func refreshProviderSnapshotsInBackground() {
        seedProviderSnapshotsForStartup()
        // F10: the snapshot pipeline discards the live/fallback signal, so the
        // "built-in defaults" warning never appeared on the startup path; run
        // the VM's own model fetch alongside to populate the fallback flag.
        Task {
            await loadProviderSnapshots()
            await loadModels()
        }
    }

    private func seedProviderSnapshotsForStartup() {
        guard providerSnapshots.isEmpty else { return }
        Task {
            let fallback = await Self.localFallbackProviderSnapshots()
            await MainActor.run {
                guard self.providerSnapshots.isEmpty else { return }
                self.applyProviderSnapshots(fallback)
            }
        }
    }

    /// Local, process-locator-backed rows used for startup and load-failure
    /// recovery. Prefer real binary paths so Grok/Codex are not marked
    /// unavailable solely because seed used an empty path.
    nonisolated public static func localFallbackProviderSnapshots() async -> [AgentProviderSnapshot] {
        var rows: [AgentProviderSnapshot] = []
        for provider in AgentProvider.allCases {
            let models: [AgentModelDescriptor]
            switch provider {
            case .codex:
                models = await CodexRunner().listModels()
            case .claude:
                models = ClaudeRunner.listModels(installedVersion: nil)
            case .grok:
                models = GrokRunner.listModels(installedVersion: nil)
            }
            rows.append(AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: models,
                binaryPath: ProcessLocator.resolve(provider.rawValue) ?? "",
                modelDiscoverySource: .builtInFallback
            ))
        }
        return rows
    }

    /// Live catalog verification for untagged claude/codex rows. `nonisolated`
    /// so Process/URLSession probes never run under `AgentAppViewModel`'s
    /// MainActor isolation (send-path beachball). Results are TTL-cached via
    /// `ModelListTTLDecision` so a second send within the window reuses the
    /// last live list instead of re-spawning CLI / network discovery.
    nonisolated static func snapshotsWithVerifiedCatalogProvenance(
        _ snapshots: [AgentProviderSnapshot],
        cwd: String,
        launchConfig: ((AgentProvider, String?) -> (binary: String?, environment: [String: String]))?,
        forceRefresh: Bool,
        now: Date = Date()
    ) async -> [AgentProviderSnapshot] {
        var resolved: [AgentProviderSnapshot] = []
        resolved.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            guard snapshot.modelDiscoverySource == nil,
                  snapshot.provider == .claude || snapshot.provider == .codex else {
                resolved.append(snapshot)
                continue
            }
            let launch = launchConfig?(snapshot.provider, snapshot.id)
            let binary = launch?.binary ?? snapshot.binaryPath ?? snapshot.provider.rawValue
            let environment = launch?.environment ?? [:]
            let cacheKey = CatalogVerificationCache.key(
                provider: snapshot.provider,
                binary: binary,
                cwd: cwd,
                environment: environment,
                instanceId: snapshot.id
            )
            let liveModels: [AgentModelDescriptor]
            if !forceRefresh,
               let cached = CatalogVerificationCache.shared.models(
                for: cacheKey,
                ttl: ModelListTTLDecision.defaultCatalogTTL,
                now: now
               ) {
                liveModels = cached
            } else {
                Self.catalogVerificationProbeCountForTesting &+= 1
                if let probe = Self.catalogVerificationLiveProbeForTesting {
                    liveModels = await probe(snapshot.provider, binary, environment, cwd)
                } else {
                    switch snapshot.provider {
                    case .claude:
                        let result = await ClaudeRunner(binaryNameOverride: binary)
                            .listModelsResult(environment: environment)
                        liveModels = result.isFallback ? [] : result.models
                    case .codex:
                        liveModels = await CodexAppServerModelDiscovery.listModels(
                            binary: binary,
                            cwd: cwd,
                            environment: environment
                        )
                    case .grok:
                        liveModels = []
                    }
                }
                // Cache live hits and empty failures alike so a flapping CLI
                // does not re-block the next send within the TTL.
                CatalogVerificationCache.shared.store(liveModels, for: cacheKey, at: now)
            }
            let capabilityVerified = snapshot.installed
                && snapshot.status == .available
                && snapshot.capabilities?.supportsStreaming == true
                && snapshot.binaryPath?.isEmpty == false
            let source = AgentProviderCatalogProvenance.resolvedSource(
                reportedSource: snapshot.modelDiscoverySource,
                liveCatalogVerified: !liveModels.isEmpty,
                streamingCapabilityVerified: capabilityVerified
            )
            resolved.append(Self.snapshot(
                snapshot,
                models: liveModels.isEmpty ? snapshot.models : liveModels,
                discoverySource: source
            ))
        }
        return resolved
    }

    /// Testing seam: increments once per live catalog verification probe
    /// (cache misses only). Used to prove send reuses a fresh TTL cache.
    nonisolated(unsafe) static var catalogVerificationProbeCountForTesting = 0
    /// Testing seam: optional live-probe override so hermetic tests never
    /// touch a real CLI or network during catalog verification.
    nonisolated(unsafe) static var catalogVerificationLiveProbeForTesting:
        (@Sendable (AgentProvider, String, [String: String], String) async -> [AgentModelDescriptor])?

    /// Process-wide TTL cache for untagged-snapshot catalog verification.
    private final class CatalogVerificationCache: @unchecked Sendable {
        static let shared = CatalogVerificationCache()
        private let lock = NSLock()
        private var entries: [String: (models: [AgentModelDescriptor], fetchedAt: Date)] = [:]

        static func key(
            provider: AgentProvider,
            binary: String,
            cwd: String,
            environment: [String: String],
            instanceId: String
        ) -> String {
            let envFingerprint = environment.keys.sorted().joined(separator: ",")
            return "\(provider.rawValue)|\(instanceId)|\(binary)|\(cwd)|\(envFingerprint)"
        }

        func models(for key: String, ttl: TimeInterval, now: Date) -> [AgentModelDescriptor]? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[key],
                  !ModelListTTLDecision.shouldRefetch(
                    lastFetchedAt: entry.fetchedAt,
                    ttl: ttl,
                    now: now
                  ) else {
                return nil
            }
            return entry.models
        }

        func store(_ models: [AgentModelDescriptor], for key: String, at date: Date) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = (models, date)
        }

        func resetForTesting() {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll()
        }
    }

    /// Test-only: clear the process-wide catalog verification cache.
    nonisolated static func resetCatalogVerificationCacheForTesting() {
        CatalogVerificationCache.shared.resetForTesting()
        catalogVerificationProbeCountForTesting = 0
        catalogVerificationLiveProbeForTesting = nil
    }

    nonisolated private static func snapshot(
        _ snapshot: AgentProviderSnapshot,
        models: [AgentModelDescriptor],
        discoverySource: AgentModelDiscoverySource
    ) -> AgentProviderSnapshot {
        AgentProviderSnapshot(
            id: snapshot.id,
            provider: snapshot.provider,
            driverKind: snapshot.driverKind,
            displayName: snapshot.displayName,
            accentColor: snapshot.accentColor,
            continuationGroup: snapshot.continuationGroup,
            interactionModes: snapshot.interactionModes,
            permissionModes: snapshot.permissionModes,
            enabled: snapshot.enabled,
            installed: snapshot.installed,
            version: snapshot.version,
            status: snapshot.status,
            statusDetail: snapshot.statusDetail,
            authenticated: snapshot.authenticated,
            accountLabel: snapshot.accountLabel,
            accountAuthMethod: snapshot.accountAuthMethod,
            binaryPath: snapshot.binaryPath,
            homePath: snapshot.homePath,
            environmentKeys: snapshot.environmentKeys,
            models: models,
            slashCommands: snapshot.slashCommands,
            skills: snapshot.skills,
            advisory: snapshot.advisory,
            updateState: snapshot.updateState,
            capabilities: snapshot.capabilities,
            modelDiscoverySource: discoverySource,
            modelDiscoveryCacheKey: snapshot.modelDiscoveryCacheKey
        )
    }

    public var selectedProviderSnapshot: AgentProviderSnapshot? {
        AgentProviderSnapshotSelection.resolve(
            snapshots: providerSnapshots,
            provider: provider,
            instanceId: providerInstanceId
        )
    }

    public var providerExecutionUnavailableReason: String? {
        Self.providerExecutionUnavailableReason(for: selectedProviderSnapshot)
    }

    public var selectedProviderCanRun: Bool {
        providerExecutionUnavailableReason == nil
    }

    nonisolated public static func providerExecutionUnavailableReason(
        for snapshot: AgentProviderSnapshot?
    ) -> String? {
        // Match iOS fail-closed: nil snapshot must not look runnable. The old
        // `return nil` here let send reach preflight and surface
        // "Provider capabilities are not loaded yet." only after the user tried.
        guard let snapshot else {
            return AgentProviderRunPreflightError.missingSnapshot.description
        }
        if !snapshot.enabled || snapshot.status == .disabled {
            return snapshot.statusDetail ?? "\(snapshot.displayName) is disabled."
        }
        if !snapshot.installed || snapshot.status == .unavailable {
            return snapshot.statusDetail ?? "\(snapshot.displayName) is unavailable."
        }
        if snapshot.authenticated == false {
            return "\(snapshot.displayName) is not authenticated. Sign in to continue."
        }
        return nil
    }

    public var selectedModelDescriptor: AgentModelDescriptor? {
        if let exact = modelOptionsForSelectedProvider.first(where: { $0.id == model }) {
            return exact
        }
        return model.isEmpty ? nil : modelOptionsForSelectedProvider.first { $0.supportsCustomModel }
    }

    public var modelOptionsForSelectedProvider: [AgentModelDescriptor] {
        let snapshot = selectedProviderSnapshot
        let optionProvider = snapshot?.provider ?? provider
        let snapshotModels = snapshot?.models.filter { $0.provider == optionProvider } ?? []
        if !snapshotModels.isEmpty { return snapshotModels }
        return availableModels.filter { $0.provider == optionProvider }
    }

    /// F9: a pinned model missing from the displayed list is kept, never
    /// silently rewritten to the first fallback alias. This notice tells the
    /// user why no picker row is highlighted (the pill's modelLabel already
    /// falls back to the raw id).
    public var selectedModelUnavailableNotice: String? {
        guard !model.isEmpty else { return nil }
        let options = modelOptionsForSelectedProvider
        guard !options.isEmpty else { return nil }
        guard !options.contains(where: { $0.id == model }) else { return nil }
        guard !(customModelsByProvider[provider] ?? []).contains(model) else { return nil }
        return "\(model) is not in the current model list"
    }

    /// F10/F33: `availableModelsAreFallback` describes the VM's own fetch, but
    /// the picker prefers snapshot rows. Only claim "built-in defaults" when
    /// the rows on screen match the flagged fetch, so a live snapshot list
    /// never carries a false fallback warning.
    public var displayedModelListIsFallback: Bool {
        guard availableModelsAreFallback else { return false }
        return modelOptionsForSelectedProvider.map(\.id)
            == availableModels.filter { $0.provider == provider }.map(\.id)
    }

    public var supportedReasoningEffortsForSelectedModel: [AgentReasoningEffort] {
        selectedModelDescriptor?.supportedReasoningEfforts ?? AgentReasoningEffort.supportedCases
    }

    public var supportsReasoningForSelectedModel: Bool {
        !supportedReasoningEffortsForSelectedModel.isEmpty
    }

    public var supportsServiceTierForSelectedModel: Bool {
        selectedModelDescriptor?.supportsServiceTier == true
    }

    public var supportsCustomModelForSelectedProvider: Bool {
        modelOptionsForSelectedProvider.contains { $0.supportsCustomModel }
    }

    public var customModelsForSelectedProvider: [String] {
        customModelsByProvider[provider] ?? []
    }

    public var selectedModelContextWindowLabel: String? {
        guard let tokens = selectedModelDescriptor?.contextWindowTokens, tokens > 0 else { return nil }
        if tokens >= 1_000_000, tokens % 1_000_000 == 0 { return "\(tokens / 1_000_000)M ctx" }
        if tokens >= 1_000, tokens % 1_000 == 0 { return "\(tokens / 1_000)k ctx" }
        return "\(tokens) ctx"
    }

    private func modelSelectionIsValid(_ model: String, in models: [AgentModelDescriptor]) -> Bool {
        guard !models.isEmpty else { return true }
        if models.contains(where: { $0.id == model && $0.provider == provider }) { return true }
        return !model.isEmpty
            && (customModelsByProvider[provider] ?? []).contains(model)
            && models.contains { $0.provider == provider && $0.supportsCustomModel }
    }

    /// B8 backstop shared by the F8/F9 keep-the-pin paths: an id that provably
    /// belongs to a different provider must never survive a provider switch,
    /// even when the current provider's list is only a fallback.
    private func modelIsFromAnotherProvider(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return providerSnapshots.contains { snapshot in
            snapshot.provider != provider && snapshot.models.contains { $0.id == id }
        }
    }

    public var currentModelSelection: AgentModelSelection {
        let exactDescriptor = modelOptionsForSelectedProvider.first { $0.id == model }
        let descriptor = selectedModelDescriptor
        let isCustom = exactDescriptor == nil && descriptor?.supportsCustomModel == true && !model.isEmpty
        return AgentModelSelection(
            provider: provider,
            modelId: isCustom ? (descriptor?.id ?? "") : model,
            customModelId: isCustom ? model : nil,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier
        )
    }

    public func normalizeSelectedModelOptions() {
        let efforts = supportedReasoningEffortsForSelectedModel
        if efforts.isEmpty {
            reasoningEffort = .medium
        } else if !efforts.contains(reasoningEffort) {
            // Prefer the model default when clamping (Grok 4.5 default is high;
            // otherwise keep the first advertised level).
            reasoningEffort = efforts.contains(.high) ? .high : (efforts.first ?? .medium)
        }
        if !supportsServiceTierForSelectedModel {
            serviceTier = .auto
        }
    }

    /// Cache of on-disk Claude skill/command names keyed by cwd, so the composer
    /// does not re-scan the filesystem on every keystroke. Refreshed lazily when
    /// the cwd changes.
    private var cachedClaudeSlashEntries: (cwd: String, entries: [String])?

    /// Project + user Claude skills/commands for the composer `/` menu. Empty for
    /// non-Claude providers (the discovery is `.claude`-directory specific).
    private func claudeProjectSlashEntries() -> [String] {
        guard selectedProviderSnapshot?.provider == .claude else { return [] }
        let cwd = self.cwd
        if let cached = cachedClaudeSlashEntries, cached.cwd == cwd { return cached.entries }
        let home = ProcessInfo.processInfo.environment["HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let entries = ClaudeSlashCommandDiscovery.discover(cwd: cwd, home: home)
        cachedClaudeSlashEntries = (cwd, entries)
        return entries
    }

    public var composerSuggestions: [AgentComposerSuggestion] {
        let isClaude = selectedProviderSnapshot?.provider == .claude
        return AgentComposerSuggestions.suggestions(
            for: prompt,
            cursorOffset: composerCursorOffset,
            snapshot: selectedProviderSnapshot,
            localSlashCommands: Self.localSlashCommands,
            extraCommands: isClaude ? ClaudeSlashCommandDiscovery.builtInClaudeCommands : [],
            extraSkillNames: isClaude ? claudeProjectSlashEntries() : []
        )
    }

    public func applyComposerSuggestion(_ suggestion: AgentComposerSuggestion) {
        prompt = AgentComposerSuggestions.replacingActiveToken(
            in: prompt,
            cursorOffset: composerCursorOffset,
            with: suggestion.insertText
        )
        promptHistoryCursor = nil
    }

    public func providerDisplayName(_ provider: AgentProvider) -> String {
        providerSnapshots.first { $0.provider == provider }?.displayName ?? provider.rawValue.capitalized
    }

    public func providerInstanceDisplayName(_ id: String) -> String {
        providerSnapshots.first { $0.id == id }?.displayName ?? id
    }

    public var providerStatusMessage: String? {
        guard let snapshot = selectedProviderSnapshot, snapshot.status != .available else { return nil }
        let message = snapshot.statusDetail ?? "\(snapshot.displayName) is \(snapshot.status.rawValue)."
        let signature = "\(snapshot.id)|\(snapshot.status.rawValue)|\(message)"
        return signature == dismissedProviderStatusSignature ? nil : message
    }

    public var providerAccountStatusMessage: String? {
        guard let snapshot = selectedProviderSnapshot,
              let summary = snapshot.accountSummary else { return nil }
        return "\(snapshot.displayName): \(summary)"
    }

    public var providerRecoveryActionTitle: String? {
        guard let snapshot = selectedProviderSnapshot else { return nil }
        if pendingSignInProvider == snapshot.provider,
           pendingSignInSnapshotID == snapshot.id,
           snapshot.authenticated == false {
            return AgentErrorRecoveryAction.retry.title
        }
        return Self.providerRecoveryActionTitle(for: snapshot)
    }

    public static func providerRecoveryActionTitle(for snapshot: AgentProviderSnapshot) -> String? {
        if snapshot.authenticated == false {
            return AgentErrorRecoveryAction.signIn.title
        }
        return snapshot.recoveryActionTitle
    }

    public func performProviderRecoveryAction() async {
        guard let snapshot = selectedProviderSnapshot,
              let title = providerRecoveryActionTitle else { return }
        if title == AgentErrorRecoveryAction.retry.title,
           pendingSignInProvider == snapshot.provider,
           pendingSignInSnapshotID == snapshot.id {
            _ = await refreshPendingProviderAuthentication(retryLastPromptWhenAuthenticated: false)
            return
        }
        if title.hasPrefix("Update") {
            guard let providerRecoveryAction else {
                providerRecoveryStatusMessage = "Update unavailable: app router is not ready."
                return
            }
            providerRecoveryActionRunning = true
            defer { providerRecoveryActionRunning = false }
            do {
                let stdout = try await providerRecoveryAction(snapshot.provider, snapshot.id)
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                providerRecoveryStatusMessage = stdout.isEmpty ? "Update completed." : stdout
                await loadProviderSnapshots()
            } catch {
                providerRecoveryStatusMessage = "Update failed: \(error)"
            }
            return
        }
        if snapshot.authenticated == false {
            providerRecoveryActionRunning = true
            defer { providerRecoveryActionRunning = false }
            beginProviderSignIn(provider: snapshot.provider, snapshotID: snapshot.id)
            return
        }
        let command: String
        switch snapshot.provider {
        case .codex:
            command = "npm install -g @openai/codex"
        case .claude:
            command = "npm install -g @anthropic-ai/claude-code"
        case .grok:
            command = "curl -fsSL https://x.ai/cli/install.sh | bash"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        providerRecoveryStatusMessage = "Copied: \(command)"
    }

    private func beginProviderSignIn(provider: AgentProvider, snapshotID: String?) {
        guard let providerSignInAction else {
            providerRecoveryStatusMessage = "Sign-in unavailable: app router is not ready."
            return
        }
        do {
            try providerSignInAction(provider)
            pendingSignInProvider = provider
            pendingSignInSnapshotID = snapshotID
            providerRecoveryStatusMessage = "Opened \(providerDisplayName(provider)) sign-in in Terminal. Complete sign-in there, then choose Retry."
        } catch {
            providerRecoveryStatusMessage = "Could not open sign-in Terminal: \(error)"
        }
    }

    @discardableResult
    private func refreshPendingProviderAuthentication(
        retryLastPromptWhenAuthenticated: Bool
    ) async -> Bool {
        guard let pendingSignInProvider else { return false }
        let snapshots: [AgentProviderSnapshot]
        if let providerAuthenticationRefresher {
            snapshots = await providerAuthenticationRefresher(pendingSignInProvider)
        } else if let providerSnapshotLoader {
            do {
                snapshots = try await providerSnapshotLoader()
            } catch {
                providerRecoveryStatusMessage = "Could not refresh authentication status: \(error)"
                return false
            }
        } else {
            await loadProviderSnapshots()
            snapshots = providerSnapshots
        }
        guard !snapshots.isEmpty else {
            providerRecoveryStatusMessage = "Could not refresh authentication status. Choose Retry to try again."
            return false
        }
        applyProviderSnapshots(snapshots)
        let refreshed = snapshots.first {
            if let pendingSignInSnapshotID {
                return $0.id == pendingSignInSnapshotID
            }
            return $0.provider == pendingSignInProvider
        }
        guard refreshed?.authenticated == true else {
            providerRecoveryStatusMessage = "Sign-in is not confirmed yet. Complete it in Terminal, then choose Retry."
            return false
        }
        self.pendingSignInProvider = nil
        pendingSignInSnapshotID = nil
        providerRecoveryStatusMessage = retryLastPromptWhenAuthenticated
            ? "Authentication confirmed. Retrying the request."
            : "Authentication confirmed. Retry your request when ready."
        if retryLastPromptWhenAuthenticated {
            await retryLastPrompt()
        }
        return true
    }

    public var contextHealthMessage: String? {
        AgentContextStatusPresentation.message(
            usage: timeline.tokenUsage,
            compactionSummary: timeline.contextCompactionSummary
        )
    }

    /// A1: the provider (source) is fixed once the thread has a real
    /// conversation — only model/effort stay changeable after that.
    /// P3: system notes (from /status, /clear, etc.) must not count as
    /// "a conversation started", otherwise the source locks after the very
    /// first /status call before any user turn.
    public var providerLocked: Bool {
        selectedThreadId != nil && messages.contains { $0.role != .system }
    }
    public var selectedThreadRunIsStartingOrRunning: Bool {
        selectedThreadId.map(isThreadStartingOrRunning) ?? false
    }

    /// True only while the selected thread is still assembling its turn and no
    /// run is tracked yet. Deliberately yields to the running state so the two
    /// status lines can never both render.
    public var selectedThreadIsPreparingRun: Bool {
        guard let preparingRunThreadId, preparingRunThreadId == selectedThreadId else { return false }
        return !selectedThreadRunIsStartingOrRunning
    }

    /// A fresh thread also uses `.pending` as its persisted idle state. A Stop
    /// affordance therefore needs a run identity, not status alone; otherwise a
    /// never-started thread is rendered as busy and its first prompt is queued.
    public func isThreadStartingOrRunning(_ threadId: AgentThreadID) -> Bool {
        if trackedRunId(for: threadId) != nil { return true }
        // LaunchAgent-owned scheduled runs have no local coordinator session.
        return isScheduledThreadRunning?(threadId) == true
    }

    private func trackedRunId(for threadId: AgentThreadID) -> AgentRunID? {
        runThreads.first(where: { $0.value == threadId })?.key
            ?? coordinator.activeRunId(threadId: threadId)
    }

    // MARK: - Path B (LaunchAgent-owned scheduled run) UI binding

    /// Poll while the selected thread is owned by the LaunchAgent so stream
    /// events written to shared SQLite keep painting without a local coordinator.
    private var scheduledLivePollTask: Task<Void, Never>?
    private var scheduledLiveStreamCount: Int = 0

    /// Seed Working-for clock + run id from durable agent_runs and start live poll.
    private func bindScheduledOwnedRun(threadId: AgentThreadID) {
        let durable = try? coordinator.durableActiveRun(threadId: threadId)
        runStartedAt = AgentAppViewModel.resolvedRunStartedAt(
            current: runStartedAt,
            persisted: durable?.startedAt ?? (try? coordinator.runStartedAt(threadId: threadId))
        )
        if let durable {
            currentRunId = durable.id
            runThreads[durable.id] = threadId
            if status != .running { status = .running }
        }
        ensureScheduledLivePoll(for: threadId)
    }

    private func ensureScheduledLivePoll(for threadId: AgentThreadID) {
        guard scheduledLivePollTask == nil else { return }
        scheduledLiveStreamCount = coordinator.latestStreamEvents(threadId: threadId).count
        scheduledLivePollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // 2s is enough for LaunchAgent-owned progress; 1s doubled MainActor work.
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, !self.isDisposed else { return }
                self.tickScheduledLivePoll()
            }
        }
    }

    private func stopScheduledLivePoll() {
        scheduledLivePollTask?.cancel()
        scheduledLivePollTask = nil
        scheduledLiveStreamCount = 0
    }

    private func tickScheduledLivePoll() {
        guard let id = selectedThreadId else {
            stopScheduledLivePoll()
            return
        }
        guard isScheduledThreadRunning?(id) == true else {
            // Run finished in the LaunchAgent; one full rebind picks up terminal state.
            stopScheduledLivePoll()
            selectThread(id, markRead: false)
            return
        }
        let events = coordinator.latestStreamEvents(threadId: id)
        if events.count != scheduledLiveStreamCount {
            scheduledLiveStreamCount = events.count
            timeline = AssistantTimelineState()
            for event in events {
                timeline.apply(event)
            }
            timeline.enforceAggregateHotTextBudget()
            rehydrateDurableActiveState(threadId: id)
            timelineItemIndex = TimelineItemIndex(turns: timeline.turns)
            scheduleTimelineUpdateTick()
        }
        if let durable = try? coordinator.durableActiveRun(threadId: id) {
            runStartedAt = AgentAppViewModel.resolvedRunStartedAt(
                current: runStartedAt,
                persisted: durable.startedAt
            )
            currentRunId = durable.id
            runThreads[durable.id] = id
            if status != .running { status = .running }
        }
    }

    public var executionLocked: Bool { providerLocked || selectedThreadRunIsStartingOrRunning }
    public var activeRunConfigurationLocked: Bool {
        selectedThreadRunIsStartingOrRunning
            || selectedThreadId.map { coordinator.activeThreadIdsSnapshot().contains($0) } == true
            || selectedThreadId.map { coordinator.hasProviderSession(threadId: $0) } == true
    }

    public func setProviderInstance(_ id: String) {
        guard !executionLocked else { return }
        guard let snapshot = providerSnapshots.first(where: { $0.id == id }) else { return }
        sourceSelectionUserPinned = true
        providerInstanceId = snapshot.id
        provider = snapshot.provider
        // F10/F33: same flag coherence as applyProviderSnapshots — snapshot
        // rows replace the VM's own fetch, so a stale fallback flag must not
        // put a false "built-in defaults" warning on the new instance's list.
        if availableModelsAreFallback {
            availableModelsAreFallback = snapshot.models.map(\.id) == availableModels.map(\.id)
        }
        availableModels = snapshot.models
        applyPreferredModelForCurrentProvider(availableModels: snapshot.models)
        normalizeSelectedModelOptions()
        normalizeInteractionModeForSelectedProvider()
        persistThreadConfig()
    }

    public func setProvider(_ newProvider: AgentProvider) {
        guard !executionLocked else { return }
        if let selectedThreadId { persistComposerDraft(for: selectedThreadId) }
        sourceSelectionUserPinned = true
        provider = newProvider
        // Prefer a real snapshot id when snapshots are loaded so Source stays
        // checkmarked after a Source switch (ids are "codex-cli", not "codex").
        if let snap = providerSnapshots.first(where: { $0.provider == newProvider && $0.enabled })
            ?? providerSnapshots.first(where: { $0.provider == newProvider }) {
            providerInstanceId = snap.id
            if snap.modelDiscoverySource != nil {
                availableModelsAreFallback = snap.modelListIsFallback
            } else if availableModelsAreFallback {
                availableModelsAreFallback = snap.models.map(\.id) == availableModels.map(\.id)
            }
            availableModels = snap.models
            applyPreferredModelForCurrentProvider(availableModels: snap.models)
        } else {
            providerInstanceId = newProvider.rawValue
            availableModels = []
            applyPreferredModelForCurrentProvider(availableModels: [])
        }
        if let selectedThreadId {
            restoreComposerDraft(
                threadId: selectedThreadId,
                providerInstanceId: providerInstanceId,
                fallbackInteractionMode: .default
            )
        }
        normalizeSelectedModelOptions()
        normalizeInteractionModeForSelectedProvider()
        persistThreadConfig()
    }

    /// Persist the chosen run configuration onto the selected thread so a
    /// resumed run uses the right source, model, permission, and effort.
    @discardableResult
    public func persistThreadConfig() -> Bool {
        normalizeSelectedModelOptions()
        rememberNewThreadDefaults()
        guard let id = selectedThreadId else { return false }
        do {
            guard let stored = try threadRepo.get(id: id) else {
                statusMessage = "Could not save thread configuration: thread not found."
                return false
            }
            var updated = stored
            updated.provider = provider
            updated.providerInstanceId = providerInstanceId
            updated.runAsUser = runAsUser
            updated.model = model
            updated.permissionMode = permissionMode
            updated.reasoningEffort = reasoningEffort
            updated.serviceTier = serviceTier
            updated.modelSelection = currentModelSelection
            updated.interactionMode = interactionMode
            updated.updatedAt = Date()
            let routing = stored.effectiveRoutingConfiguration
            updated.routingConfiguration = try routing.replacing(
                expectedRevision: routing.revision,
                mode: routing.mode,
                manualSelection: currentModelSelection,
                manualProviderInstanceId: providerInstanceId,
                eligibleProviders: routing.eligibleProviders,
                policyDigest: routing.policyDigest,
                updatedAt: updated.updatedAt
            )
            try threadRepo.upsert(updated)
            if let i = threads.firstIndex(where: { $0.id == id }) {
                threads[i] = updated
            }
            persistComposerDraft(for: id)
            onThreadConfigPersisted?(updated)
            return true
        } catch {
            if let stored = try? threadRepo.get(id: id) { restoreThreadConfiguration(from: stored) }
            statusMessage = "Could not save thread configuration: \(error)"
            return false
        }
    }

    /// Changes the thread-owned routing mode with optimistic revision protection.
    /// Auto never overwrites the manual picker values; disabling it restores the
    /// exact provider/model/effort/tier captured when Auto was enabled.
    @discardableResult
    public func setAutoModelRoutingEnabled(_ enabled: Bool) -> Bool {
        guard let id = selectedThreadId else {
            routingMode = enabled ? .auto : .manual
            rememberNewThreadDefaults()
            statusMessage = ""
            return true
        }
        do {
            guard let stored = try threadRepo.get(id: id) else {
                statusMessage = "Could not save Auto model routing: thread not found."
                return false
            }
            let current = stored.effectiveRoutingConfiguration
            let requestedMode: AgentRoutingMode = enabled ? .auto : .manual
            guard current.mode != requestedMode else { return true }

            let updatedConfiguration: AgentRoutingConfiguration
            if enabled {
                updatedConfiguration = try orchestrationRuntime.autoConfiguration(
                    replacing: current,
                    expectedRevision: current.revision,
                    manualSelection: currentModelSelection,
                    manualProviderInstanceId: providerInstanceId,
                    providerSnapshots: providerSnapshots
                )
            } else {
                updatedConfiguration = try orchestrationRuntime.manualConfiguration(
                    replacing: current,
                    expectedRevision: current.revision
                )
            }
            try threadRepo.setRoutingConfiguration(
                updatedConfiguration,
                threadId: id,
                expectedRevision: current.revision
            )
            guard let persisted = try threadRepo.get(id: id) else {
                statusMessage = "Could not restore the persisted routing configuration."
                return false
            }
            routingMode = updatedConfiguration.mode
            rememberNewThreadDefaults()
            if !enabled {
                restoreThreadConfiguration(from: persisted)
            } else if let index = threads.firstIndex(where: { $0.id == id }) {
                threads[index] = persisted
            }
            statusMessage = ""
            onThreadConfigPersisted?(persisted)
            return true
        } catch {
            if let latest = try? threadRepo.get(id: id) {
                restoreThreadConfiguration(from: latest)
            }
            statusMessage = "Could not save Auto model routing: \(error)"
            return false
        }
    }

    private func restoreThreadConfiguration(from thread: AgentThread) {
        let routing = thread.effectiveRoutingConfiguration
        routingMode = routing.mode
        provider = routing.manualSelection.provider
        providerInstanceId = routing.manualProviderInstanceId ?? routing.manualSelection.provider.rawValue
        runAsUser = thread.runAsUser ?? AgentRunAsUser.current()
        model = routing.manualSelection.effectiveModel
        permissionMode = thread.permissionMode
        reasoningEffort = routing.manualSelection.reasoningEffort
        serviceTier = routing.manualSelection.serviceTier
        interactionMode = thread.effectiveInteractionMode
        normalizeInteractionModeForSelectedProvider()
        if let i = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[i] = thread
        }
    }

    /// Select the macOS account that will execute provider processes (sudo -u).
    /// Locked after the first real conversation message, same as provider source.
    public func setRunAsUser(_ user: AgentRunAsUser) {
        guard !providerLocked else { return }
        guard !selectedThreadRunIsStartingOrRunning else { return }
        // Re-resolve against the live directory so deleted/recreated accounts fail closed.
        if let live = MacOSLocalUserCatalog.resolve(shortName: user.shortName) {
            runAsUser = live
        } else {
            runAsUser = user
        }
        persistThreadConfig()
        // Binary/auth probes are runAsUser-aware — refresh so Auto admits the
        // account that will actually exec (not the previous user's snapshot).
        Task { await loadProviderSnapshots() }
    }

    public func refreshAvailableRunAsUsers() {
        availableRunAsUsers = MacOSLocalUserCatalog.listEligibleUsers()
        if let selected = runAsUser,
           let live = MacOSLocalUserCatalog.resolve(shortName: selected.shortName) {
            runAsUser = live
        } else if runAsUser == nil {
            runAsUser = AgentRunAsUser.current()
        }
    }

    public func setPermissionMode(_ mode: AgentPermissionMode) {
        guard !activeRunConfigurationLocked else { return }
        guard supportedPermissionModesForSelectedProvider.contains(mode) else {
            statusMessage = permissionModeUnavailableReason(mode) ?? "Permission mode is unavailable for this session."
            return
        }
        permissionMode = mode
        persistThreadConfig()
        if mode == .fullAccess {
            scheduleFullAccessPlanAutoImplementIfNeeded()
        }
    }

    /// Persist an async callback's permission escalation against the thread that
    /// owned the card, not whichever thread is selected when the await returns.
    private func setPermissionMode(_ mode: AgentPermissionMode, for threadId: AgentThreadID) {
        do {
            guard var thread = try threadRepo.get(id: threadId) else { return }
            thread.permissionMode = mode
            thread.updatedAt = Date()
            try threadRepo.upsert(thread)
            if let index = threads.firstIndex(where: { $0.id == threadId }) {
                threads[index].permissionMode = mode
            }
            if selectedThreadId == threadId {
                permissionMode = mode
            }
            onThreadConfigPersisted?(thread)
        } catch {
            statusMessage = "Could not save permission mode: \(error)"
        }
    }

    public func setReasoningEffort(_ effort: AgentReasoningEffort) {
        let efforts = supportedReasoningEffortsForSelectedModel
        reasoningEffort = efforts.isEmpty ? .medium : (efforts.contains(effort) ? effort : (efforts.first ?? .medium))
        persistThreadConfig()
    }

    public func setServiceTier(_ tier: AgentServiceTier) {
        serviceTier = supportsServiceTierForSelectedModel ? tier : .auto
        persistThreadConfig()
    }

    /// IMP-MAC_AGENT-006: cycle reasoning effort across the model's supported
    /// efforts (for the Cmd+Shift+. power-user shortcut). No-op when the model
    /// has no reasoning efforts. Returns the new effort for transient feedback.
    @discardableResult
    public func cycleReasoningEffort() -> AgentReasoningEffort? {
        let efforts = supportedReasoningEffortsForSelectedModel
        guard !efforts.isEmpty else { return nil }
        let index = efforts.firstIndex(of: reasoningEffort) ?? -1
        let next = efforts[(index + 1) % efforts.count]
        setReasoningEffort(next)
        return next
    }

    public func setExecutionMode(_ mode: AgentExecutionMode) {
        guard !executionLocked else { return }
        executionMode = mode
        if mode == .worktree, baseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            baseBranch = gitBranch ?? "main"
        }
        persistThreadExecutionConfig()
    }

    public func setBaseBranch(_ branch: String) {
        guard !executionLocked else { return }
        baseBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if executionMode == .worktree {
            persistThreadExecutionConfig()
        }
    }

    @discardableResult
    public func persistThreadExecutionConfig() -> Bool {
        guard let id = selectedThreadId else { return false }
        do {
            guard var thread = try threadRepo.get(id: id) else { return false }
            let branch = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            thread.executionMode = executionMode
            thread.baseBranch = executionMode == .worktree ? (branch.isEmpty ? (gitBranch ?? "main") : branch) : nil
            if executionMode == .local { thread.worktreePath = nil }
            thread.updatedAt = Date()
            try threadRepo.upsert(thread)
            if let i = threads.firstIndex(where: { $0.id == id }) {
                threads[i] = thread
            }
            return true
        } catch {
            if let stored = try? threadRepo.get(id: id) {
                executionMode = stored.executionMode
                baseBranch = stored.baseBranch ?? gitBranch ?? "main"
                worktreePath = stored.worktreePath
                if let i = threads.firstIndex(where: { $0.id == id }) { threads[i] = stored }
            }
            statusMessage = "Could not save thread execution settings: \(error)"
            return false
        }
    }

    public func setModel(_ model: String) {
        self.model = model
        rememberCurrentModel()
        normalizeSelectedModelOptions()
        persistThreadConfig()
    }

    public func setCustomModel(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportsCustomModelForSelectedProvider else { return }
        if !trimmed.isEmpty {
            customModelStore?.add(trimmed, provider: provider)
            var values = customModelsByProvider[provider] ?? []
            if !values.contains(trimmed) {
                values.append(trimmed)
                customModelsByProvider[provider] = values
            }
        }
        model = trimmed.isEmpty
            ? preferredModelForCurrentProvider(availableModels: modelOptionsForSelectedProvider)
            : trimmed
        rememberCurrentModel()
        normalizeSelectedModelOptions()
        persistThreadConfig()
    }

    public func createThread(title: String) {
        // New threads always reopen on the last model the user used for this
        // provider (not whatever model an older selected thread left on the VM).
        applyPreferredModelForCurrentProvider()
        normalizeSelectedModelOptions()
        // Auto admission requires revision > 0 and a current policy digest.
        // Leaving revision at the default 0 makes every first Auto send fail with
        // AgentOrchestrationAdmissionError.invalidPolicy (NSError code 4).
        let routingConfiguration = AgentRoutingConfiguration(
            mode: routingMode,
            manualSelection: currentModelSelection,
            manualProviderInstanceId: providerInstanceId,
            eligibleProviders: AgentProvider.allCases,
            policyDigest: routingMode == .auto ? orchestrationRuntime.policyDigest : "",
            revision: routingMode == .auto ? 1 : 0
        )
        let t = AgentThread(workspaceId: workspaceID, title: title, provider: provider,
                            providerInstanceId: providerInstanceId,
                            model: model,
                            permissionMode: permissionMode, reasoningEffort: reasoningEffort,
                            executionMode: executionMode,
                            baseBranch: executionMode == .worktree ? (baseBranch.isEmpty ? (gitBranch ?? "main") : baseBranch) : nil,
                            serviceTier: serviceTier, modelSelection: currentModelSelection,
                            runAsUser: runAsUser, routingConfiguration: routingConfiguration)
        let prunedThreadIDs: [AgentThreadID]
        do {
            prunedThreadIDs = try threadRepo.upsertEnforcingWorkspaceThreadLimit(t)
        } catch {
            statusMessage = "Could not create thread: \(error)"
            return
        }
        if !prunedThreadIDs.isEmpty {
            retireCommittedThreadPrunes(prunedThreadIDs)
            applyAuthoritativeThreadDeletions(Set(prunedThreadIDs))
            onThreadLifecycle?(.deleted(prunedThreadIDs))
        }
        if selectedThreadId == nil {
            // A fresh composer can hold user input, including a draft preserved
            // from an automatically pruned selection. Bind that input to the
            // new row before selectThread restores its thread-scoped draft.
            persistComposerDraft(for: t.id)
        }
        reloadThreads()
        onThreadLifecycle?(.created(threads.first(where: { $0.id == t.id }) ?? t))
        selectThread(t.id)
    }

    /// Delete every thread in this workspace (stops active providers first).
    @discardableResult
    public func clearAllThreads() async -> Bool {
        let ids = Set(threads.map(\.id))
        return await deleteThreads(ids)
    }

    private func restoreNewThreadDefaults(_ saved: AgentNewThreadDefaults) {
        routingMode = saved.routingMode
        runAsUser = saved.runAsUser ?? AgentRunAsUser.current()
        provider = saved.provider
        providerInstanceId = saved.providerInstanceId
        model = saved.model
        lastModelStore.remember(model: saved.model, for: saved.provider)
        reasoningEffort = saved.reasoningEffort
    }

    private func rememberNewThreadDefaults() {
        newThreadDefaultsStore?.save(AgentNewThreadDefaults(
            routingMode: routingMode,
            runAsUser: runAsUser,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            reasoningEffort: reasoningEffort
        ))
    }

    /// Resolve last-used → built-in default → first listed model for the
    /// active provider. Used for new threads and provider switches.
    public func preferredModelForCurrentProvider(
        availableModels: [AgentModelDescriptor]? = nil
    ) -> String {
        let options = availableModels ?? modelOptionsForSelectedProvider
        return AgentDefaultModelSelection.resolve(
            provider: provider,
            lastUsed: lastModelStore.model(for: provider),
            availableModelIds: options.map(\.id),
            supportsCustomModel: options.contains(where: \.supportsCustomModel)
                || supportsCustomModelForSelectedProvider
        )
    }

    public func applyPreferredModelForCurrentProvider(
        availableModels: [AgentModelDescriptor]? = nil
    ) {
        model = preferredModelForCurrentProvider(availableModels: availableModels)
    }

    public func rememberCurrentModel() {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Never poison last-model with a foreign provider id after rebind.
        if modelIsFromAnotherProvider(trimmed) { return }
        let options = modelOptionsForSelectedProvider
        let known = options.contains(where: { $0.id == trimmed })
            || (customModelsByProvider[provider] ?? []).contains(trimmed)
        let allowCustom = options.contains(where: \.supportsCustomModel)
            || supportsCustomModelForSelectedProvider
        guard known || allowCustom else { return }
        lastModelStore.remember(model: trimmed, for: provider)
    }

    public func preparePullRequestThread() async {
        let url = pullRequestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        guard let pullRequestThreadPreparer else {
            pullRequestStatusMessage = "PR preparation unavailable: app router is not ready."
            return
        }
        normalizeSelectedModelOptions()
        pullRequestPreparing = true
        defer { pullRequestPreparing = false }
        do {
            let thread = try await pullRequestThreadPreparer(
                url,
                provider,
                model,
                permissionMode,
                reasoningEffort,
                serviceTier,
                currentModelSelection,
                providerInstanceId
            )
            pullRequestURL = ""
            reloadThreads()
            onThreadLifecycle?(.created(threads.first(where: { $0.id == thread.id }) ?? thread))
            selectThread(thread.id)
            pullRequestStatusMessage = "Opened \(thread.title)"
        } catch {
            pullRequestStatusMessage = "PR preparation failed: \(error)"
        }
    }

    public func renameThread(_ id: AgentThreadID, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let t: AgentThread
        do {
            guard var stored = try threadRepo.get(id: id) else { return }
            stored.title = title
            stored.updatedAt = Date()
            try threadRepo.upsert(stored)
            t = stored
        } catch {
            statusMessage = "Could not rename thread: \(error)"
            return
        }
        reloadThreads()
        onThreadLifecycle?(.updated(threads.first(where: { $0.id == id }) ?? t))
    }

    /// A2: set/clear a thread's swatch color (empty string clears).
    public func setThreadColor(_ id: AgentThreadID, _ color: String) {
        let t: AgentThread
        do {
            guard var stored = try threadRepo.get(id: id) else { return }
            stored.color = color.isEmpty ? nil : color
            stored.updatedAt = Date()
            try threadRepo.upsert(stored)
            t = stored
        } catch {
            statusMessage = "Could not change thread color: \(error)"
            return
        }
        reloadThreads()
        onThreadLifecycle?(.updated(threads.first(where: { $0.id == id }) ?? t))
    }

    public func setThreadPinned(_ id: AgentThreadID, _ pinned: Bool) {
        do {
            try threadRepo.setPinned(id: id, pinned: pinned)
        } catch {
            statusMessage = "Could not change pinned state: \(error)"
            return
        }
        reloadThreads()
        if let updated = threads.first(where: { $0.id == id }) {
            onThreadLifecycle?(.updated(updated))
        }
    }

    public func reorderThread(_ id: AgentThreadID, before target: AgentThreadID) {
        guard id != target,
              let targetIndex = threads.firstIndex(where: { $0.id == target }) else { return }
        do {
            try threadRepo.reorder(id: id, position: targetIndex)
        } catch {
            statusMessage = "Could not reorder threads: \(error)"
            return
        }
        reloadThreads()
        onThreadLifecycle?(.reordered(workspaceID, threads.map(\.id)))
    }

    // UX-XPLAT-DELETE-UNDO: thread deletion stays IMMEDIATE and final (the
    // delete*Thread contract is unchanged). On top of it we keep a transient
    // in-memory snapshot of the just-deleted thread(s) + their messages for a
    // short window so the user can undo an accidental delete. After the window
    // the snapshot is dropped and the delete is permanent. This is purely
    // additive: nothing defers the actual DELETE.
    public struct ThreadDeletionUndo {
        /// One deleted thread captured before it was removed from the store.
        public struct ThreadSnapshot: Sendable, Equatable {
            public let thread: AgentThread
            public let messages: [AgentMessage]
        }

        /// All threads removed by a single delete action, the instant captured,
        /// and which (if any) thread was selected at delete time so undo can
        /// restore selection too. `count` drives the toast copy.
        public var snapshots: [ThreadSnapshot]
        public var relationalSnapshot: AgentThreadRelationalSnapshot? = nil
        public var attachmentGCPinID: String? = nil
        public var capturedAt: Date
        public var previouslySelectedThreadId: AgentThreadID?

        public var count: Int { snapshots.count }

        /// Pure: is an undo still allowed `window` seconds after capture?
        /// WHY: an accidental delete must be recoverable, but only briefly —
        /// after the window the snapshot is dropped and the delete is final.
        public static func isWithinUndoWindow(
            capturedAt: Date,
            now: Date,
            window: TimeInterval
        ) -> Bool {
            now.timeIntervalSince(capturedAt) < window
        }

        /// Pure: FK-safe restore order for one snapshot. agent_messages has a
        /// `thread_id REFERENCES agent_threads(id) ON DELETE CASCADE` foreign
        /// key with `foreign_keys=ON`, so the parent thread row MUST be
        /// re-inserted before any message, and messages re-append oldest→newest
        /// to preserve their original order.
        public static func restorePlan(
            for snapshot: ThreadSnapshot
        ) -> (thread: AgentThread, messagesInAppendOrder: [AgentMessage]) {
            (snapshot.thread, snapshot.messages.sorted { $0.createdAt < $1.createdAt })
        }
    }

    /// Seconds the undo toast stays actionable after a thread delete.
    public static let threadDeletionUndoWindow: TimeInterval = 10

    /// UX-XPLAT-DELETE-UNDO: transient snapshot of the most recent thread
    /// delete. Non-nil only inside the undo window; cleared on undo, on a new
    /// delete, or when the window lapses. Drives the undo toast.
    @Published public private(set) var pendingThreadDeletionUndo: ThreadDeletionUndo?

    @discardableResult
    public func deleteThread(_ id: AgentThreadID) async -> Bool {
        await deleteThreads([id])
    }

    @discardableResult
    public func deleteThreads(_ ids: Set<AgentThreadID>) async -> Bool {
        guard !ids.isEmpty else { return true }
        let orderedIDs = ids.sorted { $0.value.uuidString < $1.value.uuidString }
        let suppressionLeases: [(AgentThreadID, UUID)]
        if let acquireQueueDrainSuppressions {
            suppressionLeases = await acquireQueueDrainSuppressions(orderedIDs)
        } else if let acquireQueueDrainSuppression {
            var acquired: [(AgentThreadID, UUID)] = []
            for id in ids {
                acquired.append((id, await acquireQueueDrainSuppression(id)))
            }
            suppressionLeases = acquired
        } else {
            suppressionLeases = []
        }
        defer {
            for (id, lease) in suppressionLeases {
                releaseQueueDrainSuppression?(id, lease)
            }
        }
        // AG-002: a thread row owns the provider lifecycle. Do not cascade-delete
        // its data or evict UI caches until every selected provider has confirmed
        // terminal state and its process tree is dead.
        do {
            try await coordinator.stopAndAwaitTermination(threadIds: orderedIDs)
        } catch {
            timeline.apply(.error(
                message: "Could not delete thread because its provider is still running: \(error.localizedDescription)",
                recoverable: true
            ))
            lastErrorRecoverable = true
            scheduleTimelineUpdateTick()
            return false
        }

        let previouslySelectedThreadId = selectedThreadId
        let wasSelected = selectedThreadId.map(ids.contains) ?? false
        let capturedAt = currentTime()
        let attachmentGCPinID = UUID().uuidString.lowercased()
        let relationalSnapshot: AgentThreadRelationalSnapshot
        do {
            relationalSnapshot = try threadRepo.deleteWithRelationalSnapshot(
                ids: Array(ids),
                undoGCPin: AgentThreadUndoGCPin(
                    id: attachmentGCPinID,
                    expiresAt: capturedAt.addingTimeInterval(Self.threadDeletionUndoWindow)
                )
            )
        } catch {
            statusMessage = "Could not delete thread data: \(error)"
            return false
        }
        let undo = ThreadDeletionUndo(
            snapshots: relationalSnapshot.threads.map { .init(thread: $0, messages: []) },
            relationalSnapshot: relationalSnapshot,
            attachmentGCPinID: attachmentGCPinID,
            capturedAt: capturedAt,
            previouslySelectedThreadId: previouslySelectedThreadId
        )
        evictThreadCaches(ids)
        if wasSelected {
            self.selectedThreadId = nil
        messages = []
        messageHistoryIsPartial = false
        timeline = AssistantTimelineState()
        resetTimelineUpdateTick()
        }
        reloadThreads()
        onThreadLifecycle?(.deleted(orderedIDs))
        // Reselect a remaining thread when the open one was deleted (delete UX);
        // never auto-bind a surface that was on the fresh-composer state.
        if wasSelected, selectedThreadId == nil, let next = threads.first {
            selectThread(next.id)
        }
        armThreadDeletionUndo(undo)
        return true
    }

    /// F9: drop deleted threads' per-thread caches so they don't leak for the life
    /// of the surface (composer drafts, the streaming dedup caches, workspace
    /// membership, the repaired-title marker), plus the coordinator's per-thread
    /// auto-continuation bookkeeping. The thread's persistent state is captured for
    /// undo separately; these transient caches rebuild on demand if a delete is
    /// undone.
    private func cachedThreadIDs() -> Set<AgentThreadID> {
        var ids = repairedThreadIds
        ids.formUnion(threadWorkspaceCache.keys)
        ids.formUnion(composerDraftsByThread.keys)
        ids.formUnion(lastPersistedAssistantContentByThread.keys)
        ids.formUnion(lastPersistedFinalIdByThread.keys)
        ids.formUnion(queueStatusByThread.keys)
        ids.formUnion(providerThreadSnapshotConfirmedAtByThread.keys)
        ids.formUnion(runThreads.values)
        return ids
    }

    /// Clears visible state owned by a selected thread that disappeared outside the
    /// explicit-delete flow. The selection is already nil when this runs, so the
    /// existing reload helpers reset queue/checkpoint projections to fresh-composer
    /// state without persisting a change for the deleted thread. The unsent composer
    /// itself is deliberately preserved as the new unbound draft; pruning history
    /// must not destroy user input.
    private func resetDeletedSelectionToFreshComposer() {
        composerCursorOffset = nil
        attachmentInputError = nil
        lastSentAttachmentCount = 0
        pendingAttachmentRetryConfirmation = nil
        messages = []
        messageHistoryIsPartial = false
        cancelOlderMessageLoad()
        timeline = AssistantTimelineState()
        timelineItemIndex = TimelineItemIndex(turns: [])
        resetTimelineUpdateTick()
        _ = streamEventBatch.drain()
        streamUIBackpressured = false
        historyReplayNotice = nil
        sr1TranslatedMessageIds = []
        sr1OriginalTextsByMessageId = [:]
        providerThreadSnapshotStatusMessage = nil
        providerThreadSnapshotLastConfirmedAt = nil
        selectedThreadHasRecoverableContext = false
        liveBackgroundShellCount = 0
        currentRunId = nil
        runStartedAt = nil
        stopScheduledLivePoll()
        userInputSelections = [:]
        userInputDrafts = [:]
        transcriptHistoryRevealCount = 0
        planNotes = ""
        subagentActivity = .empty
        tokenSaverFooterReloadTask?.cancel()
        tokenSaverFooterReloadTask = nil
        tokenSaverThreadSavedTokens = 0
        tokenSaverThreadMeasuredTokens = 0
        reloadQueuedMessages()
        reloadCheckpoints()
    }

    private func recoverDeletedSelectionIfNeeded(_ removedThreadIDs: Set<AgentThreadID>) {
        guard let selectedThreadId, removedThreadIDs.contains(selectedThreadId) else { return }
        let preservedUnsentDraft = !prompt.isEmpty || !attachments.isEmpty
        self.selectedThreadId = nil
        publishInterestedThreadId(nil)
        resetDeletedSelectionToFreshComposer()
        if preservedUnsentDraft {
            statusMessage = Self.deletedThreadDraftRecoveryMessage
        }
        onSelectedThreadChanged?(nil)
    }

    private func applyAuthoritativeThreadDeletions(_ deletedIDs: Set<AgentThreadID>) {
        guard !deletedIDs.isEmpty else { return }
        evictThreadCaches(deletedIDs)
        threads.removeAll { deletedIDs.contains($0.id) }
        recoverDeletedSelectionIfNeeded(deletedIDs)
    }

    /// The repository transaction is authoritative for the victim list. Retire
    /// global runtime state before local cache eviction or lifecycle fan-out so a
    /// failed rail reload cannot leave a deleted provider session behind.
    private func retireCommittedThreadPrunes(
        _ ids: [AgentThreadID],
        coordinatorAlreadyRetired: Bool = false
    ) {
        guard !ids.isEmpty else { return }
        if let retireDeletedThreadRuntime {
            retireDeletedThreadRuntime(ids, coordinatorAlreadyRetired)
        } else if !coordinatorAlreadyRetired {
            // Direct/test surfaces have no AppContext retry owner. Delegate to
            // the coordinator's single fallback driver so retryRequired is kept.
            coordinator.retireDeletedThreads(ids, scheduleRetries: true)
        }
    }

    private func evictThreadCaches(_ ids: some Sequence<AgentThreadID>) {
        let ids = Set(ids)
        guard !ids.isEmpty else { return }
        let removedRunIDs = Set(runThreads.compactMap { runId, threadId in
            ids.contains(threadId) ? runId : nil
        })
        for runId in removedRunIDs {
            runThreads.removeValue(forKey: runId)
        }
        if let currentRunId, removedRunIDs.contains(currentRunId) {
            self.currentRunId = nil
            runStartedAt = nil
            isStopping = false
        }
        for id in ids {
            repairedThreadIds.remove(id)
            threadWorkspaceCache.removeValue(forKey: id)
            composerDraftsByThread.removeValue(forKey: id)
            lastPersistedAssistantContentByThread.removeValue(forKey: id)
            lastPersistedFinalIdByThread.removeValue(forKey: id)
            queueStatusByThread.removeValue(forKey: id)
            providerThreadSnapshotConfirmedAtByThread.removeValue(forKey: id)
            coordinator.forgetThread(id)
        }
    }

    #if DEBUG
    func setReloadThreadListForTesting(_ loader: (() throws -> [AgentThread])?) {
        reloadThreadListForTesting = loader
    }

    func seedSelectedThreadChromeForTesting(_ threadId: AgentThreadID) {
        let now = Date(timeIntervalSince1970: 0)
        subagentActivity = SubagentActivitySnapshot(active: [
            SubagentActivityItem(
                id: UUID(),
                runId: nil,
                threadId: threadId,
                nodeId: "test-node",
                displayName: "test worker",
                provider: .codex,
                model: nil,
                phase: .working,
                lifecycleStatus: .accepted,
                finalRunStatus: nil,
                admittedAt: now,
                finalizedAt: nil,
                lifecycleUpdatedAt: now,
                isActive: true
            )
        ], done: [])
        tokenSaverThreadSavedTokens = 321
        tokenSaverThreadMeasuredTokens = 123
    }

    /// Test-only: the set of thread ids still present in ANY per-thread VM cache,
    /// so a test can prove `evictThreadCaches` leaves no residue after a delete.
    var threadCacheResidueForTesting: Set<AgentThreadID> {
        cachedThreadIDs()
    }

    /// Seeds the two per-thread caches that are otherwise populated only by
    /// queue/provider work, so cache-eviction regressions can observe them.
    func seedAdditionalThreadCachesForTesting(_ threadId: AgentThreadID) {
        let confirmedAt = Date(timeIntervalSince1970: 0)
        queueStatusByThread[threadId] = "test queue status"
        providerThreadSnapshotConfirmedAtByThread[threadId] = confirmedAt
        if selectedThreadId == threadId {
            queueStatusMessage = "test queue status"
            providerThreadSnapshotLastConfirmedAt = confirmedAt
        }
    }

    /// Seeds only the in-memory composer cache. Cap-performance fixtures must
    /// not manufacture durable user drafts, because those are now protected from
    /// automatic retention and are not memory the cap is allowed to reclaim.
    func seedComposerDraftCacheForTesting(
        _ threadId: AgentThreadID,
        providerInstanceId: String,
        text: String
    ) {
        composerDraftsByThread[threadId, default: [:]][providerInstanceId] = AgentThreadDraft(
            threadId: threadId,
            providerInstanceId: providerInstanceId,
            text: text
        )
    }

    @discardableResult
    func seedRunThreadProjectionForTesting(_ threadId: AgentThreadID) -> AgentRunID {
        let runId = AgentRunID()
        runThreads[runId] = threadId
        return runId
    }

    /// Test-only logical payload measure for pruning regressions. This counts the
    /// UTF-8 text held by the in-memory composer draft cache, rather than allocator
    /// footprint, so it remains deterministic when malloc retains freed pages.
    var cachedComposerDraftUTF8BytesForTesting: Int {
        composerDraftsByThread.values.reduce(into: 0) { total, drafts in
            total += drafts.values.reduce(0) { $0 + $1.text.utf8.count }
        }
    }
    #endif

    /// Publish the snapshot as the active undo affordance and schedule its
    /// expiry. The delete itself already happened; this only controls how long
    /// the user can take it back.
    private func armThreadDeletionUndo(_ undo: ThreadDeletionUndo?) {
        threadDeletionUndoExpiryTask?.cancel()
        if pendingThreadDeletionUndo?.attachmentGCPinID != undo?.attachmentGCPinID {
            releaseThreadDeletionUndoGCPin(pendingThreadDeletionUndo)
        }
        guard let undo else {
            pendingThreadDeletionUndo = nil
            return
        }
        pendingThreadDeletionUndo = undo
        let window = Self.threadDeletionUndoWindow
        threadDeletionUndoExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Only clear the snapshot we armed; a newer delete owns its own.
            if let current = self.pendingThreadDeletionUndo,
               current.attachmentGCPinID == undo.attachmentGCPinID,
               !ThreadDeletionUndo.isWithinUndoWindow(
                   capturedAt: current.capturedAt,
                   now: self.currentTime(),
                   window: window
               ) {
                self.releaseThreadDeletionUndoGCPin(current)
                self.pendingThreadDeletionUndo = nil
            }
        }
    }

    private func releaseThreadDeletionUndoGCPin(_ undo: ThreadDeletionUndo?) {
        guard let id = undo?.attachmentGCPinID else { return }
        try? threadRepo.removeUndoGCPin(id: id)
    }

    /// UX-XPLAT-DELETE-UNDO: restore the most recently deleted thread(s) from
    /// the transient snapshot, provided the undo window has not lapsed. Returns
    /// true if a restore happened. FK-safe: re-inserts the thread row first,
    /// then re-appends its messages.
    @discardableResult
    public func undoLastThreadDeletion() -> Bool {
        guard let undo = pendingThreadDeletionUndo,
              ThreadDeletionUndo.isWithinUndoWindow(
                  capturedAt: undo.capturedAt,
                  now: currentTime(),
                  window: Self.threadDeletionUndoWindow
              ) else {
            // Window lapsed (or nothing to undo): drop the stale snapshot.
            releaseThreadDeletionUndoGCPin(pendingThreadDeletionUndo)
            pendingThreadDeletionUndo = nil
            threadDeletionUndoExpiryTask?.cancel()
            return false
        }
        let prunedThreadIDs: [AgentThreadID]
        do {
            if let relationalSnapshot = undo.relationalSnapshot {
                prunedThreadIDs = try threadRepo.restoreEnforcingWorkspaceThreadLimit(relationalSnapshot)
            } else {
                prunedThreadIDs = []
                for snapshot in undo.snapshots {
                    let plan = ThreadDeletionUndo.restorePlan(for: snapshot)
                    try threadRepo.upsert(plan.thread)
                    for message in plan.messagesInAppendOrder {
                        try messageRepo.append(message)
                    }
                }
            }
        } catch {
            statusMessage = "Could not restore deleted thread data: \(error)"
            return false
        }
        if !prunedThreadIDs.isEmpty {
            retireCommittedThreadPrunes(prunedThreadIDs)
            applyAuthoritativeThreadDeletions(Set(prunedThreadIDs))
            onThreadLifecycle?(.deleted(prunedThreadIDs))
        }
        // restoreEnforcingWorkspaceThreadLimit returned only after the complete
        // relational graph committed. Materialize those exact committed rows now;
        // this is not a snapshot fallback after a failed repository operation.
        let committedRestoredThreads = undo.snapshots.map(\.thread)
        let restoredIDs = Set(committedRestoredThreads.map(\.id))
        threads.removeAll { restoredIDs.contains($0.id) }
        threads.append(contentsOf: committedRestoredThreads)
        threads.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.value.uuidString > $1.id.value.uuidString
        }
        for thread in committedRestoredThreads {
            if let workspaceID = thread.workspaceId {
                threadWorkspaceCache[thread.id] = workspaceID
            }
        }
        releaseThreadDeletionUndoGCPin(undo)
        pendingThreadDeletionUndo = nil
        threadDeletionUndoExpiryTask?.cancel()
        // Remote mirrors already saw the delete event; re-announce the restored
        // committed threads before any fallible rail reload.
        for thread in committedRestoredThreads {
            onThreadLifecycle?(.created(thread))
        }
        if let restore = undo.previouslySelectedThreadId,
           restoredIDs.contains(restore) {
            selectThread(restore)
        }
        reloadThreads()
        return true
    }

    /// UX-XPLAT-REVERT-UNDO: transient handle to the most recent checkpoint
    /// revert. `capturedAt` mirrors the toast arming instant (a hair after the
    /// coordinator's own undo capture); `checkpointTurnCount` drives the copy.
    public struct CheckpointRevertUndoToast: Equatable {
        public let threadId: AgentThreadID
        public let cwd: String
        public let checkpointTurnCount: Int
        public let capturedAt: Date
    }

    /// Seconds the undo toast stays actionable after a checkpoint revert.
    public static let checkpointRevertUndoWindow: TimeInterval = 10

    /// UX-XPLAT-REVERT-UNDO: transient handle to the most recent checkpoint
    /// revert. Non-nil only inside the undo window; cleared on undo, on a new
    /// revert, or when the window lapses. Drives the revert undo toast.
    @Published public private(set) var pendingCheckpointRevertUndo: CheckpointRevertUndoToast?

    /// Publish the toast as the active undo affordance and schedule its expiry.
    /// The revert itself already happened; this only controls how long the user
    /// can take it back. Mirrors armThreadDeletionUndo.
    private func armCheckpointRevertUndo(_ toast: CheckpointRevertUndoToast) {
        checkpointRevertUndoExpiryTask?.cancel()
        pendingCheckpointRevertUndo = toast
        let window = Self.checkpointRevertUndoWindow
        checkpointRevertUndoExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Only clear the toast we armed; a newer revert owns its own.
            if let current = self.pendingCheckpointRevertUndo,
               current.capturedAt == toast.capturedAt,
               !CheckpointRevertUndo.isWithinUndoWindow(
                   capturedAt: current.capturedAt,
                   now: self.currentTime(),
                   window: window
               ) {
                self.pendingCheckpointRevertUndo = nil
            }
        }
    }

    /// UX-XPLAT-REVERT-UNDO: ask the coordinator to reverse the most recent
    /// checkpoint revert (files + DB), then refresh the view. The coordinator
    /// owns its own undo window and THROWS if it has lapsed; the catch surfaces
    /// that. The toast is dismissed immediately on tap, like thread-delete undo.
    public func undoLastCheckpointRevert() {
        guard let toast = pendingCheckpointRevertUndo else { return }
        checkpointRevertUndoExpiryTask?.cancel()
        Task { @MainActor in
            do {
                try coordinator.undoLastCheckpointRevert(threadId: toast.threadId, cwd: toast.cwd)
                loadAllMessages(toast.threadId)
                reloadCheckpoints()
                reloadThreads()
                checkpointStatusMessage = "Restored."
            } catch {
                checkpointStatusMessage = "Undo failed: \(error.localizedDescription)"
            }
        }
        pendingCheckpointRevertUndo = nil
    }

    /// Derive the persisted thread title from the first user message.
    /// Display truncation is handled separately by AgentThreadTitle.display.
    public static func deriveTitle(from text: String) -> String {
        AgentThreadTitle.titleFromFirstMessage(text)
    }

    public func statusSummary() -> String {
        let t = threads.first(where: { $0.id == selectedThreadId })?.title ?? "—"
        return "provider=\(provider.rawValue) model=\(model) permission=\(permissionMode.rawValue) reasoning=\(reasoningEffort.rawValue) status=\(status.rawValue) thread=\(t)"
    }

    /// IMP-MAC_AGENT-013: serialize a full thread (read from the durable store,
    /// not the paged in-memory window) to shareable markdown.
    public func exportThreadMarkdown(
        _ id: AgentThreadID,
        includeTimeline: Bool = false
    ) -> (fileName: String, contents: String)? {
        guard let thread = threads.first(where: { $0.id == id }) ?? (try? threadRepo.get(id: id)) else { return nil }
        // Export only the retained window (newest N), not unbounded history.
        let rows = (try? messageRepo.listRecent(
            threadId: id,
            limit: AgentMessageRepository.maxMessagesPerThread
        )) ?? []
        var lines = ["# \(thread.title)", ""]
        for message in rows {
            let heading: String
            switch message.role {
            case .user: heading = "## User"
            case .assistant: heading = "## Assistant"
            case .system: heading = "## System"
            }
            lines.append(heading)
            lines.append("")
            lines.append(message.content)
            lines.append("")
        }
        if includeTimeline {
            let tlLines = ThreadMarkdownFormatter.timelineMarkdownLines(
                turns: timeline.turns,
                approvals: timeline.pendingRequests
            )
            if !tlLines.isEmpty {
                lines.append("## Timeline")
                lines.append("")
                lines.append(contentsOf: tlLines)
                lines.append("")
            }
        }
        let safeName = thread.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (safeName.isEmpty ? "agent-thread" : safeName) + ".md"
        return (fileName, lines.joined(separator: "\n"))
    }

    private func systemNote(_ text: String) {
        guard let tid = selectedThreadId else { return }
        let m = AgentMessage(threadId: tid, role: .system, content: text)
        do {
            try messageRepo.append(m)
            messages.append(m)
        } catch {
            statusMessage = "Could not save system note: \(error)"
        }
    }

    /// `/fork` — create a provider-native branch, copy the visible local
    /// transcript into it, then select the isolated child thread.
    public func forkCurrentThread() async {
        guard let tid = selectedThreadId,
              let src = threads.first(where: { $0.id == tid }) else { return }
        guard selectedProviderCapabilities.supportsFork else {
            systemNote(threadForkUnavailableReason ?? "Provider-side fork is unavailable for this session.")
            return
        }
        let child = AgentThread(
            projectId: src.projectId,
            workspaceId: src.workspaceId ?? workspaceID,
            title: "\(src.title) (fork)",
            provider: src.provider,
            providerInstanceId: src.providerInstanceId,
            model: src.model,
            permissionMode: src.permissionMode,
            reasoningEffort: src.reasoningEffort,
            executionMode: src.executionMode,
            baseBranch: src.baseBranch,
            worktreePath: src.worktreePath,
            serviceTier: src.serviceTier,
            modelSelection: src.modelSelection,
            interactionMode: src.effectiveInteractionMode
        )
        do {
            let result = try await coordinator.forkThreadReturningPrunedThreadIDs(
                sourceThreadId: tid,
                childThread: child
            )
            if !result.prunedThreadIDs.isEmpty {
                retireCommittedThreadPrunes(
                    result.prunedThreadIDs,
                    coordinatorAlreadyRetired: true
                )
                applyAuthoritativeThreadDeletions(Set(result.prunedThreadIDs))
                onThreadLifecycle?(.deleted(result.prunedThreadIDs))
            }
            reloadThreads()
            selectThread(result.thread.id)
        } catch {
            statusMessage = "Could not fork thread: \(error)"
        }
    }

    /// Intercept only RemoteCode-owned slash commands before they reach the
    /// provider. Provider commands such as `/goal` must pass through.
    public static let localSlashCommands = ["/clear", "/default", "/fork", "/model", "/plan", "/status"]

    /// Parse a local RemoteCode slash/dollar command. Public so scheduled Path B
    /// can reject UI-only commands the same way Agent App intercepts them.
    public static func localSlashCommandParts(_ raw: String) -> (command: String, argument: String)? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept `/` and `$` so autocomplete insert of `$clear` / `$plan` still
        // hits the local RemoteCode command path (parity with slash trigger).
        guard let first = line.first, first == "/" || first == "$" else { return nil }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        return (
            parts.first?.lowercased() ?? "",
            parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        )
    }

    @discardableResult
    public func handleSlashCommand(_ raw: String) -> Bool {
        guard let parts = Self.localSlashCommandParts(raw) else { return false }
        let cmd = parts.command
        let arg = parts.argument
        switch cmd {
        case "clear":
            createThread(title: "New thread")
            // P2: /clear creates a new thread (CLI semantics); tell the user so
            // the silent switch doesn't look like a bug.
            systemNote("/clear — started a new thread. Previous thread is still in the rail.")
        case "fork":
            Task { @MainActor in
                await forkCurrentThread()
            }
        case "model":
            if !arg.isEmpty, let m = availableModels.first(where: {
                $0.id.localizedCaseInsensitiveContains(arg) || $0.label.localizedCaseInsensitiveContains(arg)
            }) {
                setModel(m.id)
                systemNote("Model → \(m.label)")
            } else {
                let names = availableModels.map { $0.label }.joined(separator: ", ")
                systemNote(names.isEmpty ? "No models loaded yet." : "Models: \(names)")
            }
        case "plan":
            guard supportsPlanInteractionForSelectedProvider else {
                systemNote(planInteractionUnavailableReason ?? "Plan mode is unavailable for this session.")
                return true
            }
            interactionMode = .plan
            permissionMode = .supervised
            persistThreadConfig()
            systemNote("Plan mode on · permission: supervised")
        case "default":
            interactionMode = .default
            persistThreadConfig()
            systemNote("Default mode on")
        case "status":
            systemNote(statusSummary())
        default:
            return false
        }
        return true
    }

    public func addAttachments(_ paths: [String]) {
        do {
            try AgentProviderRunPreflight.validate(
                snapshot: selectedProviderSnapshot,
                interactionMode: interactionMode,
                permissionMode: permissionMode,
                attachments: []
            )
            guard paths.isEmpty || selectedProviderSnapshot?.effectiveCapabilities.supportsAttachments == true else {
                throw AgentProviderRunPreflightError.attachmentsUnsupported(
                    selectedProviderSnapshot?.displayName ?? provider.rawValue.capitalized
                )
            }
            let staged = try attachmentStore?.stage(paths: paths) ?? AgentAttachmentResolver.resolve(paths: paths)
            try AgentProviderRunPreflight.validate(
                snapshot: selectedProviderSnapshot,
                interactionMode: interactionMode,
                permissionMode: permissionMode,
                attachments: attachments + staged
            )
            let deduplicationKey: (AgentAttachment) -> String = { attachment in
                if let digest = attachment.sha256, !digest.isEmpty { return "sha256:\(digest)" }
                return attachment.id ?? attachment.path
            }
            var known = Set(attachments.map(deduplicationKey))
            for attachment in staged where known.insert(deduplicationKey(attachment)).inserted {
                attachments.append(attachment)
            }
            attachmentInputError = nil
            statusMessage = ""
            if let selectedThreadId { persistComposerDraft(for: selectedThreadId) }
        } catch {
            attachmentInputError = String(describing: error)
            statusMessage = attachmentInputError ?? "Attachment failed."
        }
    }
    public func insertDroppedFilePaths(_ paths: [String]) {
        let insertion = DroppedFilePaths.composerInputText(for: paths)
        prompt = DroppedFilePaths.appending(insertion, to: prompt)
        promptWasEdited()
        focusTick &+= 1
    }
    public func promptWasEdited() {
        promptHistoryCursor = nil
        if let selectedThreadId { persistComposerDraft(for: selectedThreadId) }
    }
    public func removeAttachment(_ attachment: AgentAttachment) {
        attachments.removeAll { $0 == attachment }
        if let selectedThreadId { persistComposerDraft(for: selectedThreadId) }
    }

    private func clearVisibleErrorForNewUserMessage() {
        dismissDisplayedError()
        dismissStatusMessage()
    }

    public func dismissDisplayedError() {
        timeline.clearError()
        lastErrorRecoverable = false
        pendingAttachmentRetryConfirmation = nil
    }

    public func dismissStatusMessage() {
        statusMessage = ""
        attachmentInputError = nil
    }

    public func dismissHistoryReplayNotice() {
        historyReplayNotice = nil
    }

    public func dismissQueueStatusMessage() {
        if let selectedThreadId {
            queueStatusByThread.removeValue(forKey: selectedThreadId)
        }
        queueStatusMessage = nil
    }

    public func handleQueueLifecycleEvent(kind: String, threadId: String?, message: String?) {
        switch kind {
        case "agent.message.queue.failed", AgentQueueEventKinds.drained, AgentQueueEventKinds.cancelled:
            break
        default:
            return
        }
        guard let threadId,
              let uuid = UUID(uuidString: threadId) else { return }
        let eventThreadId = AgentThreadID(uuid)
        let eventWorkspaceID: WorkspaceID?
        if let cachedWorkspaceID = threadWorkspaceCache[eventThreadId] {
            eventWorkspaceID = cachedWorkspaceID
        } else {
            do {
                eventWorkspaceID = try threadRepo.get(id: eventThreadId)?.workspaceId
            } catch {
                return
            }
            if eventWorkspaceID == workspaceID {
                threadWorkspaceCache[eventThreadId] = eventWorkspaceID
            }
        }
        guard eventWorkspaceID == workspaceID else { return }
        switch kind {
        case "agent.message.queue.failed":
            let status = message ?? "The queued message could not start yet."
            setQueueStatus(status, threadId: eventThreadId)
        case AgentQueueEventKinds.drained:
            setQueueStatus(nil, threadId: eventThreadId)
        case AgentQueueEventKinds.cancelled:
            if let queuedMessageRepo,
               (try? queuedMessageRepo.list(threadId: eventThreadId).isEmpty) == true {
                setQueueStatus(nil, threadId: eventThreadId)
            }
        default:
            return
        }
    }

    /// Apply authoritative deletion IDs before the fallible rail reload. Cap
    /// producers publish these IDs because another surface cannot rediscover
    /// them if its first post-delete list read fails.
    public func handleThreadLifecycleEvent(kind: String, threadId: String?, threadIds: [String]?) {
        let rawIDs: [String]
        switch kind {
        case "agent.thread.deleted":
            rawIDs = threadId.map { [$0] } ?? []
        case "agent.thread.deleted_many":
            rawIDs = threadIds ?? []
        default:
            return
        }
        let deletedIDs = Set(rawIDs.compactMap { raw -> AgentThreadID? in
            UUID(uuidString: raw).map(AgentThreadID.init)
        })
        applyAuthoritativeThreadDeletions(deletedIDs)
    }

    public func dismissProviderThreadSnapshotStatusMessage() {
        providerThreadSnapshotStatusMessage = nil
    }

    public func dismissModelListStatusMessage() {
        modelListStatusMessage = nil
    }

    public func dismissProviderSnapshotStatusMessage() {
        providerSnapshotStatusMessage = nil
    }

    public func dismissProviderRecoveryStatusMessage() {
        providerRecoveryStatusMessage = nil
    }

    public func dismissPullRequestStatusMessage() {
        pullRequestStatusMessage = nil
    }

    public func dismissCheckpointStatusMessage() {
        checkpointStatusMessage = nil
    }

    public func dismissProviderStatusMessage() {
        guard let snapshot = selectedProviderSnapshot, snapshot.status != .available else { return }
        let message = snapshot.statusDetail ?? "\(snapshot.displayName) is \(snapshot.status.rawValue)."
        dismissedProviderStatusSignature = "\(snapshot.id)|\(snapshot.status.rawValue)|\(message)"
    }

    /// WHY: while Auto is on and provider/model lists are still loading, a send
    /// would start with incomplete routing and race the orchestrator. The send
    /// button and Enter path must both refuse until prerequisites are ready.
    nonisolated public static func isComposerSendBlockedByAutoRoutingLoad(
        routingMode: AgentRoutingMode,
        hasSelectedThread: Bool,
        providerSnapshotsEmpty: Bool,
        providerSnapshotsLoading: Bool,
        modelListLoading: Bool
    ) -> Bool {
        routingMode == .auto
            && hasSelectedThread
            && (providerSnapshotsEmpty || providerSnapshotsLoading || modelListLoading)
    }

    public func send() async {
        let originalPrompt = prompt
        let sendThreadId = selectedThreadId
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        // Auto is still resolving providers/models — refuse send (button is also
        // disabled) so a half-ready routing snapshot cannot start a provider.
        if Self.isComposerSendBlockedByAutoRoutingLoad(
            routingMode: routingMode,
            hasSelectedThread: selectedThreadId != nil,
            providerSnapshotsEmpty: providerSnapshots.isEmpty,
            providerSnapshotsLoading: providerSnapshotsLoading,
            modelListLoading: modelListLoading
        ) {
            statusMessage = "Automatic model routing is still loading. Try again in a moment."
            return
        }
        // Clear the composer immediately on send so the textarea empties before
        // snapshot load / provider start / queue admission. Capture attachments
        // first; restore the draft only if the turn never starts.
        let attachedForSend = attachments
        prompt = ""
        // At most one snapshot load per send. Catalog probes (CLI Process /
        // network discovery) are expensive and must not run 2–3× on the
        // MainActor-isolated send path. A fresh TTL cache covers the rest.
        var didLoadProviderSnapshotsThisSend = false
        // Snapshots can still be empty on first send (seed/load race). Load once
        // before the fail-closed gate so a ready Grok/Codex install is not blocked.
        // Also needed before `$goal` → `/goal` rewrite so provider slash catalogs
        // (Codex `/goal`) are available for normalization.
        if selectedProviderSnapshot == nil {
            await loadProviderSnapshots()
            didLoadProviderSnapshotsThisSend = true
        }
        // Canonical first-token triggers for every provider:
        // commands (`$goal`/`/goal`) → `/…`; skills (`/sam-work`/`$sam-work`) → `$…`.
        let text = AgentComposerSuggestions.normalizingComposerTriggerPrefix(
            trimmed,
            localSlashCommands: Self.localSlashCommands,
            providerSlashCommands: Array(Set(
                (selectedProviderSnapshot?.slashCommands ?? [])
                    + AgentComposerSuggestions.passThroughSlashCommands
            )),
            skills: selectedProviderSnapshot?.skills ?? []
        )
        // Auto no longer silently routes to another provider — the Source host
        // must be runnable (install/auth/models). The old Auto bypass left users
        // with a late generic preferredSourceUnavailable after a failed admit.
        if !selectedProviderCanRun {
            // One refresh covers stale seed rows and run-as-user probe lag —
            // but only when this send has not already loaded and the catalog
            // TTL says the cache is stale.
            if !didLoadProviderSnapshotsThisSend,
               !providerSnapshotsAreFresh {
                await loadProviderSnapshots()
                didLoadProviderSnapshotsThisSend = true
            }
            if !selectedProviderCanRun {
                statusMessage = providerExecutionUnavailableReason ?? "The selected provider is unavailable."
                restoreComposerPromptAfterFailedSend(originalPrompt, expectedThreadId: sendThreadId)
                return
            }
        }
        // A real turn "uses" the active model — new threads reopen on it.
        rememberCurrentModel()
        lastSentAttachmentCount = attachedForSend.count
        recordPromptHistory(text)
        clearVisibleErrorForNewUserMessage()
        if let slash = Self.localSlashCommandParts(text),
           (slash.command == "plan" || slash.command == "default"),
           !slash.argument.isEmpty {
            if slash.command == "plan", !supportsPlanInteractionForSelectedProvider {
                _ = handleSlashCommand("/plan")
                prompt = slash.argument
                if let selectedThreadId { persistComposerDraft(for: selectedThreadId) }
                return
            }
            _ = handleSlashCommand("/\(slash.command)")
            // A failed/unavailable enqueue must fall through to a real run —
            // returning anyway silently dropped the user's prompt.
            if selectedThreadCanQueuePrompt,
               await enqueuePromptWhileRunning(text: slash.argument, attached: attachedForSend) {
                return
            }
            if await startProviderRun(
                text: slash.argument,
                attached: attachedForSend,
                recordHistory: false,
                interactionMode: interactionMode,
                recoveryDisplayText: originalPrompt
            ) == nil {
                restoreComposerPromptAfterFailedSend(originalPrompt, expectedThreadId: sendThreadId)
            }
            return
        }
        if (text.hasPrefix("/") || text.hasPrefix("$")), handleSlashCommand(text) {
            return
        }
        if selectedThreadCanQueuePrompt,
           await enqueuePromptWhileRunning(text: text, attached: attachedForSend) {
            return
        }
        if await startProviderRun(
            text: text,
            attached: attachedForSend,
            recordHistory: false,
            interactionMode: interactionMode,
            recoveryDisplayText: originalPrompt
        ) == nil {
            restoreComposerPromptAfterFailedSend(originalPrompt, expectedThreadId: sendThreadId)
        }
    }

    /// Puts the draft back only when send never started a turn and the composer
    /// is still empty on the same thread (user did not type or switch away).
    private func restoreComposerPromptAfterFailedSend(
        _ original: String,
        expectedThreadId: AgentThreadID?
    ) {
        guard prompt.isEmpty else { return }
        if let expectedThreadId, selectedThreadId != expectedThreadId { return }
        prompt = original
    }

    /// UX-MAC_AGENT-BG-AWAIT / incomplete-turn: manually resume a thread that
    /// stalled mid-task (supervised counterpart of the autonomous auto-nudge).
    /// Uses the reason-specific prompt (workflow handoff vs background await).
    public func continueAfterBackgroundWait() async {
        guard let reason = incompleteTurnReason else { return }
        prompt = IncompleteTurnContinuation.prompt(for: reason)
        await send()
    }

    private var selectedThreadCanQueuePrompt: Bool {
        guard let selectedThreadId else { return false }
        if selectedThreadRunIsStartingOrRunning { return true }
        if coordinator.activeThreadIdsSnapshot().contains(selectedThreadId) { return true }
        if coordinator.hasProviderSession(threadId: selectedThreadId) { return true }
        guard let currentRunId,
              let runStatus = try? coordinator.runStatus(currentRunId) else { return false }
        return runStatus == .running || runStatus == .pending
    }

    private func enqueuePromptWhileRunning(
        text: String,
        attached: [AgentAttachment],
        interactionMode: AgentInteractionMode? = nil
    ) async -> Bool {
        guard let selectedThreadId, let queuedMessageRepo else { return false }
        let mode = interactionMode ?? self.interactionMode
        do {
            let routing = (try? threadRepo.get(id: selectedThreadId))?.effectiveRoutingConfiguration
                ?? .legacyManual(selection: currentModelSelection, providerInstanceId: providerInstanceId)
            if routing.mode == .auto {
                _ = try orchestrationRuntime.route(
                    configuration: routing,
                    providerSnapshots: providerSnapshots
                )
            } else {
                try AgentProviderRunPreflight.validate(
                    snapshot: selectedProviderSnapshot,
                    interactionMode: mode,
                    permissionMode: permissionMode,
                    attachments: attached
                )
            }
            let queued = try queuedMessageRepo.enqueueConsumingDraft(
                threadId: selectedThreadId,
                providerInstanceId: providerInstanceId,
                text: text,
                attachments: attached,
                interactionMode: mode,
                queuedRoutingSnapshot: AgentQueuedMessageRoutingSnapshot(configuration: routing)
            )
            // Queued follow-ups live only in the queue UI until drain starts the
            // provider turn. Do not mirror a transcript bubble yet — that would
            // look like the agent already received the message. Identity is still
            // queued id = future run id on drain (AgentRunID(queued.id)), so the
            // bubble appears once via startProviderRun when the turn actually starts.
            // Still clear the prior Active plan: the user has superseded it.
            timeline.clearActivePlan()
            suppressStaleActivePlanUpdates = true
            resetTimelineUpdateTick()
            prompt = ""
            attachments = []
            clearComposerDraftMemory(threadId: selectedThreadId, providerInstanceId: providerInstanceId)
            // UX-MAC_AGENT-019: a run is in flight, so this message was queued,
            // not sent now — confirm that explicitly near the composer.
            reloadQueuedMessages()
            setQueueStatus(
                "Queued — will run after the current turn.",
                threadId: selectedThreadId
            )
            // QA-MAC_AGENT-010: track queue depth for diagnostics.
            agentSurfaceLog.info("queue.enqueued thread=\(selectedThreadId.value.uuidString, privacy: .public) depth=\(self.queuedMessages.count, privacy: .public)")
            onQueuedMessageEvent?(AgentQueueEventKinds.queued, queued)
            return true
        } catch {
            setQueueStatus(
                "Queue send failed: \(error)",
                threadId: selectedThreadId
            )
            return false
        }
    }

    /// Ensures Auto routing can pass orchestration admission (`revision > 0` +
    /// current policy digest). Heals threads created before that contract was
    /// enforced, without changing manual routing.
    private func admitReadyAutoRoutingConfiguration(
        from configuration: AgentRoutingConfiguration,
        threadId: AgentThreadID?
    ) throws -> AgentRoutingConfiguration {
        guard configuration.mode == .auto else { return configuration }
        let needsHeal = configuration.revision <= 0
            || configuration.policyDigest != orchestrationRuntime.policyDigest
            || configuration.eligibleProviders.isEmpty
        guard needsHeal else { return configuration }

        let seed = AgentRoutingConfiguration(
            schemaVersion: configuration.schemaVersion,
            mode: .manual,
            manualSelection: configuration.manualSelection,
            manualProviderInstanceId: configuration.manualProviderInstanceId,
            eligibleProviders: configuration.eligibleProviders.isEmpty
                ? AgentProvider.allCases
                : configuration.eligibleProviders,
            policyDigest: "",
            revision: max(0, configuration.revision),
            updatedAt: configuration.updatedAt
        )
        let healed = try orchestrationRuntime.autoConfiguration(
            replacing: seed,
            expectedRevision: seed.revision,
            manualSelection: configuration.manualSelection,
            manualProviderInstanceId: configuration.manualProviderInstanceId ?? providerInstanceId,
            providerSnapshots: providerSnapshots
        )
        if let threadId {
            try threadRepo.setRoutingConfiguration(
                healed,
                threadId: threadId,
                expectedRevision: configuration.revision
            )
            if let persisted = try threadRepo.get(id: threadId),
               let index = threads.firstIndex(where: { $0.id == threadId }) {
                threads[index] = persisted
            }
            routingMode = .auto
        }
        return healed
    }

    @discardableResult
    private func startProviderRun(
        text: String,
        attached: [AgentAttachment],
        recordHistory: Bool,
        interactionMode: AgentInteractionMode,
        resumeInterrupted: Bool = false,
        requestedRunId: AgentRunID? = nil,
        routingConfiguration: AgentRoutingConfiguration? = nil,
        queuedRoutingSnapshot: AgentQueuedMessageRoutingSnapshot? = nil,
        /// Exact pre-normalization composer text for post-start draft-cleanup recovery.
        /// Provider still receives `text`; omit for non-send callers.
        recoveryDisplayText: String? = nil
    ) async -> AgentRunID? {
        let baseRouting = queuedRoutingSnapshot?.configuration
            ?? routingConfiguration
            ?? selectedThreadId.flatMap { try? threadRepo.get(id: $0)?.effectiveRoutingConfiguration }
            ?? .legacyManual(selection: currentModelSelection, providerInstanceId: providerInstanceId)
        let runProvider = provider
        let runProviderInstanceId = providerInstanceId
        let runModel = model
        let runReasoningEffort = reasoningEffort
        let runServiceTier = serviceTier
        let runSnapshot = selectedProviderSnapshot
        let routingSnapshot: AgentOrchestrationRoutingSnapshot?
        let effectiveRouting: AgentRoutingConfiguration
        do {
            // Queued messages keep the snapshot captured at enqueue time.
            if queuedRoutingSnapshot != nil {
                effectiveRouting = baseRouting
            } else {
                effectiveRouting = try admitReadyAutoRoutingConfiguration(
                    from: baseRouting,
                    threadId: selectedThreadId
                )
            }
            if effectiveRouting.mode == .auto {
                guard selectedThreadId != nil else {
                    throw AgentOrchestrationAdmissionError.invalidRoutingMode
                }
                // Prefer a fresh probe when the Source is not yet Auto-admittable
                // (stale seed / run-as-user home not reflected in the last load).
                // Skip when the catalog is still inside the shared TTL — send()
                // may have just loaded, and a third MainActor-bound probe is what
                // beachballed the composer.
                var admitSnapshots = providerSnapshots
                if AgentOrchestrationRuntime.autoAdmitSnapshot(
                    provider: effectiveRouting.manualSelection.provider,
                    preferredInstanceId: effectiveRouting.manualProviderInstanceId ?? runProviderInstanceId,
                    providerSnapshots: admitSnapshots,
                    requireLiveCatalog: false
                ) == nil,
                   !providerSnapshotsAreFresh {
                    await loadProviderSnapshots()
                    admitSnapshots = providerSnapshots
                }
                if AgentOrchestrationRuntime.autoAdmitSnapshot(
                    provider: effectiveRouting.manualSelection.provider,
                    preferredInstanceId: effectiveRouting.manualProviderInstanceId ?? runProviderInstanceId,
                    providerSnapshots: admitSnapshots,
                    requireLiveCatalog: false
                ) == nil {
                    let threadRunAs = selectedThreadId.flatMap { id in
                        threads.first(where: { $0.id == id })?.runAsUser
                    } ?? runAsUser
                    throw AgentOrchestrationAdmissionError.preferredSourceUnavailable(
                        effectiveRouting.manualSelection.provider,
                        detail: AgentOrchestrationRuntime.preferredSourceUnavailabilityDetail(
                            provider: effectiveRouting.manualSelection.provider,
                            preferredInstanceId: effectiveRouting.manualProviderInstanceId ?? runProviderInstanceId,
                            providerSnapshots: admitSnapshots,
                            runAsUser: threadRunAs
                        )
                    )
                }
                let launchConfigurations = Dictionary(uniqueKeysWithValues: admitSnapshots.map { snapshot in
                    let launch = providerLaunchConfig?(snapshot.provider, snapshot.id)
                    return (snapshot.id, AgentOrchestrationLaunchConfiguration(
                        binary: launch?.binary,
                        environment: launch?.environment ?? [:]
                    ))
                })
                routingSnapshot = AgentOrchestrationRoutingSnapshot(
                    configuration: effectiveRouting,
                    providerSnapshots: admitSnapshots,
                    launchConfigurations: launchConfigurations,
                    admissionSnapshot: queuedRoutingSnapshot
                )
            } else {
                routingSnapshot = nil
                try AgentProviderRunPreflight.validate(
                    snapshot: runSnapshot,
                    interactionMode: interactionMode,
                    permissionMode: permissionMode,
                    attachments: attached
                )
            }
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return nil
        }
        if recordHistory { recordPromptHistory(text) }
        if selectedThreadId == nil {
            createThread(title: "New thread")
        }
        guard let tid = selectedThreadId else { return nil }
        // Everything from here to the tracked run below is preparation the user
        // cannot see (Graphify roots, prompt compression, provider spawn). Show
        // "Loading…" for it; the defer covers the failure exits so a thread can
        // never be left permanently loading.
        preparingRunThreadId = tid
        defer {
            if preparingRunThreadId == tid { preparingRunThreadId = nil }
        }
        // B5: title a still-default thread from its first message.
        if let t = threads.first(where: { $0.id == tid }),
           AgentThreadTitle.isPlaceholder(t.title),
           ((try? messageRepo.listRecent(threadId: tid, limit: 1))?.isEmpty ?? true) {
            renameThread(tid, to: Self.deriveTitle(from: text))
        }
        loadAllMessages(tid)
        suppressPersistedFinalDuplicatedByTimeline()
        lastErrorRecoverable = false  // UX-MAC_AGENT-009: clear stale Retry on new run
        selectedThreadHasRecoverableContext = false  // UX-MAC_AGENT-CONTINUE: run started; hide Continue
        let display = attached.isEmpty ? text
            : text + "\n\n📎 " + attached.map(\.displayName).joined(separator: ", ")
        // The coordinator is the single writer of run messages — mirror
        // the user message in-memory only (no double-persist). Queue drain
        // passes the same UUID as runId, so the optimistic bubble is stable.
        let runId = requestedRunId ?? AgentRunID()
        let durableUserMessageExists = (try? messageRepo.get(id: AgentMessageID(runId.value))) != nil
        if !resumeInterrupted && !durableUserMessageExists {
            presentOutgoingUserMessage(
                threadId: tid,
                messageId: AgentMessageID(runId.value),
                display: display,
                attachments: attached
            )
        } else {
            // Resume / already-persisted path still drops a stale Active plan so
            // the transcript bottom is the new turn, not the prior checklist.
            timeline.clearActivePlan()
            suppressStaleActivePlanUpdates = true
            resetTimelineUpdateTick()
            focusTick &+= 1
        }
        // UX-MAC_AGENT-PLAN-FRESH: keep suppressStaleActivePlanUpdates = true until a
        // *fresh* activePlanUpdated for this follow-up arrives (see flushStreamEvents).
        // Clearing suppress here immediately re-painted the prior turn's completed
        // checklist under the new user bubble (late events + durable rehydrate).
        persistThreadConfig()
        let launchConfig = providerLaunchConfig?(runProvider, runProviderInstanceId)
        let threadRunAsUser = threads.first(where: { $0.id == tid })?.runAsUser ?? runAsUser
        let persistedThread = threads.first(where: { $0.id == tid })
        let providerThreadId = persistedThread?.provider == runProvider
            ? persistedThread?.providerThreadId
            : nil
        // Graphify: same host path as AppCommandRouter RPC send — resolve roots,
        // kick refresh, inject RC_GRAPHIFY_* into provider environment (fail-open).
        // Root resolution shells out to `git rev-parse` twice per candidate
        // directory (blocking Process + waitUntilExit). When the workspace root
        // is not itself a repo, classify() walks the tree to depth 2, so that is
        // hundreds of spawns — measured at 2.7s of blocked MainActor on send,
        // i.e. the macOS spinner before the run started. Resolve off the main
        // actor; send still awaits it, so the run environment is unchanged.
        let graphifyBase = launchConfig?.environment ?? [:]
        let graphifyThreadId = tid.value
        let graphifyCwd = cwd
        let graphifyWorktreePath = persistedThread?.worktreePath
        let graphifyAttachmentPaths = attached.map(\.path)
        let graphifyEnv = await Task.detached(priority: .userInitiated) {
            GraphifyWorkspaceService.shared.applyToAgentEnvironment(
                base: graphifyBase,
                threadId: graphifyThreadId,
                threadCwd: graphifyCwd,
                worktreePath: graphifyWorktreePath,
                workspaceCwd: graphifyCwd,
                attachmentPaths: graphifyAttachmentPaths
            ).environment
        }.value
        let req = AgentRunRequest(
            runId: runId,
            threadId: tid,
            provider: runProvider,
            providerInstanceId: runProviderInstanceId,
            model: runModel,
            cwd: cwd,
            prompt: text,
            userMessageContent: display,
            attachments: attached,
            providerThreadId: resumeInterrupted ? nil : providerThreadId,
            permissionMode: permissionMode,
            reasoningEffort: runReasoningEffort,
            serviceTier: runServiceTier,
            interactionMode: interactionMode,
            providerBinary: launchConfig?.binary,
            environment: graphifyEnv,
            runAsUser: threadRunAsUser
        )
        do {
            guard var pendingThread = try threadRepo.get(id: tid) else {
                throw NSError(
                    domain: "RemoteCode.AgentAppViewModel",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Thread disappeared before provider start."]
                )
            }
            pendingThread.status = .pending
            pendingThread.updatedAt = Date()
            try threadRepo.upsert(pendingThread)
            if let index = threads.firstIndex(where: { $0.id == tid }) {
                threads[index] = pendingThread
            }
            status = .pending
            currentRunId = runId
            runThreads[runId] = tid
            runStartedAt = nil
            isStopping = false
            onRunStateChange?()
        } catch {
            statusMessage = "Failed to prepare run: \(error)"
            status = .failed
            return nil
        }
        do {
            let runId = try await coordinator.startRun(
                req,
                routingSnapshot: routingSnapshot,
                recordUserMessage: !resumeInterrupted
            )
            do {
                try clearComposerDraft(threadId: tid, providerInstanceId: providerInstanceId)
                attachments = []
                prompt = ""
            } catch {
                // Provider already started — do not drop the visible recovery draft.
                // send() clears the composer optimistically before start; only blank it
                // after durable delete succeeds. Attachments were not cleared yet.
                // Prefer the pre-normalization visible input (`$goal`/whitespace) so
                // recovery matches what the user typed, not the provider-run command.
                if prompt.isEmpty {
                    prompt = recoveryDisplayText ?? text
                }
                statusMessage = "Provider started, but draft cleanup failed: \(error)"
            }
            let runStatus = (try? coordinator.runStatus(runId)) ?? .running
            await MainActor.run {
                self.terminalRunIds.remove(runId)
                if runStatus == .running || runStatus == .pending {
                    self.currentRunId = runId
                    self.runThreads[runId] = tid
                    self.status = .running
                    self.runStartedAt = AgentAppViewModel.resolvedRunStartedAt(
                        current: self.runStartedAt,
                        persisted: (try? self.coordinator.runStartedAt(threadId: tid)) ?? (try? self.coordinator.runStartedAt(runId: runId))
                    )
                    self.isStopping = false  // UX-MAC_AGENT-STOP: fresh run; clear stale stopping flag
                } else {
                    self.currentRunId = nil
                    self.runThreads[runId] = nil
                    self.status = runStatus
                    self.runStartedAt = nil
                }
                self.reloadThreads()
                self.onRunStateChange?()
            }
            return runId
        } catch {
            await MainActor.run {
                // Prefer LocalizedError copy so ManagedProviderAdmissionError shows
                // the human message instead of the raw enum case name in the banner.
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.statusMessage = "Failed to start: \(detail)"
                self.status = .failed
                self.currentRunId = nil
                self.runThreads[runId] = nil
                self.runStartedAt = nil
                self.clearActivePlanFollowUpSuppressionIfSafe()
                self.reloadThreads()
                self.onRunStateChange?()
            }
            return nil
        }
    }

    public func implementLatestPlan(newThread: Bool = false) async {
        guard let sourceThreadId = selectedThreadId,
              let plan = latestProposedPlan else { return }
        let targetThreadId: AgentThreadID
        if newThread {
            createThread(title: "Implement plan")
            guard let selectedThreadId else { return }
            targetThreadId = selectedThreadId
        } else {
            targetThreadId = sourceThreadId
        }
        let prompt = AgentPlanImplementationPrompt.make(markdown: plan.markdown)
        clearVisibleErrorForNewUserMessage()
        // Same-thread Approve must not open a concurrent provider turn. Grok/Codex/Claude
        // adapters reject second prompts while inFlight; queue like send() and drain after.
        if !newThread && selectedThreadCanQueuePrompt {
            guard await enqueuePromptWhileRunning(text: prompt, attached: [], interactionMode: .default) else { return }
            markLatestPlanImplemented(sourceThreadId: sourceThreadId, plan: plan, targetThreadId: targetThreadId)
            return
        }
        guard await startProviderRun(text: prompt, attached: [], recordHistory: false, interactionMode: .default) != nil else { return }
        markLatestPlanImplemented(sourceThreadId: sourceThreadId, plan: plan, targetThreadId: targetThreadId)
    }

    public func rejectLatestPlan() async {
        guard latestProposedPlan != nil else { return }
        let prompt = "Reject this proposed plan. Do not implement it. Stay in Plan mode and produce a revised plan before making any workspace changes."
        clearVisibleErrorForNewUserMessage()
        if selectedThreadCanQueuePrompt {
            _ = await enqueuePromptWhileRunning(text: prompt, attached: [], interactionMode: .plan)
            return
        }
        _ = await startProviderRun(text: prompt, attached: [], recordHistory: false, interactionMode: .plan)
    }

    private func markLatestPlanImplemented(
        sourceThreadId: AgentThreadID,
        plan: AssistantProposedPlan,
        targetThreadId: AgentThreadID
    ) {
        do {
            try proposedPlanRepo?.markImplemented(threadId: sourceThreadId, planId: plan.id, implementationThreadId: targetThreadId)
        } catch {
            statusMessage = "Plan started, but implementation state could not be saved: \(error)"
            return
        }
        var implemented = plan
        implemented.implementedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        timeline.apply(.proposedPlan(implemented))
    }

    private func recordPromptHistory(_ text: String) {
        guard !text.isEmpty else { return }
        promptHistory.append(text)
        promptHistory = Array(promptHistory.suffix(PromptHistoryStore.limit))
        promptHistoryStore?.save(promptHistory, workspaceID: workspaceID)
        // NOTE: call promptHistoryStore?.search(workspaceID:query:limit:) from a
        // search field in the composer to surface filtered history to the user.
        promptHistoryCursor = nil
    }

    nonisolated static func promptHistoryWriteErrorMessage(_ error: Error) -> String {
        "Prompt history could not be saved: \(error.localizedDescription)."
    }

    /// UX-MAC_AGENT-009: re-send the last prompt after a recoverable error
    /// without forcing the user to retype it.
    public func retryLastPrompt() async {
        let failedMessage = selectedThreadId.flatMap { threadId in
            try? messageRepo.listRecent(
                threadId: threadId,
                limit: AgentMessageRepository.maxMessagesPerThread
            ).last(where: { $0.role == .user })
        }
        let last = failedMessage.map(Self.retryPrompt) ?? promptHistory.last
        guard let last, !last.isEmpty else { return }
        let persistedAttachments = failedMessage?.attachments ?? []
        if !persistedAttachments.isEmpty {
            var retryable: [AgentAttachment] = []
            var unavailable: [String] = []
            for attachment in persistedAttachments {
                do {
                    guard let attachmentStore else { throw AgentAttachmentResolverError.notReadableFile(attachment.displayName) }
                    retryable.append(try attachmentStore.validatedForRetry(attachment))
                } catch {
                    unavailable.append(attachment.displayName)
                }
            }
            if !unavailable.isEmpty {
                pendingAttachmentRetryConfirmation = AttachmentRetryConfirmation(
                    prompt: last,
                    retryableAttachments: retryable,
                    unavailableAttachmentNames: unavailable
                )
                return
            }
            clearVisibleErrorForNewUserMessage()
            _ = await startProviderRun(text: last, attached: retryable, recordHistory: false, interactionMode: interactionMode)
            return
        } else if lastSentAttachmentCount > 0 {
            pendingAttachmentRetryConfirmation = AttachmentRetryConfirmation(
                prompt: last,
                retryableAttachments: [],
                unavailableAttachmentNames: ["previous attachments"]
            )
            return
        }
        clearVisibleErrorForNewUserMessage()
        _ = await startProviderRun(text: last, attached: [], recordHistory: false, interactionMode: interactionMode)
    }

    public var displayedErrorRecoveryAction: AgentErrorRecoveryAction? {
        guard let message = timeline.error else { return nil }
        let action = Self.errorRecoveryAction(
            provider: provider,
            message: message,
            recoverable: lastErrorRecoverable
        )
        if action == .signIn, pendingSignInProvider == provider {
            return .retry
        }
        return action
    }

    nonisolated public static func errorRecoveryAction(
        provider: AgentProvider,
        message: String,
        recoverable: Bool
    ) -> AgentErrorRecoveryAction? {
        let normalized = message.lowercased()
        let resumeInvalidMarkers = [
            "session not found", "session/load", "invalid session", "invalid resume",
            "resume cursor", "could not be resumed", "failed to resume", "resume invalid"
        ]
        if resumeInvalidMarkers.contains(where: normalized.contains) {
            return .startFresh
        }
        let authMarkers = [
            "[auth-required]", "401", "403", "unauthorized", "unauthenticated",
            "authentication", "login required", "sign in required", "token expired",
            "invalid_api_key", "invalid api key", "forbidden"
        ]
        if authMarkers.contains(where: normalized.contains) {
            return .signIn
        }
        let retryMarkers = [
            "rate limit", "rate_limit", "too many requests", "429", "network",
            "connection", "timed out", "timeout", "temporarily unavailable",
            "service unavailable", "502", "503", "504"
        ]
        if retryMarkers.contains(where: normalized.contains) || recoverable {
            return .retry
        }
        _ = provider // classification deliberately shares one vocabulary across providers.
        return nil
    }

    public func performDisplayedErrorRecoveryAction() async {
        guard let action = displayedErrorRecoveryAction else { return }
        switch action {
        case .retry:
            if pendingSignInProvider == provider {
                _ = await refreshPendingProviderAuthentication(retryLastPromptWhenAuthenticated: true)
                return
            }
            await retryLastPrompt()
        case .startFresh:
            let failedPrompt = selectedThreadId.flatMap { threadId in
                try? messageRepo.listRecent(
                    threadId: threadId,
                    limit: AgentMessageRepository.maxMessagesPerThread
                ).last(where: { $0.role == .user })
            }.map(Self.retryPrompt)
            createThread(title: "New thread")
            if let failedPrompt, !failedPrompt.isEmpty {
                prompt = failedPrompt
                focusTick &+= 1
            }
        case .signIn:
            beginProviderSignIn(provider: provider, snapshotID: selectedProviderSnapshot?.id)
        }
    }

    public func confirmRetryWithoutUnavailableAttachments() async {
        guard let pending = pendingAttachmentRetryConfirmation else { return }
        pendingAttachmentRetryConfirmation = nil
        systemNote("Retry continuing without unavailable attachment(s): \(pending.unavailableAttachmentNames.joined(separator: ", ")).")
        clearVisibleErrorForNewUserMessage()
        _ = await startProviderRun(
            text: pending.prompt,
            attached: pending.retryableAttachments,
            recordHistory: false,
            interactionMode: interactionMode
        )
    }

    public func cancelRetryWithoutUnavailableAttachments() {
        pendingAttachmentRetryConfirmation = nil
    }

    private static func retryPrompt(_ message: AgentMessage) -> String {
        guard !message.attachments.isEmpty else { return message.content }
        let suffix = "\n\n📎 " + message.attachments.map(\.displayName).joined(separator: ", ")
        return message.content.hasSuffix(suffix) ? String(message.content.dropLast(suffix.count)) : message.content
    }

    @discardableResult
    public func recallPreviousPrompt() -> Bool {
        guard prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || promptHistoryCursor != nil else { return false }
        guard !promptHistory.isEmpty else { return false }
        let next = promptHistoryCursor.map { max($0 - 1, 0) } ?? (promptHistory.count - 1)
        promptHistoryCursor = next
        prompt = promptHistory[next]
        return true
    }

    @discardableResult
    public func recallNextPrompt() -> Bool {
        guard let cursor = promptHistoryCursor else { return false }
        let next = cursor + 1
        guard next < promptHistory.count else {
            promptHistoryCursor = nil
            prompt = ""
            return true
        }
        promptHistoryCursor = next
        prompt = promptHistory[next]
        return true
    }

    public func stop() {
        let tid = selectedThreadId
        let localRunId = currentRunId ?? tid.flatMap { trackedRunId(for: $0) }
        // Second click while already Stopping: hard-await termination so a
        // stuck soft interrupt cannot leave the button disabled forever. This must
        // stay AHEAD of the stale-projection branch below: the first Stop can
        // already have released durable ownership (markStopRequested synthesizes a
        // cancelled terminal with providerTerminalAcknowledged=false) while the
        // provider's own teardown is still outstanding, and stopAndAwaitTermination
        // is the only path that then releases that live adapter session.
        if isStopping, let tid {
            Task { @MainActor in
                do {
                    try await self.coordinator.stopAndAwaitTermination(threadId: tid)
                } catch {
                    self.statusMessage = "Force stop: \(error.localizedDescription)"
                }
                // If the coordinator still owns the run after the hard deadline,
                // clear the UI latch so the user is not stuck on Stopping…
                if self.trackedRunId(for: tid) == nil {
                    self.isStopping = false
                    if self.selectedThreadId == tid {
                        self.currentRunId = nil
                        self.runStartedAt = nil
                    }
                } else if !self.hasStoppableRun(threadId: tid) {
                    // Ownership is only a stale surface projection (no live run, no
                    // durable pending/running row). That is not a stop timeout, so
                    // clear it silently instead of blaming the provider.
                    self.clearStaleRunProjection(threadId: tid)
                } else {
                    // Loud failure: hard timeout still left ownership — drop the
                    // latch so Stop is usable again and surface the error.
                    self.isStopping = false
                    if self.statusMessage.isEmpty {
                        self.statusMessage = "Stop is taking longer than expected. Try again or restart the agent."
                    }
                }
            }
            return
        }
        // Nothing to interrupt: the surface shows Working for a run that neither
        // this process nor SQLite still lists as active (a projection left behind
        // by a finished turn, or re-inflated by a recovered provider session).
        // Latching "Stopping…" here stranded the UI forever — only run lifecycle
        // events clear that latch and none can arrive for a dead run — so drop the
        // projection and go idle instead.
        if let tid, !hasStoppableRun(threadId: tid) {
            // Keep both best-effort stops the old fall-through performed: a handle
            // can still be registered under a runId whose thread mapping was
            // already released, and only stopRun(runId:) can cancel that orphan.
            if let localRunId { coordinator.stopRun(localRunId) }
            coordinator.stopRun(threadId: tid)
            clearStaleRunProjection(threadId: tid)
            return
        }
        // Path B: scheduled runs are owned by the LaunchAgent. Prefer XPC stop
        // when SQLite says this thread has an active scheduled occurrence.
        if let tid, isScheduledThreadRunning?(tid) == true, let stopScheduledThread {
            isStopping = true
            Task { @MainActor in
                let accepted = await stopScheduledThread(tid, localRunId)
                if !accepted {
                    // Loud failure: do not leave the UI stuck on Stopping…
                    self.isStopping = false
                    self.statusMessage = "Could not stop scheduled run (scheduler unavailable or run not owned)."
                }
            }
            return
        }
        if let r = localRunId {
            coordinator.stopRun(r)
        }
        if let tid {
            coordinator.stopRun(threadId: tid)
        }
        // UX-MAC_AGENT-STOP: signal that the interrupt was sent so the UI can
        // show "Stopping..." until the run terminates. Keep the control enabled
        // so a second click can force-stop if soft cancel stalls.
        isStopping = true
    }

    /// True when Stop has a real target: a coordinator-owned run, a provider start
    /// still in flight, a durable pending/running row, or a LaunchAgent-owned
    /// scheduled occurrence. A live adapter session alone does NOT count — a
    /// recovered session for an already-finished turn is exactly the case that must
    /// resolve to "nothing to stop" instead of a permanent Stopping… latch.
    private func hasStoppableRun(threadId: AgentThreadID) -> Bool {
        if isScheduledThreadRunning?(threadId) == true { return true }
        if coordinator.activeRunId(threadId: threadId) != nil { return true }
        if coordinator.hasPendingProviderStart(threadId: threadId) { return true }
        // A failed durable read must not be reported as "idle": attempting a real
        // stop is always safer than clearing a projection that may be backing a
        // live run, so a throwing read counts as stoppable.
        do {
            if try coordinator.durableActiveRun(threadId: threadId) != nil { return true }
        } catch {
            return true
        }
        return false
    }

    /// Drop every run projection this surface holds for `threadId` and repaint the
    /// thread from its durable status. Used when Stop finds no live run.
    private func clearStaleRunProjection(threadId: AgentThreadID) {
        for (runId, mapped) in runThreads where mapped == threadId {
            runThreads[runId] = nil
            terminalRunIds = Self.boundedTerminalRunIds(existing: terminalRunIds, adding: runId)
        }
        if selectedThreadId == threadId {
            currentRunId = nil
            runStartedAt = nil
            isStopping = false
            if let durableStatus = (try? threadRepo.get(id: threadId))?.status {
                status = durableStatus
            }
            clearActivePlanFollowUpSuppressionIfSafe()
        }
        stopScheduledLivePoll()
        scheduleReloadThreads()
        onRunStateChange?()
    }

    /// Stop a specific thread by id, regardless of which thread is currently selected.
    /// Allows the thread rail to stop any running thread without switching selection.
    public func stopThread(_ id: AgentThreadID) {
        if isScheduledThreadRunning?(id) == true, let stopScheduledThread {
            Task { @MainActor in
                _ = await stopScheduledThread(id, trackedRunId(for: id))
            }
            return
        }
        coordinator.stopRun(threadId: id)
    }

    // PERF-MAC_AGENT-006: last assistant text this VM persisted per thread, to
    // skip the O(history) reload when re-deduping the same completed answer.
    private var lastPersistedAssistantContentByThread: [AgentThreadID: String] = [:]

    // PERF-MAC_AGENT-012: ID of the last final message this surface appended per
    // thread. Non-nil = this session already wrote a final to DB; a subsequent
    // completion with new text can skip the O(history) messageRepo.list and just
    // append. Nil = first completion in this session → reload once to guard
    // against a prior session having written the same final already.
    private var lastPersistedFinalIdByThread: [AgentThreadID: AgentMessageID] = [:]

    // Pure decision seam: returns true when a full DB reload is needed before
    // deciding whether to append. False = session ID-memo proves last persist is
    // known; the incoming text differs (content memo already ruled out identity),
    // so a direct append is safe without consulting the full message list.
    //
    // nonisolated + static: callable from tests without a surface instance and
    // without main-actor hops.
    nonisolated static func shouldReloadForFinal(
        lastPersistedId: AgentMessageID?,
        lastPersistedKey: String?,
        incomingKey: String
    ) -> Bool {
        // Content equality is checked by the caller before reaching this point;
        // if we are here incomingKey != lastPersistedKey (new text).
        // If we have persisted before (id != nil) we already know DB state for
        // this thread from this session: the last final's id is recorded and its
        // content was different from incomingKey. A new final can be safely
        // appended. Reload only when id is nil (no session history — must check
        // DB for a pre-existing row written by a prior session/path).
        return lastPersistedId == nil
    }

    private func persistFinalAssistantIfMissing(_ text: String, threadId: AgentThreadID) {
        let text = AssistantTimelineState.cappedText(text)
        // Fast path: same text already persisted this session — nothing to do.
        if lastPersistedAssistantContentByThread[threadId] == text { return }
        // PERF-MAC_AGENT-012: if we have a session ID for this thread the DB
        // state is known — skip O(history) list and append directly.
        // Reload only on first completion in a session (id == nil) to guard
        // against a prior session/path having already written this exact text.
        if Self.shouldReloadForFinal(
            lastPersistedId: lastPersistedFinalIdByThread[threadId],
            lastPersistedKey: lastPersistedAssistantContentByThread[threadId],
            incomingKey: text
        ) {
            // Only scan the retained window for duplicate finals.
            let existing = (try? messageRepo.listRecent(
                threadId: threadId,
                limit: AgentMessageRepository.maxMessagesPerThread
            )) ?? []
            guard !existing.contains(where: { $0.role == .assistant && $0.content == text }) else {
                lastPersistedAssistantContentByThread[threadId] = text
                return
            }
        }
        let msg = AgentMessage(threadId: threadId, role: .assistant, content: text)
        try? messageRepo.append(msg)
        lastPersistedAssistantContentByThread[threadId] = text
        lastPersistedFinalIdByThread[threadId] = msg.id
    }

    // MARK: AgentRunObserver

    /// Whether a stream event tagged with `run` may (re)latch the Working /
    /// running projection for `threadId`.
    ///
    /// WHY: `terminalRunIds` is in-memory only, so it is empty in a freshly
    /// launched process. A recovered provider session re-announces itself on
    /// reconnect (codex re-emits `mcpServer/startupStatus` plus the `itemStarted`
    /// it was interrupted on) and those events carry the PREVIOUS, already
    /// finished runId. That used to flip the surface back to "Working for Ns" for
    /// a run that ended hours earlier — a latch the user could never clear: Stop
    /// had no live run to interrupt, so the first click only latched "Stopping…"
    /// and the second reported a stop timeout while the spinner kept ticking.
    /// Require live coordinator ownership or a durable pending/running row before
    /// a stream event may claim the run is active. Timeline paint is unaffected;
    /// only the run-active latch is gated.
    private func streamEventMayMarkRunActive(_ run: AgentRunID, threadId: AgentThreadID) -> Bool {
        if terminalRunIds.contains(run) { return false }
        if coordinator.activeRunId(threadId: threadId) == run { return true }
        // Events can precede handle registration: startRun commits the run row as
        // `.pending` before the provider emits, so the durable row is the proof
        // that this run is the thread's current turn.
        if let durable = try? coordinator.durableActiveRun(threadId: threadId), durable.id == run {
            return true
        }
        // Deliberately NOT memoized into `terminalRunIds`: a run row written by
        // another process (scheduled occurrence) can be invisible to this read for
        // a moment, and a permanent blacklist would then hide a genuinely live run
        // forever. The durable read only happens for runs this process does not
        // own, so a hot streaming run still short-circuits on the check above.
        return false
    }

    // PERF-MAC_AGENT-010: accumulate streaming events and flush all of them in
    // a single main-actor hop. A fast token stream emits thousands of events/sec;
    // the old code allocated one Task per event. Now the first event schedules
    // ONE flush Task; subsequent events in the same tick just append to the buffer
    // and the flush Task drains everything atomically. Event order is preserved.
    private func flushStreamEvents() {
        guard !isDisposed else {
            _ = streamEventBatch.drain()
            return
        }
        let quantum = streamEventBatch.drainQuantum()
        let pending = quantum.entries
        if pending.isEmpty {
            if streamUIBackpressured, let tid = selectedThreadId {
                rehydrateTimelineAfterStreamBackpressure(threadId: tid)
            }
            return
        }
        if quantum.hasMore {
            // Small gap so input/scroll can interleave between paint quanta.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(4))
                self?.flushStreamEvents()
            }
        }
        var nextTimeline = timeline
        var nextCurrentRunId = currentRunId
        var nextStatus = status
        var nextLastErrorRecoverable = lastErrorRecoverable
        var appliedEvent = false
        var nextBackgroundShellCount = liveBackgroundShellCount
        var appliedEvents: [AssistantEvent] = []
        appliedEvents.reserveCapacity(pending.count)
        for (event, run, threadId) in pending {
            guard threadId == self.selectedThreadId else { continue }
            // User already sent a follow-up: drop *stale* plan progress from the
            // prior turn so the checklist cannot reappear under the new user bubble.
            // While a follow-up is only queued (not yet a transcript bubble), the
            // newest user message still belongs to the *prior* turn — so timestamp
            // freshness alone would wrongly accept live plan updates from that run.
            // Accept only a plan whose updatedAtMs is at/after the follow-up anchor
            // once the new turn owns the transcript, then lift suppress for this run.
            if suppressStaleActivePlanUpdates, case .activePlanUpdated(let plan) = event {
                let newestUserAt = self.messages.last(where: { $0.role == .user })?.createdAt
                if AgentAppView.shouldAcceptActivePlanForFollowUp(
                    plan: plan,
                    newestUserMessageAt: newestUserAt,
                    runStartedAt: self.runStartedAt,
                    hasQueuedFollowUp: self.hasQueuedFollowUpOnSelectedThread()
                ) {
                    self.suppressStaleActivePlanUpdates = false
                } else {
                    continue
                }
            }
            appliedEvent = true
            appliedEvents.append(event)
            // CLAUDE-BG-LIFECYCLE: the provider's pending background-work set
            // rides the session snapshot; pick off the count for the "N shells"
            // chip. Cheap: only claude.session.snapshot events are decoded, and
            // the adapter already coalesces snapshots whose state did not change.
            if let count = Self.backgroundShellCount(fromRuntimeEvent: event) {
                nextBackgroundShellCount = count
            }
            if self.streamEventMayMarkRunActive(run, threadId: threadId) {
                nextCurrentRunId = run
                self.runThreads[run] = threadId
                if nextStatus != .running { nextStatus = .running }
                // Stream events can mark the run running before startProviderRun
                // assigns runStartedAt. Seed it so the live window does not fall
                // through to a full-history paint on the first deltas.
                if self.runStartedAt == nil {
                    self.runStartedAt = Date()
                }
            }
            nextTimeline.apply(event)
            // UX-MAC_AGENT-009: track recoverability of the latest error so the
            // transcript can offer Retry. F26: only an .error event may change the
            // flag — producers emit trailing runtime items right after a recoverable
            // error (auth_status, resume fallback), and timeline.error (the banner)
            // persists across non-error events, so clearing on any other event made
            // the Retry affordance unreachable. The flag resets where the displayed
            // error itself is cleared (clearVisibleErrorForNewUserMessage /
            // startProviderRun / selectThread's timeline rebuild).
            if case let .error(_, recoverable) = event {
                nextLastErrorRecoverable = recoverable
            }
        }
        nextTimeline.enforceAggregateHotTextBudget()
        guard appliedEvent else {
            if !quantum.hasMore, streamUIBackpressured, let tid = selectedThreadId {
                rehydrateTimelineAfterStreamBackpressure(threadId: tid)
            }
            return
        }
        // UX: transient durability banners (sqlite "database is locked", etc.)
        // stick only while the stream is still failing. Once a later event proves
        // the run continued, drop the banner so it does not outlive the outage.
        if Self.shouldAutoClearTransientTimelineError(
            errorAfterBatch: nextTimeline.error,
            appliedEvents: appliedEvents
        ) {
            nextTimeline.clearError()
            nextLastErrorRecoverable = false
        }
        if self.currentRunId != nextCurrentRunId { self.currentRunId = nextCurrentRunId }
        if self.status != nextStatus { self.status = nextStatus }
        if self.lastErrorRecoverable != nextLastErrorRecoverable {
            self.lastErrorRecoverable = nextLastErrorRecoverable
        }
        if self.liveBackgroundShellCount != nextBackgroundShellCount {
            self.liveBackgroundShellCount = nextBackgroundShellCount
        }
        self.timeline = nextTimeline
        self.refreshSR1TranslationStateFromTimeline()
        self.scheduleTimelineUpdateTick()
        // Full access auto-approves plans: if a proposed plan arrived mid-stream,
        // queue/start implementation without surfacing Approve/Reject.
        if appliedEvents.contains(where: { if case .proposedPlan = $0 { return true }; return false }) {
            scheduleFullAccessPlanAutoImplementIfNeeded()
        }
        // After the hot queue drains, rebuild from durable stream events so any
        // paints skipped while the MainActor was behind are restored without
        // forcing the user to Continue / reopen the thread.
        if !quantum.hasMore, streamUIBackpressured, let tid = selectedThreadId {
            rehydrateTimelineAfterStreamBackpressure(threadId: tid)
        }
    }

    /// Count of CLI-owned background shells / async subagents carried by a
    /// `claude.session.snapshot` runtime event, or nil when `event` is not such a
    /// snapshot (or predates the field — e.g. the SDK-bridge route, which does not
    /// report background tasks). Returning nil rather than 0 is deliberate: an
    /// unrelated event must not clear a live count. Pure, for unit testing.
    nonisolated static func backgroundShellCount(fromRuntimeEvent event: AssistantEvent) -> Int? {
        guard case .providerRuntime(let runtime) = event,
              runtime.provider == .claude,
              runtime.method == "claude.session.snapshot",
              let data = runtime.payloadJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = payload["pendingBackgroundTaskIds"] as? [String] else { return nil }
        return ids.count
    }

    /// Apply one event that the hot queue refused, without growing the queue.
    /// Timeline caps keep the paint bounded; used for the first saturation of an
    /// episode so a single huge tool payload still appears live.
    private func applyRefusedStreamEventDirectly(
        _ event: AssistantEvent,
        run: AgentRunID,
        threadId: AgentThreadID
    ) {
        guard threadId == selectedThreadId else { return }
        if suppressStaleActivePlanUpdates, case .activePlanUpdated(let plan) = event {
            let newestUserAt = messages.last(where: { $0.role == .user })?.createdAt
            if AgentAppView.shouldAcceptActivePlanForFollowUp(
                plan: plan,
                newestUserMessageAt: newestUserAt,
                runStartedAt: runStartedAt,
                hasQueuedFollowUp: hasQueuedFollowUpOnSelectedThread()
            ) {
                suppressStaleActivePlanUpdates = false
            } else {
                return
            }
        }
        if streamEventMayMarkRunActive(run, threadId: threadId) {
            currentRunId = run
            runThreads[run] = threadId
            if status != .running { status = .running }
        }
        timeline.apply(event)
        timeline.enforceAggregateHotTextBudget()
        if case let .error(_, recoverable) = event {
            lastErrorRecoverable = recoverable
        }
        refreshSR1TranslationStateFromTimeline()
        scheduleTimelineUpdateTick()
        if case .proposedPlan = event {
            scheduleFullAccessPlanAutoImplementIfNeeded()
        }
    }

    /// True when the selected thread still has a follow-up that has not become a
    /// transcript bubble yet. Plan events during this window belong to the prior
    /// still-running turn and must not lift follow-up plan suppress.
    private func hasQueuedFollowUpOnSelectedThread() -> Bool {
        guard let selectedThreadId else { return false }
        return queuedMessages.contains { $0.threadId == selectedThreadId }
    }

    /// Lift follow-up plan suppress only when no queued successor is waiting.
    /// Clearing on predecessor terminal while a queue row exists would re-paint
    /// the prior checklist before drain starts the new turn.
    private func clearActivePlanFollowUpSuppressionIfSafe() {
        guard !hasQueuedFollowUpOnSelectedThread() else { return }
        suppressStaleActivePlanUpdates = false
    }

    /// Rebuild the live timeline from the durable hot-replay window after the UI
    /// queue refused events. Idempotent: clears the backpressure flag so a quiet
    /// stream does not keep replaying.
    private func rehydrateTimelineAfterStreamBackpressure(threadId: AgentThreadID) {
        guard streamUIBackpressured, selectedThreadId == threadId else { return }
        streamUIBackpressured = false
        let events = coordinator.latestStreamEvents(threadId: threadId)
        var rebuilt = AssistantTimelineState()
        let newestUserAt = messages.last(where: { $0.role == .user })?.createdAt
        for event in events {
            if suppressStaleActivePlanUpdates, case .activePlanUpdated(let plan) = event {
                if AgentAppView.shouldAcceptActivePlanForFollowUp(
                    plan: plan,
                    newestUserMessageAt: newestUserAt,
                    runStartedAt: runStartedAt,
                    hasQueuedFollowUp: hasQueuedFollowUpOnSelectedThread()
                ) {
                    suppressStaleActivePlanUpdates = false
                } else {
                    continue
                }
            }
            rebuilt.apply(event)
        }
        rebuilt.enforceAggregateHotTextBudget()
        timeline = rebuilt
        rehydrateDurableActiveState(threadId: threadId)
        lastErrorRecoverable = Self.displayedErrorIsRecoverable(in: events)
        refreshSR1TranslationStateFromTimeline()
        timelineItemIndex = TimelineItemIndex(turns: timeline.turns)
        scheduleTimelineUpdateTick()
    }

    /// True for local durability noise that is not a provider-run failure.
    /// These banners should auto-dismiss when the thread keeps making progress.
    nonisolated static func isTransientPersistenceTimelineError(_ message: String) -> Bool {
        let n = message.lowercased()
        return n.contains("persistence failure")
            || n.contains("database is locked")
            || n.contains("sqlite step: database is locked")
    }

    /// After a stream batch: drop a transient persistence banner when any
    /// non-error event shows the run continued past the lock/outage.
    nonisolated static func shouldAutoClearTransientTimelineError(
        errorAfterBatch: String?,
        appliedEvents: [AssistantEvent]
    ) -> Bool {
        guard let errorAfterBatch, isTransientPersistenceTimelineError(errorAfterBatch) else {
            return false
        }
        return appliedEvents.contains { event in
            if case .error = event { return false }
            return true
        }
    }

    /// Pure multi-tab stream gate: only the surface whose selected thread matches
    /// the event should buffer/flush. `nil` interest means no selected thread
    /// (fresh composer) — drop all stream events.
    nonisolated static func acceptsStreamEvent(
        eventThreadId: AgentThreadID,
        interestedThreadId: AgentThreadID?
    ) -> Bool {
        eventThreadId == interestedThreadId
    }

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {
        // Multi-tab freeze guard: every open Agent App observes the coordinator.
        // Drop stream events for other threads before buffering/scheduling so N
        // idle tabs do not pay MainActor work for one streaming tab.
        guard Self.acceptsStreamEvent(
            eventThreadId: threadId,
            interestedThreadId: currentInterestedThreadId()
        ) else { return }
        // PERF-MAC_AGENT-010: append to the batch buffer. If the buffer was
        // empty (first event of this tick), schedule a single flush Task.
        // Later events in the same tick just append — no extra Task allocation.
        let outcome = streamEventBatch.appendBounded(event: event, run: run, threadId: threadId)
        switch outcome {
        case .scheduled, .scheduledAfterEviction:
            Task { @MainActor in
                self.flushStreamEvents()
            }
            if outcome == .scheduledAfterEviction {
                Task { @MainActor in
                    guard !self.isDisposed, self.selectedThreadId == threadId else { return }
                    // Oldest UI paints were dropped under budget; durable history
                    // still has them — rehydrate when the queue drains / run ends.
                    self.streamUIBackpressured = true
                }
            }
        case .bufferedAfterEviction:
            Task { @MainActor in
                guard !self.isDisposed, self.selectedThreadId == threadId else { return }
                self.streamUIBackpressured = true
            }
        case .buffered:
            break
        case .saturated:
            // Single frame larger than the entire hot queue. Provider keeps
            // running; apply directly (timeline caps) and rehydrate later.
            let refused = event
            Task { @MainActor in
                guard !self.isDisposed, self.selectedThreadId == threadId else { return }
                self.streamUIBackpressured = true
                self.applyRefusedStreamEventDirectly(refused, run: run, threadId: threadId)
            }
        case .saturationAlreadyReported:
            Task { @MainActor in
                guard !self.isDisposed, self.selectedThreadId == threadId else { return }
                self.streamUIBackpressured = true
            }
        }
    }

    private func resetTimelineUpdateTick() {
        timelineUpdateTickTask?.cancel()
        timelineUpdateTickTask = nil
        timelineUpdateTick = 0
    }

    private func scheduleTimelineUpdateTick() {
        guard timelineUpdateTickTask == nil else { return }
        // ~30 Hz paint coalesce (was 16 ms / 60 Hz) — fewer full transcript
        // re-evaluations while tokens stream.
        timelineUpdateTickTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(33))
            guard !Task.isCancelled else { return }
            self.timelineUpdateTick &+= 1
            self.timelineUpdateTickTask = nil
        }
    }

    /// Whether this Agent App surface should treat a finished run as local work
    /// that may promote the sidebar workspace MRU / refresh busy chrome.
    /// WHY: every mounted Agent App observes the coordinator. Without a workspace
    /// gate, one completed run fans out `onRunCompleted` to every surface and each
    /// re-stamps a different workspace's `lastActivityAt`, so the workspace that
    /// just finished is no longer first in the MRU list.
    nonisolated public static func shouldHandleRunFinishForWorkspace(
        threadWorkspace: WorkspaceID?,
        surfaceWorkspace: WorkspaceID
    ) -> Bool {
        threadWorkspace == surfaceWorkspace
    }

    /// Sidebar promote / busy refresh belongs only to the workspace that owned
    /// the finished run — not to every open Agent App tab in other workspaces.
    nonisolated public static func shouldNotifyHostOfRunLifecycle(
        threadWorkspace: WorkspaceID?,
        surfaceWorkspace: WorkspaceID,
        status: AgentRunStatus,
        notifyOnCompletedOnly: Bool
    ) -> Bool {
        guard shouldHandleRunFinishForWorkspace(
            threadWorkspace: threadWorkspace,
            surfaceWorkspace: surfaceWorkspace
        ) else { return false }
        if notifyOnCompletedOnly { return status == .completed }
        return true
    }

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
        streamEventBatch.resetSaturation(for: runId)
        Task { @MainActor in
            guard !self.isDisposed else { return }
            let finishedTid = threadId
            // Same workspace filter as didChangeStatus: multi-tab Agent Apps must
            // not pay MainActor work or promote unrelated workspaces on finish.
            let threadWorkspace: WorkspaceID?
            if let cached = self.threadWorkspaceCache[finishedTid] {
                threadWorkspace = cached
            } else {
                threadWorkspace = try? self.threadRepo.get(id: finishedTid)?.workspaceId
                if let wid = threadWorkspace {
                    self.threadWorkspaceCache[finishedTid] = wid
                }
            }
            guard Self.shouldHandleRunFinishForWorkspace(
                threadWorkspace: threadWorkspace,
                surfaceWorkspace: self.workspaceID
            ) else { return }

            self.terminalRunIds = Self.boundedTerminalRunIds(existing: self.terminalRunIds, adding: runId)
            self.runThreads[runId] = nil
            if status == .completed, let msg = finalMessage, !msg.isEmpty {
                // The coordinator is normally the persistence owner, but
                // live provider completions can arrive after stream drain on
                // a background handler. Keep the restart contract here too.
                self.persistFinalAssistantIfMissing(msg, threadId: finishedTid)
                if finishedTid == self.selectedThreadId {
                    self.loadAllMessages(finishedTid)
                    self.suppressPersistedFinalDuplicatedByTimeline()
                    self.timeline.clearActivePlan()
                    self.scheduleTimelineUpdateTick()
                }
            }
            if finishedTid == self.selectedThreadId {
                if self.streamUIBackpressured {
                    self.rehydrateTimelineAfterStreamBackpressure(threadId: finishedTid)
                }
                if status == .completed || status == .cancelled {
                    // A finished turn that progressed past a durability blip must
                    // not leave "database is locked" stuck under the composer.
                    if let err = self.timeline.error,
                       Self.isTransientPersistenceTimelineError(err) {
                        self.timeline.clearError()
                        self.lastErrorRecoverable = false
                        self.scheduleTimelineUpdateTick()
                    }
                }
                if status == .failed,
                   self.timeline.error == nil,
                   let finalMessage,
                   !finalMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let recoverable = Self.errorRecoveryAction(
                        provider: self.provider,
                        message: finalMessage,
                        recoverable: false
                    ) == .retry
                    self.timeline.apply(.error(message: finalMessage, recoverable: recoverable))
                    self.lastErrorRecoverable = recoverable
                    self.scheduleTimelineUpdateTick()
                }
                self.status = status
                self.currentRunId = nil
                self.runStartedAt = nil
                // UX-MAC_AGENT-PLAN-FRESH: end-of-run lifts follow-up plan suppress so a
                // later turn (or durable rehydrate) is not permanently latched off when
                // the provider never emitted a fresh plan this run. Paint gate still
                // hides stale/all-done checklists independently. Keep suppress if a
                // queued successor is waiting (prior plan must not reappear mid-queue).
                self.clearActivePlanFollowUpSuppressionIfSafe()
                self.isStopping = false  // UX-MAC_AGENT-STOP: run finished; clear stopping flag
            }
            // Coalesce N same-workspace Agent App tabs into one reload per surface.
            self.scheduleReloadThreads()
            self.loadGitBranchThrottled()   // the run may have changed the tree
            if Self.shouldNotifyHostOfRunLifecycle(
                threadWorkspace: threadWorkspace,
                surfaceWorkspace: self.workspaceID,
                status: status,
                notifyOnCompletedOnly: true
            ) {
                self.onRunCompleted?()
                // Plan may have landed only as the turn ended; full access must still auto-implement.
                if finishedTid == self.selectedThreadId {
                    self.scheduleFullAccessPlanAutoImplementIfNeeded()
                }
            }
            self.onRunStateChange?()
            // Final replies show cumulative thread savings; refresh after each turn
            // so the footer tracks ledger growth during the conversation.
            if finishedTid == self.selectedThreadId {
                self.reloadTokenSaverThreadSavings()
            }
        }
    }

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID) {
        Task { @MainActor in
            guard !self.isDisposed else { return }
            // PERF-MAC_AGENT-009: use the cache for the workspace filter; fall back to
            // DB only on a cache miss (first event for a thread not yet loaded here).
            let threadWorkspace: WorkspaceID?
            if let cached = self.threadWorkspaceCache[threadId] {
                threadWorkspace = cached
            } else {
                threadWorkspace = try? self.threadRepo.get(id: threadId)?.workspaceId
                if let wid = threadWorkspace {
                    self.threadWorkspaceCache[threadId] = wid
                }
            }
            guard threadWorkspace == self.workspaceID else { return }
            // Coalesce N same-workspace Agent App tabs into one reload per surface.
            self.scheduleReloadThreads()
            if threadId == self.selectedThreadId {
                if status == .running {
                    self.status = status
                    self.terminalRunIds.remove(runId)
                    self.currentRunId = runId
                    self.runStartedAt = AgentAppViewModel.resolvedRunStartedAt(
                        current: self.runStartedAt,
                        persisted: (try? self.coordinator.runStartedAt(threadId: threadId)) ?? (try? self.coordinator.runStartedAt(runId: runId))
                    )
                    self.isStopping = false  // UX-MAC_AGENT-STOP: new run started; clear any stale stopping flag
                } else if Self.isTerminalRunStatus(status) {
                    // Always record the terminal runId so late stream events cannot
                    // re-inflate runThreads / Working after cancel/complete (ghost
                    // "Threads · N active"). Full selected-thread idle paint still
                    // waits until the coordinator releases active ownership.
                    self.terminalRunIds = Self.boundedTerminalRunIds(existing: self.terminalRunIds, adding: runId)
                    self.runThreads[runId] = nil
                    if !self.coordinator.activeThreadIdsSnapshot().contains(threadId) {
                        self.status = status
                        self.currentRunId = nil
                        self.runStartedAt = nil
                        self.clearActivePlanFollowUpSuppressionIfSafe()
                        self.isStopping = false  // UX-MAC_AGENT-STOP: terminal; clear stopping flag
                    } else {
                        // Ownership still held: nudge durable reconcile so a
                        // finishedAt row cannot leave activeThreads ghosted.
                        _ = self.coordinator.reconcileStaleActiveOwnershipWithDurableState()
                        if !self.coordinator.activeThreadIdsSnapshot().contains(threadId) {
                            self.status = status
                            self.currentRunId = nil
                            self.runStartedAt = nil
                            self.clearActivePlanFollowUpSuppressionIfSafe()
                            self.isStopping = false
                        }
                    }
                } else {
                    self.status = status
                }
            } else if Self.isTerminalRunStatus(status) {
                // Non-selected threads: still clear the rail projection so the
                // active count and spinner drop when this run ends.
                self.terminalRunIds = Self.boundedTerminalRunIds(existing: self.terminalRunIds, adding: runId)
                self.runThreads[runId] = nil
                _ = self.coordinator.reconcileStaleActiveOwnershipWithDurableState()
            }
            // Admission receipts finalize on terminal status; refresh so Active/Done
            // lists track real lifecycle without a separate poll.
            self.refreshSubagentActivity()
            self.onRunStateChange?()
        }
    }

    private static func isTerminalRunStatus(_ status: AgentRunStatus) -> Bool {
        switch status {
        case .completed, .failed, .cancelled, .interrupted:
            return true
        case .pending, .running:
            return false
        }
    }

    // MARK: - Continue (relaunch-interrupted thread) seam

    /// Pure, testable function that decides whether to show the inline Continue
    /// action. True only when the selected thread has a recoverable provider
    /// session AND no run is currently active.
    /// WHY: a relaunch-interrupted thread should be one-click resumable, not a
    /// dead end requiring the user to re-type their last prompt.
    nonisolated public static func showsContinueAction(hasRecoverableContext: Bool, runActive: Bool) -> Bool {
        hasRecoverableContext && !runActive
    }

    /// Recoverability belongs to the currently displayed error. Timeline replay
    /// retains the last error banner, so relaunch/thread switching must restore
    /// the matching Retry affordance from the same persisted event stream.
    nonisolated public static func displayedErrorIsRecoverable(in events: [AssistantEvent]) -> Bool {
        for event in events.reversed() {
            if case .error(_, let recoverable) = event { return recoverable }
        }
        return false
    }

    /// Resume a relaunch-interrupted provider context without inventing an empty
    /// user message. The instruction is provider-only and the coordinator loads
    /// the durable cursor plus runtime configuration from the interrupted session.
    public func continueInterruptedThread() async {
        guard let continuingThreadId = selectedThreadId else { return }
        guard !coordinator.hasProviderSession(threadId: continuingThreadId) else {
            statusMessage = "The provider turn is still running."
            return
        }
        let hadRecoverableContext = selectedThreadHasRecoverableContext
        let runId = await startProviderRun(
            text: "Continue the interrupted turn from the last saved context. Do not repeat completed work.",
            attached: [],
            recordHistory: false,
            interactionMode: interactionMode,
            resumeInterrupted: true
        )
        if runId == nil,
           selectedThreadId == continuingThreadId,
           hadRecoverableContext {
            selectedThreadHasRecoverableContext = true
        }
    }

    // MARK: - Stop button state seam

    public enum StopButtonState: Equatable {
        /// Run is active, stop has not been requested yet.
        case stop
        /// Stop was requested; button is disabled while the interrupt round-trips.
        case stopping
        /// No active run; button should be hidden.
        case hidden
    }

    /// Pure, testable function that drives the Stop button label and enabled state.
    /// WHY: a Stop button with no feedback invites repeated clicks and user confusion.
    public static func stopButtonState(runActive: Bool, isStopping: Bool) -> StopButtonState {
        guard runActive else { return .hidden }
        return isStopping ? .stopping : .stop
    }

    /// Returns the authoritative run-start time.
    ///
    /// WHY: the Mac IS the host, so the persisted `AgentRun.startedAt` is the
    /// ground truth. The `current` argument (the value already held by the
    /// view model) is returned unchanged when it is already set AND no persisted
    /// value is available -- this handles the brief race between run creation
    /// and DB commit. When `persisted` is available it always wins so that
    /// "Working for Xs" counts from the true start, not from the moment the
    /// view noticed the run.
    nonisolated public static func resolvedRunStartedAt(current: Date?, persisted: Date?) -> Date {
        if let persisted { return persisted }
        return current ?? Date()
    }

    // PERF-L15: bound the terminal-run-id set so it cannot grow without limit.
    // Run IDs are fresh UUIDs; they are never re-used, so old finished IDs
    // accumulate forever. The gate at flushStreamEvents only needs recent IDs
    // (coordinator has already released any run older than cap). When the set
    // would exceed cap, drop an arbitrary existing entry (not the new one).
    // internal (not private) so the test target can call it directly.
    nonisolated internal static func boundedTerminalRunIds(
        existing: Set<AgentRunID>,
        adding newId: AgentRunID,
        cap: Int = 256
    ) -> Set<AgentRunID> {
        var updated = existing
        updated.insert(newId)
        if updated.count > cap, let oldest = updated.first(where: { $0 != newId }) {
            updated.remove(oldest)
        }
        return updated
    }

    func refreshSR1TranslationStateFromTimeline(
        _ sourceTimeline: AssistantTimelineState? = nil,
        preservingExisting: Bool = false
    ) {
        let sourceTimeline = sourceTimeline ?? timeline
        var ids: Set<AgentMessageID> = []
        var originals: [AgentMessageID: String] = [:]
        for (rawId, translation) in sourceTimeline.sr1TranslationsByMessageId {
            guard let uuid = UUID(uuidString: rawId) else { continue }
            let id = AgentMessageID(uuid)
            ids.insert(id)
            originals[id] = translation.originalText
        }
        // Two callers, two semantics:
        // - Live-stream batches REPLACE, so translations evicted by the hot-text
        //   budget also leave the published cache (memory bound).
        // - selectThread replays PRESERVE, because live badges
        //   (onSR1TranslatedMessageId) are not in the persisted replay and a
        //   same-thread reselect or the deferred provider-snapshot re-replay must
        //   not wipe them (F6 keeps clearing as the explicit job of the
        //   thread-SWITCH branch in selectThread).
        if preservingExisting {
            ids.formUnion(sr1TranslatedMessageIds)
            originals.merge(sr1OriginalTextsByMessageId) { fromTimeline, _ in fromTimeline }
        }
        if ids != sr1TranslatedMessageIds {
            sr1TranslatedMessageIds = ids
        }
        if originals != sr1OriginalTextsByMessageId {
            sr1OriginalTextsByMessageId = originals
        }
    }
}

/// Lock-protected selected-thread mirror for multi-tab stream filtering.
/// Safe from coordinator background threads and the main actor.
final class InterestedThreadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AgentThreadID?

    func set(_ id: AgentThreadID?) {
        lock.lock()
        value = id
        lock.unlock()
    }

    func get() -> AgentThreadID? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// PERF-MAC_AGENT-010: lock-protected buffer used by runCoordinator(_:didReceive:)
// to coalesce streaming events. Safe to access from both the coordinator's
// background thread (append) and the main actor (drain).
final class StreamEventBatch: @unchecked Sendable {
    struct Limits: Equatable {
        /// Hot UI queue only — durable stream history is bounded separately.
        /// Hot UI queue only — durable stream history is bounded separately.
        /// Smaller quanta keep each MainActor hop short so scrolling/composer
        /// stay responsive during tool storms (rehydrate fills gaps after).
        var maxBufferedCount: Int = 8_192
        var maxBufferedBytes: Int = 32 * 1_024 * 1_024
        var drainCount: Int = 64
        var drainBytes: Int = 1 * 1_024 * 1_024
    }

    enum AppendOutcome: Equatable {
        case scheduled
        case buffered
        /// Newest event admitted after dropping oldest buffered UI events.
        case scheduledAfterEviction
        case bufferedAfterEviction
        /// Single frame larger than the entire hot queue — cannot retain; durable
        /// history still holds it and the surface rehydrates from there.
        case saturated
        case saturationAlreadyReported
    }

    struct DrainQuantum {
        let entries: [(event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID)]
        let encodedByteCount: Int
        let hasMore: Bool
    }

    private struct Entry {
        let event: AssistantEvent
        let run: AgentRunID
        let threadId: AgentThreadID
        let encodedByteCount: Int
    }
    private let lock = NSLock()
    private let limits: Limits
    private var buffer: [Entry] = []
    private var bufferedBytes = 0
    private var flushScheduled = false
    private var saturationRunID: AgentRunID?

    init(limits: Limits = Limits()) {
        self.limits = Limits(
            maxBufferedCount: max(1, limits.maxBufferedCount),
            maxBufferedBytes: max(1, limits.maxBufferedBytes),
            drainCount: max(1, limits.drainCount),
            drainBytes: max(1, limits.drainBytes)
        )
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return buffer.isEmpty
    }

    /// Appends an event. Returns `true` iff the caller should schedule a flush Task
    /// (i.e. the buffer was empty before this append — first event of the tick).
    func append(event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) -> Bool {
        appendBounded(event: event, run: run, threadId: threadId) == .scheduled
    }

    func appendBounded(event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) -> AppendOutcome {
        let eventBytes = (try? JSONEncoder().encode(event).count) ?? event.debugDescription.utf8.count
        let bytes = eventBytes + MemoryLayout<AgentRunID>.stride + MemoryLayout<AgentThreadID>.stride
        lock.lock()
        defer { lock.unlock() }
        if let saturationRunID, saturationRunID != run {
            self.saturationRunID = nil
        }
        // drainBytes is a *paint quantum* (how much work one MainActor hop applies),
        // not a hard admission ceiling. drainQuantum already admits a single event
        // larger than the quantum when the buffer head is oversized.
        //
        // Budget pressure: drop OLDEST buffered UI events until the newest fits.
        // Durable stream history still has the dropped paints; the surface rehydrates.
        // Only a single frame larger than the entire hot queue is refused.
        if bytes > limits.maxBufferedBytes {
            if saturationRunID == run { return .saturationAlreadyReported }
            saturationRunID = run
            return .saturated
        }
        var didEvict = false
        while !buffer.isEmpty
            && (buffer.count >= limits.maxBufferedCount
                || bufferedBytes + bytes > limits.maxBufferedBytes) {
            let removed = buffer.removeFirst()
            bufferedBytes = max(0, bufferedBytes - removed.encodedByteCount)
            didEvict = true
        }
        buffer.append(Entry(event: event, run: run, threadId: threadId, encodedByteCount: bytes))
        bufferedBytes += bytes
        if didEvict {
            saturationRunID = run
            if flushScheduled { return .bufferedAfterEviction }
            flushScheduled = true
            return .scheduledAfterEviction
        }
        if flushScheduled { return .buffered }
        flushScheduled = true
        return .scheduled
    }

    func drainQuantum() -> DrainQuantum {
        lock.lock()
        defer { lock.unlock() }
        var count = 0
        var bytes = 0
        while count < buffer.count && count < limits.drainCount {
            let next = buffer[count].encodedByteCount
            if count > 0 && bytes + next > limits.drainBytes { break }
            bytes += next
            count += 1
        }
        let drained = Array(buffer.prefix(count))
        buffer.removeFirst(count)
        bufferedBytes -= bytes
        let hasMore = !buffer.isEmpty
        flushScheduled = hasMore
        if !hasMore { saturationRunID = nil }
        return DrainQuantum(
            entries: drained.map { ($0.event, $0.run, $0.threadId) },
            encodedByteCount: bytes,
            hasMore: hasMore
        )
    }

    /// Drains and returns all buffered entries, resetting the buffer and the
    /// scheduled flag so the next incoming event will schedule a new flush.
    func drain() -> [(event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID)] {
        lock.lock()
        defer { lock.unlock() }
        let out = buffer.map { ($0.event, $0.run, $0.threadId) }
        buffer.removeAll(keepingCapacity: true)
        bufferedBytes = 0
        flushScheduled = false
        saturationRunID = nil
        return out
    }

    func resetSaturation(for runID: AgentRunID) {
        lock.lock()
        if saturationRunID == runID { saturationRunID = nil }
        lock.unlock()
    }
}

public struct AgentComposerSuggestion: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        case slashCommand
        case skill
    }

    public let id: String
    public let title: String
    public let subtitle: String
    public let insertText: String
    public let kind: Kind

    public init(title: String, subtitle: String, insertText: String, kind: Kind) {
        self.id = "\(kind)-\(insertText)"
        self.title = title
        self.subtitle = subtitle
        self.insertText = insertText
        self.kind = kind
    }
}

public enum AgentComposerSuggestions {
    /// Provider-pass-through commands available on every Agent provider (Codex,
    /// Claude, Grok). Not RemoteCode-local handlers — `send` forwards them as the
    /// first user token. Always merged into autocomplete + `$`→`/` normalization so
    /// a stale/empty snapshot cannot hide `/goal`.
    public static let passThroughSlashCommands = ["/goal"]

    public static func suggestions(
        for text: String,
        cursorOffset: Int? = nil,
        snapshot: AgentProviderSnapshot?,
        localSlashCommands: [String],
        extraCommands: [String] = [],
        extraSkillNames: [String] = [],
        limit: Int = 8
    ) -> [AgentComposerSuggestion] {
        let token = activeToken(in: text, cursorOffset: cursorOffset)
        // Both `/` and `$` open the same mixed catalog: modes/commands + skills.
        // Insert text keeps the typed trigger so `/sam-work` and `$goal` work.
        guard let trigger = token.first, trigger == "/" || trigger == "$" else { return [] }
        let prefix = String(trigger)
        let query = String(token.dropFirst()).lowercased()
        let display = snapshot?.displayName ?? "Provider"
        // extraCommands = provider built-ins the app doesn't own (e.g. `/mcp`).
        // extraSkillNames = project/user skills + commands discovered on disk so
        // the menu matches interactive claude's `/`, not just the cached probe.
        let providerCommands = Array(Set((snapshot?.slashCommands ?? []) + passThroughSlashCommands + extraCommands))
        let allCommands = Array(Set(localSlashCommands + providerCommands))
        let skills = Array(Set((snapshot?.skills ?? []) + extraSkillNames))

        struct Candidate: Equatable {
            let bare: String
            let kind: AgentComposerSuggestion.Kind
            let subtitle: String
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(allCommands.count + skills.count)
        for command in allCommands {
            let bare = command.hasPrefix("/") || command.hasPrefix("$")
                ? String(command.dropFirst())
                : command
            guard !bare.isEmpty else { continue }
            let source = localSlashCommands.contains(command) || localSlashCommands.contains("/\(bare)")
                ? "RemoteCode command"
                : "\(display) command"
            candidates.append(Candidate(bare: bare, kind: .slashCommand, subtitle: source))
        }
        for skill in skills where !skill.isEmpty {
            candidates.append(Candidate(
                bare: skill,
                kind: .skill,
                subtitle: "\(display) skill"
            ))
        }

        // WHY: skill catalogs are large (50–80+). Ranking every bare name together
        // with limit=8 buries modes/commands (`/plan`, `/goal`) under ads-* skills
        // on bare `/`. Emit every matching command first (never truncated by limit),
        // then give skills their OWN budget of `limit` rows on top. The earlier
        // `max(limit, commandCount)` cap starved skills to ZERO whenever commands
        // already filled `limit` (e.g. Claude's built-ins + `/mcp`), hiding every
        // project/user skill on a bare `/`; skills must always get room.
        let commandBares = ranked(
            candidates.filter { $0.kind == .slashCommand }.map(\.bare),
            query: query
        )
        let skillBares = ranked(
            candidates.filter { $0.kind == .skill }.map(\.bare),
            query: query
        )
        var seenBareKind = Set<String>()
        var results: [AgentComposerSuggestion] = []
        results.reserveCapacity(max(limit, commandBares.count))

        func append(bares: [String], kind: AgentComposerSuggestion.Kind, stopAt: Int?) {
            for bare in bares {
                if let stopAt, results.count >= stopAt { return }
                for candidate in candidates
                    where candidate.kind == kind
                        && candidate.bare.caseInsensitiveCompare(bare) == .orderedSame {
                    let key = "\(candidate.kind)-\(candidate.bare.lowercased())"
                    guard seenBareKind.insert(key).inserted else { continue }
                    let title = "\(prefix)\(candidate.bare)"
                    results.append(AgentComposerSuggestion(
                        title: title,
                        subtitle: candidate.subtitle,
                        insertText: "\(title) ",
                        kind: candidate.kind
                    ))
                    if let stopAt, results.count >= stopAt { return }
                }
            }
        }

        append(bares: commandBares, kind: .slashCommand, stopAt: nil)
        let skillCap = results.count + limit
        append(bares: skillBares, kind: .skill, stopAt: skillCap)
        return results
    }

    /// Canonical first-token triggers before provider dispatch (all providers):
    /// - Known slash commands → `/name` (from `$name` or `/name`)
    /// - Known skills that are not also commands → `$name` (from `/name` or `$name`)
    /// Commands win on name collision so `$plan`/`/plan` stay modes, not skills.
    public static func normalizingComposerTriggerPrefix(
        _ raw: String,
        localSlashCommands: [String],
        providerSlashCommands: [String],
        skills: [String]
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trigger = trimmed.first, trigger == "/" || trigger == "$" else { return raw }
        let body = trimmed.dropFirst()
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let barePart = parts.first else { return raw }
        let bareRaw = String(barePart)
        let bareKey = bareRaw.lowercased()
        guard !bareKey.isEmpty else { return raw }

        func bareCatalog(_ tokens: [String]) -> [String: String] {
            var map: [String: String] = [:]
            for token in tokens {
                let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedToken.isEmpty else { continue }
                let name = (trimmedToken.hasPrefix("/") || trimmedToken.hasPrefix("$"))
                    ? String(trimmedToken.dropFirst())
                    : trimmedToken
                let key = name.lowercased()
                guard !key.isEmpty, map[key] == nil else { continue }
                map[key] = name
            }
            return map
        }

        let commandCatalog = bareCatalog(localSlashCommands + providerSlashCommands)
        let skillCatalog = bareCatalog(skills)
        let argument = parts.count > 1 ? String(parts[1]) : nil

        func compose(prefix: Character, name: String) -> String {
            if let argument, !argument.isEmpty {
                return "\(prefix)\(name) \(argument)"
            }
            return "\(prefix)\(name)"
        }

        if let commandName = commandCatalog[bareKey] {
            return compose(prefix: "/", name: commandName.lowercased())
        }
        if let skillName = skillCatalog[bareKey] {
            return compose(prefix: "$", name: skillName)
        }
        return raw
    }

    /// Compatibility wrapper: command-only rewrite (`$goal` → `/goal`).
    public static func normalizingProviderSlashPrefix(
        _ raw: String,
        localSlashCommands: [String],
        providerSlashCommands: [String]
    ) -> String {
        normalizingComposerTriggerPrefix(
            raw,
            localSlashCommands: localSlashCommands,
            providerSlashCommands: providerSlashCommands,
            skills: []
        )
    }

    public static func replacingActiveToken(in text: String, cursorOffset: Int? = nil, with replacement: String) -> String {
        guard let range = activeTokenRange(in: text, cursorOffset: cursorOffset) else { return replacement }
        var updated = text
        updated.replaceSubrange(range, with: replacement)
        return updated
    }

    private static func activeToken(in text: String, cursorOffset: Int? = nil) -> String {
        guard let range = activeTokenRange(in: text, cursorOffset: cursorOffset) else { return "" }
        return String(text[range])
    }

    /// Returns the range of the token immediately before the cursor.
    ///
    /// WHY: suggestions must anchor at the cursor position, not `text.endIndex`,
    /// so that editing the middle of a multiline prompt (e.g. inserting a slash
    /// command on line 2 of 3) produces correct suggestions. When `cursorOffset`
    /// is nil the old behavior (anchor at endIndex) is preserved for call sites
    /// that have not yet been wired up.
    ///
    /// The token extends from the nearest preceding whitespace (exclusive) to
    /// the cursor position (exclusive of any text after the cursor).
    nonisolated public static func activeTokenRange(text: String, cursorOffset: Int) -> Range<String.Index>? {
        let utf16 = text.utf16
        // Negative offsets are invalid (buggy caller) -> nil. An offset past the
        // end (e.g. a transient paste race in NSTextView) clamps to endIndex so
        // suggestions still resolve the trailing token rather than vanishing.
        guard cursorOffset >= 0 else { return nil }
        let cursorOffset = min(cursorOffset, utf16.count)
        let cursorIdx: String.Index
        if cursorOffset == utf16.count {
            cursorIdx = text.endIndex
        } else if let idx = text.index(text.startIndex, offsetBy: cursorOffset, limitedBy: text.endIndex) {
            cursorIdx = idx
        } else {
            cursorIdx = text.endIndex
        }
        var start = cursorIdx
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isWhitespace { break }
            start = previous
        }
        guard start < cursorIdx else { return nil }
        return start..<cursorIdx
    }

    private static func activeTokenRange(in text: String, cursorOffset: Int? = nil) -> Range<String.Index>? {
        if let offset = cursorOffset {
            return activeTokenRange(text: text, cursorOffset: offset)
        }
        // Legacy: anchor at text.endIndex (used when cursor position is unknown).
        let end = text.endIndex
        var start = end
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isWhitespace { break }
            start = previous
        }
        guard start < end else { return nil }
        return start..<end
    }

    private static func ranked(_ values: [String], query: String) -> [String] {
        let unique = Array(Set(values)).sorted()
        guard !query.isEmpty else { return unique }
        let normalizedQuery = query.hasPrefix("$") || query.hasPrefix("/")
            ? String(query.dropFirst()).lowercased()
            : query
        guard !normalizedQuery.isEmpty else { return unique }
        return unique
            .filter {
                let value = $0.lowercased()
                let bare = value.hasPrefix("/") || value.hasPrefix("$")
                    ? String(value.dropFirst())
                    : value
                return bare.contains(normalizedQuery) || value.contains(normalizedQuery)
            }
            .sorted { lhs, rhs in
                let l = lhs.lowercased()
                let r = rhs.lowercased()
                let lBare = l.hasPrefix("/") || l.hasPrefix("$") ? String(l.dropFirst()) : l
                let rBare = r.hasPrefix("/") || r.hasPrefix("$") ? String(r.dropFirst()) : r
                let lp = lBare.hasPrefix(normalizedQuery) || l.hasPrefix(normalizedQuery)
                    || l.hasPrefix("/\(normalizedQuery)") || l.hasPrefix("$\(normalizedQuery)")
                let rp = rBare.hasPrefix(normalizedQuery) || r.hasPrefix(normalizedQuery)
                    || r.hasPrefix("/\(normalizedQuery)") || r.hasPrefix("$\(normalizedQuery)")
                if lp != rp { return lp }
                return lhs < rhs
            }
    }
}

public enum AgentContextStatusPresentation {
    public static func message(usage: AssistantTokenUsage?, compactionSummary: String?) -> String? {
        let compacted = compactionSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let usage else {
            return compacted?.isEmpty == false ? "Context compacted: \(compacted!)" : nil
        }
        // Occupancy percentage must come from per-request `contextTokens` only.
        // `totalTokens` can be session-cumulative billing (Claude modelUsage cache
        // re-reads) and must never drive "Context N%" — that produced 999%.
        let tokenText: String
        if let occupancy = usage.contextTokens {
            if let window = usage.contextWindow, window > 0 {
                let pct = min(100, max(0, Int((Double(occupancy) / Double(window) * 100).rounded())))
                tokenText = "Context \(pct)% · \(occupancy) / \(window) tokens"
            } else {
                tokenText = "Context \(occupancy) tokens"
            }
        } else if let window = usage.contextWindow, window > 0 {
            tokenText = "Session \(usage.totalTokens) / \(window) tokens"
        } else {
            tokenText = "Session \(usage.totalTokens) tokens"
        }
        var parts = [tokenText]
        if usage.compactsAutomatically == true {
            parts.append("auto-compacts")
        }
        if let compacted, !compacted.isEmpty {
            parts.append("compacted")
        }
        return parts.joined(separator: " · ")
    }
}

public struct AgentTimelineItemPresentation: Equatable, Sendable {
    public let icon: String
    public let verb: String
    public let label: String
    public let detail: String?

    public static func make(for item: AssistantItem) -> AgentTimelineItemPresentation {
        let label = primaryText(for: item).replacingOccurrences(of: "\n", with: " ")
        return AgentTimelineItemPresentation(
            icon: icon(for: item),
            verb: verb(for: item),
            label: label,
            detail: detailText(for: item)
        )
    }

    private static func primaryText(for item: AssistantItem) -> String {
        if let progress = item.progress {
            let percent = Int((AssistantTimelineState.normalizedProgress(progress) * 100).rounded())
            return "\(percent)% \(basePrimaryText(for: item))"
        }
        return basePrimaryText(for: item)
    }

    private static func basePrimaryText(for item: AssistantItem) -> String {
        if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary
        }
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? item.type.rawValue : body
    }

    private static func detailText(for item: AssistantItem) -> String? {
        if item.type == .reasoning {
            // F21: the Codex app-server adapter streams reasoning text into `output`
            // with a constant "Reasoning" summary, so prefer the actual text over
            // the placeholder; summary remains the fallback for providers that only
            // send reasoning summaries.
            if item.output?.isEmpty == false { return item.output }
            let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary?.isEmpty == false ? summary : nil
        }
        return item.output?.isEmpty == false ? item.output : nil
    }

    /// The command / input that a tool actually ran, extracted from `item.body`.
    /// The parser stores a tool_use's input there as JSON (e.g. {"command":"…"} for Bash,
    /// {"file_path":"…"} for Read/Edit). The transcript previously showed only "Ran Bash"
    /// with no command — this surfaces the actual command so the run is legible.
    static func toolCommandPreview(for item: AssistantItem) -> String? {
        switch item.type {
        case .tool, .mcpToolCall, .dynamicToolCall, .collabToolCall, .commandExecution:
            break
        default:
            return nil
        }
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Most-informative field per tool family, in priority order.
            for key in ["command", "cmd", "script", "query", "pattern", "skill", "file_path", "path", "url", "prompt", "name"] {
                if let value = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return AgentAppView.cappedVisibleText(value, limit: AgentAppView.commandPreviewCharacterLimit, truncatedLabel: "hidden from preview")
                }
            }
            // Prefer humanized meta for opaque task/timeout payloads over raw API keys.
            if let human = humanizedStructuredPreview(from: obj) {
                return human
            }
            // Unknown shape: a clean one-line key: value digest. Scalars show their value;
            // arrays/objects show a compact shape hint (not Swift's brace-y debug description).
            let digest = obj.keys.sorted().prefix(4).map { key -> String in
                "\(key): \(Self.shortValue(obj[key]))"
            }.joined(separator: "   ")
            return digest.isEmpty ? nil : digest
        }
        // Non-JSON body is already a human-readable input/description.
        return AgentAppView.cappedVisibleText(body, limit: AgentAppView.commandPreviewCharacterLimit, truncatedLabel: "hidden from preview")
    }

    // MARK: Tool card presentation (collapsed density)

    /// L1 title for tool rows: short tool name without full shell pipelines or call UUIDs.
    /// Does not mutate stored summary/body — pure display transform.
    static func toolDisplayLabel(for item: AssistantItem) -> String {
        var label = basePrimaryText(for: item)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Provider titles sometimes embed `[bg]` + the whole command.
        label = label.replacingOccurrences(
            of: #"^\[bg\]\s*"#,
            with: "",
            options: .regularExpression
        )
        label = label.replacingOccurrences(
            of: #"(?i)^background:\s*"#,
            with: "",
            options: .regularExpression
        )
        // "Get task output: call-<uuid>" / trailing call ids
        label = label.replacingOccurrences(
            of: #"(?i)(?::\s*|\s+)call-[0-9a-f-]{8,}\s*$"#,
            with: "",
            options: .regularExpression
        )
        label = label.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
        if looksLikeShellCommand(label) {
            return shellToolFamilyName(for: item)
        }
        if label.contains("_"), !label.contains(" "), label.count <= 64 {
            return label
                .split(separator: "_")
                .map { part in
                    let s = String(part)
                    return s.prefix(1).uppercased() + s.dropFirst().lowercased()
                }
                .joined(separator: " ")
        }
        // Collapse very long titles that aren't pure shell (still too noisy for L1).
        if label.count > 48, toolCommandPreview(for: item) != nil {
            return shellToolFamilyName(for: item)
        }
        return label.isEmpty ? item.type.rawValue : label
    }

    /// Collapsed L2 summary: meaningful last command, no distill pipe, short paths.
    /// Full command remains available via `toolCommandPreview` when expanded.
    /// When stages are elided, appends `· +N more` so density never silently drops intent.
    static func toolCommandSummary(for item: AssistantItem) -> String? {
        guard let full = toolCommandPreview(for: item) else { return nil }
        // Structured human previews are already short — keep them.
        if full.contains(" · ") || full.hasPrefix("timeout ") || full.hasSuffix(" task") || full.hasSuffix(" tasks") {
            return full
        }
        return summarizeShellishCommand(full)
    }

    /// True when the tool ran (or is running) detached/backgrounded.
    static func isBackgroundTool(for item: AssistantItem) -> Bool {
        if let summary = item.summary?.lowercased(),
           summary.contains("[bg]")
            || summary.contains("background shell")
            || summary.contains("background agent")
            || summary.hasPrefix("background") {
            return true
        }
        guard let obj = toolInputObject(for: item) else { return false }
        if let flag = obj["background"] as? Bool { return flag }
        if let flag = obj["background"] as? NSNumber { return flag.boolValue }
        if let flag = obj["run_in_background"] as? Bool { return flag }
        if let flag = obj["run_in_background"] as? NSNumber { return flag.boolValue }
        return false
    }

    /// Token Saver distill wrapper was present on the command (display chip only).
    static func toolCommandWasDistilled(for item: AssistantItem) -> Bool {
        guard let raw = rawShellCommand(for: item) ?? toolCommandPreview(for: item) else { return false }
        return raw.range(of: #"\|\s*distill\b"#, options: .regularExpression) != nil
    }

    /// Compact elapsed label (`12s`, `1m 53s`) from start→end timestamps.
    static func durationLabel(fromMs: Int64, toMs: Int64) -> String? {
        let elapsedMs = max(0, Int(toMs - fromMs))
        return formatDurationMs(elapsedMs)
    }

    /// Duration for finished timeline items only (≥1s). Streaming stays nil in v1 —
    /// no per-row live clock (perf + "Working for Xs" already covers the active run).
    static func toolDurationLabel(for item: AssistantItem, nowMs: Int64? = nil) -> String? {
        _ = nowMs // reserved for a future ElapsedTickSchedule path
        switch item.state {
        case .streaming:
            return nil
        case .completed, .failed, .cancelled:
            guard let finished = item.finishedAtMs else { return nil }
            let elapsedMs = max(0, Int(finished - item.startedAtMs))
            // Suppress 0s walls when providers stamp started==finished.
            guard elapsedMs >= 1_000 else { return nil }
            return formatDurationMs(elapsedMs)
        }
    }

    /// Accessibility label: status + tool name + optional summary + duration (not color-only).
    static func toolAccessibilityLabel(for item: AssistantItem, nowMs: Int64? = nil) -> String {
        var parts: [String] = [verb(for: item), toolDisplayLabel(for: item)]
        if isBackgroundTool(for: item) { parts.append("background") }
        if toolCommandWasDistilled(for: item) { parts.append("distilled") }
        if let summary = toolCommandSummary(for: item), !summary.isEmpty {
            parts.append(summary)
        }
        if let duration = toolDurationLabel(for: item, nowMs: nowMs) {
            parts.append(duration)
        }
        return parts.joined(separator: ", ")
    }

    /// Humanize task/timeout shaped inputs for collapsed display.
    static func humanizedStructuredPreview(from obj: [String: Any]) -> String? {
        var parts: [String] = []
        if let ids = obj["task_ids"] as? [Any], !ids.isEmpty {
            parts.append(ids.count == 1 ? "1 task" : "\(ids.count) tasks")
        } else if let id = obj["task_id"] {
            let text = shortValue(id)
            if !text.isEmpty, text != "—" { parts.append("task \(text)") }
        }
        if let timeout = intMillis(from: obj["timeout_ms"]) ?? intMillis(from: obj["timeout"]) {
            if let label = formatDurationMs(timeout) {
                parts.append("timeout \(label)")
            }
        }
        // Only claim this path when we humanized the noisy keys providers dump by default.
        let noisyKeys: Set<String> = ["task_ids", "task_id", "timeout_ms", "timeout", "call_id", "id"]
        let otherKeys = obj.keys.filter { !noisyKeys.contains($0) }
        guard !parts.isEmpty, otherKeys.isEmpty || otherKeys.count <= 1 else { return nil }
        return parts.joined(separator: " · ")
    }

    static func summarizeShellishCommand(_ command: String) -> String {
        var s = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        var elided = 0
        // Drop Token Saver distill pipes (presentation only; body stays intact).
        // Count as elided so Token Saver proof is not silently erased (chip + "+N more").
        if let range = s.range(of: #"\s*2>&1\s*\|\s*distill\b[\s\S]*$"#, options: .regularExpression) {
            s = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            elided += 1
        } else if let range = s.range(of: #"\s*\|\s*distill\b[\s\S]*$"#, options: .regularExpression) {
            s = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            elided += 1
        }
        // Drop only closed-allowlist leading segments (`cd`, `export`, `source`, `.`, `set -e…`).
        let segments = s
            .components(separatedBy: "&&")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if segments.count > 1 {
            var kept = segments
            while let first = kept.first, isDisposableLeadingShellSegment(first), kept.count > 1 {
                kept.removeFirst()
                elided += 1
            }
            s = kept.first ?? s
            if kept.count > 1 {
                // Additional trailing stages after the primary command stay collapsed.
                elided += kept.count - 1
            }
        }
        let home = NSHomeDirectory()
        if !home.isEmpty {
            s = s.replacingOccurrences(of: home, with: "~")
        }
        // Collapse `/Users/name/...` even when not exactly NSHomeDirectory (remote paths).
        s = s.replacingOccurrences(
            of: #"/Users/[^/\s]+/"#,
            with: "~/",
            options: .regularExpression
        )
        let limit = 96
        if s.count > limit {
            s = String(s.prefix(limit - 1)) + "…"
        }
        if elided > 0 {
            return "\(s) · +\(elided) more"
        }
        return s
    }

    /// Leading shell setup stages safe to hide behind `· +N more` (never hide `rm` etc.).
    static func isDisposableLeadingShellSegment(_ segment: String) -> Bool {
        let t = segment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("cd ") || t == "cd" { return true }
        if t.hasPrefix("export ") { return true }
        if t.hasPrefix("source ") || t.hasPrefix(". ") { return true }
        if t.hasPrefix("set -") || t == "set -e" || t == "set -eo pipefail" { return true }
        return false
    }

    /// Raw `command`/`cmd`/`script` string from tool input JSON (uncapped), if present.
    static func rawShellCommand(for item: AssistantItem) -> String? {
        guard let obj = toolInputObject(for: item) else { return nil }
        for key in ["command", "cmd", "script"] {
            if let value = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func looksLikeShellCommand(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 8 else { return false }
        if t.contains("&&") || t.contains("|") { return true }
        if t.hasPrefix("cd ") || t.hasPrefix("git ") || t.hasPrefix("npm ") || t.hasPrefix("swift ") {
            return true
        }
        if t.contains("/Users/") || t.hasPrefix("~/") { return true }
        return false
    }

    static func shellToolFamilyName(for item: AssistantItem) -> String {
        if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty,
           !looksLikeShellCommand(summary.replacingOccurrences(of: #"^\[bg\]\s*"#, with: "", options: .regularExpression)),
           summary.count <= 32,
           !summary.contains(":") {
            return summary.replacingOccurrences(of: #"^\[bg\]\s*"#, with: "", options: .regularExpression)
        }
        switch item.type {
        case .commandExecution: return "Shell"
        default: return "Shell"
        }
    }

    static func toolInputObject(for item: AssistantItem) -> [String: Any]? {
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty,
              let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    static func intMillis(from value: Any?) -> Int? {
        switch value {
        case let i as Int: return i
        case let i as Int64: return Int(i)
        case let n as NSNumber: return n.intValue
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(trimmed)
        default: return nil
        }
    }

    static func formatDurationMs(_ ms: Int) -> String? {
        guard ms >= 0 else { return nil }
        if ms < 1000 { return "\(max(ms, 0))ms" }
        let totalSeconds = ms / 1000
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 60 {
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
        }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        return remMinutes == 0 ? "\(hours)h" : "\(hours)h \(remMinutes)m"
    }

    /// UX-MAC_AGENT-OPEN-SPLIT: the openable target of a tool call — Read/Edit-style
    /// inputs carry a file path, fetch-style inputs a URL. Drives the transcript's
    /// "open in split panel" affordance on tool rows.
    enum ToolOpenTarget: Equatable {
        case file(String)
        case url(URL)
    }

    static func toolOpenTarget(for item: AssistantItem) -> ToolOpenTarget? {
        switch item.type {
        case .tool, .mcpToolCall, .dynamicToolCall, .collabToolCall, .commandExecution, .fileChange:
            break
        default:
            return nil
        }
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty,
              let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["file_path", "path", "notebook_path"] {
            if let value = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return .file(value)
            }
        }
        if let raw = (obj["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: raw),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return .url(url)
        }
        return nil
    }

    /// A compact, human-readable rendering of a tool-input value for the one-line digest.
    /// Scalars print their value; arrays/objects print a shape hint instead of raw braces.
    static func shortValue(_ value: Any?) -> String {
        switch value {
        case let s as String: return String(s.prefix(80))
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return "[\(a.count)]"
        case let d as [String: Any]: return "{\(d.keys.sorted().prefix(3).joined(separator: ","))}"
        case is NSNull, nil: return "—"
        default: return String(String(describing: value ?? "").prefix(40))
        }
    }

    /// Whether this timeline item is a Skill tool whose body/output must stay complete.
    /// Skill content is a protected verbatim category (never Distill / display truncation).
    static func isSkillToolItem(_ item: AssistantItem) -> Bool {
        if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           summary.compare("Skill", options: .caseInsensitive) == .orderedSame {
            return true
        }
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skill = (obj["skill"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !skill.isEmpty else {
            return false
        }
        return true
    }

    /// Sanitize + cap inline tool output: strip ANSI escape codes (Bash output is full
    /// of them and they render as literal garbage in a Text view) and cap length so one noisy
    /// command can't blow up the transcript. Full text remains selectable / in the stored event.
    /// Skill tool output is never truncated in presentation — skill content must stay complete.
    static func cappedDetail(_ text: String, limit: Int = 6_000, for item: AssistantItem? = nil) -> String {
        let clean = stripANSI(text)
        if let item, isSkillToolItem(item) {
            return clean
        }
        guard clean.count > limit else { return clean }
        let head = clean.prefix(limit)
        let dropped = clean.count - head.count
        return "\(head)\n… \(dropped) more characters truncated in view …"
    }

    /// Remove ANSI/VT control sequences (SGR colors, cursor moves, OSC) so command output is
    /// readable instead of showing literal escape codes. Cheap fast-path when none present.
    static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{001B}") else { return text }
        return text
            .replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression) // CSI (incl. SGR)
            .replacingOccurrences(of: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)", with: "", options: .regularExpression) // OSC
            .replacingOccurrences(of: "\u{001B}[@-Z\\\\-_]", with: "", options: .regularExpression) // lone escapes
    }

    private static func verb(for item: AssistantItem) -> String {
        switch item.state {
        case .streaming: return "Running"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .completed:
            switch item.type {
            case .fileChange: return "Changed"
            case .webSearch: return "Searched"
            case .imageView: return "Viewed"
            case .review: return "Reviewed"
            case .contextCompaction: return "Compacted"
            case .error: return "Issue"
            default: return "Ran"
            }
        }
    }

    private static func icon(for item: AssistantItem) -> String {
        if item.state == .streaming { return "circle.dotted" }
        if item.state == .failed { return "xmark.octagon" }
        if item.state == .cancelled { return "nosign" }
        switch item.type {
        case .fileChange: return "doc.badge.gearshape"
        case .mcpToolCall, .dynamicToolCall, .collabToolCall: return "puzzlepiece.extension"
        case .webSearch: return "magnifyingglass"
        case .imageView: return "photo"
        case .review: return "checklist"
        case .contextCompaction: return "rectangle.compress.vertical"
        case .error: return "exclamationmark.triangle"
        default: return "terminal"
        }
    }

}

public struct AgentImageViewPresentation: Equatable, Sendable {
    public let displayName: String
    public let resourceURL: URL

    public static func make(for item: AssistantItem) -> AgentImageViewPresentation? {
        guard item.type == .imageView else { return nil }
        // Prefer the private resource path (never shown as label text). Absolute
        // paths in body/summary are a last resort when resourcePath is missing.
        let candidates: [String?] = [item.resourcePath, item.body, item.summary, item.output]
        for raw in candidates {
            guard let path = Self.absoluteFilePath(from: raw) else { continue }
            let url = URL(fileURLWithPath: path)
            return AgentImageViewPresentation(
                displayName: url.lastPathComponent,
                resourceURL: url
            )
        }
        return nil
    }

    /// Absolute filesystem path only — basenames alone must not resolve against CWD.
    public static func absoluteFilePath(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("~") {
            return (trimmed as NSString).expandingTildeInPath
        }
        guard trimmed.hasPrefix("/") else { return nil }
        return (trimmed as NSString).standardizingPath
    }

    /// Pure: which items in a tool-burst group can show a transcript thumbnail.
    public static func presentations(in items: [AssistantItem]) -> [AgentImageViewPresentation] {
        items.compactMap(make(for:))
    }
}

// MARK: - Transcript image thumbnails (UX-MAC_AGENT-IMAGE-THUMB)

/// Compact or featured image preview for agent-cited images in the transcript.
/// Loads off the main actor and reserves layout space so thumbs don't CLS the chat.
private struct AgentTranscriptImageThumb: View {
    enum Style {
        /// Grid cell in a multi-image strip.
        case strip
        /// Single image row: larger, letterboxed.
        case featured
    }

    let url: URL
    let displayName: String
    var style: Style = .strip
    var accessibilityID: String = "agent.image.thumb"

    @State private var image: NSImage?
    @State private var failed = false

    private var thumbWidth: CGFloat { style == .featured ? 320 : 112 }
    private var thumbHeight: CGFloat { style == .featured ? 200 : 84 }

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .fill(DS.Palette.surface)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .frame(width: thumbWidth, height: thumbHeight)
                            .clipped()
                    } else if failed {
                        VStack(spacing: DS.Space.xs) {
                            Image(systemName: "photo")
                                .font(.system(size: style == .featured ? 22 : 16, weight: .medium))
                                .foregroundColor(DS.Palette.textTertiary)
                            if style == .featured {
                                Text("Preview unavailable")
                                    .font(DS.Font.caption2)
                                    .foregroundColor(DS.Palette.textTertiary)
                            }
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: thumbWidth, height: thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                )

                Text(displayName)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: thumbWidth, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(displayName)")
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel("Image \(displayName)")
        .accessibilityHint("Opens the image")
        .dsPointingHandCursor()
        .task(id: url.path) { await loadThumbnail() }
    }

    @MainActor
    private func loadThumbnail() async {
        failed = false
        image = nil
        let path = url.path
        let maxPixel = style == .featured ? 960 : 280
        let loaded: NSImage? = await Task.detached(priority: .utility) {
            Self.downsampledImage(at: path, maxPixel: maxPixel)
        }.value
        if let loaded {
            image = loaded
        } else {
            failed = true
        }
    }

    /// Decode a bounded thumbnail so multi-megapixel screenshots don't stall the UI.
    nonisolated private static func downsampledImage(at path: String, maxPixel: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        return NSImage(contentsOf: url)
    }
}

/// Horizontal strip of thumbnails for grouped image citations ("Running 2 images…").
private struct AgentTranscriptImageThumbStrip: View {
    let presentations: [AgentImageViewPresentation]
    var accessibilityPrefix: String = "agent.image.strip"

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                ForEach(Array(presentations.enumerated()), id: \.offset) { index, presentation in
                    AgentTranscriptImageThumb(
                        url: presentation.resourceURL,
                        displayName: presentation.displayName,
                        style: .strip,
                        accessibilityID: "\(accessibilityPrefix).\(index)"
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(presentations.count) image preview\(presentations.count == 1 ? "" : "s")")
    }
}

// MARK: - ThreadMarkdownFormatter

/// Pure, nonisolated formatter that converts live timeline data (tool-call items
/// and approval requests) into markdown lines suitable for inclusion in the
/// exported thread markdown when the caller opts in via `includeTimeline: true`.
///
/// Kept separate from `AgentAppViewModel` so it is fully testable without any
/// actor or SwiftUI state. All inputs are value types.
public enum ThreadMarkdownFormatter {

    /// Render timeline items (tool calls, commands, etc.) and approval requests
    /// as ordered markdown lines.  Items are sorted chronologically by
    /// `startedAtMs`; approvals are interleaved by `createdAtMs`.
    ///
    /// Returns an empty array when both collections are empty, so callers can
    /// skip the section header when there is nothing to show.
    public static func timelineMarkdownLines(
        turns: [AssistantTurnSnapshot],
        approvals: [AssistantPendingRequest]
    ) -> [String] {
        struct Entry {
            let sortKey: Int64
            let line: String
        }

        var entries: [Entry] = []

        // Tool-call items from all turns.
        for turn in turns {
            for item in turn.items {
                guard isTimelineItem(item) else { continue }
                let label = itemLabel(item)
                let statePart = item.state.rawValue
                let durPart = itemDurationString(item).map { " [\($0)]" } ?? ""
                let line = "- \(label) (\(statePart))\(durPart)"
                entries.append(Entry(sortKey: item.startedAtMs, line: line))
            }
        }

        // Approval requests.
        for req in approvals {
            let statePart = req.state.rawValue
            let durPart = approvalDurationString(req).map { " [\($0)]" } ?? ""
            let line = "- Approval: \(req.title) (\(statePart))\(durPart)"
            entries.append(Entry(sortKey: req.createdAtMs, line: line))
        }

        guard !entries.isEmpty else { return [] }

        entries.sort { $0.sortKey < $1.sortKey }
        return entries.map(\.line)
    }

    // MARK: - Private helpers

    /// Exclude assistant-message items and reasoning from the work log since
    /// those are already captured in the role-based export.
    private static func isTimelineItem(_ item: AssistantItem) -> Bool {
        switch item.type {
        case .assistantMessage, .reasoning: return false
        default: return true
        }
    }

    private static func itemLabel(_ item: AssistantItem) -> String {
        if let s = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? item.type.rawValue : String(body.prefix(120))
    }

    private static func itemDurationString(_ item: AssistantItem) -> String? {
        guard let finished = item.finishedAtMs, finished >= item.startedAtMs else { return nil }
        let seconds = Int((finished - item.startedAtMs) / 1000)
        guard seconds > 0 else { return nil }
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private static func approvalDurationString(_ req: AssistantPendingRequest) -> String? {
        guard let resolved = req.resolvedAtMs, resolved >= req.createdAtMs else { return nil }
        let seconds = Int((resolved - req.createdAtMs) / 1000)
        guard seconds > 0 else { return nil }
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

private final class TimelineScrollScheduler {
    var scheduled = false
    var forcePending = false
}

private struct PendingSessionApprovalConfirmation {
    let originThreadId: AgentThreadID
    let request: AssistantPendingRequest
}

public struct AgentAppView: View {
    struct QueueStatusBannerPresentation: Equatable {
        let message: String
        let offersCopy: Bool
        let offersRetry: Bool
    }

    private static let threadRailWidthRange: ClosedRange<CGFloat> = 180...360
    private static let threadRailIdealWidth: CGFloat = 220
    private static let conversationMinimumWidth: CGFloat = 560
    private static let planSidebarIdealWidth: CGFloat = 300
    private static let timelineBottomRevealSlack: CGFloat = 4
    private static let scrollDownButtonBottomInset: CGFloat = 22
    static func visibleStatusMessage(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func standaloneQueueStatusMessage(_ message: String?, queuedCount: Int) -> String? {
        guard queuedCount == 0, let message else { return nil }
        return visibleStatusMessage(message)
    }

    static func standaloneQueueStatusBanner(
        _ message: String?,
        queuedCount: Int
    ) -> QueueStatusBannerPresentation? {
        guard let message = standaloneQueueStatusMessage(message, queuedCount: queuedCount) else {
            return nil
        }
        return QueueStatusBannerPresentation(message: message, offersCopy: true, offersRetry: true)
    }
    @ObservedObject var vm: AgentAppViewModel
    @State private var renamingThreadId: AgentThreadID?
    @State private var renameText: String = ""
    @State private var expandedTools: Set<String> = []
    @State private var expandedToolGroups: Set<String> = []
    // UX-MAC_AGENT-010: reasoning rows collapse to "Thought" by default once
    // completed; ids here are the ones the user explicitly expanded.
    @State private var expandedReasoning: Set<String> = []
    @State private var selectedThreadIds: Set<AgentThreadID> = []
    @State private var lastSelectedThreadId: AgentThreadID?
    @State private var draggingThreadId: AgentThreadID?
    @State private var timelineSticksToBottom = true
    @State private var showScrollDownButton = false
    // IMP-MAC_AGENT-010: highlights the transcript while a file drag hovers it.
    @State private var timelineDropTargeted = false
    @State private var timelineScrollScheduler = TimelineScrollScheduler()
    @State private var composerEditorHeight: CGFloat = PromptComposerEditor.minHeight
    // macos:32: suggestion popup state. selection nil == nothing highlighted;
    // dismissed == user pressed Esc for the current token.
    @State private var suggestionSelectedIndex: Int? = nil
    @State private var suggestionPopupDismissed = false
    @AppStorage("agent.threadRail.intent.v1") private var threadRailIntentRaw = AdaptiveSidebarIntent.auto.rawValue
    @AppStorage("agent.planSidebar.intent.v1") private var planSidebarIntentRaw = AdaptiveSidebarIntent.auto.rawValue
    @State private var showThreadRail = true
    @State private var lastAutomaticThreadRailChange: TimeInterval?
    @State private var lastAutomaticPlanSidebarChange: TimeInterval?
    @State private var proposedPlanExpanded = false
    @State private var showWorkLog = false
    @State private var expandedCompletedWorkTurns: Set<String> = []
    @State private var queuedMessagePendingCancel: AgentQueuedMessage?
    @State private var pendingSessionApproval: PendingSessionApprovalConfirmation?
    @State private var expandedRequestPreviews: Set<String> = []
    @State private var declineReasonDrafts: [String: String] = [:]
    // P1: thread delete confirmation — ids staged here until user confirms.
    @State private var pendingDeleteThreadIds: Set<AgentThreadID> = []
    /// Clear All confirmation for the thread rail.
    @State private var pendingClearAllThreads = false
    // UX-XPLAT-007: checkpoint revert confirmation — staged turn count until user confirms.
    @State private var pendingRevertCheckpointTurnCount: Int?
    // P3: user-message "show more" — message ids the user has expanded past 28 lines.

    @State private var showModelOptions = false
    @State private var showAllModelOptions = false
    /// Source/account capsule popover (Codex / Claude / Grok). Always openable so
    /// locked/single-source states fail loud instead of a dead click.
    @State private var showSourceOptions = false
    /// Subagents activity popover (provider-neutral Active/Done list).
    @State private var showSubagentActivity = false
    // UX-MAC_AGENT-013: inline custom-model entry replaces the blocking NSAlert.
    @State private var showCustomModelField = false
    @State private var customModelDraft = ""
    /// Composer Simple (attach/model/send) vs Power (full toolbar).
    @AppStorage("agent.composer.chromeMode.v1") private var composerChromeModeRaw =
        AgentComposerChromeMode.simple.rawValue
    private var composerChromeMode: AgentComposerChromeMode {
        AgentComposerChromeMode(rawValue: composerChromeModeRaw) ?? .simple
    }

    public init(vm: AgentAppViewModel) { self.vm = vm }

    /// Pure seam: whether to show the "translated from compressed output" badge.
    /// WHY: humanized SR1 replies should be transparently labeled so the user knows
    /// the message was rewritten by Token Saver. Tested in isolation so the badge
    /// decision is independent of view state.
    static func showsTranslatedBadge(wasSR1Translated: Bool) -> Bool {
        wasSR1Translated
    }

    static func sr1BadgeLabel(hasOriginalText: Bool) -> String {
        hasOriginalText
            ? "translated from compressed output - View original"
            : "translated from compressed output"
    }

    static let fullAccessScopeDescription =
        "The agent runs tools, edits, and proposed plans without asking for this thread until you change it."

    static let sessionApprovalHelp =
        "Auto-approve requests for this thread until you change it"

    static let threadDeletionConfirmationDescription =
        "Threads are deleted immediately. You can undo for 10 seconds; after that, their history is permanently deleted."

    static let emptyThreadSubtitle =
        "Send a prompt to start a Codex, Claude, or Grok thread."

    static func attachmentRemovalAccessibilityLabel(path: String) -> String {
        "Remove attachment \((path as NSString).lastPathComponent)"
    }

    /// Pure seam: checkpoint revert always needs a destructive confirmation.
    /// WHY: reverting rolls back the working tree and cannot be undone; any
    /// checkpoint that is ready to apply is destructive. The predicate is
    /// extracted so tests can verify the guard without instantiating views.
    nonisolated static func needsRevertConfirmation(checkpointStatus: AgentTurnCheckpointStatus) -> Bool {
        checkpointStatus == .ready
    }

    static func shouldRenderFinalAssistantMessage(_ turn: AssistantTurnSnapshot, persistedAssistantTexts: [String] = []) -> Bool {
        guard let final = turn.finalAssistantMessage, !final.isEmpty else { return false }
        if assistantText(final, matchesAny: persistedAssistantTexts) { return false }
        let bodies = renderableAssistantItemBodies(in: turn, persistedAssistantTexts: persistedAssistantTexts)
        if assistantText(bodies.joined(separator: "\n"), equals: final) { return false }
        return !bodies.contains { assistantText($0, matches: final) }
    }

    static func shouldRenderAssistantItemBody(_ body: String, priorAssistantTexts: [String] = [], persistedAssistantTexts: [String] = []) -> Bool {
        if SR1ResponseDetector.isSR1(body),
           persistedAssistantTexts.contains(where: { !$0.isEmpty && !SR1ResponseDetector.isSR1($0) }) {
            return false
        }
        return !body.isEmpty &&
            !assistantText(body, equalsAny: priorAssistantTexts) &&
            !assistantText(body, equalsAny: persistedAssistantTexts)
    }

    static func shouldRenderPersistedAssistantMessage(_ text: String, timelineTurns: [AssistantTurnSnapshot]) -> Bool {
        guard !text.isEmpty else { return false }
        return !timelineTurns.contains { turn in
            let visibleAssistantText = renderableAssistantItemBodies(in: turn, persistedAssistantTexts: [text])
                .joined(separator: "\n")
            return assistantText(visibleAssistantText, equals: text)
        }
    }

    static func renderableItems(in turn: AssistantTurnSnapshot, persistedAssistantTexts: [String] = []) -> [AssistantItem] {
        var priorAssistantTexts: [String] = []
        return turn.items.filter { item in
            guard item.type == .assistantMessage else { return true }
            let shouldRender = shouldRenderAssistantItemBody(
                item.body,
                priorAssistantTexts: priorAssistantTexts,
                persistedAssistantTexts: persistedAssistantTexts
            )
            if shouldRender {
                priorAssistantTexts.append(item.body)
            }
            return shouldRender
        }
    }

    static func completedFinalAssistantItemIDs(in turn: AssistantTurnSnapshot,
                                               renderableItems: [AssistantItem],
                                               persistedAssistantTexts: [String] = []) -> Set<String> {
        guard turn.finished else { return [] }
        let assistantItems = renderableItems.filter { $0.type == .assistantMessage }
        guard !assistantItems.isEmpty else { return [] }
        if let final = turn.finalAssistantMessage,
           !shouldRenderFinalAssistantMessage(turn, persistedAssistantTexts: persistedAssistantTexts) {
            // The final answer is the LAST assistant item that the final text
            // covers — not every assistant item in the turn. A turn can emit many
            // preamble messages ("State:/Action:/…") before the real answer; those
            // must collapse into the Worked disclosure, leaving only the last
            // message as the visible answer. Legacy Grok turns persisted the joined
            // text phases as `final`; accepting the inverse containment keeps their
            // last answer visible without changing new turns. When the last item has
            // already been hidden because it duplicates the persisted answer, no item
            // matches and every preamble correctly demotes to the work log.
            return Set([assistantItems.last {
                assistantText($0.body, matches: final) || assistantText(final, matches: $0.body)
            }?.id].compactMap { $0 })
        }
        if turn.finalAssistantMessage == nil, let final = assistantItems.last {
            return [final.id]
        }
        return []
    }

    static func completedWorkItems(in turn: AssistantTurnSnapshot,
                                   renderableItems: [AssistantItem],
                                   persistedAssistantTexts: [String] = []) -> [AssistantItem] {
        guard turn.finished else { return renderableItems }
        let finalIDs = completedFinalAssistantItemIDs(
            in: turn,
            renderableItems: renderableItems,
            persistedAssistantTexts: persistedAssistantTexts
        )
        return renderableItems.filter { !finalIDs.contains($0.id) }
    }

    static func completedVisibleAssistantItems(in turn: AssistantTurnSnapshot,
                                               renderableItems: [AssistantItem],
                                               persistedAssistantTexts: [String] = []) -> [AssistantItem] {
        guard turn.finished else { return renderableItems }
        let finalIDs = completedFinalAssistantItemIDs(
            in: turn,
            renderableItems: renderableItems,
            persistedAssistantTexts: persistedAssistantTexts
        )
        return renderableItems.filter { finalIDs.contains($0.id) }
    }

    // MARK: Tool-burst grouping
    //
    // A run of >=2 consecutive tool-style items (e.g. a flurry of MCP status polls or
    // file reads) collapses into one "Ran N commands" row the user can expand — instead
    // of flooding the transcript with identical "Ran …" lines. A lone tool call renders
    // inline as before. Non-tool items (assistant text, reasoning, plan, errors) always
    // break a run, so the answer prose is never swallowed into a group.
    enum TurnRenderBlock: Identifiable, Equatable {
        case item(AssistantItem)
        case toolGroup(id: String, items: [AssistantItem])

        var id: String {
            switch self {
            case .item(let item): return "block-item-\(item.id)"
            case .toolGroup(let id, _): return "block-group-\(id)"
            }
        }
    }

    /// Tool-call kinds that are safe to fold into a count. `error`/`review`/`contextCompaction`
    /// are deliberately excluded — they're noteworthy and must stay visible standalone.
    static func isGroupableTool(_ type: AssistantItemType) -> Bool {
        switch type {
        case .tool, .commandExecution, .mcpToolCall, .dynamicToolCall, .collabToolCall, .webSearch, .imageView, .fileChange:
            return true
        case .reasoning, .plan, .assistantMessage, .review, .contextCompaction, .error:
            return false
        }
    }

    static func turnRenderBlocks(_ items: [AssistantItem], groupThreshold: Int = 2) -> [TurnRenderBlock] {
        var blocks: [TurnRenderBlock] = []
        var run: [AssistantItem] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            if run.count >= groupThreshold {
                blocks.append(.toolGroup(id: run[0].id, items: run))
            } else {
                blocks.append(contentsOf: run.map { .item($0) })
            }
            run.removeAll(keepingCapacity: true)
        }
        for item in items {
            if isGroupableTool(item.type) {
                run.append(item)
            } else {
                flushRun()
                blocks.append(.item(item))
            }
        }
        flushRun()
        return blocks
    }

    /// F2: the per-turn data `turnView` needs, computed once instead of re-deriving
    /// `renderableItems` / `completedFinalAssistantItemIDs` (twice) / block grouping /
    /// plan filtering on every SwiftUI body pass. Pure value so it can be memoized for
    /// immutable (finished) turns and unit-tested against the prior inline logic.
    struct TurnRenderInputs: Equatable {
        var turnPlans: [AssistantProposedPlan]
        var visibleBlocks: [TurnRenderBlock]
        var completedWorkBlocks: [TurnRenderBlock]
        /// Block count for the collapsed "Work so far" label — available even when
        /// `completedWorkBlocks` is empty (lazy: full blocks only when expanded).
        var completedWorkBlockCount: Int
        var hiddenLiveItemCount: Int
        var shouldRenderFinal: Bool
    }

    static func computeTurnRenderInputs(turn: AssistantTurnSnapshot,
                                        persistedAssistantTexts: [String],
                                        proposedPlans allPlans: [AssistantProposedPlan],
                                        running: Bool,
                                        expandCompletedWork: Bool = false,
                                        followUpWorkAnchorMs: Int64? = nil) -> TurnRenderInputs {
        let turnPlans = allPlans.filter {
            $0.turnId == turn.turnId && !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Chat follow-up: only items that started at/after the newest user message
        // paint under that bubble. Long provider turns often keep prior tools in
        // the same turnId — without this filter "Work so far · N steps" re-shows
        // the previous task under the new prompt.
        let rawRenderable = renderableItems(in: turn, persistedAssistantTexts: persistedAssistantTexts)
            .filter { !($0.type == .plan && !turnPlans.isEmpty) }
        let renderable = itemsAfterFollowUpAnchor(rawRenderable, anchorMs: followUpWorkAnchorMs)
        let runningTurn = !turn.finished && running
        // Chat-fluid live path: fold already-settled tools/thoughts into the same
        // "Worked" disclosure used after completion, and only paint the active
        // tail (streaming item + brief context). Grok emits Thought between tools,
        // which breaks consecutive tool grouping — without this partition the live
        // transcript re-expands every command as a full toolRow.
        if runningTurn {
            let (settled, active) = partitionLiveTurnItems(renderable)
            let activeVisible = visibleLiveTurnItems(active, running: true)
            let hiddenLiveItemCount = max(0, renderable.count - settled.count - activeVisible.count)
            // PERF: the collapsed disclosure only needs a count. Building full
            // TurnRenderBlock trees for 200+ settled tools on every body pass was
            // a main-thread tax during long live turns.
            let workCount = turnRenderBlockCount(settled)
            let workBlocks = AgentCompletedWorkPresentation.shouldBuildBlocks(
                expandCompletedWork: expandCompletedWork,
                workItemCount: workCount
            ) ? turnRenderBlocks(settled) : []
            return TurnRenderInputs(
                turnPlans: turnPlans,
                visibleBlocks: turnRenderBlocks(activeVisible),
                completedWorkBlocks: workBlocks,
                completedWorkBlockCount: workCount,
                hiddenLiveItemCount: hiddenLiveItemCount,
                shouldRenderFinal: false
            )
        }
        let finalIDs = turn.finished
            ? completedFinalAssistantItemIDs(in: turn, renderableItems: renderable, persistedAssistantTexts: persistedAssistantTexts)
            : []
        let workItems = turn.finished ? renderable.filter { !finalIDs.contains($0.id) } : []
        let visibleAssistant = turn.finished ? renderable.filter { finalIDs.contains($0.id) } : renderable
        let visibleBlocks = turnRenderBlocks(visibleAssistant)
        let workCount = turnRenderBlockCount(workItems)
        let completedWorkBlocks = AgentCompletedWorkPresentation.shouldBuildBlocks(
            expandCompletedWork: expandCompletedWork,
            workItemCount: workCount
        ) ? turnRenderBlocks(workItems) : []
        let shouldRenderFinal = turn.finalAssistantMessage != nil
            && shouldRenderFinalAssistantMessage(turn, persistedAssistantTexts: persistedAssistantTexts)
            // If every item was scoped out as pre-follow-up, don't re-paint the
            // prior turn's final answer under the new user bubble.
            && !(followUpWorkAnchorMs != nil && renderable.isEmpty && workItems.isEmpty)
        return TurnRenderInputs(turnPlans: turnPlans,
                                visibleBlocks: visibleBlocks,
                                completedWorkBlocks: completedWorkBlocks,
                                completedWorkBlockCount: workCount,
                                hiddenLiveItemCount: 0,
                                shouldRenderFinal: shouldRenderFinal)
    }

    /// Count-only twin of `turnRenderBlocks` — same grouping rules, no block allocs.
    static func turnRenderBlockCount(_ items: [AssistantItem], groupThreshold: Int = 2) -> Int {
        var count = 0
        var run = 0
        func flushRun() {
            guard run > 0 else { return }
            count += run >= groupThreshold ? 1 : run
            run = 0
        }
        for item in items {
            if isGroupableTool(item.type) {
                run += 1
            } else {
                flushRun()
                count += 1
            }
        }
        flushRun()
        return count
    }

    /// Split a live turn into settled work (already done — collapse) vs the active
    /// tail the user needs to see right now (streaming + short open context).
    /// Pure + testable. Finished turns never call this.
    nonisolated static func partitionLiveTurnItems(
        _ items: [AssistantItem],
        activeTailLimit: Int = liveTurnActiveTailLimit
    ) -> (settled: [AssistantItem], active: [AssistantItem]) {
        guard !items.isEmpty else { return ([], []) }
        let tailLimit = max(1, activeTailLimit)
        if let lastStreaming = items.lastIndex(where: { $0.state == .streaming }) {
            // Keep a short pre-stream context so the active command/thought has
            // continuity, but fold everything older into the work disclosure.
            let activeStart = max(0, lastStreaming - (tailLimit - 1))
            return (Array(items.prefix(activeStart)), Array(items.suffix(from: activeStart)))
        }
        // Between tools nothing is streaming: keep only the newest tail live so
        // a multi-minute turn does not re-paint every completed command.
        if items.count <= tailLimit {
            return ([], items)
        }
        return (Array(items.dropLast(tailLimit)), Array(items.suffix(tailLimit)))
    }

    /// Collapsed-group header text: count-aware verb + noun, e.g. "Ran 4 commands",
    /// "Changed 3 files", or "Running 2 commands…" while any member is still streaming.
    static func toolGroupSummary(_ items: [AssistantItem]) -> String {
        let noun = toolGroupNoun(items)
        if items.contains(where: { $0.state == .streaming }) {
            return "Running \(items.count) \(noun)…"
        }
        let verbs = Set(items.map { AgentTimelineItemPresentation.make(for: $0).verb })
        let verb = verbs.count == 1 ? (verbs.first ?? "Ran") : "Ran"
        return "\(verb) \(items.count) \(noun)"
    }

    static func toolGroupNoun(_ items: [AssistantItem]) -> String {
        let plural = items.count != 1
        switch Set(items.map(\.type)) {
        case [.fileChange]: return plural ? "files" : "file"
        case [.webSearch]: return plural ? "searches" : "search"
        case [.imageView]: return plural ? "images" : "image"
        default: return plural ? "commands" : "command"
        }
    }

    private static func assistantText(_ text: String, matchesAny candidates: [String]) -> Bool {
        candidates.contains { assistantText(text, matches: $0) }
    }

    private static func assistantText(_ text: String, equalsAny candidates: [String]) -> Bool {
        candidates.contains { assistantText(text, equals: $0) }
    }

    private static func renderableAssistantItemBodies(in turn: AssistantTurnSnapshot, persistedAssistantTexts: [String] = []) -> [String] {
        renderableItems(in: turn, persistedAssistantTexts: persistedAssistantTexts)
            .filter { $0.type == .assistantMessage }
            .map(\.body)
            .filter { !$0.isEmpty }
    }

    private static func assistantText(_ lhs: String, matches rhs: String) -> Bool {
        let normalizedLHS = normalizedAssistantText(lhs)
        let normalizedRHS = normalizedAssistantText(rhs)
        guard !normalizedLHS.isEmpty, !normalizedRHS.isEmpty else { return false }
        let compactLHS = compactAssistantText(lhs)
        let compactRHS = compactAssistantText(rhs)
        return normalizedLHS == normalizedRHS ||
            normalizedLHS.contains(normalizedRHS) ||
            compactLHS == compactRHS ||
            compactLHS.contains(compactRHS)
    }

    private static func assistantText(_ lhs: String, equals rhs: String) -> Bool {
        let normalizedLHS = normalizedAssistantText(lhs)
        let normalizedRHS = normalizedAssistantText(rhs)
        guard !normalizedLHS.isEmpty, !normalizedRHS.isEmpty else { return false }
        return normalizedLHS == normalizedRHS ||
            compactAssistantText(lhs) == compactAssistantText(rhs)
    }

    // PERF-MAC_AGENT-002: collapse whitespace manually over unicode scalars
    // instead of regex; these run for every assistant row on every render, and
    // regex over capped 80k-char bodies dominated the dedup cost. Results are
    // memoized so repeated comparisons of the same body don't re-scan.
    private static let dedupeCacheCharacterLimit = 16_384
    private static let normalizedTextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 512
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    private static let compactTextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 512
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    private static func normalizedAssistantText(_ text: String) -> String {
        guard text.count <= dedupeCacheCharacterLimit else {
            return makeNormalizedAssistantText(text)
        }
        let key = text as NSString
        if let cached = normalizedTextCache.object(forKey: key) {
            return cached as String
        }
        let out = makeNormalizedAssistantText(text)
        normalizedTextCache.setObject(out as NSString, forKey: key, cost: out.utf8.count)
        return out
    }

    private static func makeNormalizedAssistantText(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.unicodeScalars.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func compactAssistantText(_ text: String) -> String {
        guard text.count <= dedupeCacheCharacterLimit else {
            return makeCompactAssistantText(text)
        }
        let key = text as NSString
        if let cached = compactTextCache.object(forKey: key) {
            return cached as String
        }
        let out = makeCompactAssistantText(text)
        compactTextCache.setObject(out as NSString, forKey: key, cost: out.utf8.count)
        return out
    }

    private static func makeCompactAssistantText(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    private struct AssistantTextLookup {
        var normalizedIds: [String: Set<AgentMessageID>] = [:]
        var compactIds: [String: Set<AgentMessageID>] = [:]

        init(messages: [AgentMessage]) {
            for message in messages where message.role == .assistant && !message.content.isEmpty {
                normalizedIds[normalizedAssistantText(message.content), default: []].insert(message.id)
                compactIds[compactAssistantText(message.content), default: []].insert(message.id)
            }
        }

        func ids(equalTo text: String) -> Set<AgentMessageID> {
            guard !text.isEmpty else { return [] }
            var ids = normalizedIds[normalizedAssistantText(text)] ?? []
            ids.formUnion(compactIds[compactAssistantText(text)] ?? [])
            return ids
        }
    }

    static func hiddenPersistedAssistantMessageIDs(messages: [AgentMessage],
                                                   timelineTurns: [AssistantTurnSnapshot],
                                                   persistedAssistantTexts: [String]? = nil) -> Set<AgentMessageID> {
        let assistantMessages = messages.filter { $0.role == .assistant && !$0.content.isEmpty }
        guard !assistantMessages.isEmpty, !timelineTurns.isEmpty else { return [] }
        let persistedTexts = persistedAssistantTexts ?? assistantMessages.map(\.content)
        let lookup = AssistantTextLookup(messages: assistantMessages)
        var hidden: Set<AgentMessageID> = []
        for turn in timelineTurns {
            let visibleAssistantText = renderableAssistantItemBodies(in: turn, persistedAssistantTexts: persistedTexts)
                .joined(separator: "\n")
            hidden.formUnion(lookup.ids(equalTo: visibleAssistantText))
        }
        return hidden
    }

    /// Max width for user prompt bubbles. Short text hugs content; long text wraps here.
    /// Kept well under the old 600pt hard fill so chat bubbles stay compact.
    static let userMessageBubbleMaxWidth: CGFloat = 420
    /// Leading spacer so user bubbles stay right-aligned with a readable gutter.
    static let userMessageBubbleLeadingGutter: CGFloat = 48
    /// Floor so a very narrow agent column still shows a usable bubble.
    static let userMessageBubbleMinWidth: CGFloat = 160

    /// Flexible bubble cap for the current transcript column.
    /// Long prompts wrap at this width; short prompts still hug via `fixedSize`.
    /// Never exceeds `userMessageBubbleMaxWidth`, and never exceeds the column
    /// minus the leading gutter — prevents the bubble + copy/timestamp meta from
    /// painting over the timeline edge and adjacent chrome.
    static func userMessageBubbleWidthCap(columnWidth: CGFloat) -> CGFloat {
        let usable = columnWidth - userMessageBubbleLeadingGutter
        guard usable.isFinite, usable > 0 else { return userMessageBubbleMinWidth }
        return min(userMessageBubbleMaxWidth, max(userMessageBubbleMinWidth, usable))
    }
    nonisolated static let runningTranscriptContextSlack: TimeInterval = 2
    // PERF-MAC_AGENT-023: idle/completed threads render their transcript in an
    // eager (non-Lazy) VStack, so a very long thread re-builds and re-lays-out the
    // whole history on every routine invalidation (focus, hover, scroll, the
    // one-shot completion tick) — pathologically slow on huge threads. Bound the
    // idle render to a recent tail, mirroring the running-state window; the older
    // slice stays one tap away via the existing "earlier transcript items" reveal.
    nonisolated static let idleTranscriptWindowCount = 30
    nonisolated static let hiddenTranscriptRevealPageCount = 50
    /// Entries kept *before* the newest user message during a follow-up.
    /// 0 = start clean at the user's bubble (prior history via reveal row).
    nonisolated static let followUpPrecedingContextCount = 0
    static let liveTurnRenderableItemLimit = 48
    /// How many trailing items stay expanded while a turn is still running.
    /// Everything older folds into the "Work so far" disclosure so Thought-
    /// interleaved tool storms read like a chat, not a full command log.
    static let liveTurnActiveTailLimit = 3
    static let liveTurnBodyCharacterLimit = 2_000
    static let liveTurnOutputCharacterLimit = 1_500
    static let liveTurnSummaryCharacterLimit = 240
    static let commandPreviewCharacterLimit = 1_200

    /// User bubbles show the full stored prompt. Layout wraps long lines and
    /// grows vertically with content — no character or line-count truncation.
    static func userMessageDisplayText(_ text: String) -> String {
        text
    }

    static func cappedVisibleText(_ text: String, limit: Int, truncatedLabel: String = "truncated in live view") -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        let dropped = text.count - head.count
        return "\(head)\n... \(dropped) more characters \(truncatedLabel) ..."
    }

    static func cappedOptionalVisibleText(_ text: String?, limit: Int, truncatedLabel: String = "truncated in live view") -> String? {
        guard let text else { return nil }
        return cappedVisibleText(text, limit: limit, truncatedLabel: truncatedLabel)
    }

    static func liveRenderableCopy(_ item: AssistantItem) -> AssistantItem {
        var copy = item
        copy.summary = cappedOptionalVisibleText(copy.summary, limit: liveTurnSummaryCharacterLimit)
        // Streaming Thought: keep the *tail* (latest tokens) like the Grok TUI.
        // Head-capping freezes early chain-of-thought while later tokens rewrite
        // "on top" of the answer without the user seeing them.
        if item.type == .reasoning, item.state == .streaming {
            copy.body = cappedVisibleTextTail(copy.body, limit: liveTurnBodyCharacterLimit)
        } else {
            copy.body = cappedVisibleText(copy.body, limit: liveTurnBodyCharacterLimit)
        }
        copy.output = cappedOptionalVisibleText(copy.output, limit: liveTurnOutputCharacterLimit)
        return copy
    }

    /// Keep the newest `limit` characters (plus a short head-omission marker).
    static func cappedVisibleTextTail(_ text: String, limit: Int, truncatedLabel: String = "earlier characters truncated in live view") -> String {
        guard text.count > limit else { return text }
        let tail = text.suffix(limit)
        let dropped = text.count - tail.count
        return "... \(dropped) \(truncatedLabel) ...\n\(tail)"
    }

    static func toolCommandPreview(for item: AssistantItem) -> String? {
        AgentTimelineItemPresentation.toolCommandPreview(for: item)
    }

    static func visibleLiveTurnItems(_ items: [AssistantItem], running: Bool) -> [AssistantItem] {
        guard running else { return items }
        return items.suffix(liveTurnRenderableItemLimit).map(liveRenderableCopy)
    }

    enum TranscriptEntry: Identifiable {
        case message(AgentMessage)
        case turn(AssistantTurnSnapshot)

        var id: String {
            switch self {
            case .message(let message): return "message-\(message.id.value.uuidString)"
            case .turn(let turn): return "turn-\(turn.turnId)"
            }
        }

        var sortTime: TimeInterval {
            switch self {
            case .message(let message):
                return message.createdAt.timeIntervalSince1970
            case .turn(let turn):
                // Prefer first item time (stable once content exists). Fall back to
                // turn.startedAtMs so an empty live turn does not sort at epoch 0
                // (which placed Thinking… *above* the user message that triggered it).
                if let started = turn.items.map(\.startedAtMs).min() {
                    return TimeInterval(started) / 1000
                }
                if let started = turn.startedAtMs {
                    return TimeInterval(started) / 1000
                }
                return TimeInterval.greatestFiniteMagnitude
            }
        }
    }

    /// Returns the ordered slice of `allItems` not present in `visibleWindow`.
    /// These are the older entries hidden while a run is active, available for
    /// read-only audit when the user taps the "N earlier items hidden" row.
    nonisolated static func hiddenTranscriptSlice(
        allItems: [TranscriptEntry],
        visibleWindow: [TranscriptEntry]
    ) -> [TranscriptEntry] {
        let visibleIDs = Set(visibleWindow.map(\.id))
        return allItems.filter { !visibleIDs.contains($0.id) }
    }

    nonisolated static func hiddenTranscriptRevealWindow(
        allItems: [TranscriptEntry],
        visibleWindow: [TranscriptEntry],
        revealCount: Int
    ) -> [TranscriptEntry] {
        guard revealCount > 0 else { return [] }
        return Array(hiddenTranscriptSlice(
            allItems: allItems,
            visibleWindow: visibleWindow
        ).suffix(revealCount))
    }

    /// Count-only path for collapsed history. The reveal row needs only this
    /// number; building the hidden prefix on every composer keystroke scans a
    /// huge completed thread even though the rows are not visible.
    nonisolated static func hiddenTranscriptCount(
        totalCount: Int,
        visibleCount: Int
    ) -> Int {
        max(0, totalCount - visibleCount)
    }

    /// Canonical transcript ordering: ascending by `sortTime`, then by `id` for a
    /// total order (deterministic regardless of sort stability). Message and turn
    /// ids carry distinct prefixes, so two entries never tie on (sortTime, id).
    nonisolated static func transcriptEntryOrdersBefore(_ lhs: TranscriptEntry, _ rhs: TranscriptEntry) -> Bool {
        if lhs.sortTime == rhs.sortTime { return lhs.id < rhs.id }
        return lhs.sortTime < rhs.sortTime
    }

    /// F7: build the merged transcript in O(N) by merging two already-ordered
    /// sequences instead of re-sorting the whole thread (O(N log N)) on every
    /// structural change (turn/item/message add) during a run. `messages` are
    /// append-only in createdAt order and `turns` in start order, so each side is
    /// already in canonical order. The message side is verified in O(N); if a
    /// thread ever violates the invariant (e.g. exact-timestamp ties out of id
    /// order) we fall back to a full sort, so the output is ALWAYS identical to the
    /// canonical ordering — only the path that produces it gets cheaper.
    nonisolated static func mergeTranscriptEntries(messages: [AgentMessage],
                                                  turns: [AssistantTurnSnapshot]) -> [TranscriptEntry] {
        let messageEntries = messages.map(TranscriptEntry.message)
        // Turns are few; sort defensively so the merge precondition always holds.
        let turnEntries = turns.map(TranscriptEntry.turn).sorted(by: transcriptEntryOrdersBefore)
        guard isOrderedByTranscriptOrder(messageEntries) else {
            return (messageEntries + turnEntries).sorted(by: transcriptEntryOrdersBefore)
        }
        return mergeOrderedTranscriptEntries(messageEntries, turnEntries)
    }

    /// True when `entries` is already in canonical transcript order (no adjacent
    /// inversion). O(N), no allocation.
    nonisolated static func isOrderedByTranscriptOrder(_ entries: [TranscriptEntry]) -> Bool {
        guard entries.count > 1 else { return true }
        for i in 1..<entries.count where transcriptEntryOrdersBefore(entries[i], entries[i - 1]) {
            return false
        }
        return true
    }

    /// Standard 2-way merge of two canonically-ordered sequences. Equivalent to
    /// `(a + b).sorted(by: transcriptEntryOrdersBefore)` because there are no
    /// cross-side (sortTime, id) ties (distinct id prefixes) and each input is sorted.
    nonisolated static func mergeOrderedTranscriptEntries(_ a: [TranscriptEntry], _ b: [TranscriptEntry]) -> [TranscriptEntry] {
        var result: [TranscriptEntry] = []
        result.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if transcriptEntryOrdersBefore(b[j], a[i]) {
                result.append(b[j]); j += 1
            } else {
                result.append(a[i]); i += 1
            }
        }
        if i < a.count { result.append(contentsOf: a[i...]) }
        if j < b.count { result.append(contentsOf: b[j...]) }
        return result
    }

    // PERF-MAC_AGENT-001: the merged+sorted transcript is read from `body`, so
    // it recomputed (O(n log n)) on every @Published change — every streaming
    // delta and every keystroke. Memoize it, re-sorting only when the message
    // or turn identities actually change (cheap signature compare).
    private final class TranscriptCache {
        var signature: String?
        var entries: [TranscriptEntry] = []
    }
    private let transcriptCache = TranscriptCache()

    private var transcriptEntries: [TranscriptEntry] {
        let signature = transcriptSignature
        if transcriptCache.signature == signature {
            // F1: a signature hit only proves the ORDER is unchanged — the signature
            // deliberately ignores item bodies/outputs/states and turn completion so
            // streaming deltas don't re-sort. The cached entries embed VALUE COPIES
            // of the turn snapshots, so serving them verbatim froze streamed text at
            // the last structural change. Re-materialize the turn payloads from the
            // live timeline (shallow O(entries) map, no re-sort); messages are
            // append-only immutable rows, so their cached copies stay.
            //
            // CRITICAL: write rematerialized entries BACK into the cache so a turn
            // that completes mid-signature stays baseline-finished and
            // shouldRematerializeTurn stops returning true on every later tick.
            let refreshed = Self.rematerializedTranscriptEntries(
                cached: transcriptCache.entries,
                turns: vm.timeline.turns
            )
            transcriptCache.entries = refreshed
            return refreshed
        }
        let merged = Self.mergeTranscriptEntries(messages: vm.messages, turns: vm.timeline.turns)
        transcriptCache.signature = signature
        transcriptCache.entries = merged
        return merged
    }

    /// F1 + large-thread stream path: rewrite cached `.turn` payloads from the
    /// live timeline while preserving cached ORDER.
    ///
    /// - **Unfinished / live turns** always take the live snapshot (streaming
    ///   bodies must not freeze — F1).
    /// - **Finished turns** keep the cached payload unless completion structure
    ///   changed (`finished`, item count, or final text). Token deltas on a live
    ///   turn must not rebuild every finished turn's item tree (O(paint-window)).
    nonisolated static func rematerializedTranscriptEntries(
        cached: [TranscriptEntry],
        turns: [AssistantTurnSnapshot],
        liveTurnIds: Set<String>? = nil
    ) -> [TranscriptEntry] {
        guard !turns.isEmpty else { return cached }
        var turnsById = [String: AssistantTurnSnapshot](minimumCapacity: turns.count)
        for turn in turns { turnsById[turn.turnId] = turn }
        let explicitLive = liveTurnIds
        return cached.map { entry in
            guard case .turn(let stale) = entry else { return entry }
            guard let live = turnsById[stale.turnId] else { return entry }
            if Self.shouldRematerializeTurn(stale: stale, live: live, liveTurnIds: explicitLive) {
                return .turn(live)
            }
            return entry
        }
    }

    /// Pure gate for stream-tick rematerialization scope.
    nonisolated static func shouldRematerializeTurn(
        stale: AssistantTurnSnapshot,
        live: AssistantTurnSnapshot,
        liveTurnIds: Set<String>? = nil
    ) -> Bool {
        if let liveTurnIds, liveTurnIds.contains(live.turnId) {
            return true
        }
        // Always refresh unfinished turns (streaming body/output/state).
        if !live.finished { return true }
        // Completion transition or structural change on a finished turn.
        if stale.finished != live.finished { return true }
        if stale.items.count != live.items.count { return true }
        if stale.finalAssistantMessage != live.finalAssistantMessage { return true }
        // Stable finished turn: keep cached payload (skip full item-tree copy).
        return false
    }

    private var visibleTranscriptEntries: [TranscriptEntry] {
        Self.visibleTranscriptWindow(
            entries: transcriptEntries,
            status: vm.status,
            runStartedAt: vm.runStartedAt
        )
    }

    /// Pure seam: which transcript entries the eager VStack renders.
    ///
    /// - Running / pending: prefer the slice from the newest user message
    ///   (optional short preceding context) so a follow-up starts clean under
    ///   the user's bubble instead of re-expanding prior turns. Fallbacks:
    ///   time-cutoff live window when no user message exists and `runStartedAt`
    ///   is set; otherwise the recent idle tail — never the full thread.
    /// - Idle/completed: the most recent `idleWindowCount` entries when the thread
    ///   is longer than that, so a huge thread no longer re-renders in full on
    ///   every invalidation. The pre-window slice is surfaced by the existing
    ///   `hiddenTranscriptSlice` + reveal row, so no history is dropped.
    nonisolated static func visibleTranscriptWindow(
        entries: [TranscriptEntry],
        status: AgentRunStatus,
        runStartedAt: Date?,
        idleWindowCount: Int = idleTranscriptWindowCount,
        runningSlack: TimeInterval = runningTranscriptContextSlack,
        precedingContextCount: Int = followUpPrecedingContextCount
    ) -> [TranscriptEntry] {
        // Pending is part of the active follow-up lifecycle (composer send →
        // provider start). Treat it like a live turn so we never flash the
        // idle "last 30" history between send and running.
        if status == .running || status == .pending {
            // Anchor first so k=0 is not bypassed by the tiny-thread early return
            // (e.g. [old assistant, new user] must not re-show the prior answer).
            if let anchored = followUpAnchoredWindow(
                entries: entries,
                precedingContextCount: precedingContextCount
            ) {
                return anchored
            }
            guard entries.count > 2 else { return entries }
            guard status == .running, let startedAt = runStartedAt else {
                // Pending, or running before runStartedAt is assigned: keep the
                // chat focused on the newest segment, not the whole thread.
                return Array(entries.suffix(min(idleWindowCount, entries.count)))
            }
            let cutoff = startedAt.addingTimeInterval(-runningSlack).timeIntervalSince1970
            let liveEntries = entries.filter { $0.sortTime >= cutoff }
            return liveEntries.isEmpty ? Array(entries.suffix(2)) : liveEntries
        }
        guard entries.count > idleWindowCount else { return entries }
        return Array(entries.suffix(idleWindowCount))
    }

    /// Entries from the last user message (minus optional preceding context) to end.
    /// Returns nil when no user message is present so callers keep their fallback.
    nonisolated static func followUpAnchoredWindow(
        entries: [TranscriptEntry],
        precedingContextCount: Int = followUpPrecedingContextCount
    ) -> [TranscriptEntry]? {
        guard let anchor = entries.lastIndex(where: {
            if case .message(let message) = $0 { return message.role == .user }
            return false
        }) else { return nil }
        let start = max(0, anchor - max(0, precedingContextCount))
        let window = Array(entries[start...])
        return window.isEmpty ? nil : window
    }

    /// Whether an Active plan belongs to the current follow-up (not a prior turn).
    /// Pure seam used by stream gating and the view paint gate.
    nonisolated static func isActivePlanFreshForFollowUp(
        plan: AssistantActivePlan,
        newestUserMessageAt: Date?,
        runStartedAt: Date?,
        slack: TimeInterval = runningTranscriptContextSlack
    ) -> Bool {
        let planSeconds = TimeInterval(plan.updatedAtMs) / 1000
        var anchor: TimeInterval = 0
        if let runStartedAt {
            anchor = max(anchor, runStartedAt.timeIntervalSince1970)
        }
        if let newestUserMessageAt {
            anchor = max(anchor, newestUserMessageAt.timeIntervalSince1970)
        }
        guard anchor > 0 else { return true }
        return planSeconds >= anchor - slack
    }

    /// Chat contract: a fully completed checklist is history, not a live card.
    nonisolated static func activePlanIsFullyCompleted(_ plan: AssistantActivePlan) -> Bool {
        !plan.steps.isEmpty && plan.steps.allSatisfy { $0.status == .completed }
    }

    /// Whether stream/rehydrate may apply this plan while follow-up suppress is on.
    /// Rejects all-done checklists (re-emitted prior plans) and non-fresh timestamps.
    nonisolated static func shouldAcceptActivePlanForFollowUp(
        plan: AssistantActivePlan,
        newestUserMessageAt: Date?,
        runStartedAt: Date?,
        hasQueuedFollowUp: Bool,
        slack: TimeInterval = runningTranscriptContextSlack
    ) -> Bool {
        if hasQueuedFollowUp { return false }
        // A re-stamped all-Done plan is not "a new plan for this message".
        if activePlanIsFullyCompleted(plan) { return false }
        return isActivePlanFreshForFollowUp(
            plan: plan,
            newestUserMessageAt: newestUserMessageAt,
            runStartedAt: runStartedAt,
            slack: slack
        )
    }

    /// View-level paint gate for the inline / sidebar Active plan card.
    /// Chat contract: fully completed plans never paint (they read as the prior
    /// turn's checklist under the new bubble). Incomplete plans only paint when
    /// fresh relative to the follow-up anchor.
    nonisolated static func shouldRenderActivePlan(
        plan: AssistantActivePlan?,
        status: AgentRunStatus,
        runStartedAt: Date?,
        newestUserMessageAt: Date?,
        slack: TimeInterval = runningTranscriptContextSlack
    ) -> Bool {
        guard let plan, !plan.steps.isEmpty else { return false }
        if activePlanIsFullyCompleted(plan) { return false }
        return isActivePlanFreshForFollowUp(
            plan: plan,
            newestUserMessageAt: newestUserMessageAt,
            runStartedAt: runStartedAt,
            slack: slack
        )
    }

    /// Items that belong *after* the newest user message (chat follow-up scope).
    /// Drops prior-turn tools that still live in a long-lived provider turn blob
    /// so "Work so far · N steps" only counts work since the user spoke.
    nonisolated static func itemsAfterFollowUpAnchor(
        _ items: [AssistantItem],
        anchorMs: Int64?
    ) -> [AssistantItem] {
        guard let anchorMs else { return items }
        return items.filter { $0.startedAtMs >= anchorMs }
    }

    /// Milliseconds cutoff for post-user-message work. `nil` when not in a live
    /// follow-up (idle history keeps full turn content).
    nonisolated static func followUpWorkAnchorMs(
        status: AgentRunStatus,
        newestUserMessageAt: Date?,
        slack: TimeInterval = runningTranscriptContextSlack
    ) -> Int64? {
        guard status == .running || status == .pending else { return nil }
        guard let newestUserMessageAt else { return nil }
        let seconds = newestUserMessageAt.timeIntervalSince1970 - slack
        return Int64(seconds * 1000)
    }

    /// Cheap identity signature: changes only when a message/turn is added,
    /// removed, or reordered, not on streaming text deltas. O(turns), NOT O(messages):
    /// the full thread loads append-only (new sends land at the end), so the message
    /// side collapses to count + first/last id — capturing every add/remove/revert
    /// without walking all N messages on every body eval (critical now that N is the
    /// whole thread, not a 30-row window).
    ///
    /// Extracted as `nonisolated static` so it is testable without a view context and
    /// shared by every consumer in a single body pass through `SignatureCache`.
    nonisolated static func buildTranscriptSignature(messages: [AgentMessage],
                                                     turns: [AssistantTurnSnapshot]) -> String {
        var sig = "m\(messages.count)|\(messages.first?.id.value.uuidString ?? "-")|\(messages.last?.id.value.uuidString ?? "-")|t\(turns.count)|"
        for turn in turns {
            sig += turn.turnId
            // A turn's sortTime derives from its items' min startedAtMs; fold item count
            // in so the sort refreshes on item add (not on pure text deltas).
            sig += "#\(turn.items.count)"
        }
        return sig
    }

    /// F40: order-sensitive, non-cancelling fold of per-turn item counts. The previous
    /// XOR fold cancelled for equal-count turns (h ^ h == 0), so a flush in which two
    /// equal-count turns each gained an item ({c,c} -> {c+1,c+1}) left the hash — and
    /// therefore the cached signature and the stale transcript merge — unchanged.
    nonisolated static func turnItemCountsHash(_ turns: [AssistantTurnSnapshot]) -> Int {
        var hasher = Hasher()
        for turn in turns { hasher.combine(turn.items.count) }
        return hasher.finalize()
    }

    // PERF-MAC_AGENT-011: cache the signature string so a single SwiftUI body
    // pass computes it only once regardless of how many consumers read it.
    private final class SignatureCache {
        var lastMessages: Int = -1
        var lastFirstId: String = ""
        var lastLastId: String = ""
        var lastTurnsCount: Int = -1
        var lastTurnsItemCountsHash: Int = 0
        var cached: String = ""
    }
    private let signatureCache = SignatureCache()

    private var transcriptSignature: String {
        let msgCount = vm.messages.count
        let firstId = vm.messages.first?.id.value.uuidString ?? "-"
        let lastId = vm.messages.last?.id.value.uuidString ?? "-"
        let turnCount = vm.timeline.turns.count
        // Cheap hash of per-turn item counts — changes when an item is added to any turn.
        let itemCountsHash = Self.turnItemCountsHash(vm.timeline.turns)
        let c = signatureCache
        if c.lastMessages == msgCount && c.lastFirstId == firstId && c.lastLastId == lastId
            && c.lastTurnsCount == turnCount && c.lastTurnsItemCountsHash == itemCountsHash {
            return c.cached
        }
        let sig = Self.buildTranscriptSignature(messages: vm.messages, turns: vm.timeline.turns)
        c.lastMessages = msgCount; c.lastFirstId = firstId; c.lastLastId = lastId
        c.lastTurnsCount = turnCount; c.lastTurnsItemCountsHash = itemCountsHash
        c.cached = sig
        return sig
    }

    // Memoized on a message-only key so it recomputes only when a message is
    // appended/removed (human-paced) — NOT on every streaming tool call, and NOT
    // O(messages) per visible turn render.
    private final class AssistantTextsCache {
        var key: String?
        var texts: [String] = []
    }
    private let assistantTextsCache = AssistantTextsCache()

    // F2: per-turn render data, memoized for FINISHED turns (immutable content) so a
    // long completed thread no longer re-derives renderableItems / final-id splitting /
    // block grouping / plan filtering for every visible turn on every body pass. Keyed
    // per turnId; an entry is replaced when its signature changes. Running turns are
    // never cached (their content changes each delta) — they compute fresh.
    private final class TurnRenderCache {
        var entries: [String: (signature: String, value: TurnRenderInputs)] = [:]
    }
    private let turnRenderCache = TurnRenderCache()
    #if DEBUG
    // Test-only: counts how many times the uncached per-turn computation ran, so a
    // unit test can prove finished turns are served from cache across body passes.
    static nonisolated(unsafe) var turnRenderComputeCountForTesting = 0
    #endif

    /// F2: the memoized entry point used by `turnView`. Finished turns are immutable,
    /// so their inputs are cached against a signature that also folds in the external
    /// dependencies (persisted assistant texts + proposed plans). Running/unfinished
    /// turns are computed fresh every pass.
    private func turnRenderInputs(for turn: AssistantTurnSnapshot) -> TurnRenderInputs {
        let running = vm.selectedThreadRunIsStartingOrRunning
        let expandWork = expandedCompletedWorkTurns.contains(turn.turnId)
        let followUpAnchorMs = Self.followUpWorkAnchorMs(
            status: vm.status,
            newestUserMessageAt: vm.messages.last(where: { $0.role == .user })?.createdAt
        )
        guard turn.finished else {
            return computeTurnRenderInputsCounted(
                turn: turn,
                running: running,
                expandCompletedWork: expandWork,
                followUpWorkAnchorMs: followUpAnchorMs
            )
        }
        let plansKey = "\(vm.timeline.proposedPlans.count)|\(vm.timeline.proposedPlans.last?.id ?? "-")"
        let signature = Self.finishedTurnRenderSignature(
            turn: turn,
            assistantTextsKey: assistantTextsKey,
            plansKey: plansKey,
            expandCompletedWork: expandWork
        ) + "|a\(followUpAnchorMs.map(String.init) ?? "-")"
        if let cached = turnRenderCache.entries[turn.turnId], cached.signature == signature {
            return cached.value
        }
        let value = computeTurnRenderInputsCounted(
            turn: turn,
            running: running,
            expandCompletedWork: expandWork,
            followUpWorkAnchorMs: followUpAnchorMs
        )
        // Bound the cache: a hard cap keeps it from growing with total finished turns
        // over a very long session (entries rebuild on demand if cleared).
        if turnRenderCache.entries.count > 1_024 { turnRenderCache.entries.removeAll(keepingCapacity: true) }
        turnRenderCache.entries[turn.turnId] = (signature, value)
        return value
    }

    /// Signature for a FINISHED turn's render data. A finished turn's items are
    /// immutable, so (turnId, items.count) is a stable content key; the persisted
    /// assistant texts and proposed plans are external dependencies that change the
    /// answer-vs-worklog split and the plan rows, so they fold into the key too.
    /// `expandCompletedWork` is included so collapsed (count-only) and expanded
    /// (full blocks) inputs do not share a stale cache entry.
    nonisolated static func finishedTurnRenderSignature(turn: AssistantTurnSnapshot,
                                                        assistantTextsKey: String,
                                                        plansKey: String,
                                                        expandCompletedWork: Bool = false) -> String {
        "\(turn.turnId)|i\(turn.items.count)|\(assistantTextsKey)|pl\(plansKey)|w\(expandCompletedWork ? 1 : 0)"
    }

    private func computeTurnRenderInputsCounted(
        turn: AssistantTurnSnapshot,
        running: Bool,
        expandCompletedWork: Bool,
        followUpWorkAnchorMs: Int64?
    ) -> TurnRenderInputs {
        #if DEBUG
        Self.turnRenderComputeCountForTesting &+= 1
        #endif
        return Self.computeTurnRenderInputs(
            turn: turn,
            persistedAssistantTexts: persistedAssistantTexts,
            proposedPlans: vm.timeline.proposedPlans,
            running: running,
            expandCompletedWork: expandCompletedWork,
            followUpWorkAnchorMs: followUpWorkAnchorMs
        )
    }

    /// The message-only key that backs `persistedAssistantTexts`'s memo; reused as the
    /// persisted-texts component of the finished-turn render signature.
    private var assistantTextsKey: String {
        "\(vm.messages.count)|\(vm.messages.last?.id.value.uuidString ?? "-")"
    }

    private final class HiddenPersistedAssistantMessageCache {
        var key: String?
        var ids: Set<AgentMessageID> = []
    }
    private let hiddenPersistedAssistantMessageCache = HiddenPersistedAssistantMessageCache()

    private var persistedAssistantTexts: [String] {
        let key = "\(vm.messages.count)|\(vm.messages.last?.id.value.uuidString ?? "-")"
        if assistantTextsCache.key == key { return assistantTextsCache.texts }
        let texts = vm.messages.compactMap { $0.role == .assistant ? $0.content : nil }
        assistantTextsCache.key = key
        assistantTextsCache.texts = texts
        return texts
    }

    private var hiddenPersistedAssistantMessageIDs: Set<AgentMessageID> {
        // PERF-MAC_AGENT-011: transcriptSignature is now cached in SignatureCache so
        // this call and the call in transcriptEntries share one computation per body pass.
        let key = "\(vm.messages.count)|\(vm.messages.last?.id.value.uuidString ?? "-")|\(transcriptSignature)|u\(vm.timelineUpdateTick)"
        if hiddenPersistedAssistantMessageCache.key == key {
            return hiddenPersistedAssistantMessageCache.ids
        }
        let ids = Self.hiddenPersistedAssistantMessageIDs(
            messages: vm.messages,
            timelineTurns: vm.timeline.turns,
            persistedAssistantTexts: persistedAssistantTexts
        )
        hiddenPersistedAssistantMessageCache.key = key
        hiddenPersistedAssistantMessageCache.ids = ids
        return ids
    }

    public var body: some View {
        GeometryReader { proxy in
            HSplitView {
                if showThreadRail {
                    threadRail
                        .frame(
                            minWidth: Self.threadRailWidthRange.lowerBound,
                            idealWidth: Self.threadRailIdealWidth,
                            maxWidth: Self.threadRailWidthRange.upperBound
                        )
                }
                conversationColumn
                    .frame(minWidth: 0, maxWidth: .infinity)
                if vm.showPlanSidebar {
                    planSidebar.frame(minWidth: 240, idealWidth: Self.planSidebarIdealWidth, maxWidth: 420)
                }
            }
            .onAppear { applyAdaptiveSidebars(width: proxy.size.width, event: .structural) }
            .onChange(of: proxy.size.width) { width in
                applyAdaptiveSidebars(width: width, event: .resize)
            }
            .onChange(of: vm.showPlanSidebar) { _ in
                applyAdaptiveSidebars(width: proxy.size.width, event: .structural)
            }
        }
        .background(DS.Palette.bg)
        .background(newThreadShortcut)
        // UX-MAC_AGENT-OPEN-SPLIT: any tapped link inside this surface's markdown
        // (file mentions, bare URLs, markdown links) routes through the VM so it
        // opens — or reuses — a split panel to the right instead of leaving the app.
        .environment(\.openURL, OpenURLAction { url in
            vm.handleTranscriptLink(url) ? .handled : .systemAction
        })
        .task {
            // Let the first transcript/composer frame paint before provider
            // catalog probes (claude/codex/grok model lists) compete for CPU.
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            if vm.providerSnapshots.isEmpty {
                await vm.loadProviderSnapshots()
                // F10: the snapshot path drops the live/fallback signal —
                // run the VM's own fetch so availableModelsAreFallback (and
                // with it the "built-in defaults" warning + Refresh row) is
                // populated on startup, not only after a manual retry.
                await vm.loadModels()
            }
            // Subagent badge polling is workspace-coalesced in
            // AgentWorkspaceRailReloadCoordinator (one timer per workspace).
            // Registration happens in AgentAppViewModel.init.
        }
        .onDeleteCommand { deleteSelectedThreads() }
        // P1: confirm before deleting threads — irreversible and instant otherwise.
        .confirmationDialog(
            pendingDeleteThreadIds.count == 1
                ? "Delete this thread?"
                : "Delete \(pendingDeleteThreadIds.count) threads?",
            isPresented: Binding(
                get: { !pendingDeleteThreadIds.isEmpty },
                set: { if !$0 { pendingDeleteThreadIds = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { commitPendingDelete() }
            Button("Cancel", role: .cancel) { pendingDeleteThreadIds = [] }
        } message: {
            Text(Self.threadDeletionConfirmationDescription)
        }
        .confirmationDialog(
            "Clear all threads?",
            isPresented: $pendingClearAllThreads,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) { commitClearAllThreads() }
            Button("Cancel", role: .cancel) { pendingClearAllThreads = false }
        } message: {
            Text("Deletes every thread in this workspace and its history. Running agents will be stopped first. This cannot be undone after the undo window expires.")
        }
    }

    // UX-MAC_AGENT-002: ⌘N starts a thread even when the rail (and its "+"
    // button) is collapsed. A zero-size button carries the shortcut.
    private var newThreadShortcut: some View {
        Button { vm.createThread(title: "New thread") } label: { EmptyView() }
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityHidden(true)
    }

    // MARK: Thread rail

    private var threadRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader(vm.activeThreadCount > 0 ? "Threads · \(vm.activeThreadCount) active" : "Threads",
                            trailing: AnyView(
                HStack(spacing: DS.Space.xs) {
                    DSIconButton("sidebar.left", help: "Hide threads") {
                        threadRailIntent = .forcedHidden
                        showThreadRail = false
                    }
                    if !vm.threads.isEmpty {
                        Button("Clear All") { pendingClearAllThreads = true }
                            .buttonStyle(.plain)
                            .font(DS.Font.caption.weight(.medium))
                            .foregroundColor(DS.Palette.textSecondary)
                            .accessibilityIdentifier("agent.thread.clearAll")
                            .help("Delete all threads in this workspace")
                    }
                    DSIconButton("plus", help: "New thread (⌘N)") { vm.createThread(title: "New thread") }
                        .accessibilityIdentifier("agent.thread.new")
                }
            ))
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            if vm.threads.isEmpty {
                DSEmptyState(icon: "bubble.left.and.bubble.right",
                             title: "No threads",
                             subtitle: Self.emptyThreadSubtitle)
            } else {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(DS.Palette.textTertiary)
                    TextField("Search threads", text: $vm.threadSearchQuery)
                        .textFieldStyle(.plain)
                        .font(DS.Font.caption)
                        .accessibilityIdentifier("agent.thread.search")
                    if !vm.threadSearchQuery.isEmpty {
                        Button { vm.threadSearchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(DS.Palette.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.xs)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
                        if vm.filteredThreads.isEmpty {
                            Text("No threads match \"\(vm.threadSearchQuery)\"")
                                .font(DS.Font.caption)
                                .foregroundColor(DS.Palette.textTertiary)
                                .padding(DS.Space.sm)
                        } else {
                            ForEach(vm.filteredThreads, id: \.id) { t in threadRow(t) }
                        }
                    }.padding(DS.Space.sm)
                }
                .focusable()
                .onMoveCommand { direction in
                    let delta: Int
                    switch direction {
                    case .up:   delta = -1
                    case .down: delta = 1
                    default: return
                    }
                    let threads = vm.filteredThreads
                    let current = threads.firstIndex(where: { $0.id == vm.selectedThreadId })
                    guard let next = AgentThreadRailKeyboardNav.moveThreadSelection(
                        current: current,
                        direction: delta,
                        count: threads.count
                    ) else { return }
                    vm.selectThread(threads[next].id)
                }
            }
        }
        .background(DS.Palette.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
        }
    }

    @ViewBuilder
    private func threadRow(_ t: AgentThread) -> some View {
        if renamingThreadId == t.id {
            renameRow(t)
        } else {
            let selected = vm.selectedThreadId == t.id
            let multiSelected = selectedThreadIds.contains(t.id)
            let running = vm.isThreadStartingOrRunning(t.id)
            let showLeadingStatus = t.pinned || t.status == .failed || !t.hasUnread || running
            Button { selectThreadRow(t) } label: {
                HStack(spacing: DS.Space.md) {
                    if running {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Running")
                            .accessibilityIdentifier("agent.thread.row.running.\(t.id.value.uuidString)")
                    } else if showLeadingStatus {
                        Image(systemName: t.pinned ? "pin.fill" : "circle.fill")
                            .font(.system(size: t.pinned ? 9 : 7, weight: .semibold))
                            .foregroundColor(TabColor.from(t.color).map { Color(hex: $0.hex) }
                                             ?? (t.status == .failed ? DS.Palette.danger : DS.Palette.textTertiary))
                            .frame(width: 8, height: 8)
                    } else {
                        Color.clear.frame(width: 8, height: 8)
                    }
                    Text(AgentThreadRailRowCopy.monogram(for: t.provider))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: 16, height: 16)
                        .background(DS.Palette.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AgentThreadTitle.display(t.title)).font(DS.Font.bodyDense.weight(t.hasUnread ? .semibold : .regular))
                            .foregroundColor(DS.Palette.text).lineLimit(1)
                        Text(AgentThreadRailRowCopy.subtitle(
                            provider: t.provider,
                            model: t.model,
                            updatedAt: t.updatedAt,
                            now: vm.currentTime()
                        ))
                            .font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if t.hasUnread {
                        Circle().fill(DS.Palette.accent).frame(width: 7, height: 7)
                            .accessibilityLabel("Unread activity")
                            .accessibilityIdentifier("agent.thread.row.unread.\(t.id.value.uuidString)")
                    }
                    if AgentThreadRowPresentation.showsSelectionCheck(
                        threadStatus: t.status,
                        selected: selected,
                        surfaceStatus: vm.status,
                        multiSelected: multiSelected
                    ) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Palette.accent)
                    }
                }
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.sm)
                .background((selected || multiSelected) ? DS.Palette.selection : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(t.title)
            .accessibilityIdentifier("agent.thread.row.\(t.id.value.uuidString)")
            .overlay(alignment: .trailing) {
                if running {
                    Button {
                        vm.stopThread(t.id)
                    } label: {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Palette.danger.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, DS.Space.md)
                    .accessibilityLabel("Stop thread")
                    .accessibilityIdentifier("agent.thread.row.stop.\(t.id.value.uuidString)")
                    .help("Stop this thread")
                }
            }
            .onDrag {
                draggingThreadId = t.id
                return NSItemProvider(object: t.id.value.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: AgentThreadDropDelegate(vm: vm, draggingThreadId: $draggingThreadId, target: t))
            .contextMenu {
                if running {
                    Button("Stop", role: .destructive) { vm.stopThread(t.id) }
                        .accessibilityIdentifier("agent.thread.contextmenu.stop.\(t.id.value.uuidString)")
                    Divider()
                }
                Button(t.pinned ? "Unpin" : "Pin") { vm.setThreadPinned(t.id, !t.pinned) }
                Divider()
                Button("Rename…") { renameText = t.title; renamingThreadId = t.id }
                Menu("Color") {
                    Button { vm.setThreadColor(t.id, "") } label: {
                        TabColorMenuLabel.none
                    }
                    ForEach(TabColor.allCases, id: \.self) { c in
                        Button { vm.setThreadColor(t.id, c.rawValue) } label: {
                            TabColorMenuLabel(c)
                        }
                    }
                }
                Divider()
                // IMP-MAC_AGENT-013: export the thread to a shareable markdown file.
                Button("Export…") { exportThread(t) }
                Divider()
                Button("Delete", role: .destructive) {
                    pendingDeleteThreadIds = selectedThreadIds.isEmpty ? [t.id] : selectedThreadIds
                }
            }
        }
    }

    private func renameRow(_ t: AgentThread) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "pencil")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Palette.accent)
            TextField("Thread name", text: $renameText)
                .textFieldStyle(.plain)
                .font(DS.Font.bodyDense)
                .onSubmit { commitRename(t) }
            Button { renamingThreadId = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Cancel rename")
            .help("Cancel rename")
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .strokeBorder(DS.Palette.accent.opacity(0.4), lineWidth: DS.Border.hairline))
    }

    private func commitRename(_ t: AgentThread) {
        vm.renameThread(t.id, to: renameText)
        renamingThreadId = nil
    }

    // MARK: Conversation column

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            header
            if vm.permissionMode == .fullAccess {
                fullAccessBanner
            }
            if let undo = vm.pendingThreadDeletionUndo {
                threadDeletionUndoBanner(undo)
            }
            if let crToast = vm.pendingCheckpointRevertUndo {
                checkpointRevertUndoBanner(crToast)
            }
            if !vm.timeline.workActivities.isEmpty {
                workLogRow
                    .padding(.horizontal, 22)
                    .padding(.vertical, DS.Space.md)
                    .background(DS.Palette.bg)
            }
            timeline
            backgroundAwaitBanner
            pendingCallbackRows
            // Unified system strip: severity-ordered, capped (replaces stacked banners).
            systemStatusStrip
            queuedMessagesSection
            // F1: render the composer inside a scope that observes only the composer
            // text, so a keystroke re-renders the composer subtree and NOT this body
            // (which builds the whole transcript).
            ComposerReactiveScope(composerState: vm.composerState) { composer }
        }
        .background(DS.Palette.bg)
        // C6: Esc interrupts an in-flight run (remotecode.io parity).
        .onExitCommand { if vm.selectedThreadRunIsStartingOrRunning { vm.stop() } }
        // IMP-MAC_AGENT-006: power-user shortcut to cycle reasoning effort
        // without opening the model popover; the composer model pill reflects
        // the new effort immediately. Hidden control carries the shortcut.
        .background(
            Button("") { vm.cycleReasoningEffort() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    // Thin context header. Run-config (provider/model/permission) lives in
    // the composer footer now, Codex-style.
    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            if !showThreadRail {
                DSIconButton("sidebar.left", help: "Show threads") {
                    threadRailIntent = .forcedVisible
                    showThreadRail = true
                }
                // UX-MAC_AGENT-002: keep a new-thread affordance reachable while
                // the rail's "+" button is collapsed away.
                DSIconButton("plus", help: "New thread (⌘N)") { vm.createThread(title: "New thread") }
                    .accessibilityIdentifier("agent.thread.new.collapsed")
            }
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
            Text(vm.gitBranch ?? "no branch")
                .font(DS.Font.caption2.monospaced())
                .foregroundColor(DS.Palette.textSecondary)
            if let context = vm.contextHealthMessage {
                Text("·").foregroundColor(DS.Palette.textTertiary)
                Text(context)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            Text("·").foregroundColor(DS.Palette.textTertiary)
            Text(URL(fileURLWithPath: vm.cwd).lastPathComponent)
                .font(DS.Font.caption2)
                .foregroundColor(DS.Palette.textTertiary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            // Unified working phase strip (replaces separate awaiting/shell/status pills).
            workingPhaseStrip
            // Provider-neutral Subagents activity for the selected thread only
            // (admission receipts + coordinator). Compact badge + popover; does
            // not touch transcript/composer or aggregate sibling threads.
            // Auto (orchestrate) always exposes the chrome so delegated workers
            // are discoverable the moment the first child receipt lands — not
            // only after the user already knows to look for a hidden badge.
            if !vm.subagentActivity.isEmpty || showSubagentActivity || vm.routingMode == .auto {
                SubagentActivityBadge(
                    snapshot: vm.subagentActivity,
                    now: vm.currentTime(),
                    isPresented: $showSubagentActivity,
                    orchestrateActive: vm.routingMode == .auto
                )
            }
            DSIconButton("list.bullet.rectangle", help: "Toggle plan") {
                planSidebarIntent = vm.showPlanSidebar ? .forcedHidden : .forcedVisible
                vm.showPlanSidebar.toggle()
            }
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
        .dsBar(edge: .bottom)
    }

    // Persistent, prominent banner while full access is on, beyond the small
    // permission pill in the composer footer (UX-MAC_AGENT-004).
    private var fullAccessBanner: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.danger)
            VStack(alignment: .leading, spacing: 1) {
                Text("Full access is on")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.danger)
                Text(Self.fullAccessScopeDescription)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            Spacer(minLength: 0)
            Button("Switch to supervised") { vm.setPermissionMode(.supervised) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.danger.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Palette.danger.opacity(0.3)).frame(height: 1) }
        .accessibilityIdentifier("agent.fullAccessBanner")
    }

    // UX-XPLAT-DELETE-UNDO: transient toast offering to restore a just-deleted
    // thread. The delete already happened; Undo re-inserts the snapshot.
    private func threadDeletionUndoBanner(_ undo: AgentAppViewModel.ThreadDeletionUndo) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.textSecondary)
            Text(undo.count > 1 ? "\(undo.count) threads deleted" : "Thread deleted")
                .font(DS.Font.caption.weight(.semibold))
                .foregroundColor(DS.Palette.text)
            Spacer(minLength: 0)
            Button("Undo") { vm.undoLastThreadDeletion() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("agent.thread.delete.undo")
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Palette.line).frame(height: 1) }
        .accessibilityIdentifier("agent.thread.delete.undoBanner")
    }

    private func checkpointRevertUndoBanner(_ toast: AgentAppViewModel.CheckpointRevertUndoToast) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.textSecondary)
            Text("Reverted to checkpoint \(toast.checkpointTurnCount)")
                .font(DS.Font.caption.weight(.semibold))
                .foregroundColor(DS.Palette.text)
            Spacer(minLength: 0)
            Button("Undo") { vm.undoLastCheckpointRevert() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("agent.checkpoint.revert.undo")
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Palette.line).frame(height: 1) }
        .accessibilityIdentifier("agent.checkpoint.revert.undoBanner")
    }

    private var modelLabel: String {
        if vm.routingMode == .auto { return "Auto" }
        return vm.modelOptionsForSelectedProvider.first(where: { $0.id == vm.model })?.label ?? vm.model
    }
    private var autoRoutingPrerequisitesLoading: Bool {
        vm.selectedThreadId != nil && (
            vm.providerSnapshots.isEmpty || vm.providerSnapshotsLoading || vm.modelListLoading
        )
    }
    private var autoRoutingPillLoading: Bool {
        vm.routingMode == .auto && autoRoutingPrerequisitesLoading
    }
    private var permissionLabel: String {
        switch vm.permissionMode {
        case .supervised: return "Supervised"
        case .autoAcceptEdits: return "Auto-edit"
        case .fullAccess: return "Full access"
        }
    }
    private var permissionTone: Color {
        switch vm.permissionMode {
        case .supervised: return DS.Palette.textSecondary
        case .autoAcceptEdits: return DS.Palette.warning
        case .fullAccess: return DS.Palette.danger
        }
    }
    private var effortLabel: String { vm.reasoningEffort.displayName }
    private var serviceTierLabel: String { vm.serviceTier == .fast ? "Fast" : "Auto" }
    /// P3: VoiceOver label for the model picker pill that reads as structured
    /// text rather than the raw concatenated visual tokens.
    private var modelMenuAccessibilityLabel: String {
        if vm.routingMode == .auto {
            return autoRoutingPillLoading ? "Auto model routing, loading" : "Auto model routing"
        }
        var parts = ["Model \(modelLabel)"]
        if vm.supportsReasoningForSelectedModel {
            parts.append("effort \(effortLabel)")
        }
        if vm.serviceTier == .fast {
            parts.append("tier Fast")
        }
        return parts.joined(separator: ", ")
    }

    private var threadRailIntent: AdaptiveSidebarIntent {
        get { AdaptiveSidebarIntent(rawValue: threadRailIntentRaw) ?? .auto }
        nonmutating set { threadRailIntentRaw = newValue.rawValue }
    }

    private var planSidebarIntent: AdaptiveSidebarIntent {
        get { AdaptiveSidebarIntent(rawValue: planSidebarIntentRaw) ?? .auto }
        nonmutating set { planSidebarIntentRaw = newValue.rawValue }
    }

    // QA-MAC_AGENT-013: UI tests can pin both sidebars visible to get a stable
    // layout that resize-driven auto-collapse can't flake. Set via launch arg
    // `-agent.pinSidebars` or env `RC_AGENT_PIN_SIDEBARS=1`.
    private static let sidebarsPinnedForTesting: Bool =
        ProcessInfo.processInfo.arguments.contains("-agent.pinSidebars")
        || ProcessInfo.processInfo.environment["RC_AGENT_PIN_SIDEBARS"] == "1"

    private func applyAdaptiveSidebars(width: CGFloat, event: AdaptiveSidebarLayoutEvent) {
        if Self.sidebarsPinnedForTesting {
            showThreadRail = true
            vm.showPlanSidebar = true
            return
        }
        applyAdaptivePlanSidebar(width: width, event: event)
        applyAdaptiveThreadRail(width: width, event: event)
    }

    private func applyAdaptivePlanSidebar(width: CGFloat, event: AdaptiveSidebarLayoutEvent) {
        let now = vm.currentTime().timeIntervalSinceReferenceDate
        let reservedThreadWidth = showThreadRail ? Self.threadRailIdealWidth : 0
        let decision = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: width - reservedThreadWidth,
            contentMinimumExtent: Self.conversationMinimumWidth,
            sidebarExtent: Self.planSidebarIdealWidth,
            currentVisible: vm.showPlanSidebar,
            intent: planSidebarIntent,
            event: event,
            now: now,
            lastAutomaticChange: lastAutomaticPlanSidebarChange
        )
        guard decision.isVisible != vm.showPlanSidebar else { return }
        vm.showPlanSidebar = decision.isVisible
        if decision.didChangeAutomatically {
            lastAutomaticPlanSidebarChange = now
            // UX-MAC_AGENT-011: make auto-collapse one-way — once the policy
            // hides the plan sidebar for being too narrow, persist that intent so
            // a later resize never surprises the user by auto-showing it. The
            // header "Toggle plan" button restores it explicitly (.forcedVisible).
            if !decision.isVisible, planSidebarIntent == .auto {
                planSidebarIntent = .forcedHidden
            }
        }
    }

    private func applyAdaptiveThreadRail(width: CGFloat, event: AdaptiveSidebarLayoutEvent) {
        let now = vm.currentTime().timeIntervalSinceReferenceDate
        let reservedPlanWidth = vm.showPlanSidebar ? Self.planSidebarIdealWidth : 0
        let decision = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: width - reservedPlanWidth,
            contentMinimumExtent: Self.conversationMinimumWidth,
            sidebarExtent: Self.threadRailIdealWidth,
            currentVisible: showThreadRail,
            intent: threadRailIntent,
            event: event,
            now: now,
            lastAutomaticChange: lastAutomaticThreadRailChange
        )
        guard decision.isVisible != showThreadRail else { return }
        showThreadRail = decision.isVisible
        if decision.didChangeAutomatically {
            lastAutomaticThreadRailChange = now
        }
    }

    /// "1 shell" / "2 shells" — matches the Claude CLI's own wording so the two
    /// surfaces read the same. Pure, for unit testing the pluralization.
    nonisolated static func backgroundShellLabel(_ count: Int) -> String {
        count == 1 ? "1 shell" : "\(count) shells"
    }

    private func statusTone(_ s: AgentRunStatus) -> DSPill.Tone {
        switch s {
        case .running: return .accent
        case .completed: return .success
        case .failed: return .danger
        case .cancelled, .interrupted: return .warning
        default: return .neutral
        }
    }

    // MARK: Timeline

    // Flat, Codex-style transcript: a centered reading column, user
    // messages as right-aligned bubbles, assistant output as full-width
    // prose, tools as one dim line. No per-item cards.
    private var timeline: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                GeometryReader { viewport in
                    // Horizontal padding on the transcript stack is 22pt each side.
                    // User bubbles size against this content column, not the raw viewport.
                    let timelineColumnWidth = max(0, viewport.size.width - 44)
                    ScrollView {
                        // PERF-MAC_AGENT-022: the live transcript is already bounded.
                        // `LazyVStack` repeatedly hit SwiftUI LazyLayout placement loops
                        // while rows streamed in/out, so use an eager stack for the small
                        // visible window and keep full history in the model.
                        VStack(alignment: .leading, spacing: 32) {
                            let allEntries = transcriptEntries
                            let entries = Self.visibleTranscriptWindow(
                                entries: allEntries,
                                status: vm.status,
                                runStartedAt: vm.runStartedAt
                            )
                            let hiddenCount = Self.hiddenTranscriptCount(
                                totalCount: allEntries.count,
                                visibleCount: entries.count
                            )
                            let revealedHiddenCount = min(
                                vm.transcriptHistoryRevealCount,
                                hiddenCount
                            )
                            TimelineScrollFollower(
                                slack: Self.timelineBottomRevealSlack,
                                pinned: timelineSticksToBottom,
                                onScrolledAway: { onTimelineScrolledAway() },
                                onReturnedToBottom: { onTimelineReturnedToBottom() }
                            )
                            .frame(width: 0, height: 0)
                            .accessibilityHidden(true)
                            if vm.messageHistoryIsPartial {
                                VStack(alignment: .leading, spacing: DS.Space.xs) {
                                    Text("Showing the recent message window. Earlier messages remain stored locally.")
                                        .font(DS.Font.caption)
                                        .foregroundColor(DS.Palette.textTertiary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .accessibilityIdentifier("agent.transcript.partialMessageHistory")
                                    Button {
                                        vm.loadOlderMessages()
                                    } label: {
                                        if vm.isLoadingOlderMessages {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Label("Load older messages", systemImage: "arrow.up.circle")
                                                .font(DS.Font.caption)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(vm.isLoadingOlderMessages)
                                    .accessibilityIdentifier("agent.transcript.loadOlderMessages")
                                }
                            }
                            if hiddenCount > 0 {
                                runningHiddenTranscriptRow(
                                    hiddenCount,
                                    revealedCount: revealedHiddenCount,
                                    pageCount: Self.hiddenTranscriptRevealPageCount,
                                    onReveal: {
                                        vm.transcriptHistoryRevealCount = min(
                                            hiddenCount,
                                            vm.transcriptHistoryRevealCount + Self.hiddenTranscriptRevealPageCount
                                        )
                                    }
                                )
                            }
                            if revealedHiddenCount > 0 {
                                let hiddenEntries = Self.hiddenTranscriptRevealWindow(
                                    allItems: allEntries,
                                    visibleWindow: entries,
                                    revealCount: revealedHiddenCount
                                )
                                ForEach(hiddenEntries) { entry in
                                    switch entry {
                                    case .message(let message):
                                        messageRow(message, columnWidth: timelineColumnWidth)
                                    case .turn(let turn):
                                        turnView(turn)
                                    }
                                }
                            }
                            ForEach(entries) { entry in
                                switch entry {
                                case .message(let message):
                                    messageRow(message, columnWidth: timelineColumnWidth)
                                case .turn(let turn):
                                    turnView(turn)
                                }
                            }
                            // B-1: one chip for the whole thread, after the newest
                            // finished answer — never N copies under every final.
                            if !vm.selectedThreadRunIsStartingOrRunning {
                                tokenSaverThreadFooter()
                            }
                            if Self.shouldRenderActivePlan(
                                plan: vm.activePlan,
                                status: vm.status,
                                runStartedAt: vm.runStartedAt,
                                newestUserMessageAt: vm.messages.last(where: { $0.role == .user })?.createdAt
                            ), let plan = vm.activePlan {
                                activePlanRow(plan)
                            }
                            if vm.messages.isEmpty && vm.timeline.turns.isEmpty && vm.timeline.error == nil {
                                emptyConversation
                            }
                            if vm.selectedThreadRunIsStartingOrRunning { workingStatus }
                            else if vm.selectedThreadIsPreparingRun { loadingStatus }
                            if let err = vm.timeline.error { errorRow(err) }
                            // UX-MAC_AGENT-CONTINUE: show inline Continue only when the
                            // selected thread was interrupted by a relaunch and is not
                            // currently running. One tap replays recoverableResumeContext.
                            if AgentAppViewModel.showsContinueAction(
                                hasRecoverableContext: vm.selectedThreadHasRecoverableContext,
                                runActive: vm.selectedThreadRunIsStartingOrRunning
                            ) { interruptedContinueRow }
                            // Scroll-to target only. Bottom detection is handled by the
                            // AppKit TimelineScrollFollower above — NOT by a per-layout
                            // GeometryReader preference, which fed onPreferenceChange -> @State
                            // writes -> body invalidation -> re-layout -> new maxY ... a
                            // self-sustaining layout loop that froze the UI on scroll
                            // (PERF-MAC_AGENT-021).
                            Color.clear
                                .frame(height: 1)
                                .id("BOTTOM")
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 32)
                        .frame(width: viewport.size.width, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .coordinateSpace(name: "agentTimeline")
                    .background(DS.Palette.bg)
                    // IMP-MAC_AGENT-010: the conversation area is a natural drop
                    // target — accept file drops here too, routing them to the
                    // same composer attachments as the composer's own drop zone.
                    .onDrop(of: [UTType.fileURL], isTargeted: $timelineDropTargeted) { providers in
                        loadDroppedFileAttachments(from: providers)
                    }
                    .overlay {
                        if timelineDropTargeted {
                            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                                .strokeBorder(DS.Palette.accent, lineWidth: 2)
                                .padding(DS.Space.sm)
                                .allowsHitTesting(false)
                        }
                    }
                }
                if showScrollDownButton {
                    Button {
                        scrollTimelineToBottom(proxy, force: true)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(DS.Palette.accent)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Scroll to latest message")
                    .accessibilityIdentifier("agent.timeline.scrollToBottom")
                    .help("Scroll to latest message")
                    .padding(.trailing, 14)
                    .padding(.bottom, Self.scrollDownButtonBottomInset)
                    .zIndex(1)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .onAppear { scheduleTimelineScrollToBottom(proxy) }
            .onChange(of: vm.focusTick) { _ in
                // focusTick bumps on outgoing user send — collapse before the
                // new turn paints so pending follow-ups do not keep prior expands.
                collapseTranscriptForNewTurn()
                scheduleTimelineScrollToBottom(proxy, force: true)
            }
            // Prefer coalesced paint tick + last-message identity over raw counts
            // so every token/turn delta does not schedule redundant scroll work.
            .onChange(of: vm.timelineUpdateTick) { _ in
                scheduleTimelineScrollToBottom(proxy)
            }
            .onChange(of: vm.messages.last?.id) { _ in
                scheduleTimelineScrollToBottom(proxy)
            }
            .onChange(of: vm.timeline.turns.count) { _ in
                // PERF-MAC_AGENT-012: drop expansion ids for items that no longer
                // exist (turns are memory-capped at AssistantTimelineState.liveTurnLimit)
                // so the sets don't leak over a long session. Runs only on a turn
                // add/remove, not per text delta.
                DispatchQueue.main.async {
                    pruneExpandedItemIds()
                }
            }
            .onChange(of: vm.status) { newStatus in
                if newStatus == .pending || newStatus == .running {
                    collapseTranscriptForNewTurn()
                }
                scheduleTimelineScrollToBottom(proxy)
            }
            // P1: collapse revealed history + open work/tool disclosures whenever
            // a new run starts so a follow-up reads as a fresh chat turn, not a
            // re-expansion of every prior command.
            .onChange(of: vm.runStartedAt) { newValue in
                if newValue != nil {
                    collapseTranscriptForNewTurn()
                }
            }
            // PERF-MAC_AGENT-023: also collapse on thread switch. Idle threads now
            // bound their render to a recent tail (visibleTranscriptWindow), so a
            // revealed flag carried into a different long thread would eagerly
            // render its whole history with no user action — reintroducing the hang.
            .onChange(of: vm.selectedThreadId) { _ in
                vm.transcriptHistoryRevealCount = 0
                pendingSessionApproval = nil
            }
        }
    }

    private func pruneExpandedItemIds() {
        let liveItemIds = Set(vm.timeline.turns.flatMap { $0.items.map(\.id) })
        if !expandedTools.isEmpty { expandedTools.formIntersection(liveItemIds) }
        // A tool group is keyed by its first item's id, so it lives in the same id space.
        if !expandedToolGroups.isEmpty { expandedToolGroups.formIntersection(liveItemIds) }
        if !expandedReasoning.isEmpty { expandedReasoning.formIntersection(liveItemIds) }
        let liveRequestIds = Set(vm.timeline.pendingRequests.map(\.id))
        if !expandedRequestPreviews.isEmpty { expandedRequestPreviews.formIntersection(liveRequestIds) }
        let liveTurnIds = Set(vm.timeline.turns.map(\.turnId))
        if !expandedCompletedWorkTurns.isEmpty { expandedCompletedWorkTurns.formIntersection(liveTurnIds) }
    }

    // UX-MAC_AGENT-BG-AWAIT / incomplete-turn: when a thread ends incomplete
    // (background job await or multi-phase handoff), the run reads "awaiting"
    // (not a green "completed"); this banner lets the user resume it. Full-access
    // threads are also auto-nudged by the coordinator, so this is mainly supervised.
    @ViewBuilder
    private var backgroundAwaitBanner: some View {
        if let reason = vm.incompleteTurnReason {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "hourglass")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Palette.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text({
                        switch reason {
                        case .workflowHandoff: return "Agent stopped mid-workflow"
                        case .uncalledToolInvocation: return "Agent emitted an unexecuted tool call"
                        case .backgroundAwait: return "Agent is waiting on a background task"
                        }
                    }())
                        .font(DS.Font.caption.weight(.semibold))
                        .foregroundColor(DS.Palette.textSecondary)
                    Text({
                        switch reason {
                        case .workflowHandoff:
                            return "The run ended between phases. Resume it to finish the original task."
                        case .uncalledToolInvocation:
                            return "The run ended after printing tool markup instead of calling a tool. Resume it to continue."
                        case .backgroundAwait:
                            return "The run ended while standing by. Resume it to check the task and finish."
                        }
                    }())
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                }
                Spacer(minLength: 0)
                Button("Continue") {
                    Task { await vm.continueAfterBackgroundWait() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.bg)
            .accessibilityIdentifier("agent.backgroundAwaitBanner")
        }
    }

    @ViewBuilder
    private var pendingCallbackRows: some View {
        if !vm.visiblePendingRequests.isEmpty || !vm.visiblePendingUserInputs.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                ForEach(vm.visiblePendingRequests) { request in
                    pendingRequestRow(request)
                }
                ForEach(vm.visiblePendingUserInputs) { request in
                    pendingUserInputRow(request)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.bg)
            .accessibilityIdentifier("agent.pendingCallbacks")
            .confirmationDialog(
                "Allow this agent to act without approvals for this thread until you change it?",
                isPresented: Binding(
                    get: { pendingSessionApproval != nil },
                    set: { if !$0 { pendingSessionApproval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Allow full access", role: .destructive) {
                    if let pendingSessionApproval {
                        vm.respondToPendingRequest(
                            pendingSessionApproval.request,
                            response: .approveForSession,
                            originThreadId: pendingSessionApproval.originThreadId
                        )
                    }
                    pendingSessionApproval = nil
                }
                Button("Keep approving each action", role: .cancel) {
                    pendingSessionApproval = nil
                }
            } message: {
                Text("Full access lets the agent run tools and edits without asking. Keeping per-action approval is safer.")
            }
        }
    }

    @ViewBuilder
    private var workLogRow: some View {
        let activities = Array(vm.timeline.workActivities.suffix(8))
        if !activities.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showWorkLog.toggle()
                    }
                } label: {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: showWorkLog ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                            .frame(width: 10)
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Palette.textTertiary)
                        Text("Work log")
                            .font(DS.Font.caption.weight(.semibold))
                            .foregroundColor(DS.Palette.textSecondary)
                        Text("\(activities.count)")
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agent.workLog.toggle")
                .accessibilityLabel(showWorkLog ? "Hide work log" : "Show work log")
                .help(showWorkLog ? "Hide work log" : "Show work log")
                if showWorkLog {
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        ForEach(activities) { activity in
                            HStack(alignment: .top, spacing: DS.Space.sm) {
                                Image(systemName: workActivityIcon(activity))
                                    .font(.system(size: 9))
                                    .foregroundColor(workActivityColor(activity))
                                    .frame(width: 13)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(activity.title)
                                        .font(DS.Font.caption)
                                        .foregroundColor(DS.Palette.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    if let detail = activity.detail, !detail.isEmpty {
                                        Text(detail)
                                            .font(DS.Font.monoSmall)
                                            .foregroundColor(DS.Palette.textTertiary)
                                            .lineLimit(2)
                                            .truncationMode(.tail)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.vertical, DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("agent.workLog")
        }
    }

    private func workActivityIcon(_ activity: AssistantWorkActivity) -> String {
        if activity.state == AssistantItemState.streaming.rawValue { return "circle.dotted" }
        if activity.state == AssistantItemState.failed.rawValue || activity.kind == .error { return "xmark.octagon" }
        switch activity.kind {
        case .runtime: return "waveform.path.ecg"
        case .tool: return "terminal"
        case .request: return "checkmark.shield"
        case .userInput: return "questionmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private func workActivityColor(_ activity: AssistantWorkActivity) -> Color {
        if activity.state == AssistantItemState.failed.rawValue || activity.kind == .error { return DS.Palette.danger }
        if activity.state == AssistantItemState.streaming.rawValue { return DS.Palette.accent }
        return DS.Palette.textTertiary
    }

    @ViewBuilder
    private func pendingRequestRow(_ request: AssistantPendingRequest) -> some View {
        let stale = request.state == .stale
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: stale ? "exclamationmark.triangle" : "checkmark.shield")
                    .font(.system(size: 12))
                    .foregroundColor(stale ? DS.Palette.warning : DS.Palette.accent)
                Text(stale ? "Stale provider request" : "Provider approval")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                // UX-MAC_AGENT-005: label what is being approved.
                requestKindChip(request.kind)
                Spacer(minLength: 0)
            }
            Text(request.title)
                .font(DS.Font.bodyDense.weight(.semibold))
                .foregroundColor(DS.Palette.text)
                .lineLimit(2)
            // UX-MAC_AGENT-006: surface the actual command / patch so users
            // don't approve exec/applyPatch requests blind.
            requestPreview(request)
            if stale {
                Text("Restart the turn to continue.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.warning)
            } else {
                // UX-MAC_AGENT-005: emphasize the safe one-time Approve;
                // de-emphasize/warning-tint the session-wide auto-approve;
                // separate Decline.
                if declineReasonDrafts[request.id] != nil {
                    // Inline decline-with-reason form.
                    let reasonBinding = Binding(
                        get: { declineReasonDrafts[request.id] ?? "" },
                        set: { declineReasonDrafts[request.id] = $0 }
                    )
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        TextField("Reason (optional)", text: reasonBinding)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        HStack(spacing: DS.Space.sm) {
                            Button("Send Decline") {
                                let draft = declineReasonDrafts[request.id]
                                declineReasonDrafts[request.id] = nil
                                vm.respondToPendingRequest(
                                    request,
                                    response: AgentAppViewModel.declinePayload(reason: draft)
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("Cancel") { declineReasonDrafts[request.id] = nil }
                                .buttonStyle(.plain)
                                .controlSize(.small)
                        }
                    }
                } else {
                    HStack(spacing: DS.Space.sm) {
                        Button("Approve") { vm.respondToPendingRequest(request, response: .approve) }
                            .buttonStyle(.borderedProminent)
                        if request.allowsSessionApproval {
                            Button("Approve Session") {
                                if let originThreadId = vm.selectedThreadId {
                                    pendingSessionApproval = PendingSessionApprovalConfirmation(
                                        originThreadId: originThreadId,
                                        request: request
                                    )
                                }
                            }
                                .buttonStyle(.bordered)
                                .tint(DS.Palette.warning)
                                .help(Self.sessionApprovalHelp)
                        }
                        Spacer(minLength: DS.Space.md)
                        Button("Decline") { declineReasonDrafts[request.id] = "" }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .disabled(vm.selectedProviderSnapshot.map {
            !$0.effectiveCapabilities.supportsApprovals
        } ?? false)
        .accessibilityIdentifier("agent.pendingRequest.\(request.id)")
    }

    // UX-MAC_AGENT-005: a small chip naming the request kind.
    private func requestKindChip(_ kind: AssistantRequestKind) -> some View {
        Text(requestKindLabel(kind))
            .font(DS.Font.caption2.weight(.semibold))
            .foregroundColor(DS.Palette.accent)
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, 1)
            .background(DS.Palette.accent.opacity(0.13))
            .clipShape(Capsule())
    }

    private func requestKindLabel(_ kind: AssistantRequestKind) -> String {
        switch kind {
        case .commandExecution, .exec: return "Run command"
        case .applyPatch: return "Apply patch"
        case .fileChange: return "Edit file"
        case .fileRead: return "Read file"
        case .toolUserInput: return "Tool input"
        case .authTokensRefresh: return "Refresh auth"
        case .dynamic: return "Tool"
        }
    }

    // UX-MAC_AGENT-006: command kinds render monospace + copy; patch kinds
    // render a collapsible diff. Other kinds fall back to the prior detail row.
    @ViewBuilder
    private func requestPreview(_ request: AssistantPendingRequest) -> some View {
        if let detail = request.detail, !detail.isEmpty {
            switch request.kind {
            case .commandExecution, .exec:
                HStack(alignment: .top, spacing: DS.Space.sm) {
                    Text(detail)
                        .font(DS.Font.mono)
                        .foregroundColor(DS.Palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.sm)
                        .background(DS.Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                    Button { copyToPasteboard(detail) } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Palette.textSecondary)
                    .help("Copy command")
                }
            case .applyPatch, .fileChange:
                let expanded = expandedRequestPreviews.contains(request.id)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Button {
                        if expanded { expandedRequestPreviews.remove(request.id) }
                        else { expandedRequestPreviews.insert(request.id) }
                    } label: {
                        HStack(spacing: DS.Space.xs) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8)).foregroundColor(DS.Palette.textTertiary)
                            Text(expanded ? "Hide diff" : "Show diff")
                                .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    if expanded {
                        DiffPreviewText(detail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DS.Space.sm)
                            .background(DS.Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                    }
                }
            default:
                Text(detail)
                    .font(DS.Font.monoSmall)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func pendingUserInputRow(_ request: AssistantUserInputRequest) -> some View {
        let stale = request.state == .stale
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: stale ? "exclamationmark.triangle" : "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(stale ? DS.Palette.warning : DS.Palette.accent)
                Text(stale ? "Stale provider question" : "Provider question")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                Spacer(minLength: 0)
            }
            if request.isStructured {
                askUserQuestionContent(request, stale: stale)
            } else {
                legacyUserInputContent(request, stale: stale)
            }
            if !stale {
                Button("Cancel question", role: .cancel) {
                    vm.cancelPendingUserInput(request)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.selectedProviderSnapshot.map {
                    !$0.effectiveCapabilities.supportsUserInput
                } ?? false)
                .help("Cancel only this question and keep the provider session available.")
                .accessibilityIdentifier("agent.pendingUserInput.cancel.\(request.id)")
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .accessibilityIdentifier("agent.pendingUserInput.\(request.id)")
    }

    @ViewBuilder
    private func legacyUserInputContent(_ request: AssistantUserInputRequest, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(request.prompt)
                .font(DS.Font.bodyDense.weight(.semibold))
                .foregroundColor(DS.Palette.text)
            if stale {
                Text("Restart the turn to continue.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.warning)
            } else if request.options.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    let draft = Binding(
                        get: { vm.userInputDrafts[vm.userInputStateKey(request)] ?? request.answer ?? "" },
                        set: { vm.userInputDrafts[vm.userInputStateKey(request)] = $0 }
                    )
                    Group {
                        if request.isSecret {
                            SecureField("Answer", text: draft)
                        } else {
                            TextField("Answer", text: draft)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button("Answer") {
                        vm.answerPendingUserInput(request, answer: vm.userInputDrafts[vm.userInputStateKey(request)] ?? request.answer ?? "")
                    }
                    .disabled((vm.userInputDrafts[vm.userInputStateKey(request)] ?? request.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if request.allowsMultipleSelection {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(spacing: DS.Space.sm) {
                        ForEach(request.options, id: \.self) { option in
                            let selected = vm.userInputSelections[vm.userInputStateKey(request)]?.contains(option) == true
                            Button {
                                vm.toggleUserInputOption(option, for: request)
                            } label: {
                                Label(option, systemImage: selected ? "checkmark.square.fill" : "square")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Submit") {
                        vm.answerPendingUserInput(request, answer: vm.selectedUserInputAnswer(for: request))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(vm.selectedUserInputAnswer(for: request).isEmpty)
                }
            } else {
                HStack(spacing: DS.Space.sm) {
                    ForEach(request.options, id: \.self) { option in
                        Button(option) { vm.answerPendingUserInput(request, answer: option) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // Structured Claude AskUserQuestion: render each question with its header,
    // prompt, selectable options (radio for single-select, checkbox for
    // multi-select) plus an "Other" freeform field, then submit all answers at once.
    @ViewBuilder
    private func askUserQuestionContent(_ request: AssistantUserInputRequest, stale: Bool) -> some View {
        if stale {
            Text("Restart the turn to continue.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.warning)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                ForEach(request.questions) { question in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        if let header = question.header, !header.isEmpty {
                            Text(header.uppercased())
                                .font(DS.Font.caption2.weight(.semibold))
                                .foregroundColor(DS.Palette.accent)
                                .padding(.horizontal, DS.Space.xs)
                                .padding(.vertical, 1)
                                .background(DS.Palette.accent.opacity(0.13))
                                .clipShape(Capsule())
                        }
                        Text(question.prompt)
                            .font(DS.Font.bodyDense.weight(.semibold))
                            .foregroundColor(DS.Palette.text)
                        // Index-keyed so duplicate option labels can't share SwiftUI identity.
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            askUserQuestionOptionButton(option, question: question, request: request)
                        }
                        AskUserQuestionOtherField(vm: vm, question: question, request: request)
                    }
                }
                Button("Submit") { vm.submitAskUserQuestion(request) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!vm.askUserQuestionIsComplete(request))
            }
        }
    }

    @ViewBuilder
    private func askUserQuestionOptionButton(_ option: AssistantUserInputOption, question: AssistantUserInputQuestion, request: AssistantUserInputRequest) -> some View {
        let selected = vm.askUserQuestionOptionIsSelected(option.label, question: question, request: request)
        let symbol: String = question.allowsMultipleSelection
            ? (selected ? "checkmark.square.fill" : "square")
            : (selected ? "largecircle.fill.circle" : "circle")
        Button {
            vm.selectAskUserQuestionOption(option.label, question: question, request: request)
        } label: {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundColor(selected ? DS.Palette.accent : DS.Palette.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(DS.Font.bodyDense)
                        .foregroundColor(DS.Palette.text)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Expose selection state so VoiceOver announces "<label>, selected" — matching
        // the Other radio and letting users hear which option in the group is chosen.
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("agent.askOption.\(request.id).\(question.id).\(option.label)")
    }

    private func scheduleTimelineScrollToBottom(_ proxy: ScrollViewProxy, force: Bool = false) {
        let scheduler = timelineScrollScheduler
        scheduler.forcePending = scheduler.forcePending || force
        guard !scheduler.scheduled else { return }
        scheduler.scheduled = true
        DispatchQueue.main.async {
            let shouldForce = scheduler.forcePending
            scheduler.forcePending = false
            scheduler.scheduled = false
            scrollTimelineToBottom(proxy, force: shouldForce)
        }
    }

    private func scrollTimelineToBottom(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard force || timelineSticksToBottom else { return }
        if force {
            timelineSticksToBottom = true
            showScrollDownButton = false
        }
        // PERF-MAC_AGENT-003: the onChange triggers all funnel here and fire per
        // streaming delta. Skip the per-token animation while running (it caused a
        // layout pass + animation churn on every delta); only animate on settle
        // (idle, or an explicit forced scroll). TimelineScrollFollower re-pins to the
        // exact post-layout bottom on its own; this is the discrete-event re-assert.
        if vm.status == .running && !force {
            proxy.scrollTo("BOTTOM", anchor: .bottom)
        } else {
            withAnimation(DS.Motion.micro) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
        }
    }

    // TimelineScrollFollower reports pin transitions from real AppKit geometry — these
    // only flip @State when actually crossing, so they never churn the body per frame.
    private func onTimelineReturnedToBottom() {
        guard !timelineSticksToBottom || showScrollDownButton else { return }
        timelineSticksToBottom = true
        showScrollDownButton = false
    }

    private func onTimelineScrolledAway() {
        guard timelineSticksToBottom || !showScrollDownButton else { return }
        timelineSticksToBottom = false
        showScrollDownButton = true
    }

    // UX-MAC_AGENT-CONTINUE: shown when the thread was interrupted by relaunch.
    // One tap resumes via recoverableResumeContext without requiring a retype.
    @ViewBuilder
    private var interruptedContinueRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Palette.warning)
                Text("This thread was interrupted by an app restart.")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            Button {
                Task { await vm.continueInterruptedThread() }
            } label: {
                Label("Continue", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("agent.continue.interrupted")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // "Loading…" + hairline, for the window between the user's bubble appearing
    // and the run existing. No elapsed timer (nothing has started yet) and no
    // Stop (there is no run to stop) — deliberately quieter than workingStatus,
    // so the swap to "Working for Xs" reads as progress rather than a reset.
    private var loadingStatus: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading")
                Text("Loading…")
                    .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
                    .accessibilityIdentifier("agent.loading.status")
            }
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // "Working for 2m 21s" + hairline, while a run is in flight.
    private var workingStatus: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            // PERF-MAC_AGENT-004: tick every second for the first minute, then
            // every 5 seconds, so a long run doesn't force 600 re-evaluations.
            TimelineView(ElapsedTickSchedule(start: vm.runStartedAt ?? Date())) { _ in
                HStack(spacing: DS.Space.sm) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Running")
                    Text("Working for \(elapsedString)")
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
                    // UX-MAC_AGENT-008: inline Stop where the user looks when a
                    // run is taking too long, plus the Esc hint.
                    let inlineState = AgentAppViewModel.stopButtonState(
                        runActive: vm.selectedThreadRunIsStartingOrRunning,
                        isStopping: vm.isStopping
                    )
                    Button(inlineState == .stopping ? "Stopping… (click to force)" : "Stop") { vm.stop() }
                        .buttonStyle(.plain)
                        .font(DS.Font.body.weight(.medium))
                        .foregroundColor(DS.Palette.danger)
                        .help(inlineState == .stopping
                              ? "Still stopping — click again to force-stop the provider"
                              : "Stop running agent (press Esc to interrupt)")
                        .accessibilityIdentifier("agent.working.stop")
                }
            }
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var elapsedString: String {
        let now = vm.currentTime()
        let s = max(0, Int(now.timeIntervalSince(vm.runStartedAt ?? now)))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func saveLatestProposedPlan() {
        guard let plan = vm.latestProposedPlan else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = plan.exportFileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = try? vm.saveLatestProposedPlan(to: url)
    }

    // IMP-MAC_AGENT-013: write a thread's markdown export via a save panel.
    private func exportThread(_ thread: AgentThread) {
        guard let export = vm.exportThreadMarkdown(thread.id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = export.fileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? export.contents.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    @ViewBuilder
    private func assistantProse(_ text: String) -> some View {
        // UX-MAC_AGENT-BG-AWAIT: the background-await self-declaration marker is an
        // internal signal the host detects on; it must never render in the transcript.
        AgentMessageMarkdownView(text: BackgroundAwaitContinuation.strippingAwaitingMarker(text))
            .foregroundColor(DS.Palette.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // UX-MAC_AGENT-018: one-click "Copy message" for agent replies, mirroring the
    // user-message copy affordance. Copies the displayed text (for a translated
    // reply that is the human-readable translation, i.e. exactly what's on screen).
    @ViewBuilder
    private func assistantCopyBar(text: String, identifierSuffix: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Button { copyToPasteboard(text) } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Copy message")
            .accessibilityIdentifier("agent.assistantMessage.copy.\(identifierSuffix)")
            .help("Copy message")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Pure seam: thread footer figure — full bare-user credible stack
    /// (measured tool-output + dialect + graphify + multi-turn cache impact + Auto).
    ///
    /// - `measuredDelivered`: permanent ledger total for the thread (floor).
    /// - Prefers real provider usage when present; else thread-local floor from
    ///   assistant text + measured pipes so dialect legs can run.
    /// - Cache amortization uses turn count and/or `cacheReadInputTokens`.
    /// - Auto routing contributes an orchestration token-equivalent.
    ///
    /// Invariant: result ≥ measuredDelivered when enabled (estimates never lower
    /// the thread figure).
    nonisolated static func tokenSaverThreadFooterDisplayTokens(
        measuredDelivered: Int,
        assistantChars: Int,
        tokenSaverEnabled: Bool,
        graphifyActive: Bool,
        graphifySignalCount: Int = 0,
        turnCount: Int = 0,
        cacheReadInputTokens: Int = 0,
        providerRawTokens: Int = 0,
        providerBilledTokenUnits: Double? = nil,
        autoRoutingActive: Bool = false
    ) -> Int {
        let measured = max(0, measuredDelivered)
        guard tokenSaverEnabled else { return measured }
        let assistantTokens = max(0, assistantChars) / Int(TokenSaverBareUserEstimator.charsPerToken)
        // Prefer live provider usage when the thread has it; otherwise a local floor
        // so dialect can still credit without inventing global day aggregates.
        let rawFloor = max(measured, assistantTokens, providerRawTokens, 1)
        let billedFloor: Double = {
            if let billed = providerBilledTokenUnits, billed > 0 { return billed }
            return Double(rawFloor)
        }()
        let breakdown = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: measured,
            tokenSaverEnabled: true,
            graphifyActive: graphifyActive,
            orchestrationActive: autoRoutingActive,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: rawFloor,
                windowProviderBilledTokenUnits: billedFloor,
                assistantChars: max(0, assistantChars),
                graphifySignalCount: graphifyActive ? max(0, graphifySignalCount) : 0,
                turnCount: max(0, turnCount),
                cacheReadInputTokens: max(0, cacheReadInputTokens)
            )
        )
        return max(measured, breakdown.totalCredible)
    }

    /// Pure seam: footer copy.
    ///
    /// - Requires `measuredTokens > 0` so estimates only **raise** a proven ledger
    ///   figure — never invent a chip from assistant text alone.
    /// - Product copy: full stack in plain language (tool output, shorter answers,
    ///   multi-turn cache). Optional Auto note for cheaper models.
    nonisolated static func tokenSaverThreadFooterText(
        displayTokens: Int,
        measuredTokens: Int,
        enabled: Bool,
        autoRoutingActive: Bool = false
    ) -> String? {
        guard enabled, measuredTokens > 0, displayTokens > 0 else { return nil }
        let amount = formatTokenCountForFooter(displayTokens)
        // Keep the chip scannable: one number + short list of what is inside it.
        let base = "Token Saver: \(amount) tokens saved (tool output, shorter answers, multi-turn cache)"
        if autoRoutingActive {
            return base + " · Auto picked cheaper models at the same quality"
        }
        return base
    }

    /// Backward-compatible alias used by older tests — measured-only copy path.
    nonisolated static func tokenSaverThreadFooterText(
        savedTokens: Int,
        enabled: Bool
    ) -> String? {
        tokenSaverThreadFooterText(
            displayTokens: savedTokens,
            measuredTokens: savedTokens,
            enabled: enabled,
            autoRoutingActive: false
        )
    }

    nonisolated static func formatTokenCountForFooter(_ value: Int) -> String {
        let n = max(0, value)
        if n >= 1_000_000 {
            let whole = Double(n) / 1_000_000.0
            if n % 1_000_000 == 0 { return String(format: "%.0fM", whole) }
            return String(format: whole >= 10 ? "%.0fM" : "%.1fM", whole)
        }
        if n >= 1_000 {
            let whole = Double(n) / 1_000.0
            // Exact thousands → "100K"; otherwise keep one decimal ("12.5K").
            if n % 1_000 == 0 {
                return String(format: "%.0fK", whole)
            }
            return String(format: "%.1fK", whole)
        }
        return "\(n)"
    }

    /// Soft success chip once under the newest finished answer (not every turn).
    @ViewBuilder
    private func tokenSaverThreadFooter() -> some View {
        // Auto routing is the product name for model-auto orchestration on a thread.
        let autoRouting = vm.routingMode == .auto
        if let text = Self.tokenSaverThreadFooterText(
            displayTokens: vm.tokenSaverThreadSavedTokens,
            measuredTokens: vm.tokenSaverThreadMeasuredTokens,
            enabled: vm.tokenSaverFooterEnabled,
            autoRoutingActive: autoRouting
        ) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Palette.success)
                    .accessibilityHidden(true)
                Text(text)
                    .font(DS.Font.caption2.weight(.medium))
                    .foregroundColor(DS.Palette.success)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, 5)
            .background(DS.Palette.success.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text)
            .accessibilityIdentifier("agent.tokenSaver.threadFooter")
            .help(
                autoRouting
                    ? "Measured tool/command-output savings from the local Token Saver ledger (not full provider usage), plus Auto routing to cheaper models"
                    : "Measured tool/command-output savings from the local Token Saver ledger only — not total provider or context tokens"
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func runningHiddenTranscriptRow(
        _ count: Int,
        revealedCount: Int,
        pageCount: Int,
        onReveal: @escaping () -> Void
    ) -> some View {
        let canRevealMore = revealedCount < count
        let nextCount = min(max(0, pageCount), max(0, count - revealedCount))
        return Button(action: { if canRevealMore { onReveal() } }) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: canRevealMore ? "ellipsis" : "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                Text(Self.hiddenTranscriptRevealLabel(
                    count: count,
                    revealedCount: revealedCount,
                    nextCount: nextCount
                ))
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, 6)
            .background(DS.Palette.surface.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canRevealMore)
        .accessibilityLabel(Self.hiddenTranscriptRevealAccessibilityLabel(
            count: count,
            revealedCount: revealedCount
        ))
        .accessibilityIdentifier("agent.runningHiddenTranscript")
    }

    nonisolated static func hiddenTranscriptRevealLabel(
        count: Int,
        revealedCount: Int,
        nextCount: Int
    ) -> String {
        if revealedCount <= 0 {
            return "Earlier in this thread · show \(nextCount) more"
        }
        if revealedCount < count {
            return "Earlier in this thread · \(revealedCount) of \(count) shown · show more"
        }
        return "Earlier in this thread · \(count) shown, read-only"
    }

    nonisolated static func hiddenTranscriptRevealAccessibilityLabel(
        count: Int,
        revealedCount: Int
    ) -> String {
        if revealedCount <= 0 {
            return "\(count) earlier items in this thread hidden"
        }
        if revealedCount < count {
            return "\(revealedCount) of \(count) earlier items in this thread visible"
        }
        return "\(count) earlier items in this thread visible, read-only"
    }

    private func hiddenLiveTurnItemsRow(_ count: Int) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
            Text("\(count) earlier live updates hidden while this run is active")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, 6)
        .background(DS.Palette.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityIdentifier("agent.hiddenLiveTurnItems")
    }

    // IMP-MAC_AGENT-007: tappable starter prompts on an empty thread reduce
    // blank-page friction and hint at what the agent can do. Copy is shared with iOS
    // via AgentEmptyConversationStarters for parity.
    private var emptyConversation: some View {
        VStack(spacing: DS.Space.lg) {
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(DS.Palette.textTertiary)
                .frame(width: 72, height: 72)
                .background(DS.Palette.surfaceRaised)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
            VStack(spacing: DS.Space.sm) {
                Text("No messages")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(1)
                Text("Start a new agent run, or pick a starter below.")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: DS.Space.sm) {
                ForEach(AgentEmptyConversationStarters.all) { starter in
                    Button {
                        vm.prompt = starter.prompt
                        vm.focusTick &+= 1
                    } label: {
                        HStack(spacing: DS.Space.sm) {
                            Image(systemName: starter.icon)
                                .font(.system(size: 12))
                                .foregroundColor(DS.Palette.accent)
                                .frame(width: 16)
                            Text(starter.title)
                                .font(DS.Font.body)
                                .foregroundColor(DS.Palette.text)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(DS.Palette.textTertiary)
                        }
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, DS.Space.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.Palette.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                    }
                    .buttonStyle(.plain)
                    .help("Insert this starter prompt into the composer")
                    .accessibilityIdentifier("agent.starter.\(starter.title)")
                }
            }
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .center)
    }

    @ViewBuilder
    private func errorRow(_ err: String) -> some View {
        let recoverable = vm.lastErrorRecoverable
        let recoveryAction = vm.displayedErrorRecoveryAction
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .center, spacing: DS.Space.sm) {
                Image(systemName: recoverable ? "exclamationmark.triangle" : "xmark.octagon")
                    .font(.system(size: 11))
                    .foregroundColor(recoverable ? DS.Palette.warning : DS.Palette.danger)
                    .frame(width: 14, height: 14, alignment: .center)
                Text(err)
                    .font(DS.Font.monoSmall)
                    .foregroundColor(recoverable ? DS.Palette.warning : DS.Palette.danger)
                    .lineSpacing(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { vm.dismissDisplayedError() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityLabel("Dismiss error")
                .accessibilityIdentifier("agent.error.dismiss")
                .help("Dismiss error")
            }
            if let recoveryAction {
                Button {
                    Task { await vm.performDisplayedErrorRecoveryAction() }
                } label: {
                    Label(
                        recoveryAction.title,
                        systemImage: recoveryAction == .signIn
                            ? "person.crop.circle.badge.checkmark"
                            : (recoveryAction == .startFresh ? "plus.message" : "arrow.clockwise")
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier(
                    recoveryAction == .retry
                        ? "agent.error.retry"
                        : "agent.error.recovery.\(recoveryAction.rawValue)"
                )
                .confirmationDialog(
                    "Retry without unavailable attachments?",
                    isPresented: Binding(
                        get: { vm.pendingAttachmentRetryConfirmation != nil },
                        set: { if !$0 { vm.cancelRetryWithoutUnavailableAttachments() } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Retry without unavailable attachments", role: .destructive) {
                        Task { await vm.confirmRetryWithoutUnavailableAttachments() }
                    }
                    Button("Cancel", role: .cancel) {
                        vm.cancelRetryWithoutUnavailableAttachments()
                    }
                } message: {
                    Text(vm.pendingAttachmentRetryConfirmation?.unavailableAttachmentNames.joined(separator: ", ") ?? "")
                }
            }
            if let recoveryStatus = vm.providerRecoveryStatusMessage {
                dismissibleStatusRow(
                    recoveryStatus,
                    identifier: "agent.error.recovery.status.dismiss",
                    color: recoveryStatus.hasPrefix("Could not") || recoveryStatus.hasPrefix("Sign-in unavailable")
                        ? DS.Palette.danger
                        : DS.Palette.textSecondary,
                    dismiss: { vm.dismissProviderRecoveryStatusMessage() }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // UX-MAC_AGENT-017: relative ("2m ago") + absolute (hover) timestamps.
    private static let relativeTimestampFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    private static let absoluteTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func relativeTimestamp(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return relativeTimestampFormatter.localizedString(for: date, relativeTo: now)
    }

    static func absoluteTimestamp(_ date: Date) -> String {
        absoluteTimestampFormatter.string(from: date)
    }

    // UX-MAC_AGENT-018: composer chips classify by extension for the icon/thumbnail.
    // nonisolated: immutable Sendable set; read from both MainActor (isImagePath)
    // and nonisolated (isImageAttachment) contexts.
    nonisolated private static let imageChipExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "webp", "svg", "avif"
    ]
    static func isImagePath(_ path: String) -> Bool {
        imageChipExtensions.contains((path as NSString).pathExtension.lowercased())
    }
    // P3: nonisolated static so tests need no MainActor wrapper.
    nonisolated static func isImageAttachment(_ path: String) -> Bool {
        imageChipExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    // Per-turn duration from items' earliest start to latest finish.
    static func turnDurationLabel(_ turn: AssistantTurnSnapshot) -> String? {
        guard let start = turn.items.map(\.startedAtMs).min() else { return nil }
        let finishes = turn.items.compactMap(\.finishedAtMs)
        guard finishes.count == turn.items.count, let end = finishes.max(), end >= start else { return nil }
        let seconds = Int((end - start) / 1000)
        guard seconds > 0 else { return nil }
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    static func completedWorkLabel(
        _ turn: AssistantTurnSnapshot,
        live: Bool = false,
        workBlockCount: Int = 0
    ) -> String {
        if live {
            if workBlockCount > 1 {
                return "Work so far · \(workBlockCount) steps in this turn"
            }
            return "Work so far"
        }
        if let duration = turnDurationLabel(turn) {
            return "Worked for \(duration)"
        }
        return "Worked"
    }

    /// Collapse reveal + open disclosures so a new follow-up paints like a
    /// fresh chat turn. Atomically resets both model and view state.
    private func collapseTranscriptForNewTurn() {
        vm.transcriptHistoryRevealCount = 0
        expandedCompletedWorkTurns = []
        expandedTools = []
        expandedToolGroups = []
        expandedReasoning = []
    }

    /// Shared chrome for user prompt bubbles (text + padding + fill). Sized by
    /// the caller so short prompts hug and long prompts wrap without clipping.
    @ViewBuilder
    private func userMessageBubbleLabel(_ displayText: String) -> some View {
        Text(displayText)
            .font(.system(size: 13))
            .foregroundColor(DS.Palette.text)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.lg)
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func messageRow(_ msg: AgentMessage, columnWidth: CGFloat = 10_000) -> some View {
        switch msg.role {
        case .user:
            let displayText = Self.userMessageDisplayText(msg.content)
            // Cap width against the live column so the bubble wraps instead of
            // painting past the timeline edge. Height is content-driven — never
            // a fixed frame and never a line-count truncate/"Show more" gate.
            let bubbleMax = Self.userMessageBubbleWidthCap(columnWidth: columnWidth)
            let textMax = max(0, bubbleMax - (DS.Space.xl * 2))
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: Self.userMessageBubbleLeadingGutter)
                VStack(alignment: .trailing, spacing: DS.Space.xs) {
                    // WHY: SwiftUI Text (not NSTextView) so short prompts hug content
                    // and long prompts wrap. No lineLimit / no fixed height — full
                    // prompt always visible and height grows with content.
                    //
                    // ViewThatFits: prefer horizontal hug for short prompts ("oi"),
                    // fall back to a width-capped wrap for long prompts / URLs.
                    // The old fixedSize(horizontal: true) + outer maxWidth clip
                    // cropped long unbroken URLs so only a mid-string slice showed.
                    ViewThatFits(in: .horizontal) {
                        userMessageBubbleLabel(displayText)
                            .fixedSize(horizontal: true, vertical: true)
                        userMessageBubbleLabel(displayText)
                            .frame(maxWidth: textMax, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: bubbleMax, alignment: .trailing)
                    .accessibilityIdentifier("agent.userMessageBubble")
                    // UX-MAC_AGENT-017: subtle relative timestamp so long threads
                    // show when each message was sent. Keep meta inside the bubble
                    // column so copy + relative time never spill past the pane.
                    HStack(spacing: DS.Space.xs) {
                        Button { copyToPasteboard(msg.content) } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11, weight: .regular))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityLabel("Copy message")
                        .accessibilityIdentifier("agent.userMessage.copy.\(msg.id.value.uuidString)")
                        .help("Copy message")
                        Text(Self.relativeTimestamp(msg.createdAt))
                            .font(DS.Font.caption2)
                            .foregroundColor(DS.Palette.textTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: true)
                            .help(Self.absoluteTimestamp(msg.createdAt))
                    }
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: bubbleMax, alignment: .trailing)
                }
                .frame(maxWidth: bubbleMax, alignment: .trailing)
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            if !hiddenPersistedAssistantMessageIDs.contains(msg.id) {
                if msg.content.isEmpty {
                    // P2: body was blanked by the 24 MB budget safety valve.
                    Text("(content omitted — message too large to display)")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Content omitted: message body was too large to display")
                } else {
                    let showBadge = Self.showsTranslatedBadge(
                        wasSR1Translated: vm.sr1TranslatedMessageIds.contains(msg.id)
                    )
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        if showBadge {
                            if let original = vm.sr1OriginalText(for: msg.id) {
                                DisclosureGroup {
                                    Text(original)
                                        .font(DS.Font.caption)
                                        .foregroundColor(DS.Palette.textSecondary)
                                        .textSelection(.enabled)
                                        .padding(DS.Space.sm)
                                        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                                } label: {
                                    Text(Self.sr1BadgeLabel(hasOriginalText: true))
                                        .font(DS.Font.caption2)
                                        .foregroundColor(DS.Palette.textTertiary)
                                }
                                .accessibilityLabel("This reply was translated from Token Saver compressed output. View original.")
                                .accessibilityIdentifier("agent.assistantMessage.sr1Original.\(msg.id.value.uuidString)")
                            } else {
                                Text(Self.sr1BadgeLabel(hasOriginalText: false))
                                    .font(DS.Font.caption2)
                                    .foregroundColor(DS.Palette.textTertiary)
                                    .accessibilityLabel("This reply was translated from Token Saver compressed output")
                                    .accessibilityIdentifier("agent.assistantMessage.sr1Badge.\(msg.id.value.uuidString)")
                            }
                        }
                        assistantProse(msg.content)
                        assistantCopyBar(text: BackgroundAwaitContinuation.strippingAwaitingMarker(msg.content), identifierSuffix: msg.id.value.uuidString)
                    }
                }
            }
        case .system:
            Text(msg.content)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
                .italic()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func turnView(_ turn: AssistantTurnSnapshot) -> some View {
        // F2: all the per-turn derivation (renderableItems, final-id split, block
        // grouping, plan filtering) is computed once here and memoized for finished
        // turns, instead of re-running on every body pass.
        let inputs = turnRenderInputs(for: turn)
        let blocks = inputs.visibleBlocks
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            // Finished turns and live turns both fold settled work into one
            // disclosure so follow-ups read as chat (answer + compact work), not
            // a re-expanded command dump of the whole turn.
            if inputs.completedWorkBlockCount > 0 {
                completedWorkDisclosure(
                    turn: turn,
                    blocks: inputs.completedWorkBlocks,
                    workBlockCount: inputs.completedWorkBlockCount,
                    live: !turn.finished
                )
            }
            if !turn.finished {
                if inputs.hiddenLiveItemCount > 0 {
                    hiddenLiveTurnItemsRow(inputs.hiddenLiveItemCount)
                }
                ForEach(blocks) { block in
                    switch block {
                    case .item(let item): itemRow(item)
                    case .toolGroup(let id, let items): toolGroupRow(id: id, items: items)
                    }
                }
            }
            // Full access: no plan review card — plans auto-implement without Approve.
            if !vm.suppressesProposedPlanReview {
                ForEach(inputs.turnPlans) { plan in
                    proposedPlanRow(plan)
                }
            }
            if turn.finished {
                ForEach(blocks) { block in
                    switch block {
                    case .item(let item): itemRow(item)
                    case .toolGroup(let id, let items): toolGroupRow(id: id, items: items)
                    }
                }
            }
            // Only show the turn's final text if no assistant-message item
            // already rendered it (prevents the answer showing twice).
            if let final = turn.finalAssistantMessage, inputs.shouldRenderFinal {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    assistantProse(final)
                    assistantCopyBar(text: BackgroundAwaitContinuation.strippingAwaitingMarker(final), identifierSuffix: turn.turnId)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func completedWorkDisclosure(
        turn: AssistantTurnSnapshot,
        blocks: [TurnRenderBlock],
        workBlockCount: Int,
        live: Bool = false
    ) -> some View {
        let expanded = expandedCompletedWorkTurns.contains(turn.turnId)
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if expanded {
                        expandedCompletedWorkTurns.remove(turn.turnId)
                    } else {
                        expandedCompletedWorkTurns.insert(turn.turnId)
                    }
                }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    if live {
                        Image(systemName: "circle.dotted")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                    Text(Self.completedWorkLabel(turn, live: live, workBlockCount: workBlockCount))
                        .font(DS.Font.body.weight(.medium))
                        .foregroundColor(DS.Palette.textTertiary)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide work details" : "Show work details")
            .accessibilityLabel(expanded ? "Hide work details" : "Show work details")
            .accessibilityIdentifier(live ? "agent.liveWork.\(turn.turnId)" : "agent.completedWork.\(turn.turnId)")

            if expanded {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    ForEach(blocks) { block in
                        switch block {
                        case .item(let item): itemRow(item)
                        case .toolGroup(let id, let items): toolGroupRow(id: id, items: items)
                        }
                    }
                }
                .padding(.leading, DS.Space.md)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    @ViewBuilder
    private func itemRow(_ item: AssistantItem) -> some View {
        switch item.type {
        case .assistantMessage:
            if Self.shouldRenderAssistantItemBody(item.body, persistedAssistantTexts: persistedAssistantTexts) {
                assistantProse(item.body)
            }
        case .reasoning:
            reasoningRow(item)
        case .plan:
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("PLAN").font(DS.Font.caption2.weight(.semibold)).tracking(0.6)
                    .foregroundColor(DS.Palette.accent)
                assistantProse(item.body)
            }
        case .imageView:
            imageViewRow(item)
        case .tool, .commandExecution, .fileChange, .mcpToolCall, .dynamicToolCall, .collabToolCall, .webSearch, .review, .contextCompaction, .error:
            toolRow(item)
        }
    }

    // UX-MAC_AGENT-010: long chain-of-thought no longer pushes the answer down.
    // It stays open while streaming, then collapses to a tappable "Thought" row.
    @ViewBuilder
    private func reasoningRow(_ item: AssistantItem) -> some View {
        let text = item.body.isEmpty ? (AgentTimelineItemPresentation.make(for: item).detail ?? "") : item.body
        let streaming = item.state == .streaming
        let expanded = streaming || expandedReasoning.contains(item.id)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button {
                guard !streaming, !text.isEmpty else { return }
                if expanded { expandedReasoning.remove(item.id) } else { expandedReasoning.insert(item.id) }
            } label: {
                HStack(spacing: DS.Space.xs) {
                    if !streaming, !text.isEmpty {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8)).foregroundColor(DS.Palette.textTertiary)
                    }
                    Text(streaming ? "Thinking…" : "Thought")
                        .font(DS.Font.caption2.weight(.semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(streaming ? "" : (text.isEmpty ? "" : (expanded ? "Hide reasoning" : "Show reasoning")))
            if expanded, !text.isEmpty {
                Text(text)
                    .font(DS.Font.bodyDense)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agent.reasoning.\(item.id)")
    }

    @ViewBuilder
    private func imageViewRow(_ item: AssistantItem) -> some View {
        let presentation = AgentTimelineItemPresentation.make(for: item)
        let imagePresentation = AgentImageViewPresentation.make(for: item)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: presentation.icon)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Palette.textSecondary)
                Text(presentation.label)
                    .font(DS.Font.mono)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let imagePresentation {
                    Button {
                        NSWorkspace.shared.open(imagePresentation.resourceURL)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Palette.textTertiary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open image")
                    .accessibilityIdentifier("agent.image.open.\(item.id)")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([imagePresentation.resourceURL])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Palette.textTertiary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                    .accessibilityIdentifier("agent.image.reveal.\(item.id)")
                }
            }
            if let imagePresentation {
                AgentTranscriptImageThumb(
                    url: imagePresentation.resourceURL,
                    displayName: imagePresentation.displayName,
                    style: .featured,
                    accessibilityID: "agent.image.preview.\(item.id)"
                )
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
    }

    @ViewBuilder
    private func toolRow(_ item: AssistantItem) -> some View {
        let presentation = AgentTimelineItemPresentation.make(for: item)
        let displayLabel = AgentTimelineItemPresentation.toolDisplayLabel(for: item)
        // Prefer uncapped raw shell for expand/copy so live body caps cannot mangle JSON.
        let commandFull = AgentTimelineItemPresentation.rawShellCommand(for: item)
            ?? AgentTimelineItemPresentation.toolCommandPreview(for: item)
        let commandSummary = AgentTimelineItemPresentation.toolCommandSummary(for: item)
        let isBackground = AgentTimelineItemPresentation.isBackgroundTool(for: item)
        let wasDistilled = AgentTimelineItemPresentation.toolCommandWasDistilled(for: item)
        // v1: finished rows only (≥1s). Live elapsed stays on the transcript "Working for" line.
        let duration = AgentTimelineItemPresentation.toolDurationLabel(for: item)
        let output = presentation.detail
        let hasOutput = (output?.isEmpty == false)
        let fullDiffersFromSummary = (commandFull != nil && commandFull != commandSummary)
        // Expand when there is output, a longer full command, or multi-line input.
        let canExpand = hasOutput
            || fullDiffersFromSummary
            || (commandFull.map { $0.count > 96 || $0.contains("\n") } ?? false)
        let expanded = expandedTools.contains(item.id)
        let statusColor: Color = {
            switch item.state {
            case .streaming: return DS.Palette.accent
            case .failed: return DS.Palette.danger
            case .cancelled: return DS.Palette.textTertiary
            case .completed: return DS.Palette.textSecondary
            }
        }()
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button {
                guard canExpand else { return }
                if expanded { expandedTools.remove(item.id) } else { expandedTools.insert(item.id) }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: presentation.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(statusColor)
                        .frame(width: 12)
                    (Text("\(presentation.verb) ")
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
                     + Text(displayLabel)
                        .font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text))
                    .lineLimit(1).truncationMode(.tail)
                    if isBackground {
                        Text("Background")
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(DS.Palette.accent.opacity(0.12))
                            .clipShape(Capsule())
                            .accessibilityLabel("Background")
                    }
                    if wasDistilled {
                        Text("Distilled")
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(DS.Palette.surface)
                            .clipShape(Capsule())
                            .accessibilityLabel("Distilled")
                    }
                    Spacer(minLength: 0)
                    if item.state == .streaming {
                        Text("Running")
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.accent)
                    } else if item.state == .failed {
                        Text("Failed")
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.danger)
                    } else if let duration {
                        Text(duration)
                            .font(DS.Font.caption2.monospacedDigit())
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                    if canExpand {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8)).foregroundColor(DS.Palette.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(canExpand ? (expanded ? "Hide details" : "Show command and output") : "No further detail")
            .accessibilityLabel(
                AgentTimelineItemPresentation.toolAccessibilityLabel(for: item)
            )

            // L2: collapsed command summary (not the full cd && … | distill pipeline).
            // UX-MAC_AGENT-OPEN-SPLIT: file/URL tools keep an open-in-split affordance.
            if let summary = commandSummary, !summary.isEmpty {
                HStack(alignment: .top, spacing: DS.Space.xs) {
                    Text(summary)
                        .font(DS.Font.monoSmall).foregroundColor(DS.Palette.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(expanded ? nil : 1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(commandFull ?? summary)
                    if let full = commandFull, !full.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(full, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Palette.textTertiary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .dsPointingHandCursor()
                        .help("Copy full command")
                        .accessibilityIdentifier("agent.tool.copyCommand.\(item.id)")
                        .accessibilityLabel("Copy full command")
                    }
                    if let target = AgentTimelineItemPresentation.toolOpenTarget(for: item) {
                        Button {
                            switch target {
                            case .file(let path): vm.openFileMention(path)
                            case .url(let url): vm.openLinkMention(url)
                            }
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Palette.textTertiary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .dsPointingHandCursor()
                        .help("Open in split panel")
                        .accessibilityIdentifier("agent.tool.openInSplit.\(item.id)")
                    }
                }
                .padding(.horizontal, DS.Space.sm).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            // Expanded: full command (when longer/different than the summary) + output.
            if expanded, let full = commandFull, fullDiffersFromSummary, !full.isEmpty {
                Text(full)
                    .font(DS.Font.monoSmall)
                    .foregroundColor(DS.Palette.textTertiary)
                    .textSelection(.enabled)
                    .padding(.horizontal, DS.Space.sm).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surface.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityIdentifier("agent.tool.fullCommand.\(item.id)")
            }

            // Output, collapsed by default and capped so a noisy command can't blow up
            // the transcript. Skill tool output stays complete (source-aware exception).
            // Full text stays selectable.
            if expanded, let o = output, !o.isEmpty {
                Text(AgentTimelineItemPresentation.cappedDetail(o, for: item))
                    .font(DS.Font.mono).foregroundColor(DS.Palette.textSecondary)
                    .textSelection(.enabled)
                    .padding(DS.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agent.tool.row.\(item.id)")
    }

    // A collapsed burst of consecutive tool calls: "Ran N commands" with a count chip,
    // expandable to the individual tool rows (each still independently expandable for
    // output). While any member streams, the header goes live ("Running N…") and a muted
    // subtitle shows the most-recent command so progress stays legible without expanding.
    @ViewBuilder
    private func toolGroupRow(id: String, items: [AssistantItem]) -> some View {
        let streaming = items.contains { $0.state == .streaming }
        let failed = items.contains { $0.state == .failed }
        let expanded = expandedToolGroups.contains(id)
        let imageOnly = !items.isEmpty && items.allSatisfy { $0.type == .imageView }
        let imagePresentations = AgentImageViewPresentation.presentations(in: items)
        let headerIcon = streaming
            ? "circle.dotted"
            : (failed ? "exclamationmark.triangle" : (imageOnly ? "photo" : "terminal"))
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if expanded { expandedToolGroups.remove(id) } else { expandedToolGroups.insert(id) }
                }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .frame(width: 10)
                    Image(systemName: headerIcon)
                        .font(.system(size: 11))
                        .foregroundColor(failed ? DS.Palette.danger : DS.Palette.textSecondary)
                    Text(Self.toolGroupSummary(items))
                        .font(DS.Font.body.weight(.medium))
                        .foregroundColor(DS.Palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !expanded {
                        Text("\(items.count)")
                            .font(DS.Font.caption2.weight(.semibold).monospacedDigit())
                            .foregroundColor(DS.Palette.textTertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(DS.Palette.surface)
                            .clipShape(Capsule())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse" : "Expand \(items.count) items")

            // UX: image citations show thumbnails in the transcript immediately —
            // no need to expand "Running 2 images…" to see what the agent viewed.
            if !imagePresentations.isEmpty {
                AgentTranscriptImageThumbStrip(
                    presentations: imagePresentations,
                    accessibilityPrefix: "agent.toolGroup.\(id).thumb"
                )
                .padding(.leading, 20)
            } else if streaming, !expanded, let latest = items.last {
                // Live peek at the current non-image command without forcing open.
                // Prefer the collapsed summary so cd/distill pipelines stay scannable.
                let preview = AgentTimelineItemPresentation.toolCommandSummary(for: latest)
                    ?? AgentTimelineItemPresentation.toolCommandPreview(for: latest)
                    ?? AgentTimelineItemPresentation.toolDisplayLabel(for: latest)
                if !preview.isEmpty {
                    Text(preview)
                        .font(DS.Font.monoSmall)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 20)
                }
            }

            if expanded {
                HStack(alignment: .top, spacing: DS.Space.sm) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(DS.Palette.line)
                        .frame(width: 1.5)
                        .padding(.leading, 4)
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        ForEach(items, id: \.id) { item in
                            // Image members keep the thumbnail card; other tools
                            // stay on the compact command row.
                            if item.type == .imageView {
                                imageViewRow(item)
                            } else {
                                toolRow(item)
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.toolGroup.\(id)")
    }

    // MARK: Composer

    @ViewBuilder
    private var queuedMessagesSection: some View {
        // Only render the queue block when there is actually something queued. A
        // lingering queueStatusMessage (e.g. the "will run" confirmation after the
        // message already drained) must not show an empty "Queued 0" header.
        if !vm.queuedMessages.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                // UX-MAC_AGENT-019: emphasize the Queued header (accent) so it's
                // clear new sends are queuing behind the active turn.
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Palette.accent)
                    Text("Queued")
                        .font(DS.Font.caption.weight(.semibold))
                        .foregroundColor(DS.Palette.accent)
                    Text("\(vm.queuedMessages.count)")
                        .font(DS.Font.caption.monospacedDigit())
                        .foregroundColor(DS.Palette.textTertiary)
                    Spacer(minLength: 0)
                }
                .accessibilityIdentifier("agent.queued.header")
                if let message = vm.queueStatusMessage {
                    HStack(spacing: DS.Space.sm) {
                        Text(message)
                            .font(DS.Font.caption)
                            .foregroundColor(message.contains("failed") ? DS.Palette.danger : DS.Palette.textSecondary)
                        Spacer(minLength: 0)
                        Button { vm.dismissQueueStatusMessage() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityLabel("Dismiss queue status")
                        .accessibilityIdentifier("agent.queue.status.inline.dismiss")
                        .help("Dismiss")
                    }
                }
                ForEach(vm.queuedMessages, id: \.id) { message in
                    queuedMessageRow(message)
                }
                .onMove { from, to in vm.reorderQueuedMessage(from: from, to: to) }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
            .background(DS.Palette.bg)
            .confirmationDialog(
                queuedMessagePendingCancel?.durableState == .prepared
                    ? "Remove message with unresolved provider acceptance?"
                    : "Cancel queued message?",
                isPresented: Binding(
                    get: { queuedMessagePendingCancel != nil },
                    set: { if !$0 { queuedMessagePendingCancel = nil } }
                )
            ) {
                Button(
                    queuedMessagePendingCancel?.durableState == .prepared
                        ? "Remove from queue"
                        : "Cancel queued message",
                    role: .destructive
                ) {
                    if let queuedMessagePendingCancel {
                        vm.removeQueuedMessage(queuedMessagePendingCancel)
                    }
                    queuedMessagePendingCancel = nil
                }
                Button("Keep message", role: .cancel) {
                    queuedMessagePendingCancel = nil
                }
            } message: {
                if queuedMessagePendingCancel?.durableState == .prepared {
                    Text(
                        "The provider may already have received this message. Removing it only abandons the queue record and cannot undo provider-side work."
                    )
                }
            }
        }
    }

    private func inlineStatusBanner(
        _ message: String,
        identifier: String,
        dismiss: @escaping () -> Void,
        offersCopy: Bool = true,
        retry: (() -> Void)? = nil
    ) -> some View {
        // Center the trailing controls with the message row so the dismiss "×"
        // sits on the same optical midline as "Copy"/Retry (`.top` left the
        // glyph high relative to caption text).
        HStack(alignment: .center, spacing: DS.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Palette.danger)
                .frame(width: 14, height: 14, alignment: .center)
            Text(message)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if offersCopy {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                .buttonStyle(.plain)
                .font(DS.Font.caption)
                .accessibilityIdentifier("\(identifier).copy")
            }
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.plain)
                    .font(DS.Font.caption)
                    .accessibilityIdentifier("\(identifier).retry")
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Dismiss error")
            .accessibilityIdentifier("\(identifier).dismiss")
            .help("Dismiss error")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.danger.opacity(0.09))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func inlineInfoBanner(
        _ message: String,
        identifier: String,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Palette.textSecondary)
                .frame(width: 14, height: 14, alignment: .center)
            Text(message)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Dismiss history notice")
            .accessibilityIdentifier("\(identifier).dismiss")
            .help("Dismiss history notice")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.surfaceRaised)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func dismissibleStatusRow(
        _ message: String,
        identifier: String,
        color: Color,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            Text(message)
                .font(DS.Font.caption)
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Dismiss error")
            .accessibilityIdentifier(identifier)
            .help("Dismiss error")
        }
    }

    private func queuedMessageRow(_ message: AgentQueuedMessage) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                Text("#\(message.position)")
                    .font(DS.Font.caption.monospacedDigit().weight(.semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(width: 28, alignment: .leading)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    if vm.editingQueuedMessage?.id == message.id {
                        TextEditor(text: $vm.queuedMessageDraft)
                            .font(DS.Font.body)
                            .frame(minHeight: 64, maxHeight: 120)
                            .scrollContentBackground(.hidden)
                            .background(DS.Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .accessibilityLabel("Edit queued message \(message.position)")
                            .accessibilityIdentifier("agent.queued.editor.\(message.id.value.uuidString)")
                    } else {
                        Text(message.text.isEmpty ? attachmentSummary(message) : message.text)
                            .font(DS.Font.body)
                            .foregroundColor(DS.Palette.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !message.attachments.isEmpty {
                        Label("\(message.attachments.count) attachment\(message.attachments.count == 1 ? "" : "s")", systemImage: "paperclip")
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                    if let durableStatus = vm.queuedMessageDurableStatus(message) {
                        Text(durableStatus)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(
                                "agent.queued.state.\(message.id.value.uuidString)"
                            )
                    }
                }
                Spacer(minLength: DS.Space.sm)
                if vm.editingQueuedMessage?.id == message.id {
                    Button("Save") { vm.saveQueuedMessageEdit() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Cancel") {
                        vm.editingQueuedMessage = nil
                        vm.queuedMessageDraft = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        Task { await vm.forceQueuedMessageNow(message) }
                    } label: {
                        Text(vm.queuedMessageForceLabel(message))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!vm.canForceQueuedMessage(message))
                    .accessibilityLabel(vm.queuedMessagePrimaryActionAccessibilityLabel(message))
                    .accessibilityIdentifier("agent.queued.force.\(message.id.value.uuidString)")
                    Button {
                        vm.editQueuedMessage(message)
                    } label: {
                        Image(systemName: "pencil")
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled((message.durableState ?? .queued) != .queued)
                        .accessibilityLabel("Edit queued message \(message.position)")
                        .accessibilityIdentifier("agent.queued.edit.\(message.id.value.uuidString)")
                    Button {
                        if message.durableState == .prepared {
                            queuedMessagePendingCancel = message
                        } else if message.attachments.isEmpty && message.text.count < 120 {
                            vm.removeQueuedMessage(message)
                        } else {
                            queuedMessagePendingCancel = message
                        }
                    } label: {
                        if message.durableState == .prepared {
                            Text("Remove")
                                .foregroundColor(DS.Palette.danger)
                        } else {
                            Image(systemName: "trash")
                                .foregroundColor(DS.Palette.danger)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(message.durableState == .dispatched)
                    .tint(DS.Palette.danger)
                    .foregroundColor(DS.Palette.danger)
                    .accessibilityLabel(
                        message.durableState == .prepared
                            ? "Remove queued message \(message.position) with unresolved provider acceptance"
                            : "Cancel queued message \(message.position)"
                    )
                    .accessibilityIdentifier("agent.queued.cancel.\(message.id.value.uuidString)")
                }
            }
        }
        .padding(DS.Space.md)
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
        .accessibilityIdentifier("agent.queued.row.\(message.id.value.uuidString)")
    }

    private func attachmentSummary(_ message: AgentQueuedMessage) -> String {
        message.attachments.map(\.displayName).joined(separator: ", ")
    }

    // Unified Codex-style composer card: changed-files strip → editor →
    // toolbar (attach · permission · model·effort · send/stop).
    private var composer: some View {
        VStack(spacing: 0) {
            if let s = vm.gitSummary, !s.files.isEmpty { changedFilesStrip(s) }
            if !vm.attachments.isEmpty {
                attachmentChips
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.top, DS.Space.md)
            }
            PromptComposerEditor(
                text: Binding(get: { vm.prompt }, set: { vm.prompt = $0 }),
                height: $composerEditorHeight,
                focusTick: vm.focusTick,
                placeholder: vm.composerPlaceholder,
                onSend: { Task { await vm.send() } },
                onPreviousHistory: { vm.recallPreviousPrompt() },
                onNextHistory: { vm.recallNextPrompt() },
                onTextEdited: {
                    vm.promptWasEdited()
                    // macos:32: a real keystroke that changes the token re-opens a
                    // popup the user had dismissed for the previous token.
                    suggestionPopupDismissed = false
                },
                onFileDrop: { paths in vm.insertDroppedFilePaths(paths) },
                onCursorMoved: { offset in vm.composerCursorOffset = offset },
                onCaretRectChanged: { _ in },
                popupIsOpen: {
                    ComposerSuggestionNavigation.isOpen(
                        count: vm.composerSuggestions.count,
                        dismissed: suggestionPopupDismissed
                    )
                },
                onPopupNavUp: {
                    suggestionSelectedIndex = ComposerSuggestionNavigation.moveUp(
                        selected: suggestionSelectedIndex,
                        count: vm.composerSuggestions.count
                    )
                },
                onPopupNavDown: {
                    suggestionSelectedIndex = ComposerSuggestionNavigation.moveDown(
                        selected: suggestionSelectedIndex,
                        count: vm.composerSuggestions.count
                    )
                },
                onPopupApply: { applyHighlightedSuggestion() },
                onPopupDismiss: { suggestionPopupDismissed = true }
            )
            .frame(height: composerEditorHeight)
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.sm)
            .padding(.bottom, DS.Space.xs)
            .accessibilityIdentifier("agent.composer.input")
            // macos:32: reset selection + un-dismiss whenever the suggestion set
            // changes identity/count (new token, or token edited into a new list).
            .onChange(of: vm.composerSuggestions.map(\.id)) { _ in
                suggestionSelectedIndex = ComposerSuggestionNavigation.reset()
            }
            // WHY: inline panel between editor and toolbar. A caret-overlay on the
            // editor painted *under* the toolbar sibling and mixed with pills when
            // the popup opened downward. Owning layout space avoids z-order fights.
            suggestionPopup
            composerToolbar
        }
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
        .padding(DS.Space.lg)
        .background(DS.Palette.bg)
    }

    private func changedFilesStrip(_ s: GitSummary) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                Text("\(s.files.count) file\(s.files.count == 1 ? "" : "s") changed")
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                    // IMP-MAC_AGENT-008: per-file +/- breakdown on hover, so users
                    // can preview the changed-files detail without leaving the
                    // composer to open the Git panel.
                    .help(changedFilesBreakdown(s))
                Text("+\(s.totalAdditions)")
                    .font(DS.Font.caption.monospacedDigit()).foregroundColor(DS.Palette.success)
                Text("−\(s.totalDeletions)")
                    .font(DS.Font.caption.monospacedDigit()).foregroundColor(DS.Palette.danger)
                Spacer(minLength: 0)
                Button { vm.onReviewRequested?() } label: {
                    Text("Review here")
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Review changes in the Git panel")
                .help("Review changes in the Git panel")
            }
            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
        }
    }

    // IMP-MAC_AGENT-008: a per-file "path  +A −B" listing for the changed-files
    // hover tooltip; caps the list so a large change set stays readable.
    private func changedFilesBreakdown(_ s: GitSummary) -> String {
        let maxRows = 20
        var rows = s.files.prefix(maxRows).map { "\($0.path)  +\($0.additions) −\($0.deletions)" }
        if s.files.count > maxRows {
            rows.append("… \(s.files.count - maxRows) more")
        }
        return rows.joined(separator: "\n")
    }

    private var composerToolbar: some View {
        compactComposerToolbar
            .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
    }

    private var compactComposerToolbar: some View {
        HStack(spacing: DS.Space.sm) {
            if AgentComposerChromePresentation.shows(.attach, mode: composerChromeMode) {
                attachmentButton
            }
            // Power-only: run-as, source, permission, execution.
            if AgentComposerChromePresentation.shows(.runAsUser, mode: composerChromeMode) {
                // macOS user that will execute the agent (sudo -u). Distinct from
                // provider-instance Source (CODEX_HOME / personal-vs-work CLI config).
                runAsUserMenu
            }
            if AgentComposerChromePresentation.shows(.source, mode: composerChromeMode) {
                // Provider instance / CLI identity (not OS user).
                sourceMenu
            }
            if AgentComposerChromePresentation.shows(.model, mode: composerChromeMode) {
                modelMenu
            }
            if AgentComposerChromePresentation.shows(.permission, mode: composerChromeMode) {
                permissionMenu
            }
            if AgentComposerChromePresentation.shows(.execution, mode: composerChromeMode) {
                executionMenu
            }
            composerChromeModeToggle
            Spacer(minLength: DS.Space.xs)
            if vm.selectedThreadRunIsStartingOrRunning {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityLabel("Running")
                stopButton
                // UX-MAC_AGENT-007: separate the red Stop circle from the accent
                // Queue circle so the two adjacent buttons don't read as one
                // ambiguous control.
                Rectangle()
                    .fill(DS.Palette.line)
                    .frame(width: DS.Border.hairline, height: 18)
                    .padding(.horizontal, DS.Space.xxs)
            }
            if AgentComposerChromePresentation.shows(.sendStop, mode: composerChromeMode) {
                sendStopButton
            }
        }
    }

    private var composerChromeModeToggle: some View {
        Button {
            let current = composerChromeMode
            composerChromeModeRaw = (current == .simple ? AgentComposerChromeMode.power : .simple).rawValue
        } label: {
            Image(systemName: composerChromeMode == .simple ? "chevron.up.circle" : "chevron.down.circle")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundColor(DS.Palette.textSecondary)
        .help(composerChromeMode == .simple
              ? AgentComposerChromePresentation.toggleAccessibilityLabelSimple
              : AgentComposerChromePresentation.toggleAccessibilityLabelPower)
        .accessibilityLabel(composerChromeMode == .simple
            ? AgentComposerChromePresentation.toggleAccessibilityLabelSimple
            : AgentComposerChromePresentation.toggleAccessibilityLabelPower)
        .accessibilityIdentifier("agent.composer.chromeMode")
        .accessibilityValue(composerChromeMode.rawValue)
    }

    // MARK: System status strip + working phase strip

    @ViewBuilder
    private var systemStatusStrip: some View {
        let queueStandalone = Self.standaloneQueueStatusMessage(
            vm.queueStatusMessage,
            queuedCount: vm.queuedMessages.count
        )
        let candidates = AgentSystemStripPresentation.items(
            historyReplayNotice: vm.historyReplayNotice,
            statusMessage: Self.visibleStatusMessage(vm.statusMessage),
            providerSnapshotStatus: vm.providerThreadSnapshotStatusMessage,
            standaloneQueueStatus: queueStandalone
        )
        let collapsed = AgentSystemStripPresentation.collapse(candidates)
        if !collapsed.visible.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(collapsed.visible) { item in
                    systemStripRow(item)
                }
                if collapsed.overflowCount > 0 {
                    Text("+\(collapsed.overflowCount) more status")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .padding(.horizontal, DS.Space.lg)
                        .accessibilityIdentifier("agent.systemStrip.overflow")
                }
            }
            .accessibilityIdentifier("agent.systemStrip")
        }
    }

    private func systemStripRow(_ item: AgentSystemStripItem) -> some View {
        let tone: Color = {
            switch item.severity {
            case .error: return DS.Palette.danger
            case .warning: return DS.Palette.warning
            case .info: return DS.Palette.textSecondary
            }
        }()
        let icon: String = {
            switch item.severity {
            case .error: return "exclamationmark.triangle.fill"
            case .warning: return "exclamationmark.circle.fill"
            case .info: return "info.circle"
            }
        }()
        return HStack(alignment: .center, spacing: DS.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tone)
                .frame(width: 14, height: 14, alignment: .center)
            Text(item.message)
                .font(DS.Font.caption)
                .foregroundColor(item.severity == .info ? DS.Palette.textSecondary : DS.Palette.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.offersCopy {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.message, forType: .string)
                }
                .buttonStyle(.plain)
                .font(DS.Font.caption)
                .accessibilityIdentifier("\(item.id).copy")
            }
            if item.offersRetry {
                Button("Retry") {
                    switch item.id {
                    case "agent.provider.snapshot.stale":
                        vm.retryProviderThreadSnapshotRead()
                    case "agent.queue.status":
                        Task { await vm.send() }
                    default:
                        break
                    }
                }
                .buttonStyle(.plain)
                .font(DS.Font.caption)
                .accessibilityIdentifier("\(item.id).retry")
            }
            if item.offersDismiss {
                Button {
                    switch item.id {
                    case "agent.history.replay.notice":
                        vm.dismissHistoryReplayNotice()
                    case "agent.status.message":
                        vm.dismissStatusMessage()
                    case "agent.provider.snapshot.stale":
                        vm.dismissProviderThreadSnapshotStatusMessage()
                    case "agent.queue.status":
                        vm.dismissQueueStatusMessage()
                    default:
                        break
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("\(item.id).dismiss")
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background(item.severity == .error
            ? DS.Palette.danger.opacity(0.09)
            : DS.Palette.surfaceRaised)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(item.id)
    }

    @ViewBuilder
    private var workingPhaseStrip: some View {
        let runLive = vm.selectedThreadRunIsStartingOrRunning
        let activeSubagents = vm.subagentActivity.activeCount
        let phase = AgentWorkingStripPresentation.phase(
            runIsLive: runLive,
            isAwaitingBackground: vm.isAwaitingBackgroundWork,
            backgroundShellCount: vm.backgroundShellCount,
            activeSubagentCount: activeSubagents,
            hasStreamingTools: vm.timeline.turns.contains { turn in
                !turn.finished && turn.items.contains {
                    $0.state == .streaming && AgentAppView.isGroupableTool($0.type)
                }
            }
        )
        let elapsed: Int? = {
            guard runLive || vm.isAwaitingBackgroundWork else { return nil }
            guard let start = vm.runStartedAt else { return nil }
            return max(0, Int(vm.currentTime().timeIntervalSince(start)))
        }()
        if let label = AgentWorkingStripPresentation.label(phase: phase, elapsedSeconds: elapsed) {
            let tone: DSPill.Tone = {
                switch phase {
                case .awaitingBackground: return .warning
                case .subagents, .tools, .thinking: return .accent
                case .idle: return .neutral
                }
            }()
            DSPill(label, tone: tone)
                .help(phase.accessibilityLabel)
                .accessibilityIdentifier("agent.workingPhase")
                .accessibilityLabel(phase.accessibilityLabel)
        } else {
            DSPill(vm.status.rawValue, tone: statusTone(vm.status))
                .accessibilityIdentifier("agent.status.pill")
        }
    }

    private var attachmentButton: some View {
        Button(action: pickAttachments) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .disabled(!vm.selectedProviderCanRun || (vm.selectedProviderSnapshot.map {
            !$0.effectiveCapabilities.supportsAttachments
        } ?? false))
        .foregroundColor(DS.Palette.textSecondary)
        .help("Attach files").accessibilityLabel("Attach files")
        .accessibilityIdentifier("agent.attach")
    }

    // macos:32: applies the currently highlighted suggestion (or the first when
    // nothing is highlighted yet, e.g. user pressed Return right after typing the
    // token without arrowing). Reads vm state live, then resets popup state.
    private func applyHighlightedSuggestion() {
        let suggestions = vm.composerSuggestions
        guard !suggestions.isEmpty else { return }
        let index = suggestionSelectedIndex ?? 0
        guard suggestions.indices.contains(index) else { return }
        vm.applyComposerSuggestion(suggestions[index])
        suggestionSelectedIndex = ComposerSuggestionNavigation.reset()
        suggestionPopupDismissed = true
    }

    // macos:32: keyboard-navigable suggestion panel. Sits between the editor and
    // the composer toolbar so slash/skill rows never paint under attach/model/
    // permission pills (caret-overlay + place-below collided with that toolbar).
    @ViewBuilder
    private var suggestionPopup: some View {
        let suggestions = vm.composerSuggestions
        if ComposerSuggestionNavigation.isOpen(count: suggestions.count, dismissed: suggestionPopupDismissed) {
            let layout = ComposerSuggestionPlacement.layout(suggestionCount: suggestions.count)
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: suggestions.count > layout.maxVisibleRows) {
                    VStack(spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            suggestionRow(suggestion, highlighted: index == suggestionSelectedIndex)
                                .frame(height: layout.rowHeight)
                        }
                    }
                }
                .frame(height: layout.height)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
            .padding(.horizontal, DS.Space.lg)
            .padding(.bottom, DS.Space.xs)
            .accessibilityIdentifier("agent.suggestion.popup")
            .allowsHitTesting(true)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func suggestionRow(_ suggestion: AgentComposerSuggestion, highlighted: Bool) -> some View {
        Button { vm.applyComposerSuggestion(suggestion); suggestionPopupDismissed = true } label: {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: suggestion.kind == .skill ? "puzzlepiece.extension" : "command")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(highlighted ? DS.Palette.accent : DS.Palette.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(suggestion.title)
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                    Text(suggestion.subtitle)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? DS.Palette.accent.opacity(0.14) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(suggestion.subtitle)
        .accessibilityIdentifier("agent.suggestion.\(suggestion.insertText.trimmingCharacters(in: .whitespaces))")
    }

    private var permissionMenu: some View {
        Menu {
            Button("Supervised") { vm.setPermissionMode(.supervised) }
                .disabled(!vm.supportedPermissionModesForSelectedProvider.contains(.supervised))
                .help(vm.permissionModeUnavailableReason(.supervised) ?? "Ask before tool actions")
            Button("Auto-edit") { vm.setPermissionMode(.autoAcceptEdits) }
                .disabled(!vm.supportedPermissionModesForSelectedProvider.contains(.autoAcceptEdits))
                .help(vm.permissionModeUnavailableReason(.autoAcceptEdits) ?? "Apply edits without asking")
            Button("Full access") { vm.setPermissionMode(.fullAccess) }
                .disabled(!vm.supportedPermissionModesForSelectedProvider.contains(.fullAccess))
                .help(vm.permissionModeUnavailableReason(.fullAccess) ?? "Run tools without asking")
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: vm.permissionMode == .fullAccess ? "exclamationmark.shield.fill" : "lock.shield")
                    .font(.system(size: 10))
                Text(permissionLabel).font(DS.Font.caption.weight(.medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .fixedSize()
            .foregroundColor(permissionTone)
            .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
            .background(permissionTone.opacity(0.13))
            .clipShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(vm.activeRunConfigurationLocked || !vm.selectedProviderCanRun)
        .help(vm.providerExecutionUnavailableReason
            ?? (vm.activeRunConfigurationLocked ? "Permission is fixed for the active run" : "Permission mode"))
        .accessibilityIdentifier("agent.permission.menu")
    }

    private var executionMenu: some View {
        Menu {
            TextField("PR URL", text: $vm.pullRequestURL)
                .textFieldStyle(.roundedBorder)
            Button(vm.pullRequestPreparing ? "Opening..." : "Open PR as thread") {
                Task { await vm.preparePullRequestThread() }
            }
            .disabled(vm.pullRequestPreparing || vm.pullRequestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.executionLocked)
            if let message = vm.pullRequestStatusMessage {
                Divider()
                dismissibleStatusRow(
                    message,
                    identifier: "agent.pr.status.dismiss",
                    color: message.hasPrefix("PR preparation failed") ? DS.Palette.danger : DS.Palette.textSecondary,
                    dismiss: { vm.dismissPullRequestStatusMessage() }
                )
            }
            Divider()
            Picker("Execution", selection: $vm.executionMode) {
                Text("Local").tag(AgentExecutionMode.local)
                Text("Worktree").tag(AgentExecutionMode.worktree)
            }
            .onChange(of: vm.executionMode) { mode in vm.setExecutionMode(mode) }
            if vm.executionMode == .worktree {
                TextField("Base branch", text: Binding(
                    get: { vm.baseBranch },
                    set: { vm.setBaseBranch($0) }
                ))
                .textFieldStyle(.roundedBorder)
                if let path = vm.worktreePath, !path.isEmpty {
                    Divider()
                    Text(path)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                }
            }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: vm.executionMode == .worktree ? "arrow.triangle.branch" : "folder")
                    .font(.system(size: 10))
                Text(vm.executionMode == .worktree ? "Worktree" : "Local")
                    .font(DS.Font.caption.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .fixedSize()
            .foregroundColor(DS.Palette.textSecondary)
            .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
            .background(DS.Palette.surfaceRaised)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(vm.executionLocked || !vm.selectedProviderCanRun)
        .help(vm.providerExecutionUnavailableReason
            ?? (vm.executionLocked ? "Execution mode locks after the first message" : "Execution mode"))
        .accessibilityIdentifier("agent.execution.menu")
    }

    /// macOS user capsule (sudo -u). Left of provider source + model.
    private var runAsUserMenu: some View {
        let users = vm.availableRunAsUsers.isEmpty ? MacOSLocalUserCatalog.listEligibleUsers() : vm.availableRunAsUsers
        let selected = vm.runAsUser ?? AgentRunAsUser.current()
        let interactive = users.count > 1
            && !vm.providerLocked
            && !vm.selectedThreadRunIsStartingOrRunning
        let label = selected.shortName
        return Group {
            if interactive {
                Menu {
                    ForEach(users, id: \.id) { user in
                        Button {
                            vm.setRunAsUser(user)
                        } label: {
                            HStack {
                                if user.uid == selected.uid {
                                    Image(systemName: "checkmark")
                                }
                                Text(user.shortName)
                                if let full = user.fullName, full != user.shortName {
                                    Text("· \(full)")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } label: {
                    runAsUserCapsuleLabel(label: label, showChevron: true, locked: false)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                runAsUserCapsuleLabel(
                    label: label,
                    showChevron: false,
                    locked: vm.providerLocked
                )
            }
        }
        .disabled(vm.selectedThreadRunIsStartingOrRunning)
        .help(runAsUserHelpText(interactive: interactive, selected: selected))
        .accessibilityLabel("Run as macOS user \(label)")
        .accessibilityIdentifier("agent.runAsUser.menu")
        .onAppear { vm.refreshAvailableRunAsUsers() }
    }

    private func runAsUserHelpText(interactive: Bool, selected: AgentRunAsUser) -> String {
        if vm.selectedThreadRunIsStartingOrRunning {
            return "macOS user is fixed while a run is active"
        }
        if vm.providerLocked {
            return "macOS user is fixed after the first message. Start a new thread to run as a different user."
        }
        if !interactive {
            return "Provider processes run as macOS user \(selected.shortName)"
        }
        return "Choose which macOS user executes Codex/Claude/Grok (like sudo -u)"
    }

    private func runAsUserCapsuleLabel(label: String, showChevron: Bool, locked: Bool) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: locked ? "lock.fill" : "person.fill")
                .font(.system(size: 10))
            Text(label)
                .font(DS.Font.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
        }
        .fixedSize()
        .foregroundColor(DS.Palette.textSecondary)
        .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
        .background(DS.Palette.surfaceRaised)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
    }

    /// Dedicated provider-instance source capsule (CODEX_HOME isolation).
    /// Reuses provider snapshots + `setProviderInstance` so personal/work
    /// CLI configs stay the single selection authority (not a second state).
    ///
    /// Always openable (Button + popover), matching the model pill. A SwiftUI
    /// `Menu` that collapses to a static label when locked made "click does
    /// nothing" the common report after the first message — fail loud instead.
    private var sourceMenu: some View {
        let canSwitch = sourceCanSwitch
        let label = sourceCapsuleLabel
        let helpText = sourceCapsuleHelpText(canSwitch: canSwitch)
        return Button {
            showSourceOptions.toggle()
        } label: {
            sourceCapsuleLabelView(
                label: label,
                showChevron: true,
                locked: vm.providerLocked || vm.selectedThreadRunIsStartingOrRunning
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("Account \(label)")
        .accessibilityHint(canSwitch
            ? "Choose which ChatGPT, Claude, or Grok account runs this thread"
            : helpText)
        .accessibilityIdentifier("agent.source.menu")
        .popover(isPresented: $showSourceOptions, arrowEdge: .bottom) {
            sourceOptionsPopover
        }
    }

    private var sourceCanSwitch: Bool {
        AgentSourceCapsulePresentation.isInteractive(
            enabledSourceCount: sourceMenuEntries.count,
            providerLocked: vm.providerLocked,
            // Only an in-flight run blocks switching. An unauthenticated /
            // unavailable *current* provider must not trap the user — they need
            // the menu open to pick a working account.
            runLocked: vm.selectedThreadRunIsStartingOrRunning
        )
    }

    private var sourceOptionsPopover: some View {
        let canSwitch = sourceCanSwitch
        let entries = sourceMenuEntries
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            if vm.selectedThreadRunIsStartingOrRunning {
                Text("Account is fixed while a run is active")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .fixedSize(horizontal: true, vertical: false)
            } else if vm.providerLocked {
                Text("Account is fixed after the first message. Start a new thread to use a different account.")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: compactModelMenuWidth, alignment: .leading)
            } else if let reason = vm.providerExecutionUnavailableReason {
                Text(reason)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: compactModelMenuWidth, alignment: .leading)
            } else if entries.count <= 1 {
                Text("Only one account is available")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }

            compactMenuSection("Account")
            if entries.isEmpty {
                Text("No accounts loaded")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            } else {
                ForEach(entries, id: \.id) { entry in
                    compactMenuRow(entry.title, selected: entry.isSelected) {
                        selectSourceMenuEntry(entry)
                        showSourceOptions = false
                    }
                    .disabled(!canSwitch)
                }
            }
        }
        .padding(DS.Space.sm)
        .background(DS.Palette.surfaceOverlay)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("agent.source.popover")
    }

    private var sourceCapsuleLabel: String {
        AgentSourceCapsulePresentation.capsuleLabel(
            selected: vm.selectedProviderSnapshot,
            fallbackProvider: vm.provider,
            fallbackInstanceId: vm.providerInstanceId,
            snapshots: vm.providerSnapshots
        )
    }

    private var sourceMenuEntries: [AgentSourceCapsulePresentation.MenuEntry] {
        AgentSourceCapsulePresentation.menuEntries(
            snapshots: vm.providerSnapshots,
            selectedSnapshotId: vm.selectedProviderSnapshot?.id,
            selectedProvider: vm.provider,
            providerDisplayName: { vm.providerDisplayName($0) }
        )
    }

    private func selectSourceMenuEntry(_ entry: AgentSourceCapsulePresentation.MenuEntry) {
        guard sourceCanSwitch else { return }
        if vm.providerSnapshots.contains(where: { $0.id == entry.id }) {
            vm.setProviderInstance(entry.id)
            return
        }
        if let provider = AgentProvider(rawValue: entry.id) {
            vm.setProvider(provider)
            Task {
                await vm.loadModels()
                await MainActor.run { vm.persistThreadConfig() }
            }
        }
    }

    private func sourceCapsuleHelpText(canSwitch: Bool) -> String {
        if vm.selectedThreadRunIsStartingOrRunning {
            return "Account is fixed while a run is active"
        }
        if vm.providerLocked {
            return "Account is fixed after the first message. Start a new thread to use a different account."
        }
        if let reason = vm.providerExecutionUnavailableReason {
            return reason
        }
        if !canSwitch {
            return "Account / source for this agent run"
        }
        return "Choose which ChatGPT / Claude / Grok account runs this thread"
    }

    private func sourceCapsuleLabelView(label: String, showChevron: Bool, locked: Bool) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: locked ? "lock.fill" : "person.crop.circle")
                .font(.system(size: 10))
            Text(label)
                .font(DS.Font.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
        }
        .fixedSize()
        .foregroundColor(DS.Palette.textSecondary)
        .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
        .background(DS.Palette.surfaceRaised)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
    }

    private var modelMenu: some View {
        Button {
            showModelOptions.toggle()
        } label: {
            modelMenuLabel
        }
        .buttonStyle(.plain)
        // P3: expose a meaningful VoiceOver label instead of the raw concatenated
        // pill text (e.g. "gpt-5.5 · medium · ..." becomes "Model gpt-5.5, effort medium").
        .accessibilityLabel(modelMenuAccessibilityLabel)
        .accessibilityIdentifier("agent.model.menu")
        // UX-MAC_AGENT-016: keep the menu openable while running so the user can
        // read the current model/effort/tier; the mutating rows inside disable
        // themselves (see modelOptionsPopover) so nothing changes mid-run.
        .popover(isPresented: $showModelOptions, arrowEdge: .bottom) {
            modelOptionsPopover
        }
        .onChange(of: showModelOptions) { isShowing in
            if !isShowing {
                showAllModelOptions = false
                showCustomModelField = false
                customModelDraft = ""
            }
        }
        // Source/account selection lives on the dedicated left capsule so the
        // model popover stays model/effort/tier only.
        .help("Model · reasoning effort · service tier")
    }

    private var modelOptionsPopover: some View {
        // P2: "Retry loading models" must remain tappable even mid-run so a
        // failed model-list fetch can be retried without stopping the run.
        // Only mutation rows (set provider/model/effort/tier) are disabled
        // while running; the retry and recovery rows are excluded.
        let running = vm.selectedThreadRunIsStartingOrRunning
        let configurationLocked = running || !vm.selectedProviderCanRun
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let presentation = AgentModelPopoverPresentation(
            mode: vm.routingMode,
            reduceMotion: reduceMotion,
            autoRoutingLoading: autoRoutingPrerequisitesLoading
        )
        return VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.md) {
                Text("Model")
                    .font(DS.Font.caption.weight(.medium))
                    .foregroundColor(DS.Palette.text)
                Spacer(minLength: DS.Space.xxl)
                Text("Auto")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.text)
                if presentation.showsAutoLoadingIndicator {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading automatic routing")
                        .accessibilityIdentifier("agent.model.auto.loading")
                }
                Toggle("", isOn: Binding(
                    get: { vm.routingMode == .auto },
                    set: { _ = vm.setAutoModelRoutingEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DS.Palette.success)
                .disabled(running || !presentation.autoToggleEnabled)
                .accessibilityLabel(presentation.accessibilityLabel)
                .accessibilityValue(presentation.accessibilityValue)
                .accessibilityHint(presentation.accessibilityHint)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityHidden(true)
            }
            Divider()
                .accessibilityIdentifier("agent.model.auto.divider")
            if presentation.showsDisclaimer {
                autoRoutingCard(presentation: presentation)
                    .transition(presentation.transition == .fadeAndSlide
                        ? .opacity.combined(with: .move(edge: .top))
                        : .identity)
            } else {
            // UX-MAC_AGENT-016: readable while running; mutation rows disable below.
            if running {
                Text("Read-only while running")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            let modelOptions = vm.modelOptionsForSelectedProvider
            let customModels = vm.customModelsForSelectedProvider
            if vm.modelListLoading {
                Text("Loading models...")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            // P2: retry stays enabled while running so a model-list failure
            // mid-run can be recovered without stopping the agent.
            if vm.modelListStatusMessage != nil || vm.providerSnapshotStatusMessage != nil {
                compactMenuRow("Retry loading models", selected: false) {
                    Task {
                        await vm.loadProviderSnapshots()
                        await vm.loadModels()
                    }
                }
                .disabled(vm.modelListLoading)
            }
            if let modelListStatus = vm.modelListStatusMessage {
                dismissibleStatusRow(
                    modelListStatus,
                    identifier: "agent.modelList.status.dismiss",
                    color: DS.Palette.danger,
                    dismiss: { vm.dismissModelListStatusMessage() }
                )
            }
            if let providerSnapshotStatus = vm.providerSnapshotStatusMessage {
                dismissibleStatusRow(
                    providerSnapshotStatus,
                    identifier: "agent.providerSnapshot.status.dismiss",
                    color: DS.Palette.danger,
                    dismiss: { vm.dismissProviderSnapshotStatusMessage() }
                )
            }
            if !modelOptions.isEmpty || !customModels.isEmpty {
                compactMenuSection("Model")
                // F33: no provider gate — codex's baked-in list must surface
                // the same fallback notice + refresh affordance as claude.
                if vm.displayedModelListIsFallback {
                    Text("Using built-in defaults - live list unavailable")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                    compactMenuRow("Refresh model list", selected: false) {
                        // F11: reloads snapshots (the rows the picker shows)
                        // and bypasses the discovery TTL, not just loadModels.
                        Task { await vm.refreshModelList() }
                    }
                    .disabled(vm.modelListLoading)
                }
                // F9: a pinned model missing from the displayed list is kept —
                // explain why no row is checked instead of silently swapping.
                if let unavailableNotice = vm.selectedModelUnavailableNotice {
                    Text(unavailableNotice)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.warning)
                }
                let visibleModelCount = showAllModelOptions ? modelOptions.count : min(3, modelOptions.count)
                let visibleCustomModelCount = showAllModelOptions ? customModels.count : max(0, 3 - visibleModelCount)
                let visibleModels = Array(modelOptions.prefix(visibleModelCount))
                let visibleCustomModels = Array(customModels.prefix(visibleCustomModelCount))
                ForEach(visibleModels, id: \.id) { model in
                    compactMenuRow(model.label, selected: model.id == vm.model) {
                        vm.setModel(model.id)
                        showModelOptions = false
                    }
                    .disabled(configurationLocked)
                }
                ForEach(visibleCustomModels, id: \.self) { customModel in
                    compactMenuRow(customModel, selected: customModel == vm.model) {
                        vm.setCustomModel(customModel)
                        showModelOptions = false
                    }
                    .disabled(configurationLocked)
                }
                if modelOptions.count + customModels.count > 3, !showAllModelOptions {
                    compactMenuRow("More...", selected: false) {
                        showAllModelOptions = true
                    }
                }
                if vm.supportsCustomModelForSelectedProvider {
                    if showCustomModelField {
                        customModelInlineField
                    } else {
                        compactMenuRow("Custom...", selected: false) {
                            customModelDraft = vm.modelOptionsForSelectedProvider.contains(where: { $0.id == vm.model }) ? "" : vm.model
                            showCustomModelField = true
                        }
                        .disabled(configurationLocked)
                    }
                }
            }
            if vm.supportsReasoningForSelectedModel || vm.supportsServiceTierForSelectedModel {
                compactMenuDivider
            }
            if vm.routingMode == .manual && vm.supportsReasoningForSelectedModel {
                compactMenuSection("Reasoning effort")
                ForEach(vm.supportedReasoningEffortsForSelectedModel, id: \.self) { effort in
                    compactMenuRow(effort.displayName, selected: effort == vm.reasoningEffort) {
                        vm.setReasoningEffort(effort)
                        showModelOptions = false
                    }
                    .disabled(configurationLocked)
                    // F34: bare names don't distinguish Ultracode/Max/Extra
                    // High — say what each level buys before it is selected.
                    .help(effort.pickerHelpText)
                }
            }
            if vm.routingMode == .manual && vm.supportsServiceTierForSelectedModel {
                compactMenuSection("Service tier")
                compactMenuRow("Auto", selected: vm.serviceTier == .auto) {
                    vm.setServiceTier(.auto)
                    showModelOptions = false
                }
                .disabled(configurationLocked)
                compactMenuRow("Fast", selected: vm.serviceTier == .fast) {
                    vm.setServiceTier(.fast)
                    showModelOptions = false
                }
                .disabled(configurationLocked)
            }
            if let providerStatus = vm.providerStatusMessage {
                compactMenuDivider
                dismissibleStatusRow(
                    providerStatus,
                    identifier: "agent.provider.status.dismiss",
                    color: DS.Palette.danger,
                    dismiss: { vm.dismissProviderStatusMessage() }
                )
            }
            if let actionTitle = vm.providerRecoveryActionTitle {
                compactMenuRow(vm.providerRecoveryActionRunning ? "Working..." : actionTitle, selected: false) {
                    Task { await vm.performProviderRecoveryAction() }
                }
                .disabled(vm.providerRecoveryActionRunning)
            }
            if let actionStatus = vm.providerRecoveryStatusMessage {
                dismissibleStatusRow(
                    actionStatus,
                    identifier: "agent.providerRecovery.status.dismiss",
                    color: actionStatus.hasPrefix("Update failed") || actionStatus.hasPrefix("Could not") || actionStatus.hasPrefix("Sign-in unavailable")
                        ? DS.Palette.danger
                        : DS.Palette.textSecondary,
                    dismiss: { vm.dismissProviderRecoveryStatusMessage() }
                )
            }
            }
        }
        .animation(
            presentation.transition == .fadeAndSlide
                ? .easeInOut(duration: 0.2)
                : nil,
            value: vm.routingMode
        )
        .padding(DS.Space.sm)
        .background(DS.Palette.surfaceOverlay)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("agent.model.popover")
    }

    private func autoRoutingCard(presentation: AgentModelPopoverPresentation) -> some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            ZStack {
                Ellipse()
                    .stroke(
                        LinearGradient(
                            colors: [DS.Palette.accent, DS.Palette.success],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: 40, height: 20)
                    .rotationEffect(.degrees(-12))
                Image(systemName: "sparkles")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(DS.Palette.text)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text(presentation.disclaimer)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Palette.success)
                    Text(AgentModelPopoverPresentation.autoStatus)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textSecondary)
                }
            }
        }
        .padding(DS.Space.lg)
        .frame(width: 360, alignment: .leading)
        .background(
            LinearGradient(
                colors: [DS.Palette.surfaceRaised, DS.Palette.success.opacity(0.12)],
                startPoint: .leading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Palette.accent.opacity(0.22), lineWidth: DS.Border.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.model.auto.card")
    }

    private var modelMenuLabel: some View {
        HStack(spacing: DS.Space.xs) {
            if autoRoutingPillLoading {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            Text(modelLabel).font(DS.Font.caption.weight(.medium)).foregroundColor(DS.Palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if vm.routingMode == .manual && vm.supportsReasoningForSelectedModel {
                Text("·").foregroundColor(DS.Palette.textTertiary)
                Text(effortLabel).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if vm.routingMode == .manual && vm.serviceTier == .fast {
                Text("·").foregroundColor(DS.Palette.textTertiary)
                Text(serviceTierLabel).font(DS.Font.caption).foregroundColor(DS.Palette.warning)
                    .lineLimit(1)
            }
            // IMP-MAC_AGENT-014: surface the model's context window on the pill so
            // the active limit is visible at a glance without opening the popover.
            if vm.routingMode == .manual, let ctx = vm.selectedModelContextWindowLabel {
                Text("·").foregroundColor(DS.Palette.textTertiary)
                Text(ctx).font(DS.Font.caption).foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
        }
        .frame(width: currentModelMenuLabelWidth, alignment: .trailing)
        .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
        .background(DS.Palette.surfaceRaised)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
    }

    private func compactMenuSection(_ title: String) -> some View {
        Text(title)
            .font(DS.Font.caption2.weight(.semibold))
            .foregroundColor(DS.Palette.textTertiary)
            .padding(.top, DS.Space.xs)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func compactMenuRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12)
                    .opacity(selected ? 1 : 0)
                Text(title)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, DS.Space.xs)
            .frame(width: compactModelMenuWidth, alignment: .leading)
            .background(selected ? DS.Palette.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var compactMenuDivider: some View {
        Rectangle()
            .fill(DS.Palette.line)
            .frame(height: DS.Border.hairline)
            .padding(.vertical, DS.Space.xs)
            .frame(width: compactModelMenuWidth)
    }

    // UX-MAC_AGENT-013: inline custom-model field, no blocking modal. Validates
    // non-empty (trimmed) before saving; Esc/blur-style Cancel dismisses it.
    private var customModelInlineField: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            TextField("Model ID", text: $customModelDraft)
                .textFieldStyle(.roundedBorder)
                .font(DS.Font.caption)
                .frame(width: compactModelMenuWidth)
                .onSubmit { commitCustomModelDraft() }
                .accessibilityIdentifier("agent.model.custom.input")
            HStack(spacing: DS.Space.xs) {
                Button("Save") { commitCustomModelDraft() }
                    .controlSize(.small)
                    .disabled(customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("agent.model.custom.save")
                Button("Cancel") {
                    showCustomModelField = false
                    customModelDraft = ""
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, DS.Space.xs)
        .padding(.vertical, DS.Space.xs)
    }

    private func commitCustomModelDraft() {
        let trimmed = customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        vm.setCustomModel(trimmed)
        showCustomModelField = false
        customModelDraft = ""
        showModelOptions = false
    }

    // PERF-MAC_AGENT-009: the menu width was recomputed (build title array +
    // max width) on every popover re-render and inside every row's layout.
    // Memoize it, recomputing only when the option set actually changes.
    private final class ModelMenuWidthCache {
        var signature: String?
        var width: CGFloat = 112
    }
    private let modelMenuWidthCache = ModelMenuWidthCache()

    private var compactModelMenuWidth: CGFloat {
        // Source/account titles moved to the dedicated capsule; this width is
        // only for model/effort/tier rows inside the model popover.
        var titles: [String] = []
        let modelOptions = vm.modelOptionsForSelectedProvider
        let customModels = vm.customModelsForSelectedProvider
        let visibleModelCount = showAllModelOptions ? modelOptions.count : min(3, modelOptions.count)
        let visibleCustomModelCount = showAllModelOptions ? customModels.count : max(0, 3 - visibleModelCount)
        titles.append(contentsOf: modelOptions.prefix(visibleModelCount).map(\.label))
        titles.append(contentsOf: customModels.prefix(visibleCustomModelCount))
        if vm.supportsCustomModelForSelectedProvider {
            titles.append("Custom...")
        }
        if modelOptions.count + customModels.count > 3, !showAllModelOptions {
            titles.append("More...")
        }
        if vm.routingMode == .manual && vm.supportsReasoningForSelectedModel {
            titles.append(contentsOf: vm.supportedReasoningEffortsForSelectedModel.map(\.displayName))
        }
        if vm.routingMode == .manual && vm.supportsServiceTierForSelectedModel {
            titles.append(contentsOf: ["Auto", "Fast"])
        }
        if vm.providerRecoveryActionTitle != nil {
            titles.append(vm.providerRecoveryActionRunning ? "Working..." : (vm.providerRecoveryActionTitle ?? ""))
        }
        let signature = titles.joined(separator: "\u{1}")
        if modelMenuWidthCache.signature == signature {
            return modelMenuWidthCache.width
        }
        let estimated = titles.map { CGFloat($0.count * 7 + 34) }.max() ?? 112
        let width = min(max(estimated, 112), 260)
        modelMenuWidthCache.signature = signature
        modelMenuWidthCache.width = width
        return width
    }

    private var currentModelMenuLabelWidth: CGFloat {
        let label = currentModelMenuLabelParts.joined(separator: " · ")
        let measured = Self.measureCurrentModelMenuLabel(label)
        let chevronWidth: CGFloat = 8
        let loadingWidth: CGFloat = autoRoutingPillLoading ? 14 + DS.Space.xs : 0
        let separatorCount = max(0, currentModelMenuLabelParts.count - 1)
        let spacing = CGFloat(separatorCount + 1) * DS.Space.xs
        return min(max(ceil(measured + chevronWidth + loadingWidth + spacing), 44), 260)
    }

    private var currentModelMenuLabelParts: [String] {
        if vm.routingMode == .auto { return ["Auto"] }
        var parts = [modelLabel]
        if vm.supportsReasoningForSelectedModel {
            parts.append(effortLabel)
        }
        if vm.serviceTier == .fast {
            parts.append(serviceTierLabel)
        }
        if let ctx = vm.selectedModelContextWindowLabel {
            parts.append(ctx)
        }
        return parts
    }

    private static func measureCurrentModelMenuLabel(_ label: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        return (label as NSString).size(withAttributes: [.font: font]).width
    }

    private var sendStopButton: some View {
        let runActive = vm.selectedThreadRunIsStartingOrRunning
        return Button {
            Task { await vm.send() }
        } label: {
            ZStack {
                Circle()
                    .fill(sendIdleDisabled ? DS.Palette.surfaceRaised : DS.Palette.accent)
                    .frame(width: 28, height: 28)
                Image(systemName: runActive ? "text.line.first.and.arrowtriangle.forward" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(sendIdleDisabled ? DS.Palette.textTertiary : DS.Palette.onAccent)
            }
        }
        .buttonStyle(.plain)
        .disabled(sendIdleDisabled)
        .keyboardShortcut(.return, modifiers: [.command])
        .accessibilityLabel(runActive ? "Queue message" : "Send")
        .accessibilityIdentifier("agent.composer.send")
        .help(runActive ? "Queue message for this thread" : "Send prompt")
    }

    private var stopButton: some View {
        let btnState = AgentAppViewModel.stopButtonState(
            runActive: vm.selectedThreadRunIsStartingOrRunning,
            isStopping: vm.isStopping
        )
        // Keep clickable while Stopping so a second click force-stops; do not
        // latch the control disabled forever if soft cancel stalls.
        return Button { vm.stop() } label: {
            ZStack {
                Circle()
                    .fill(btnState == .stopping ? DS.Palette.surfaceRaised : DS.Palette.danger)
                    .frame(width: 28, height: 28)
                if btnState == .stopping {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(DS.Palette.textSecondary)
                } else {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(DS.Palette.bg)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(btnState == .stopping ? "Force stop running agent" : "Stop running agent")
        .accessibilityIdentifier("agent.composer.stop")
        .help(btnState == .stopping
              ? "Still stopping — click again to force-stop the provider"
              : "Stop running agent")
    }

    // P3: thumbnail for image attachments; falls back to doc icon for non-images.
    @ViewBuilder private func attachmentChipLeadingContent(_ path: String) -> some View {
        if Self.isImageAttachment(path), let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: Self.isImagePath(path) ? "photo" : "doc")
                .font(.system(size: 9))
        }
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                ForEach(vm.attachments, id: \.self) { attachment in
                    HStack(spacing: DS.Space.xs) {
                        // P3: render thumbnail for image files; icon+name for others.
                        attachmentChipLeadingContent(attachment.path)
                        Text(attachment.displayName)
                            .font(DS.Font.caption2).lineLimit(1)
                        Button { vm.removeAttachment(attachment) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.attachmentRemovalAccessibilityLabel(path: attachment.displayName))
                        .help(Self.attachmentRemovalAccessibilityLabel(path: attachment.displayName))
                    }
                    .foregroundColor(DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.sm).padding(.vertical, 3)
                    .background(DS.Palette.surfaceRaised)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                }
            }
        }
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        // P2: directories are rejected at send time by AgentAttachmentResolver;
        // disallow them at pick time so the error surfaces immediately instead
        // of silently after the run starts.
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            vm.addAttachments(panel.urls.map { $0.path })
        }
    }

    // IMP-MAC_AGENT-010: resolve dropped item providers to file paths and
    // insert them as ordinary composer text. Returns true if any provider is a file.
    private func loadDroppedFileAttachments(from providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { vm.insertDroppedFilePaths([url.path]) }
            }
        }
        return true
    }

    private var sendIdleDisabled: Bool {
        let empty =
            vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && vm.attachments.isEmpty
        return empty || autoRoutingPillLoading
    }

    private func selectThreadRow(_ thread: AgentThread) {
        if NSEvent.modifierFlags.contains(.shift),
           let lastSelectedThreadId,
           let last = vm.threads.firstIndex(where: { $0.id == lastSelectedThreadId }),
           let current = vm.threads.firstIndex(where: { $0.id == thread.id }) {
            let range = min(last, current)...max(last, current)
            selectedThreadIds.formUnion(vm.threads[range].map(\.id))
        } else {
            selectedThreadIds = [thread.id]
            lastSelectedThreadId = thread.id
        }
        vm.selectThread(thread.id)
    }

    private func deleteSelectedThreads() {
        let fallback = vm.selectedThreadId.map { Set([$0]) } ?? []
        let ids = selectedThreadIds.isEmpty ? fallback : selectedThreadIds
        guard !ids.isEmpty else { return }
        // P1: route through confirmation dialog — destructive and instant.
        pendingDeleteThreadIds = ids
    }

    private func deleteThreads(_ ids: Set<AgentThreadID>) {
        guard !ids.isEmpty else { return }
        Task {
            guard await vm.deleteThreads(ids) else { return }
            selectedThreadIds.subtract(ids)
            if let lastSelectedThreadId, ids.contains(lastSelectedThreadId) {
                self.lastSelectedThreadId = selectedThreadIds.first
            }
        }
    }

    private func commitPendingDelete() {
        let ids = pendingDeleteThreadIds
        pendingDeleteThreadIds = []
        deleteThreads(ids)
    }

    private func commitClearAllThreads() {
        pendingClearAllThreads = false
        Task {
            guard await vm.clearAllThreads() else { return }
            selectedThreadIds = []
            lastSelectedThreadId = nil
        }
    }

    // MARK: Plan notes sidebar

    private var planSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Plan", trailing: AnyView(
                DSIconButton("xmark", help: "Hide plan") {
                    planSidebarIntent = .forcedHidden
                    vm.showPlanSidebar = false
                }
            ))
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            if Self.shouldRenderActivePlan(
                plan: vm.activePlan,
                status: vm.status,
                runStartedAt: vm.runStartedAt,
                newestUserMessageAt: vm.messages.last(where: { $0.role == .user })?.createdAt
            ), let plan = vm.activePlan {
                activePlanSidebarCard(plan)
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            }
            if let proposedPlan = vm.reviewableProposedPlan {
                let plan = proposedPlanExpanded ? proposedPlan.markdown : proposedPlan.collapsedPreview
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("PROPOSED BY AGENT")
                        .font(DS.Font.caption2.weight(.semibold)).tracking(0.6)
                        .foregroundColor(DS.Palette.accent)
                    Text(proposedPlan.exportTitle)
                        .font(DS.Font.body.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                    HStack(spacing: DS.Space.xs) {
                        if proposedPlan.showsImplementationActions {
                            Button {
                                Task { await vm.implementLatestPlan(newThread: false) }
                            } label: {
                                Label("Approve", systemImage: "checkmark")
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                Task { await vm.rejectLatestPlan() }
                            } label: {
                                Label("Reject", systemImage: "xmark")
                            }
                            .buttonStyle(.bordered)
                            Button {
                                Task { await vm.implementLatestPlan(newThread: true) }
                            } label: {
                                Label("New thread", systemImage: "plus.message")
                            }
                            .buttonStyle(.bordered)
                        }
                        Button {
                            copyToPasteboard(plan)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            saveLatestProposedPlan()
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        if proposedPlan.markdown != proposedPlan.collapsedPreview {
                            Button {
                                proposedPlanExpanded.toggle()
                            } label: {
                                Label(proposedPlanExpanded ? "Collapse" : "Show all",
                                      systemImage: proposedPlanExpanded ? "chevron.up" : "chevron.down")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    ScrollView {
                        Text(plan)
                            .font(DS.Font.monoSmall)
                            .foregroundColor(DS.Palette.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: proposedPlanExpanded ? 420 : 220)
                }
                .padding(DS.Space.md)
                .background(DS.Palette.bg)
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            }
            checkpointBrowserCard
            if !vm.checkpoints.isEmpty {
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            }
            // UX-MAC_AGENT-014: when the panel has no plan/checkpoints yet, the
            // bare Notes editor reads as broken — explain what fills this panel.
            if vm.activePlan == nil, vm.reviewableProposedPlan == nil, vm.checkpoints.isEmpty {
                Text("The agent's plan and turn checkpoints appear here.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.md).padding(.top, DS.Space.sm)
            }
            Text("NOTES")
                .font(DS.Font.caption2.weight(.semibold)).tracking(0.6)
                .foregroundColor(DS.Palette.textTertiary)
                .padding(.horizontal, DS.Space.md).padding(.top, DS.Space.sm)
            TextEditor(text: $vm.planNotes)
                .font(DS.Font.mono)
                .scrollContentBackground(.hidden)
                .padding(DS.Space.md)
                .background(DS.Palette.surface)
                .onChange(of: vm.planNotes) { _ in vm.savePlanNotes() }
        }
        .background(DS.Palette.surface)
        .overlay(alignment: .leading) {
            Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
        }
    }

    @ViewBuilder
    private var checkpointBrowserCard: some View {
        if !vm.checkpoints.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack {
                    Text("CHECKPOINTS")
                        .font(DS.Font.caption2.weight(.semibold)).tracking(0.6)
                        .foregroundColor(DS.Palette.accent)
                    Spacer()
                    Button {
                        vm.reloadCheckpoints()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.xs) {
                        ForEach(vm.checkpoints) { checkpoint in
                            Button {
                                vm.selectCheckpoint(checkpoint, path: nil)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("#\(checkpoint.checkpointTurnCount) \(checkpoint.status.rawValue.uppercased())")
                                        .font(DS.Font.caption.weight(.semibold))
                                    Text("\(checkpoint.files.count) files")
                                        .font(DS.Font.caption2)
                                        .foregroundColor(DS.Palette.textSecondary)
                                }
                                .frame(width: 116, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("agent.checkpoint.row.\(checkpoint.checkpointTurnCount)")
                        }
                    }
                }
                if let checkpoint = vm.checkpoints.first(where: { $0.checkpointTurnCount == vm.selectedCheckpointTurnCount }) {
                    if !checkpoint.files.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: DS.Space.xs) {
                                Button {
                                    vm.selectCheckpoint(checkpoint, path: nil)
                                } label: {
                                    Label("All files", systemImage: "doc.text")
                                }
                                .buttonStyle(.bordered)
                                ForEach(checkpoint.files, id: \.path) { file in
                                    Button {
                                        vm.selectCheckpoint(checkpoint, path: file.path)
                                    } label: {
                                        Label(URL(fileURLWithPath: file.path).lastPathComponent, systemImage: "doc")
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("agent.checkpoint.file.\(file.path)")
                                }
                            }
                        }
                    }
                    ScrollView {
                        Text(vm.checkpointDiffPreview)
                            .font(DS.Font.monoSmall)
                            .foregroundColor(DS.Palette.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .background(DS.Palette.surface)
                    .accessibilityIdentifier("agent.checkpoint.diff")
                    HStack {
                        if let message = vm.checkpointStatusMessage {
                            dismissibleStatusRow(
                                message,
                                identifier: "agent.checkpoint.status.dismiss",
                                color: message.hasPrefix("Revert failed") ? DS.Palette.danger : DS.Palette.textSecondary,
                                dismiss: { vm.dismissCheckpointStatusMessage() }
                            )
                        }
                        Spacer()
                        // UX-XPLAT-007: stage the revert for confirmation instead
                        // of executing immediately — rolling back the working tree
                        // is irreversible without a prior git commit.
                        Button(role: .destructive) {
                            pendingRevertCheckpointTurnCount = checkpoint.checkpointTurnCount
                        } label: {
                            Label("Revert", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(!AgentAppViewModel.canRevertCheckpoint(
                            status: checkpoint.status,
                            capabilities: vm.selectedProviderCapabilities
                        ))
                        .help(vm.checkpointRevertUnavailableReason ?? "Restore provider context and workspace files to this checkpoint.")
                        .accessibilityIdentifier("agent.checkpoint.revert")
                    }
                }
            }
            .padding(DS.Space.md)
            .background(DS.Palette.bg)
            .accessibilityIdentifier("agent.checkpoints.card")
            // P1: confirm before reverting — rolls back working tree with no undo.
            .confirmationDialog(
                "Revert to checkpoint \(pendingRevertCheckpointTurnCount.map { "#\($0)" } ?? "")?",
                isPresented: Binding(
                    get: { pendingRevertCheckpointTurnCount != nil },
                    set: { if !$0 { pendingRevertCheckpointTurnCount = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Revert", role: .destructive) {
                    vm.revertSelectedCheckpoint()
                    pendingRevertCheckpointTurnCount = nil
                }
                Button("Cancel", role: .cancel) { pendingRevertCheckpointTurnCount = nil }
            } message: {
                Text("This will overwrite uncommitted changes in the working tree. This cannot be undone.")
            }
        }
    }

    private func activePlanSidebarCard(_ plan: AssistantActivePlan) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("ACTIVE PLAN")
                .font(DS.Font.caption2.weight(.semibold)).tracking(0.6)
                .foregroundColor(DS.Palette.accent)
            if let explanation = plan.explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(plan.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        Image(systemName: step.status.iconName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(step.status.tint)
                            .frame(width: 14)
                        Text(step.title)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.text)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(DS.Space.md)
        .background(DS.Palette.bg)
    }

    private func activePlanRow(_ plan: AssistantActivePlan) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Palette.accent)
                Text("Active plan")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                Spacer(minLength: 0)
            }
            if let explanation = plan.explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(DS.Font.bodyDense)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(plan.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                        Image(systemName: step.status.iconName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(step.status.tint)
                            .frame(width: 16)
                        Text(step.title)
                            .font(DS.Font.bodyDense)
                            .foregroundColor(DS.Palette.text)
                        Spacer(minLength: DS.Space.sm)
                        Text(step.status.label)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                }
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .accessibilityIdentifier("agent.activePlan")
    }

    private func proposedPlanRow(_ plan: AssistantProposedPlan) -> some View {
        let markdown = proposedPlanExpanded ? plan.markdown : plan.collapsedPreview
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Image(systemName: plan.implementedAtMs == nil ? "list.bullet.clipboard" : "checkmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.implementedAtMs == nil ? "Proposed plan" : "Implementation started")
                        .font(DS.Font.caption.weight(.semibold))
                        .foregroundColor(DS.Palette.textSecondary)
                    Text(plan.exportTitle)
                        .font(DS.Font.bodyDense.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                }
                Spacer(minLength: 0)
            }
            AgentMessageMarkdownView(text: markdown)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: DS.Space.xs) {
                if plan.showsImplementationActions {
                    Button {
                        Task { await vm.implementLatestPlan(newThread: false) }
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        Task { await vm.rejectLatestPlan() }
                    } label: {
                        Label("Reject", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        Task { await vm.implementLatestPlan(newThread: true) }
                    } label: {
                        Label("New thread", systemImage: "plus.message")
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    copyToPasteboard(markdown)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Button {
                    saveLatestProposedPlan()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                if plan.markdown != plan.collapsedPreview {
                    Button {
                        proposedPlanExpanded.toggle()
                    } label: {
                        Label(proposedPlanExpanded ? "Collapse" : "Show all",
                              systemImage: proposedPlanExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .accessibilityIdentifier("agent.proposedPlan.\(plan.id)")
    }
}

private extension AssistantPlanStepStatus {
    var iconName: String {
        switch self {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .inProgress: return "In progress"
        case .completed: return "Done"
        }
    }

    var tint: Color {
        switch self {
        case .pending: return DS.Palette.textTertiary
        case .inProgress: return DS.Palette.accent
        case .completed: return DS.Palette.success
        }
    }
}

enum PromptComposerKeyAction: Equatable {
    case send
    case insertNewline
    case previousHistory
    case nextHistory
    case ignore

    static func action(for event: NSEvent) -> PromptComposerKeyAction {
        action(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    // QA-MAC_AGENT-012: pure key mapping, testable without building an NSEvent.
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> PromptComposerKeyAction {
        if modifiers.intersection([.command, .control, .option]).isEmpty {
            if keyCode == 126 { return .previousHistory }
            if keyCode == 125 { return .nextHistory }
        }
        guard keyCode == 36 || keyCode == 76 else { return .ignore }
        // P2: Shift+Enter and Option+Enter both insert a newline; plain Enter sends.
        let wantsNewline = modifiers.contains(.shift) || modifiers.contains(.option)
        return wantsNewline ? .insertNewline : .send
    }

    /// Whether this key should go through AppKit text input (`interpretKeyEvents`)
    /// instead of send/history/popup routing.
    ///
    /// Dead keys (ABNT/US-International acute, tilde, circumflex, …) often arrive
    /// with empty `characters` and no Option modifier on the first press. Those
    /// MUST still use text input so marked-text composition can commit ç/á/é/…
    /// into the prompt. Only Return/arrows/Esc stay on the command routes.
    static func shouldInterpretTextInput(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String?
    ) -> Bool {
        guard modifiers.intersection([.command, .control]).isEmpty else { return false }
        switch keyCode {
        case 36, 76, 125, 126, 53:
            return false
        default:
            return true
        }
    }

    // macos:32: resolves a keystroke given whether the caret-anchored suggestion
    // popup is open. When the popup is CLOSED this ALWAYS defers to the existing
    // 2-arg `action(keyCode:modifiers:)` via `.passthrough`, so send/history
    // behavior is byte-for-byte identical to today. When the popup is OPEN, the
    // navigation keys (up/down/Return/Esc, with no disqualifying modifiers) are
    // intercepted; everything else still passes through. The existing 2-arg fn
    // is left UNCHANGED.
    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, popupOpen: Bool) -> ComposerKeyResolution {
        let passthrough = ComposerKeyResolution.passthrough(action(keyCode: keyCode, modifiers: modifiers))
        guard popupOpen else { return passthrough }
        let hasHardModifier = !modifiers.intersection([.command, .control, .option]).isEmpty
        switch keyCode {
        case 126 where !hasHardModifier && !modifiers.contains(.shift):
            return .navUp
        case 125 where !hasHardModifier && !modifiers.contains(.shift):
            return .navDown
        case 36, 76:
            // Plain Return applies the selection; Shift/Option-Return must still
            // insert a newline (passthrough), so the user can compose multiline
            // prompts while the popup is visible.
            if modifiers.contains(.shift) || modifiers.contains(.option) { return passthrough }
            return .applySelected
        case 53:
            return .dismissPopup
        default:
            return passthrough
        }
    }
}

// macos:32: outcome of a keystroke when the suggestion popup may be open.
enum ComposerKeyResolution: Equatable {
    case navUp
    case navDown
    case applySelected
    case dismissPopup
    case passthrough(PromptComposerKeyAction)
}

// Radio + freeform field for the auto-provided "Other" choice of a structured
// AskUserQuestion. The Other field is a real member of the radio group: tapping the
// radio claims the single selection (clearing any chosen option) so the user is no
// longer stuck with an option's radio marked, and typing also claims it via the
// binding. Owns its own @FocusState so focusing the field on a radio tap does not
// invalidate the perf-sensitive AgentAppView body.
private struct AskUserQuestionOtherField: View {
    @ObservedObject var vm: AgentAppViewModel
    let question: AssistantUserInputQuestion
    let request: AssistantUserInputRequest
    @FocusState private var focused: Bool

    var body: some View {
        let selected = vm.askUserQuestionOtherIsSelected(question: question, request: request)
        // Other is mutually exclusive with the listed options in BOTH single- and
        // multi-select questions (selecting Other replaces any chosen option), so it
        // always reads as a radio. A checkbox glyph would falsely promise it combines
        // with checked boxes when the model actually replaces them.
        let symbol = selected ? "largecircle.fill.circle" : "circle"
        let draft = Binding(
            get: { vm.userInputDrafts[vm.askUserQuestionKey(request, question)] ?? "" },
            set: { vm.setAskUserQuestionOther($0, question: question, request: request) }
        )
        HStack(alignment: .center, spacing: DS.Space.sm) {
            Button {
                vm.selectAskUserQuestionOther(question: question, request: request)
                if vm.askUserQuestionOtherIsSelected(question: question, request: request) {
                    focused = true
                }
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundColor(selected ? DS.Palette.accent : DS.Palette.textTertiary)
                    // Pad the glyph so the radio has a comfortable tap target instead of a
                    // razor-thin 12pt hit area; the listed option rows are fully tappable.
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Other")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("agent.askOther.\(request.id).\(question.id)")
            TextField("Other…", text: draft)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($focused)
        }
    }
}

// macos:32: pure, value-type navigation logic for the composer suggestion
// popup. Holds NO view state and is unit-testable in isolation. `selectedIndex`
// is the highlighted row (nil == nothing highlighted yet).
struct ComposerSuggestionNavigation: Equatable {
    var selectedIndex: Int?

    static func reset() -> Int? { nil }

    // Down: from nil -> 0; otherwise advance with wrap-around. count==0 -> nil.
    static func moveDown(selected: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current = selected else { return 0 }
        let clamped = max(0, min(current, count - 1))
        return (clamped + 1) % count
    }

    // Up: from nil -> last row; otherwise retreat with wrap-around. count==0 -> nil.
    static func moveUp(selected: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current = selected else { return count - 1 }
        let clamped = max(0, min(current, count - 1))
        return (clamped - 1 + count) % count
    }

    // The popup is open iff there is at least one suggestion and the user has
    // not dismissed it (Esc) for the current token.
    static func isOpen(count: Int, dismissed: Bool) -> Bool {
        count > 0 && !dismissed
    }
}

// WHY: layout for the slash/skill panel must stay pure and testable. The panel
// owns vertical space between the editor and toolbar so it never collides with
// composer controls (the previous caret-overlay + place-below path did).
struct ComposerSuggestionPlacement: Equatable {
    var height: CGFloat
    var rowHeight: CGFloat
    var maxVisibleRows: Int

    static let defaultRowHeight: CGFloat = 30
    static let defaultMaxVisibleRows = 6

    static func layout(
        suggestionCount: Int,
        rowHeight: CGFloat = defaultRowHeight,
        maxVisibleRows: Int = defaultMaxVisibleRows
    ) -> ComposerSuggestionPlacement {
        let visible = min(max(suggestionCount, 0), max(maxVisibleRows, 0))
        return ComposerSuggestionPlacement(
            height: CGFloat(visible) * rowHeight,
            rowHeight: rowHeight,
            maxVisibleRows: maxVisibleRows
        )
    }
}

private final class PromptComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onPreviousHistory: (() -> Bool)?
    var onNextHistory: (() -> Bool)?
    var onFileDrop: (([String]) -> Void)?
    // macos:32: suggestion-popup hooks. `popupIsOpen` is read at keyDown time so
    // the closures never capture a stale suggestion snapshot.
    var popupIsOpen: (() -> Bool)?
    var onPopupNavUp: (() -> Void)?
    var onPopupNavDown: (() -> Void)?
    var onPopupApply: (() -> Void)?
    var onPopupDismiss: (() -> Void)?
    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        // Never divert send/history/popup while a dead-key / IME composition is
        // in progress — Return must commit the accent (é), not send the message.
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }

        if PromptComposerKeyAction.shouldInterpretTextInput(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            characters: event.characters
        ) {
            interpretKeyEvents([event])
            return
        }

        let open = popupIsOpen?() ?? false
        let resolution = PromptComposerKeyAction.resolve(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            popupOpen: open
        )
        switch resolution {
        case .navUp:
            onPopupNavUp?()
        case .navDown:
            onPopupNavDown?()
        case .applySelected:
            onPopupApply?()
        case .dismissPopup:
            onPopupDismiss?()
        case .passthrough(let action):
            // Identical to today's behavior when the popup is closed (and for any
            // non-navigation key while it is open).
            switch action {
            case .send:
                onSend?()
            case .insertNewline:
                insertNewlineIgnoringFieldEditor(self)
            case .previousHistory:
                if onPreviousHistory?() != true { super.keyDown(with: event) }
            case .nextHistory:
                if onNextHistory?() != true { super.keyDown(with: event) }
            case .ignore:
                super.keyDown(with: event)
            }
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        return DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        return DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        let paths = DroppedFilePaths.paths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return super.performDragOperation(sender) }
        onFileDrop?(paths)
        return true
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard isEditable else { return false }
        let paths = DroppedFilePaths.paths(from: pasteboard)
        guard !paths.isEmpty else { return super.readSelection(from: pasteboard, type: type) }
        onFileDrop?(paths)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: DS.NS.textTertiary
        ]
        placeholderString.draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attrs)
    }
}

private struct PromptComposerEditor: NSViewRepresentable {
    static let minHeight: CGFloat = 30
    static let maxHeight: CGFloat = 132

    @Binding var text: String
    @Binding var height: CGFloat
    let focusTick: Int
    let placeholder: String
    let onSend: () -> Void
    let onPreviousHistory: () -> Bool
    let onNextHistory: () -> Bool
    let onTextEdited: () -> Void
    let onFileDrop: ([String]) -> Void
    // UX-XPLAT-009: reports the UTF-16 offset of the insertion point so
    // suggestion anchoring uses the cursor position, not text.endIndex.
    let onCursorMoved: (Int) -> Void
    // macos:32: reports the caret rect (in the text view's own coordinate space)
    // so the suggestion popup can anchor to the insertion point.
    let onCaretRectChanged: (CGRect) -> Void
    // macos:32: popup wiring. `popupIsOpen` is queried lazily at keyDown time.
    let popupIsOpen: () -> Bool
    let onPopupNavUp: () -> Void
    let onPopupNavDown: () -> Void
    let onPopupApply: () -> Void
    let onPopupDismiss: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FilePathDropScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.onFileDrop = onFileDrop

        let textView = PromptComposerTextView()
        textView.registerForDraggedTypes(DroppedFilePaths.pasteboardTypes)
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.backgroundColor = .clear
        textView.textColor = DS.NS.text
        textView.insertionPointColor = DS.NS.text
        textView.textContainerInset = NSSize(width: 0, height: 5)
        textView.minSize = NSSize(width: 0, height: Self.minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.onSend = onSend
        textView.onPreviousHistory = onPreviousHistory
        textView.onNextHistory = onNextHistory
        textView.onFileDrop = onFileDrop
        textView.popupIsOpen = popupIsOpen
        textView.onPopupNavUp = onPopupNavUp
        textView.onPopupNavDown = onPopupNavDown
        textView.onPopupApply = onPopupApply
        textView.onPopupDismiss = onPopupDismiss
        textView.placeholderString = placeholder
        // QA-MAC_AGENT-001: stable identifier on the AppKit text view so
        // XCUITest can address the composer input directly.
        textView.setAccessibilityIdentifier("agent.composer.input")
        context.coordinator.textView = textView
        context.coordinator.recalculateHeight()
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView ?? scroll.documentView as? PromptComposerTextView else { return }
        if let dropScroll = scroll as? FilePathDropScrollView {
            dropScroll.onFileDrop = onFileDrop
        }
        textView.onSend = onSend
        textView.onPreviousHistory = onPreviousHistory
        textView.onNextHistory = onNextHistory
        textView.onFileDrop = onFileDrop
        textView.popupIsOpen = popupIsOpen
        textView.onPopupNavUp = onPopupNavUp
        textView.onPopupNavDown = onPopupNavDown
        textView.onPopupApply = onPopupApply
        textView.onPopupDismiss = onPopupDismiss
        textView.placeholderString = placeholder
        // Do not clobber an in-progress dead-key / IME composition: replacing
        // `string` while marked text is active aborts accents (ç/á/é) and CJK.
        if textView.string != text, !textView.hasMarkedText() {
            context.coordinator.applyExternalText(text, to: textView)
        }
        context.coordinator.recalculateHeight()
        scroll.hasVerticalScroller = height >= Self.maxHeight
        if context.coordinator.appliedFocusTick != focusTick {
            context.coordinator.appliedFocusTick = focusTick
            DispatchQueue.main.async {
                guard let window = textView.window, window.firstResponder !== textView else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            height: $height,
            onTextEdited: onTextEdited,
            onCursorMoved: onCursorMoved,
            onCaretRectChanged: onCaretRectChanged
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var height: CGFloat
        let onTextEdited: () -> Void
        let onCursorMoved: (Int) -> Void
        let onCaretRectChanged: (CGRect) -> Void
        weak var textView: PromptComposerTextView?
        var appliedFocusTick: Int?
        private var externallyAppliedText: String?

        init(
            text: Binding<String>,
            height: Binding<CGFloat>,
            onTextEdited: @escaping () -> Void,
            onCursorMoved: @escaping (Int) -> Void,
            onCaretRectChanged: @escaping (CGRect) -> Void
        ) {
            _text = text
            _height = height
            self.onTextEdited = onTextEdited
            self.onCursorMoved = onCursorMoved
            self.onCaretRectChanged = onCaretRectChanged
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            if textView.string == externallyAppliedText {
                externallyAppliedText = nil
            } else {
                onTextEdited()
            }
            textView.needsDisplay = true
            recalculateHeight()
            reportCursor(for: textView)
        }

        // UX-XPLAT-009: selection changes (arrow keys, mouse click, etc.) must
        // also update the cursor offset so suggestions update immediately.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            reportCursor(for: textView)
        }

        private func reportCursor(for textView: NSTextView) {
            let offset = textView.selectedRange().location
            onCursorMoved(offset)
            onCaretRectChanged(caretRect(for: textView, insertionUTF16: offset))
        }

        // macos:32: insertion-point rect in the text view's own coordinate space.
        // The zero-length glyph rect can be degenerate (empty doc, caret at end of
        // a line); fall back to the glyph BEFORE the caret, then to the text
        // container origin, so the popup always has a sane anchor.
        private func caretRect(for textView: NSTextView, insertionUTF16: Int) -> CGRect {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else {
                return CGRect(origin: textView.textContainerOrigin, size: .zero)
            }
            let origin = textView.textContainerOrigin
            let length = (textView.string as NSString).length
            let location = max(0, min(insertionUTF16, length))
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: location, length: 0),
                actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            if rect.isEmpty, location > 0 {
                let priorGlyphs = layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: location - 1, length: 1),
                    actualCharacterRange: nil
                )
                let prior = layoutManager.boundingRect(forGlyphRange: priorGlyphs, in: container)
                if !prior.isEmpty {
                    // Anchor at the trailing edge of the preceding glyph.
                    rect = CGRect(x: prior.maxX, y: prior.minY, width: 0, height: prior.height)
                }
            }
            if rect.isEmpty {
                rect = CGRect(x: 0, y: 0, width: 0, height: textView.font?.pointSize ?? 13)
            }
            return rect.offsetBy(dx: origin.x, dy: origin.y)
        }

        func applyExternalText(_ value: String, to textView: NSTextView) {
            externallyAppliedText = value
            textView.string = value
            let endOffset = (value as NSString).length
            textView.setSelectedRange(NSRange(location: endOffset, length: 0))
            onCursorMoved(endOffset)
        }

        func recalculateHeight() {
            guard let textView else { return }
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let next = min(PromptComposerEditor.maxHeight,
                           max(PromptComposerEditor.minHeight, ceil(used + textView.textContainerInset.height * 2)))
            if abs(height - next) > 0.5 {
                DispatchQueue.main.async { [weak self] in
                    self?.height = next
                }
            }
        }
    }
}

// MARK: - ScrollPinPolicy (pure, testable)

/// Pure pin/unpin decision extracted from TimelineScrollFollower for unit-testing.
///
/// Callers supply the geometry they already have; this type owns NO AppKit state.
/// Extracted to support T040 (PERF-MAC_AGENT-021 regression harness).
enum ScrollPinTransition {
    /// Gap has closed to <= slack: re-pin.
    case reachedBottom
    /// Origin dropped by more than the noise threshold while NOT at the bottom:
    /// a genuine user scroll-up.
    case scrolledAway
    /// Neither condition: no state change.
    case unchanged
}

enum ScrollPinPolicy {
    /// Decide the pin-state transition that a clip-bounds change implies.
    ///
    /// - Parameters:
    ///   - originDelta: newOriginY - lastOriginY (negative means the user scrolled up).
    ///   - gap: distance from the bottom of visible content to the bottom of the document.
    ///   - slack: tolerance in points; gap <= slack is treated as "at bottom".
    /// - Returns: The transition, if any.
    nonisolated static func evaluate(originDelta: CGFloat, gap: CGFloat, slack: CGFloat) -> ScrollPinTransition {
        if gap <= slack {
            return .reachedBottom
        } else if originDelta < -0.5 {
            return .scrolledAway
        }
        return .unchanged
    }
}

/// Auto-follow + pin/unpin for the timeline, driven from the AppKit layer where the
/// real post-layout geometry lives. This replaced a timer-based SwiftUI heuristic
/// (a 0.4s guard window + a 180ms reveal Task + a DragGesture) that was both racy and
/// blind to trackpad/wheel scrolls — it only watched DragGesture, so a two-finger
/// scroll-up during a fast stream was silently ignored, and the 0.4s guard could
/// swallow a genuine scroll-away. Two AppKit facts make this version deterministic:
///
///   • A user scroll-up is the ONLY thing that DECREASES the clip view's origin.y;
///     content growing at the bottom never moves the origin. So origin.y dropping
///     while we're away from the bottom is an unambiguous "user left the bottom".
///   • When pinned, we re-scroll the clip to the document's true bottom on every
///     content-growth notification (i.e. AFTER layout), so a stream always lands
///     exactly at the bottom instead of a frame short.
///
/// Crucially this writes SwiftUI @State only on an actual pin<->unpin transition
/// (never per streaming delta), so it cannot reintroduce the layout-storm freeze
/// (PERF-MAC_AGENT-021).
private struct TimelineScrollFollower: NSViewRepresentable {
    let slack: CGFloat
    let pinned: Bool
    let onScrolledAway: () -> Void
    let onReturnedToBottom: () -> Void

    func makeNSView(context: Context) -> FollowerView {
        let view = FollowerView()
        view.configure(slack: slack, pinned: pinned, onScrolledAway: onScrolledAway, onReturnedToBottom: onReturnedToBottom)
        return view
    }

    func updateNSView(_ view: FollowerView, context: Context) {
        view.configure(slack: slack, pinned: pinned, onScrolledAway: onScrolledAway, onReturnedToBottom: onReturnedToBottom)
        view.attach()
    }

    final class FollowerView: NSView {
        private var slack: CGFloat = 4
        private var pinned: Bool = true
        private var onScrolledAway: (() -> Void)?
        private var onReturnedToBottom: (() -> Void)?

        private weak var scrollView: NSScrollView?
        private var clipObserver: NSObjectProtocol?
        private var docObserver: NSObjectProtocol?
        private var lastOriginY: CGFloat = 0
        private var lastAtBottom: Bool?
        private var pendingBottomSnap = false
        private var pendingBottomSnapWorkItem: DispatchWorkItem?
        private var lastBottomSnapAt: TimeInterval = 0
        private let minimumBottomSnapInterval: TimeInterval = 0.15

        func configure(slack: CGFloat, pinned: Bool, onScrolledAway: @escaping () -> Void, onReturnedToBottom: @escaping () -> Void) {
            self.slack = slack
            // SwiftUI @State is the source of truth; mirror it locally so a content-growth
            // notification arriving before the next updateNSView still makes the right call.
            self.pinned = pinned
            self.onScrolledAway = onScrolledAway
            self.onReturnedToBottom = onReturnedToBottom
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        deinit {
            if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
            if let docObserver { NotificationCenter.default.removeObserver(docObserver) }
            pendingBottomSnapWorkItem?.cancel()
        }

        func attach() {
            guard let scroll = enclosingScrollView else { return }
            guard scroll !== scrollView else { return }
            if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
            if let docObserver { NotificationCenter.default.removeObserver(docObserver) }
            scrollView = scroll
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            clipObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.handleScroll() }
            if let doc = scroll.documentView {
                doc.postsFrameChangedNotifications = true
                docObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: doc, queue: .main
                ) { [weak self] _ in self?.handleContentGrowth() }
            }
            lastOriginY = clip.bounds.origin.y
            handleScroll()
        }

        private func geometry() -> (origin: CGFloat, gap: CGFloat, atBottom: Bool)? {
            guard let scroll = scrollView, let doc = scroll.documentView else { return nil }
            let origin = scroll.contentView.bounds.origin.y
            let visible = scroll.contentView.bounds.height
            let content = doc.bounds.height
            let gap = content - (origin + visible)
            return (origin, gap, gap <= slack)
        }

        // The clip view moved. Reaching the bottom re-pins; origin dropping while still
        // away from the bottom is a genuine user scroll-up (content growth never lowers it).
        private func handleScroll() {
            guard let g = geometry() else { return }
            defer { lastOriginY = g.origin }
            switch ScrollPinPolicy.evaluate(originDelta: g.origin - lastOriginY, gap: g.gap, slack: slack) {
            case .reachedBottom:  report(atBottom: true)
            case .scrolledAway:   report(atBottom: false)
            case .unchanged:      break
            }
        }

        // The document grew/shrank (a streaming delta, a new row). While pinned, snap the
        // clip back to the true bottom now that layout has settled.
        private func handleContentGrowth() {
            guard let g = geometry() else { return }
            if pinned, g.gap > slack {
                scheduleScrollToBottom()
            } else if g.atBottom {
                report(atBottom: true)
            }
        }

        private func scheduleScrollToBottom() {
            guard !pendingBottomSnap else { return }
            pendingBottomSnap = true
            let now = ProcessInfo.processInfo.systemUptime
            let delay = max(0, minimumBottomSnapInterval - (now - lastBottomSnapAt))
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingBottomSnap = false
                self.pendingBottomSnapWorkItem = nil
                guard self.pinned, let g = self.geometry() else { return }
                if g.gap > self.slack {
                    self.scrollToBottom()
                } else if g.atBottom {
                    self.report(atBottom: true)
                }
            }
            pendingBottomSnapWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        private func scrollToBottom() {
            guard let scroll = scrollView, let doc = scroll.documentView else { return }
            let targetY = max(0, doc.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scroll.reflectScrolledClipView(scroll.contentView)
            lastOriginY = targetY
            lastBottomSnapAt = ProcessInfo.processInfo.systemUptime
        }

        private func report(atBottom: Bool) {
            guard atBottom != lastAtBottom else { return }
            lastAtBottom = atBottom
            pinned = atBottom
            if atBottom { onReturnedToBottom?() } else { onScrolledAway?() }
        }
    }
}

// PERF-MAC_AGENT-004: 1s cadence for the first minute, 5s after, so the
// "Working for Xs" row stops forcing a re-render every second on long runs.
private struct ElapsedTickSchedule: TimelineSchedule {
    let start: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        return AnyIterator {
            let current = next
            let elapsed = current.timeIntervalSince(start)
            let step: TimeInterval = elapsed < 60 ? 1 : 5
            next = current.addingTimeInterval(step)
            return current
        }
    }
}

/// Pure presentation rules for the composer account/source capsule.
/// Extracted so personal/work label, lock, and menu identity can be unit-tested
/// without mounting the Agent App surface.
public enum AgentSourceCapsulePresentation {
    public struct MenuEntry: Equatable, Sendable {
        public let id: String
        public let title: String
        public let isSelected: Bool

        public init(id: String, title: String, isSelected: Bool) {
            self.id = id
            self.title = title
            self.isSelected = isSelected
        }
    }

    /// True only when selecting a different account would take effect.
    /// Callers still open the capsule so locked / single-source states can
    /// explain themselves (fail loud). `runLocked` means an in-flight run —
    /// not "current provider cannot execute" (that must leave the menu usable
    /// so the user can switch to a working account).
    public static func isInteractive(
        enabledSourceCount: Int,
        providerLocked: Bool,
        runLocked: Bool
    ) -> Bool {
        enabledSourceCount > 1 && !providerLocked && !runLocked
    }

    /// Visible capsule label. Prefer configured displayName, then accountLabel,
    /// then provider/instance fallback. Never invent "Personal"/"Work" from paths.
    public static func capsuleLabel(
        selected: AgentProviderSnapshot?,
        fallbackProvider: AgentProvider,
        fallbackInstanceId: String,
        snapshots: [AgentProviderSnapshot]
    ) -> String {
        let base = primaryLabel(
            selected: selected,
            fallbackProvider: fallbackProvider,
            fallbackInstanceId: fallbackInstanceId
        )
        let enabled = snapshots.filter(\.enabled)
        guard enabled.count > 1 else { return base }
        let collisions = enabled.filter {
            primaryLabel(selected: $0, fallbackProvider: $0.provider, fallbackInstanceId: $0.id) == base
        }
        guard collisions.count > 1, let selected else { return base }
        let providerToken = selected.provider.rawValue.capitalized
        if base.localizedCaseInsensitiveContains(providerToken) {
            // Same provider + same display name → keep id so work/personal
            // clones remain distinguishable without guessing from HOME.
            return "\(base) · \(selected.id)"
        }
        return "\(providerToken) · \(base)"
    }

    public static func menuEntries(
        snapshots: [AgentProviderSnapshot],
        selectedSnapshotId: String?,
        selectedProvider: AgentProvider,
        providerDisplayName: (AgentProvider) -> String
    ) -> [MenuEntry] {
        if snapshots.isEmpty {
            return AgentProvider.allCases.map { provider in
                MenuEntry(
                    id: provider.rawValue,
                    title: providerDisplayName(provider),
                    isSelected: provider == selectedProvider
                )
            }
        }

        let enabled = snapshots.filter(\.enabled)
        // Always surface the currently selected snapshot even if disabled so
        // a locked/missing instance is not silently rewritten in the menu.
        var rows: [AgentProviderSnapshot] = enabled
        if let selectedSnapshotId,
           let selected = snapshots.first(where: { $0.id == selectedSnapshotId }),
           !rows.contains(where: { $0.id == selected.id }) {
            rows.append(selected)
        }

        // Pre-thread / single-instance hosts: if discovery only returned Codex,
        // still offer Claude and Grok so the Source capsule stays a real
        // switcher (not a dead one-item label). Prefer any known snapshot for
        // that provider; otherwise synthesize a provider-rawValue row.
        let covered = Set(rows.map(\.provider))
        for provider in AgentProvider.allCases where !covered.contains(provider) {
            if let any = snapshots.first(where: { $0.provider == provider }) {
                rows.append(any)
            }
        }

        var entries = rows.map { snapshot in
            let title = capsuleLabel(
                selected: snapshot,
                fallbackProvider: snapshot.provider,
                fallbackInstanceId: snapshot.id,
                snapshots: snapshots
            )
            return MenuEntry(
                id: snapshot.id,
                title: title,
                isSelected: snapshot.id == selectedSnapshotId
            )
        }

        let coveredAfter = Set(rows.map(\.provider))
        for provider in AgentProvider.allCases where !coveredAfter.contains(provider) {
            entries.append(MenuEntry(
                id: provider.rawValue,
                title: providerDisplayName(provider),
                isSelected: false
            ))
        }

        // If snapshot id did not match (stale "codex" vs "codex-cli"), mark
        // the first row for the selected provider so the menu shows a check.
        if !entries.contains(where: \.isSelected) {
            if let idx = entries.firstIndex(where: { entry in
                if let snap = rows.first(where: { $0.id == entry.id }) {
                    return snap.provider == selectedProvider
                }
                return entry.id == selectedProvider.rawValue
            }) {
                let e = entries[idx]
                entries[idx] = MenuEntry(id: e.id, title: e.title, isSelected: true)
            }
        }

        return entries
    }

    private static func primaryLabel(
        selected: AgentProviderSnapshot?,
        fallbackProvider: AgentProvider,
        fallbackInstanceId: String
    ) -> String {
        if let selected {
            let displayName = selected.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !displayName.isEmpty { return displayName }
            let account = selected.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !account.isEmpty { return account }
            return selected.provider.rawValue.capitalized
        }
        let instance = fallbackInstanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instance.isEmpty, instance != fallbackProvider.rawValue {
            return instance
        }
        return fallbackProvider.rawValue.capitalized
    }
}

enum AgentThreadRowPresentation {
    static func isRunning(threadStatus: AgentRunStatus, selected: Bool, surfaceStatus: AgentRunStatus) -> Bool {
        AgentThreadStopEligibility.isEligible(threadStatus: threadStatus)
            || (selected && AgentThreadStopEligibility.isEligible(threadStatus: surfaceStatus))
    }

    static func showsLeadingStatus(
        threadStatus: AgentRunStatus,
        selected: Bool,
        surfaceStatus: AgentRunStatus,
        hasUnread: Bool,
        pinned: Bool
    ) -> Bool {
        pinned || threadStatus == .failed || !hasUnread
            || isRunning(threadStatus: threadStatus, selected: selected, surfaceStatus: surfaceStatus)
    }

    static func showsSelectionCheck(
        threadStatus: AgentRunStatus,
        selected: Bool,
        surfaceStatus: AgentRunStatus,
        multiSelected: Bool
    ) -> Bool {
        multiSelected && !selected && !isRunning(threadStatus: threadStatus, selected: selected, surfaceStatus: surfaceStatus)
    }
}

/// Pure eligibility helper for per-thread stop affordances in the thread rail.
/// Determines whether a stop action is available for a given thread and, if so,
/// which threadId should be targeted. Extracted as a pure type so it can be
/// tested without touching any MainActor surface.
public enum AgentThreadStopEligibility {
    /// True while provider work is starting or running.
    public static func isEligible(threadStatus: AgentRunStatus) -> Bool {
        threadStatus == .pending || threadStatus == .running
    }

    /// Returns the threadId to target with stopThread(_:) when eligible, nil otherwise.
    public static func targetThreadId(thread: AgentThread) -> AgentThreadID? {
        isEligible(threadStatus: thread.status) ? thread.id : nil
    }
}

private struct AgentThreadDropDelegate: DropDelegate {
    let vm: AgentAppViewModel
    @Binding var draggingThreadId: AgentThreadID?
    let target: AgentThread

    func dropEntered(info: DropInfo) {
        guard let draggingThreadId, draggingThreadId != target.id else { return }
        vm.reorderThread(draggingThreadId, before: target.id)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingThreadId = nil
        return true
    }
}


@MainActor
public final class AgentAppSurface: NSObject, Surface {
    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    public let viewModel: AgentAppViewModel
    /// EventBus subscription so socket-driven thread mutations refresh
    /// this already-open surface (wired by AppCommandRouter, like Feed).
    public var subscriptionToken: AnyHashable?
    /// Called once by close() to release the EventBus subscription.
    /// Set by AppCommandRouter immediately after subscribe (mirrors Feed pattern).
    public var onClose: (() -> Void)?

    public init(workspaceID: WorkspaceID, cwd: String, coordinator: AgentRunCoordinator, threadRepo: AgentThreadRepository, messageRepo: AgentMessageRepository, draftRepo: AgentThreadDraftRepository? = nil, attachmentStore: AgentAttachmentStore? = nil, queuedMessageRepo: AgentQueuedMessageRepository? = nil, providerSessionRepo: ProviderSessionRuntimeRepository? = nil, pendingCallbackRepo: ProviderPendingCallbackRepository? = nil, proposedPlanRepo: AgentProposedPlanRepository? = nil, checkpointRepo: AgentTurnCheckpointRepository? = nil, promptHistoryStore: PromptHistoryStore? = nil, customModelStore: AgentCustomModelStore? = nil, planNotesStore: PlanNotesStore? = nil, title: String = "Agent App", initialThreadId: AgentThreadID? = nil, orchestrationRuntime: AgentOrchestrationRuntime = AgentOrchestrationRuntime()) {
        var metadata = ["workspace": workspaceID.value.uuidString, "cwd": cwd]
        if let initialThreadId { metadata["selected_thread"] = initialThreadId.value.uuidString }
        self.descriptor = SurfaceDescriptor(type: .agentApp, title: title, iconName: "sparkle", metadata: metadata)
        self.viewModel = AgentAppViewModel(workspaceID: workspaceID, cwd: cwd, coordinator: coordinator, threadRepo: threadRepo, messageRepo: messageRepo, draftRepo: draftRepo, attachmentStore: attachmentStore, queuedMessageRepo: queuedMessageRepo, providerSessionRepo: providerSessionRepo, pendingCallbackRepo: pendingCallbackRepo, proposedPlanRepo: proposedPlanRepo, checkpointRepo: checkpointRepo, promptHistoryStore: promptHistoryStore, customModelStore: customModelStore, planNotesStore: planNotesStore, initialThreadId: initialThreadId, initialRoutingMode: .auto, newThreadDefaultsStore: .shared, orchestrationRuntime: orchestrationRuntime)
        let host = NSHostingView(rootView: AgentAppView(vm: viewModel))
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        self.view = container
        super.init()
    }

    public func focus() {
        viewModel.focusTick &+= 1
        view.window?.makeFirstResponder(view)
    }
    public func unfocus() {}
    public func close() {
        // Drop coordinator fan-out + heavy transcript state before unregister.
        // Multi-tab freezes were amplified by closed surfaces still buffering
        // stream events until ARC collected the weak observer.
        viewModel.dispose()
        onClose?()
        onClose = nil
    }
    public func sendText(_ text: String) {
        viewModel.prompt = (viewModel.prompt.isEmpty ? text : viewModel.prompt + "\n" + text)
    }
    public func readText() -> String {
        viewModel.messages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
    }
    public func snapshot() -> [String: String] {
        ["selected_thread": viewModel.selectedThreadId?.value.uuidString ?? "",
         "provider": viewModel.provider.rawValue,
         "model": viewModel.model]
    }

    // A3: drives the tab/workspace spinner.
    public var isBusy: Bool { viewModel.hasRunningWorkForChrome }
}

// Pure keyboard-navigation helper for the thread rail.
// Non-MainActor + pure so the movement math is testable without any UI.
//
// moveThreadSelection(current:direction:count:)
//   direction: +1 = down, -1 = up.
//   Returns nil when count == 0 (empty rail -- no movement, no crash).
//   Clamps result to 0..<count so callers never receive an out-of-range index.
//   nil current with count > 0 returns 0 (first row) regardless of direction.
enum AgentThreadRailKeyboardNav {
    static func moveThreadSelection(current: Int?, direction: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let idx = current else { return 0 }
        return max(0, min(count - 1, idx + direction))
    }
}

private struct TabColorMenuLabel: View {
    let title: String
    let swatchImage: NSImage

    init(_ color: TabColor) {
        self.title = color.label
        self.swatchImage = Self.swatchImage(hex: color.hex)
    }

    private init(title: String, swatchImage: NSImage) {
        self.title = title
        self.swatchImage = swatchImage
    }

    static var none: TabColorMenuLabel {
        TabColorMenuLabel(title: "None", swatchImage: noneSwatchImage())
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: swatchImage)
                .renderingMode(.original)
        }
    }

    private static func swatchImage(hex: UInt32) -> NSImage {
        menuImage { rect in
            let path = NSBezierPath(
                roundedRect: rect.insetBy(dx: 2, dy: 2),
                xRadius: 3,
                yRadius: 3
            )
            NSColor(hex: hex).setFill()
            path.fill()
            DS.NS.lineStrong.withAlphaComponent(0.75).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private static func noneSwatchImage() -> NSImage {
        menuImage { rect in
            let box = NSBezierPath(
                roundedRect: rect.insetBy(dx: 2, dy: 2),
                xRadius: 3,
                yRadius: 3
            )
            DS.NS.textTertiary.withAlphaComponent(0.9).setStroke()
            box.lineWidth = 1
            box.stroke()

            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 4, y: rect.minY + 4))
            slash.line(to: NSPoint(x: rect.maxX - 4, y: rect.maxY - 4))
            slash.lineWidth = 1.25
            slash.stroke()
        }
    }

    private static func menuImage(draw: @escaping (NSRect) -> Void) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = false
        return image
    }
}

// F34: effort semantics are non-obvious — especially "Ultracode" vs "Max" vs
// "Extra High" — so the picker rows carry tooltips that spell out what each
// level buys (and costs) before the user commits to it. Ultracode is not a
// plain effort value: it is xhigh effort plus standing workflow orchestration
// (see AgentReasoningEffort.claudeSupportedCases).
extension AgentReasoningEffort {
    var pickerHelpText: String {
        switch self {
        case .minimal: return "Fastest — minimal reasoning"
        case .low: return "Light reasoning for simple tasks"
        case .medium: return "Balanced reasoning (default)"
        case .high: return "Deeper reasoning for harder tasks"
        case .xhigh: return "Very deep reasoning for hard problems"
        case .max: return "Deepest reasoning the model supports — slowest, most tokens"
        case .ultracode: return "Extra High effort + autonomous workflow orchestration"
        }
    }
}

// MARK: - Clickable transcript mentions (UX-MAC_AGENT-OPEN-SPLIT)
// File paths and links mentioned in transcript prose (and tool rows) are tappable.
// The VM resolves the raw mention against the thread's working directory and hands
// an absolute path / URL to the router callbacks, which open (or reuse) a split
// panel to the right of the surface.
extension AgentAppViewModel {
    /// Routes a tapped transcript link. Returns true when handled here (file
    /// mention or web link); false lets the system handler take over.
    @discardableResult
    public func handleTranscriptLink(_ url: URL) -> Bool {
        if let raw = AgentMessageMarkdown.filePath(fromFileLink: url) {
            openFileMention(raw)
            return true
        }
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "http", "https":
            openLinkMention(url)
            return true
        case "file":
            openFileMention(url.path)
            return true
        case "":
            // Markdown relative targets (`[plan](./plan)`) parse with no scheme.
            // Treat path-shaped tokens as file mentions so they open the Files split
            // the same way auto-detected `./plan` links do.
            if let raw = Self.relativeFileMentionToken(from: url),
               Self.isPathShapedFileMention(raw) {
                openFileMention(raw)
                return true
            }
            return false
        default:
            return false
        }
    }

    /// Best-effort path token from a scheme-less / relative markdown URL.
    nonisolated static func relativeFileMentionToken(from url: URL) -> String? {
        if let raw = AgentMessageMarkdown.filePath(fromFileLink: url) { return raw }
        let candidates = [url.relativeString, url.absoluteString, url.path]
        for c in candidates {
            let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t != "/", !t.hasPrefix("http://"), !t.hasPrefix("https://") else { continue }
            // Strip accidental percent-encoding from markdown-produced URLs.
            let decoded = t.removingPercentEncoding ?? t
            if isPathShapedFileMention(decoded) { return decoded }
        }
        return nil
    }

    public func openLinkMention(_ url: URL) {
        if let onOpenURLInSplit {
            onOpenURLInSplit(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    public func openFileMention(_ raw: String) {
        guard let resolved = Self.resolveFileMention(raw, root: worktreePath ?? cwd) else {
            NSSound.beep()
            return
        }
        if let onOpenFileInSplit {
            onOpenFileInSplit(resolved)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: resolved))
        }
    }

    /// Path-shaped mention (`./plan`, `../x`, `/abs`, `foo/bar`) vs bare filename.
    /// Path shapes may open Files at the workspace root when the leaf is missing;
    /// bare filenames must not (too ambiguous).
    nonisolated static func isPathShapedFileMention(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.hasPrefix("/") || t.hasPrefix("~") || t.hasPrefix(".") { return true }
        return t.contains("/")
    }

    /// Resolves a raw file mention to an existing absolute path: strips a
    /// `:line(:col)` suffix, expands `~`, resolves relative tokens against `root`,
    /// falls back to a bounded workspace search for bare filenames, then to the
    /// nearest existing ancestor directory (a mention of a since-deleted file still
    /// lands near it). Path-shaped mentions may land on the workspace root so
    /// `./plan` opens the Files split even before the file exists. nil when
    /// nothing on disk plausibly matches.
    nonisolated static func resolveFileMention(_ raw: String, root: String, fileManager: FileManager = .default) -> String? {
        let token = strippingLineSuffix(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !token.isEmpty else { return nil }
        let expanded = (token as NSString).expandingTildeInPath
        let candidate: String
        if expanded.hasPrefix("/") {
            candidate = (expanded as NSString).standardizingPath
        } else {
            candidate = ((root as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
        }
        if fileManager.fileExists(atPath: candidate) { return candidate }
        if !token.contains("/"), let hit = searchWorkspace(filename: token, root: root, fileManager: fileManager) {
            return hit
        }
        // Nearest existing ancestor. Bare filenames must not degrade to the
        // workspace root. Single-segment path shapes (`./plan`) may open the root
        // so planned deliverables still open the Files split before they exist.
        // Deep nonsense paths (`nowhere/at/all.xyz`) still refuse.
        let standardizedRoot = (root as NSString).standardizingPath
        let allowsRootFallback = Self.allowsWorkspaceRootFallback(forCandidate: candidate, root: standardizedRoot)
        var dir = candidate
        while dir.count > 1 {
            dir = (dir as NSString).deletingLastPathComponent
            if dir.isEmpty || dir == "/" { return nil }
            if dir == standardizedRoot {
                if allowsRootFallback, fileManager.fileExists(atPath: dir) { return dir }
                return nil
            }
            if fileManager.fileExists(atPath: dir) { return dir }
        }
        return nil
    }

    /// `./plan` / `plan.html` (one leaf under root) may open Files at the workspace
    /// root when missing. Multi-segment missing trees do not.
    nonisolated static func allowsWorkspaceRootFallback(forCandidate candidate: String, root: String) -> Bool {
        let standardizedRoot = (root as NSString).standardizingPath
        let standardizedCandidate = (candidate as NSString).standardizingPath
        guard standardizedCandidate.hasPrefix(standardizedRoot + "/") else { return false }
        let relative = String(standardizedCandidate.dropFirst(standardizedRoot.count + 1))
        let parts = relative.split(separator: "/").filter { $0 != "." && !$0.isEmpty }
        return parts.count == 1
    }

    /// "path.swift:12" / "path.swift:12:5" → "path.swift". Only digit-only
    /// trailing segments are stripped, so "http://host:8080" shapes are safe.
    nonisolated static func strippingLineSuffix(_ token: String) -> String {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return token }
        var end = parts.count
        while end > 1, !parts[end - 1].isEmpty, parts[end - 1].allSatisfy(\.isNumber) { end -= 1 }
        return parts[0..<end].joined(separator: ":")
    }

    /// Bounded search for a bare filename mention ("Reducer.swift") under the
    /// workspace root. Skips hidden directories and common dependency/build dirs;
    /// caps visited entries so a huge tree cannot stall the click.
    nonisolated static func searchWorkspace(filename: String, root: String, fileManager: FileManager = .default, visitLimit: Int = 25_000) -> String? {
        let skippedDirectories: Set<String> = ["node_modules", "DerivedData", "Pods", "dist", "build", "target", "vendor"]
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return nil }
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > visitLimit { return nil }
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory, name.hasPrefix(".") || skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            // standardizingPath: the enumerator yields /private/var/... forms for
            // symlinked roots; callers compare against the standardized root.
            if name == filename { return (url.path as NSString).standardizingPath }
        }
        return nil
    }
}
