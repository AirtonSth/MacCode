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
    @Published public var model: String = "gpt-5.5"
    @Published public var availableModels: [AgentModelDescriptor] = []
    @Published public var providerSnapshots: [AgentProviderSnapshot] = []
    @Published public var permissionMode: AgentPermissionMode = .supervised
    @Published public var reasoningEffort: AgentReasoningEffort = .medium
    @Published public var serviceTier: AgentServiceTier = .auto
    @Published public var executionMode: AgentExecutionMode = .local
    @Published public var baseBranch: String = ""
    @Published public var worktreePath: String?
    @Published public private(set) var customModelsByProvider: [AgentProvider: [String]] = [:]
    @Published public var status: AgentRunStatus = .pending
    @Published public var statusMessage: String = ""
    @Published public var currentRunId: AgentRunID?
    @Published public var hasUnreadActivity: Bool = false
    @Published public var showPlanSidebar: Bool = false
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
    @Published public var editingQueuedMessage: AgentQueuedMessage?
    @Published public var queuedMessageDraft: String = ""
    /// When the active run started — drives the "Working for Xs" line.
    @Published public var runStartedAt: Date?
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

    public let workspaceID: WorkspaceID
    public let cwd: String
    public let coordinator: AgentRunCoordinator
    public let threadRepo: AgentThreadRepository
    public let messageRepo: AgentMessageRepository
    public let draftRepo: AgentThreadDraftRepository?
    public let attachmentStore: AgentAttachmentStore?
    public let queuedMessageRepo: AgentQueuedMessageRepository?
    public let pendingCallbackRepo: ProviderPendingCallbackRepository?
    public let proposedPlanRepo: AgentProposedPlanRepository?
    public let checkpointRepo: AgentTurnCheckpointRepository?
    public let promptHistoryStore: PromptHistoryStore?
    public let customModelStore: AgentCustomModelStore?
    public let planNotesStore: PlanNotesStore?
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

    // PERF-MAC_AGENT-010: batch streaming events into one main-actor hop per
    // tick. Fast token streams produce thousands of events/sec; without batching
    // every event allocates an independent Task, each of which pays the Swift
    // concurrency scheduler overhead. Accumulate events here (protected by a
    // lock for nonisolated callers) and drain the whole buffer in one hop when
    // the first event of each tick schedules the flush Task.
    private let streamEventBatch = StreamEventBatch()

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
        pendingCallbackRepo: ProviderPendingCallbackRepository? = nil,
        proposedPlanRepo: AgentProposedPlanRepository? = nil,
        checkpointRepo: AgentTurnCheckpointRepository? = nil,
        promptHistoryStore: PromptHistoryStore? = nil,
        customModelStore: AgentCustomModelStore? = nil,
        planNotesStore: PlanNotesStore? = nil,
        initialThreadId: AgentThreadID? = nil
    ) {
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.coordinator = coordinator
        self.threadRepo = threadRepo
        self.messageRepo = messageRepo
        self.draftRepo = draftRepo
        self.attachmentStore = attachmentStore
        self.queuedMessageRepo = queuedMessageRepo
        self.pendingCallbackRepo = pendingCallbackRepo
        self.proposedPlanRepo = proposedPlanRepo
        self.checkpointRepo = checkpointRepo
        self.promptHistoryStore = promptHistoryStore
        self.customModelStore = customModelStore
        self.planNotesStore = planNotesStore
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
        reloadThreads()
        // Per-surface thread binding: select ONLY the thread this surface was
        // restored/created with. A brand-new tab passes nil and stays on the
        // fresh-composer state instead of auto-adopting the workspace's first
        // thread (the new-tab-clone bug). onSelectedThreadChanged is wired by
        // the host *after* init, so this restore-time select does not re-persist.
        if let initialThreadId, threads.contains(where: { $0.id == initialThreadId }) {
            selectThread(initialThreadId)
        }
        loadGitBranch()
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

    public func reloadThreads() {
        do {
            threads = try threadRepo.list(workspaceId: workspaceID)
        } catch {
            statusMessage = "Could not reload threads: \(error)"
            return
        }
        // PERF-MAC_AGENT-009: refresh the thread->workspace cache so didChangeStatus
        // can filter by workspace with an O(1) lookup instead of a DB read.
        for t in threads {
            if let wid = t.workspaceId {
                threadWorkspaceCache[t.id] = wid
            }
        }
        repairPlaceholderThreadTitles()
        // reloadThreads() is a PURE data reload — it must not change the
        // selection. A new/empty tab stays thread-free (fresh composer) instead
        // of auto-adopting threads.first (the new-tab-clone bug). The only
        // selection mutation here is the safe deletion-recovery below.
        if let sel = selectedThreadId, !threads.contains(where: { $0.id == sel }) {
            // The bound thread was deleted (e.g. from another client). Fall back
            // to the fresh-composer state rather than render a dangling selection.
            selectedThreadId = nil
            onSelectedThreadChanged?(nil)
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

    public func selectThread(_ id: AgentThreadID, markRead: Bool = true) {
        let isThreadSwitch = selectedThreadId != id
        if isThreadSwitch {
            // IMP-MAC_AGENT-011: stash the leaving thread's draft before swapping,
            // then restore the opened thread's draft (an in-progress prompt on a
            // re-select of the same thread is left untouched).
            if let previous = selectedThreadId { persistComposerDraft(for: previous) }
            selectedThreadId = id
            providerThreadSnapshotStatusMessage = nil
            providerThreadSnapshotLastConfirmedAt = providerThreadSnapshotConfirmedAtByThread[id]
            // F6: the SR1 translation maps are per-thread state. Reset them on a
            // thread switch so they don't accumulate the union of every translated
            // message (and its full original text) across every thread visited this
            // session. refreshSR1TranslationStateFromTimeline() below rebuilds them
            // from the opened thread's replayed timeline.
            sr1TranslatedMessageIds = []
            sr1OriginalTextsByMessageId = [:]
        } else {
            selectedThreadId = id
        }
        // Persist the per-surface binding so app restart restores THIS surface
        // to THIS thread (not threads.first). Only fires on an actual change;
        // wired by the host after init, so restore-time selects don't re-persist.
        if isThreadSwitch { onSelectedThreadChanged?(id) }
        reloadQueuedMessages()
        if let t = threads.first(where: { $0.id == id }) {
            provider = t.provider
            providerInstanceId = t.providerInstanceId ?? t.provider.rawValue
            model = t.model
            permissionMode = t.permissionMode
            reasoningEffort = t.reasoningEffort
            serviceTier = t.serviceTier
            executionMode = t.executionMode
            baseBranch = t.baseBranch ?? gitBranch ?? "main"
            worktreePath = t.worktreePath
            status = t.status
            if isThreadSwitch { restoreComposerDraft(for: t) }
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
            } else {
                currentRunId = nil
                runStartedAt = nil
            }
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
        let persistedEvents = coordinator.latestStreamEvents(threadId: id)
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
        lastErrorRecoverable = Self.displayedErrorIsRecoverable(in: persistedReplay)
        refreshSR1TranslationStateFromTimeline()
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
                self.lastErrorRecoverable = Self.displayedErrorIsRecoverable(in: replayEvents)
                self.refreshSR1TranslationStateFromTimeline()
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
            return
        }
        queuedMessages = (try? queuedMessageRepo.list(threadId: selectedThreadId)) ?? []
        if let head = queuedMessages.first,
           (try? queuedMessageRepo.dispatch(id: head.id)?.state) == .prepared {
            queueStatusMessage = "Start confirmation is pending. The message was not replayed."
        }
    }

    public func editQueuedMessage(_ message: AgentQueuedMessage) {
        editingQueuedMessage = message
        queuedMessageDraft = message.text
        queueStatusMessage = nil
    }

    public func saveQueuedMessageEdit() {
        guard let editingQueuedMessage, let queuedMessageRepo else { return }
        let text = queuedMessageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !editingQueuedMessage.attachments.isEmpty else { return }
        do {
            if let updated = try queuedMessageRepo.update(id: editingQueuedMessage.id, text: text, attachments: editingQueuedMessage.attachments) {
                queueStatusMessage = nil
                self.editingQueuedMessage = nil
                queuedMessageDraft = ""
                reloadQueuedMessages()
                onQueuedMessageEvent?(AgentQueueEventKinds.updated, updated)
            } else {
                queueStatusMessage = "Already processing."
                self.editingQueuedMessage = nil
                queuedMessageDraft = ""
                reloadQueuedMessages()
            }
        } catch {
            queueStatusMessage = "Queue edit failed: \(error)"
        }
    }

    public func forceQueuedMessageNow(_ message: AgentQueuedMessage) async {
        guard let queuedMessageRepo else { return }
        var claimedLease: AgentQueuedMessageLease?
        var preparedDispatch: (lease: AgentQueuedMessageLease, runId: AgentRunID)?
        var providerStartConfirmed = false
        do {
            if selectedThreadCanQueuePrompt {
                guard try queuedMessageRepo.promoteToFront(id: message.id) != nil else {
                    queueStatusMessage = "Already processing."
                    reloadQueuedMessages()
                    return
                }
                queueStatusMessage = "Stopping current run to start this now."
                reloadQueuedMessages()
                for queued in queuedMessages {
                    onQueuedMessageEvent?(AgentQueueEventKinds.updated, queued)
                }
                // Force = run now: interrupt the in-flight turn so the just-promoted
                // front-of-queue message starts immediately via the run-finished
                // drain (AppContext.onRunFinished -> drainNextQueuedAgentMessage).
                // The cancel resolves to .cancelled, which is drain-eligible.
                coordinator.stopRun(threadId: message.threadId)
                return
            }
            if let dispatch = try queuedMessageRepo.dispatch(id: message.id) {
                if dispatch.state == .prepared, let runId = dispatch.runId {
                    if try coordinator.runStatus(runId) != nil {
                        guard let drained = try queuedMessageRepo.acknowledgePreparedWithRunEvidence(id: message.id, runId: runId) else {
                            queueStatusMessage = "Queue recovery is already being reconciled."
                            reloadQueuedMessages()
                            return
                        }
                        queueStatusMessage = nil
                        reloadQueuedMessages()
                        onQueuedMessageEvent?(AgentQueueEventKinds.drained, drained)
                        return
                    }
                    reloadQueuedMessages()
                    queueStatusMessage = "Already processing. Relaunch recovery will reconcile this message if startup was interrupted."
                    return
                }
                if dispatch.state == .dispatched, let runId = dispatch.runId {
                    guard let drained = try queuedMessageRepo.acknowledgeDispatched(id: message.id, runId: runId) else {
                        queueStatusMessage = "Queue acknowledgement is already being recovered."
                        reloadQueuedMessages()
                        return
                    }
                    queueStatusMessage = nil
                    reloadQueuedMessages()
                    onQueuedMessageEvent?(AgentQueueEventKinds.drained, drained)
                    for remaining in queuedMessages {
                        onQueuedMessageEvent?(AgentQueueEventKinds.updated, remaining)
                    }
                    return
                }
            }
            guard let lease = try queuedMessageRepo.claim(id: message.id) else {
                queueStatusMessage = "Already processing."
                reloadQueuedMessages()
                return
            }
            claimedLease = lease
            let queued = lease.message
            let dispatchRunId = AgentRunID(queued.id.value)
            guard try queuedMessageRepo.prepareDispatch(lease, runId: dispatchRunId) else {
                _ = try? queuedMessageRepo.release(lease)
                claimedLease = nil
                queueStatusMessage = "Already processing."
                reloadQueuedMessages()
                return
            }
            preparedDispatch = (lease, dispatchRunId)
            let runId = await startProviderRun(
                text: queued.text,
                attached: queued.attachments,
                recordHistory: false,
                interactionMode: queued.interactionMode,
                requestedRunId: dispatchRunId
            )
            guard runId != nil else {
                if (try? coordinator.runStatus(dispatchRunId)) != nil {
                    if let drained = try queuedMessageRepo.acknowledgePreparedWithRunEvidence(
                        id: queued.id,
                        runId: dispatchRunId
                    ) {
                        onQueuedMessageEvent?(AgentQueueEventKinds.drained, drained)
                    }
                } else {
                    _ = try queuedMessageRepo.releasePrepared(lease, runId: dispatchRunId)
                }
                claimedLease = nil
                preparedDispatch = nil
                reloadQueuedMessages()
                return
            }
            providerStartConfirmed = true
            guard try queuedMessageRepo.markDispatched(lease, runId: dispatchRunId) else {
                queueStatusMessage = "Provider started; queue acknowledgement needs recovery."
                reloadQueuedMessages()
                return
            }
            guard let drained = try queuedMessageRepo.acknowledge(lease) else {
                queueStatusMessage = "Provider started; queue acknowledgement needs recovery."
                reloadQueuedMessages()
                return
            }
            claimedLease = nil
            preparedDispatch = nil
            if editingQueuedMessage?.id == message.id {
                editingQueuedMessage = nil
                queuedMessageDraft = ""
            }
            queueStatusMessage = nil
            reloadQueuedMessages()
            onQueuedMessageEvent?(AgentQueueEventKinds.drained, drained)
            for remaining in queuedMessages {
                onQueuedMessageEvent?(AgentQueueEventKinds.updated, remaining)
            }
        } catch {
            if let preparedDispatch, !providerStartConfirmed {
                if (try? coordinator.runStatus(preparedDispatch.runId)) != nil {
                    if let drained = try? queuedMessageRepo.acknowledgePreparedWithRunEvidence(
                        id: preparedDispatch.lease.message.id,
                        runId: preparedDispatch.runId
                    ) {
                        onQueuedMessageEvent?(AgentQueueEventKinds.drained, drained)
                    }
                } else {
                    _ = try? queuedMessageRepo.releasePrepared(preparedDispatch.lease, runId: preparedDispatch.runId)
                }
                reloadQueuedMessages()
            } else if let claimedLease, preparedDispatch == nil {
                _ = try? queuedMessageRepo.release(claimedLease)
                reloadQueuedMessages()
            }
            queueStatusMessage = "Queue force failed: \(error)"
        }
    }

    public func cancelQueuedMessage(_ message: AgentQueuedMessage) {
        guard let queuedMessageRepo else { return }
        do {
            if let cancelled = try queuedMessageRepo.delete(id: message.id) {
                if editingQueuedMessage?.id == message.id {
                    editingQueuedMessage = nil
                    queuedMessageDraft = ""
                }
                reloadQueuedMessages()
                onQueuedMessageEvent?(AgentQueueEventKinds.cancelled, cancelled)
            } else {
                queueStatusMessage = "Already processing."
                reloadQueuedMessages()
            }
        } catch {
            queueStatusMessage = "Queue cancel failed: \(error)"
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
            queueStatusMessage = "Queue reorder failed: \(error)"
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

    // MARK: Full-thread message history
    //
    // The transcript loads EVERY message in the thread up front — no infinite-scroll
    // paging, no off-screen body eviction. The old viewport window paged 30 rows at a
    // time and evicted off-screen bodies on scroll; hydrate/evict flips a row's height
    // mid-scroll, which is exactly what made auto-scroll jump around (the reported bug).
    // Render/CPU stays bounded because the LazyVStack only realizes on-screen rows, the
    // transcript signature is O(turns) (not O(messages)), and a memory safety-valve
    // blanks the oldest bodies on a pathological thread so a full load can't blow up RAM.
    nonisolated static let fullLoadBodyBudgetBytes = 24 * 1024 * 1024  // ~24 MB of transcript text

    private func loadAllMessages(_ id: AgentThreadID) {
        // F5: this read intentionally stays on the main actor. SQLiteDB serialises the
        // C connection (FULLMUTEX), but its Swift statement cache is only safe when all
        // access shares ONE concurrency domain (see SQLite.prepare) — this app keeps
        // that domain on the main actor, so dispatching this read to a background queue
        // would race the statement cache against concurrent main-actor DB access. The
        // full (unpaged) load is deliberate for scroll stability (see above); the work
        // that scaled with thread length was the per-row cost, cut by the utf8 fast path
        // (F11) and the single-pass cap+budget below.
        let loaded = try? messageRepo.listWithinBodyBudget(
            threadId: id,
            budget: Self.fullLoadBodyBudgetBytes,
            contentLimit: AssistantTimelineState.liveTextLimit
        )
        let raw = loaded?.rows ?? []
        let (rows, additionalBlanked) = Self.cappedRowsWithinBudget(raw)
        let blanked = (loaded?.blanked ?? 0) + additionalBlanked
        if blanked > 0 {
            // Fail loud: a thread big enough to trip the budget loses its oldest bodies.
            NSLog("[AgentApp] full-load body budget tripped: blanked \(blanked)/\(raw.count) oldest message bodies to stay under \(Self.fullLoadBodyBudgetBytes) bytes")
        }
        messages = rows
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

    /// Chrome should spin only for work the coordinator/repository still sees
    /// as running. A stale local status must not keep tab/sidebar chrome busy.
    public var hasRunningWorkForChrome: Bool {
        threads.contains { isThreadStartingOrRunning($0.id) }
    }

    /// UX-MAC_AGENT-BG-AWAIT: the most recent final answer for the selected
    /// thread, used to detect a background-await stall for the status badge /
    /// Continue affordance. Prefers the live timeline's last turn, falling back to
    /// the last persisted assistant message after a reload.
    public var latestFinalAssistantMessage: String? {
        if let final = timeline.turns.last?.finalAssistantMessage, !final.isEmpty { return final }
        return messages.last(where: { $0.role == .assistant })?.content
    }

    /// UX-MAC_AGENT-BG-AWAIT: true when the selected thread finished while the
    /// agent was still waiting on a background job it launched (e.g. "Standing by
    /// for the demo recording to complete."). Surfaced as an "awaiting" badge plus
    /// a Continue button instead of a misleading green "completed".
    public var isAwaitingBackgroundWork: Bool {
        status == .completed
            && BackgroundAwaitContinuation.isAwaitingBackgroundWork(latestFinalAssistantMessage)
    }

    /// P2: threads visible in the rail after applying the search query.
    /// Empty query returns all threads (no filtering).
    public var filteredThreads: [AgentThread] {
        AgentAppViewModel.filterThreads(threads, query: threadSearchQuery)
    }

    /// Pure helper: returns threads whose title or model contains `query`,
    /// case-insensitively. Empty query keeps all threads.
    nonisolated public static func filterThreads(_ threads: [AgentThread], query: String) -> [AgentThread] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return threads }
        return threads.filter {
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

    public func loadProviderSnapshots() async {
        do {
            let snapshots: [AgentProviderSnapshot]
            if let providerSnapshotLoader {
                snapshots = try await providerSnapshotLoader()
            } else {
                var local: [AgentProviderSnapshot] = []
                for provider in AgentProvider.allCases {
                    let runner: AgentProviderRunner = provider == .codex ? CodexRunner() : ClaudeRunner()
                    local.append(AgentProviderSnapshotFactory.snapshot(
                        provider: provider,
                        models: await runner.listModels(),
                        binaryPath: ProcessLocator.resolve(provider.rawValue) ?? ""
                    ))
                }
                snapshots = local
            }
            await MainActor.run {
                self.providerSnapshotStatusMessage = nil
                self.applyProviderSnapshots(snapshots)
            }
        } catch {
            await MainActor.run {
                self.providerSnapshotStatusMessage = "Provider snapshot failed. Retry from the model menu."
            }
        }
    }

    private func applyProviderSnapshots(_ snapshots: [AgentProviderSnapshot]) {
        providerSnapshots = snapshots
        // Always bind providerInstanceId to a real snapshot id. Threads often
        // store "codex" while snapshots use "codex-cli"; without remapping the
        // Source menu never shows a checkmark (selected: id == providerInstanceId).
        if snapshots.first(where: { $0.id == providerInstanceId }) == nil {
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
            if !modelSelectionIsValid(model, in: current.models) {
                // F9: never silently swap a pinned model for the snapshot's
                // first alias — a fallback snapshot may simply omit a
                // live-discovered model. Fill only an empty selection (post
                // provider switch) or evict an id from another provider; a
                // kept-but-missing pin is explained by
                // selectedModelUnavailableNotice in the picker.
                if model.isEmpty || modelIsFromAnotherProvider(model) {
                    model = current.models.first?.id ?? model
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
        await loadProviderSnapshots()
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
            let codexModels = await CodexRunner().listModels()
            let fallback = [
                AgentProviderSnapshotFactory.snapshot(provider: .codex, models: codexModels, binaryPath: ""),
                AgentProviderSnapshotFactory.snapshot(provider: .claude, models: ClaudeRunner.listModels(installedVersion: nil), binaryPath: ""),
                AgentProviderSnapshotFactory.snapshot(provider: .grok, models: GrokRunner.listModels(installedVersion: nil), binaryPath: "")
            ]
            await MainActor.run {
                guard self.providerSnapshots.isEmpty else { return }
                self.applyProviderSnapshots(fallback)
            }
        }
    }

    public var selectedProviderSnapshot: AgentProviderSnapshot? {
        providerSnapshots.first { $0.id == providerInstanceId }
            ?? providerSnapshots.first { $0.provider == provider }
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
        guard let snapshot else { return nil }
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

    public var composerSuggestions: [AgentComposerSuggestion] {
        AgentComposerSuggestions.suggestions(
            for: prompt,
            cursorOffset: composerCursorOffset,
            snapshot: selectedProviderSnapshot,
            localSlashCommands: Self.localSlashCommands
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
        return snapshot.statusDetail ?? "\(snapshot.displayName) is \(snapshot.status.rawValue)."
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

    /// A fresh thread also uses `.pending` as its persisted idle state. A Stop
    /// affordance therefore needs a run identity, not status alone; otherwise a
    /// never-started thread is rendered as busy and its first prompt is queued.
    public func isThreadStartingOrRunning(_ threadId: AgentThreadID) -> Bool {
        trackedRunId(for: threadId) != nil
    }

    private func trackedRunId(for threadId: AgentThreadID) -> AgentRunID? {
        runThreads.first(where: { $0.value == threadId })?.key
            ?? coordinator.activeRunId(threadId: threadId)
    }
    public var executionLocked: Bool { providerLocked || selectedThreadRunIsStartingOrRunning }
    public var activeRunConfigurationLocked: Bool {
        selectedThreadRunIsStartingOrRunning
            || selectedThreadId.map { coordinator.activeThreadIdsSnapshot().contains($0) } == true
    }

    public func setProviderInstance(_ id: String) {
        guard !executionLocked else { return }
        guard let snapshot = providerSnapshots.first(where: { $0.id == id }) else { return }
        providerInstanceId = snapshot.id
        provider = snapshot.provider
        // F10/F33: same flag coherence as applyProviderSnapshots — snapshot
        // rows replace the VM's own fetch, so a stale fallback flag must not
        // put a false "built-in defaults" warning on the new instance's list.
        if availableModelsAreFallback {
            availableModelsAreFallback = snapshot.models.map(\.id) == availableModels.map(\.id)
        }
        availableModels = snapshot.models
        if !modelSelectionIsValid(model, in: snapshot.models) {
            model = snapshot.models.first?.id ?? model
        }
        normalizeSelectedModelOptions()
        normalizeInteractionModeForSelectedProvider()
        persistThreadConfig()
    }

    public func setProvider(_ newProvider: AgentProvider) {
        guard !executionLocked else { return }
        if let selectedThreadId { persistComposerDraft(for: selectedThreadId) }
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
            model = snap.models.first?.id ?? ""
        } else {
            providerInstanceId = newProvider.rawValue
            availableModels = []
            model = ""
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
        guard let id = selectedThreadId else { return false }
        do {
            guard let stored = try threadRepo.get(id: id) else {
                statusMessage = "Could not save thread configuration: thread not found."
                return false
            }
            var updated = stored
            updated.provider = provider
            updated.providerInstanceId = providerInstanceId
            updated.model = model
            updated.permissionMode = permissionMode
            updated.reasoningEffort = reasoningEffort
            updated.serviceTier = serviceTier
            updated.modelSelection = currentModelSelection
            updated.interactionMode = interactionMode
            updated.updatedAt = Date()
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

    private func restoreThreadConfiguration(from thread: AgentThread) {
        provider = thread.provider
        providerInstanceId = thread.providerInstanceId ?? thread.provider.rawValue
        model = thread.model
        permissionMode = thread.permissionMode
        reasoningEffort = thread.reasoningEffort
        serviceTier = thread.serviceTier
        interactionMode = thread.effectiveInteractionMode
        normalizeInteractionModeForSelectedProvider()
        if let i = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[i] = thread
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
        model = trimmed.isEmpty ? (modelOptionsForSelectedProvider.first?.id ?? "") : trimmed
        normalizeSelectedModelOptions()
        persistThreadConfig()
    }

    public func createThread(title: String) {
        normalizeSelectedModelOptions()
        let t = AgentThread(workspaceId: workspaceID, title: title, provider: provider,
                            providerInstanceId: providerInstanceId,
                            model: model,
                            permissionMode: permissionMode, reasoningEffort: reasoningEffort,
                            executionMode: executionMode,
                            baseBranch: executionMode == .worktree ? (baseBranch.isEmpty ? (gitBranch ?? "main") : baseBranch) : nil,
                            serviceTier: serviceTier, modelSelection: currentModelSelection)
        do {
            try threadRepo.upsert(t)
        } catch {
            statusMessage = "Could not create thread: \(error)"
            return
        }
        reloadThreads()
        onThreadLifecycle?(.created(threads.first(where: { $0.id == t.id }) ?? t))
        selectThread(t.id)
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
        // AG-002: a thread row owns the provider lifecycle. Do not cascade-delete
        // its data or evict UI caches until every selected provider has confirmed
        // terminal state and its process tree is dead.
        do {
            for id in ids {
                try await coordinator.stopAndAwaitTermination(threadId: id)
            }
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
        timeline = AssistantTimelineState()
        resetTimelineUpdateTick()
        }
        reloadThreads()
        onThreadLifecycle?(.deleted(Array(ids)))
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
    private func evictThreadCaches(_ ids: some Sequence<AgentThreadID>) {
        for id in ids {
            repairedThreadIds.remove(id)
            threadWorkspaceCache.removeValue(forKey: id)
            composerDraftsByThread.removeValue(forKey: id)
            lastPersistedAssistantContentByThread.removeValue(forKey: id)
            lastPersistedFinalIdByThread.removeValue(forKey: id)
            coordinator.forgetThread(id)
        }
    }

    #if DEBUG
    /// Test-only: the set of thread ids still present in ANY per-thread VM cache,
    /// so a test can prove `evictThreadCaches` leaves no residue after a delete.
    var threadCacheResidueForTesting: Set<AgentThreadID> {
        var ids = repairedThreadIds
        ids.formUnion(threadWorkspaceCache.keys)
        ids.formUnion(composerDraftsByThread.keys)
        ids.formUnion(lastPersistedAssistantContentByThread.keys)
        ids.formUnion(lastPersistedFinalIdByThread.keys)
        return ids
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
        do {
            if let relationalSnapshot = undo.relationalSnapshot {
                try threadRepo.restore(relationalSnapshot)
            } else {
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
        releaseThreadDeletionUndoGCPin(undo)
        pendingThreadDeletionUndo = nil
        threadDeletionUndoExpiryTask?.cancel()
        reloadThreads()
        // Remote mirrors already saw the delete event; re-announce the restored
        // threads so they reappear without a manual thread-list refetch.
        for snapshot in undo.snapshots {
            onThreadLifecycle?(.created(threads.first(where: { $0.id == snapshot.thread.id }) ?? snapshot.thread))
        }
        if let restore = undo.previouslySelectedThreadId,
           threads.contains(where: { $0.id == restore }) {
            selectThread(restore)
        }
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
        let rows = (try? messageRepo.list(threadId: id)) ?? []
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
            let forked = try await coordinator.forkThread(sourceThreadId: tid, childThread: child)
            reloadThreads()
            selectThread(forked.id)
        } catch {
            statusMessage = "Could not fork thread: \(error)"
        }
    }

    /// Intercept only RemoteCode-owned slash commands before they reach the
    /// provider. Provider commands such as `/goal` must pass through.
    public static let localSlashCommands = ["/clear", "/default", "/fork", "/model", "/plan", "/status"]

    private static func localSlashCommandParts(_ raw: String) -> (command: String, argument: String)? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("/") else { return nil }
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
                model = m.id
                persistThreadConfig()
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
        addAttachments(paths)
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
        timeline.clearError()
        lastErrorRecoverable = false
    }

    public func send() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        guard attachmentInputError == nil else { return }
        guard selectedProviderCanRun else {
            statusMessage = providerExecutionUnavailableReason ?? "The selected provider is unavailable."
            return
        }
        lastSentAttachmentCount = attachments.count
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
            if selectedThreadCanQueuePrompt {
                await enqueuePromptWhileRunning(text: slash.argument, attached: attachments)
                return
            }
            _ = await startProviderRun(
                text: slash.argument,
                attached: attachments,
                recordHistory: false,
                interactionMode: interactionMode
            )
            return
        }
        if text.hasPrefix("/"), handleSlashCommand(text) {
            prompt = ""
            return
        }
        if selectedThreadCanQueuePrompt {
            await enqueuePromptWhileRunning(text: text, attached: attachments)
            return
        }
        _ = await startProviderRun(text: text, attached: attachments, recordHistory: false, interactionMode: interactionMode)
    }

    /// UX-MAC_AGENT-BG-AWAIT: manually resume a thread that stalled awaiting a
    /// background job (the supervised-mode counterpart of the autonomous auto-nudge
    /// the coordinator runs for full-access threads).
    public func continueAfterBackgroundWait() async {
        guard isAwaitingBackgroundWork else { return }
        prompt = BackgroundAwaitContinuation.continuationPrompt
        await send()
    }

    private var selectedThreadCanQueuePrompt: Bool {
        guard let selectedThreadId else { return false }
        if selectedThreadRunIsStartingOrRunning { return true }
        if coordinator.activeThreadIdsSnapshot().contains(selectedThreadId) { return true }
        guard let currentRunId,
              let runStatus = try? coordinator.runStatus(currentRunId) else { return false }
        return runStatus == .running || runStatus == .pending
    }

    private func enqueuePromptWhileRunning(text: String, attached: [AgentAttachment]) async {
        guard let selectedThreadId, let queuedMessageRepo else { return }
        do {
            try AgentProviderRunPreflight.validate(
                snapshot: selectedProviderSnapshot,
                interactionMode: interactionMode,
                permissionMode: permissionMode,
                attachments: attached
            )
            let queued = try queuedMessageRepo.enqueueConsumingDraft(
                threadId: selectedThreadId,
                providerInstanceId: providerInstanceId,
                text: text,
                attachments: attached,
                interactionMode: interactionMode
            )
            prompt = ""
            attachments = []
            clearComposerDraftMemory(threadId: selectedThreadId, providerInstanceId: providerInstanceId)
            // UX-MAC_AGENT-019: a run is in flight, so this message was queued,
            // not sent now — confirm that explicitly near the composer.
            queueStatusMessage = "Queued — will run after the current turn."
            reloadQueuedMessages()
            // QA-MAC_AGENT-010: track queue depth for diagnostics.
            agentSurfaceLog.info("queue.enqueued thread=\(selectedThreadId.value.uuidString, privacy: .public) depth=\(self.queuedMessages.count, privacy: .public)")
            onQueuedMessageEvent?(AgentQueueEventKinds.queued, queued)
        } catch {
            queueStatusMessage = "Queue send failed: \(error)"
        }
    }

    @discardableResult
    private func startProviderRun(
        text: String,
        attached: [AgentAttachment],
        recordHistory: Bool,
        interactionMode: AgentInteractionMode,
        resumeInterrupted: Bool = false,
        requestedRunId: AgentRunID? = nil
    ) async -> AgentRunID? {
        do {
            try AgentProviderRunPreflight.validate(
                snapshot: selectedProviderSnapshot,
                interactionMode: interactionMode,
                permissionMode: permissionMode,
                attachments: attached
            )
        } catch {
            statusMessage = String(describing: error)
            return nil
        }
        if recordHistory { recordPromptHistory(text) }
        if selectedThreadId == nil {
            createThread(title: "New thread")
        }
        guard let tid = selectedThreadId else { return nil }
        // B5: title a still-default thread from its first message.
        if let t = threads.first(where: { $0.id == tid }),
           AgentThreadTitle.isPlaceholder(t.title),
           ((try? messageRepo.list(threadId: tid))?.isEmpty ?? true) {
            renameThread(tid, to: Self.deriveTitle(from: text))
        }
        loadAllMessages(tid)
        suppressPersistedFinalDuplicatedByTimeline()
        timeline.clearActivePlan()
        resetTimelineUpdateTick()
        lastErrorRecoverable = false  // UX-MAC_AGENT-009: clear stale Retry on new run
        selectedThreadHasRecoverableContext = false  // UX-MAC_AGENT-CONTINUE: run started; hide Continue
        let display = attached.isEmpty ? text
            : text + "\n\n📎 " + attached.map(\.displayName).joined(separator: ", ")
        // The coordinator is the single writer of run messages — mirror
        // the user message in-memory only (no double-persist).
        let runId = requestedRunId ?? AgentRunID()
        let durableUserMessageExists = (try? messageRepo.get(id: AgentMessageID(runId.value))) != nil
        if !resumeInterrupted && !durableUserMessageExists {
            messages.append(AgentMessage(threadId: tid, role: .user, content: AssistantTimelineState.cappedText(display), attachments: attached))
        }
        focusTick &+= 1
        persistThreadConfig()
        let launchConfig = providerLaunchConfig?(provider, providerInstanceId)
        let req = AgentRunRequest(
            runId: runId,
            threadId: tid,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            cwd: cwd,
            prompt: text,
            userMessageContent: display,
            attachments: attached,
            providerThreadId: resumeInterrupted ? nil : threads.first(where: { $0.id == tid })?.providerThreadId,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            interactionMode: interactionMode,
            providerBinary: launchConfig?.binary,
            environment: launchConfig?.environment ?? [:]
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
            let runId = try await coordinator.startRun(req, recordUserMessage: !resumeInterrupted)
            do {
                try clearComposerDraft(threadId: tid, providerInstanceId: providerInstanceId)
                attachments = []
                prompt = ""
            } catch {
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
                self.statusMessage = "Failed to start: \(error)"
                self.status = .failed
                self.currentRunId = nil
                self.runThreads[runId] = nil
                self.runStartedAt = nil
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
        guard await startProviderRun(text: prompt, attached: [], recordHistory: false, interactionMode: .default) != nil else { return }
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

    public func rejectLatestPlan() async {
        guard latestProposedPlan != nil else { return }
        let prompt = "Reject this proposed plan. Do not implement it. Stay in Plan mode and produce a revised plan before making any workspace changes."
        clearVisibleErrorForNewUserMessage()
        _ = await startProviderRun(text: prompt, attached: [], recordHistory: false, interactionMode: .plan)
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
            try? messageRepo.list(threadId: threadId).last(where: { $0.role == .user })
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
                try? messageRepo.list(threadId: threadId).last(where: { $0.role == .user })
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
        if let r = currentRunId {
            coordinator.stopRun(r)
        }
        if let tid = selectedThreadId {
            coordinator.stopRun(threadId: tid)
        }
        // UX-MAC_AGENT-STOP: signal that the interrupt was sent so the UI can
        // show "Stopping..." and disable the button until the run terminates.
        isStopping = true
    }

    /// Stop a specific thread by id, regardless of which thread is currently selected.
    /// Allows the thread rail to stop any running thread without switching selection.
    public func stopThread(_ id: AgentThreadID) {
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
            let existing = (try? messageRepo.list(threadId: threadId)) ?? []
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

    // PERF-MAC_AGENT-010: accumulate streaming events and flush all of them in
    // a single main-actor hop. A fast token stream emits thousands of events/sec;
    // the old code allocated one Task per event. Now the first event schedules
    // ONE flush Task; subsequent events in the same tick just append to the buffer
    // and the flush Task drains everything atomically. Event order is preserved.
    private func flushStreamEvents() {
        let pending = streamEventBatch.drain()
        guard !pending.isEmpty else { return }
        var nextTimeline = timeline
        var nextCurrentRunId = currentRunId
        var nextStatus = status
        var nextLastErrorRecoverable = lastErrorRecoverable
        var appliedEvent = false
        for (event, run, threadId) in pending {
            guard threadId == self.selectedThreadId else { continue }
            appliedEvent = true
            if !self.terminalRunIds.contains(run) {
                nextCurrentRunId = run
                self.runThreads[run] = threadId
                if nextStatus != .running { nextStatus = .running }
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
        guard appliedEvent else { return }
        if self.currentRunId != nextCurrentRunId { self.currentRunId = nextCurrentRunId }
        if self.status != nextStatus { self.status = nextStatus }
        if self.lastErrorRecoverable != nextLastErrorRecoverable {
            self.lastErrorRecoverable = nextLastErrorRecoverable
        }
        self.timeline = nextTimeline
        self.refreshSR1TranslationStateFromTimeline()
        self.scheduleTimelineUpdateTick()
    }

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {
        // PERF-MAC_AGENT-010: append to the batch buffer. If the buffer was
        // empty (first event of this tick), schedule a single flush Task.
        // Later events in the same tick just append — no extra Task allocation.
        let shouldSchedule = streamEventBatch.append(event: event, run: run, threadId: threadId)
        if shouldSchedule {
            Task { @MainActor in
                self.flushStreamEvents()
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
        timelineUpdateTickTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            self.timelineUpdateTick &+= 1
            self.timelineUpdateTickTask = nil
        }
    }

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
        Task { @MainActor in
            let finishedTid = threadId
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
                self.isStopping = false  // UX-MAC_AGENT-STOP: run finished; clear stopping flag
            }
            self.reloadThreads()
            self.loadGitBranchThrottled()   // the run may have changed the tree
            if status == .completed {
                self.onRunCompleted?()
            }
            self.onRunStateChange?()
        }
    }

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID) {
        Task { @MainActor in
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
            self.reloadThreads()
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
                    // Terminal provider status can arrive immediately before
                    // `.finished`; keep the UI in running state until the
                    // coordinator has released the active handle.
                    if !self.coordinator.activeThreadIdsSnapshot().contains(threadId) {
                        self.status = status
                        self.terminalRunIds = Self.boundedTerminalRunIds(existing: self.terminalRunIds, adding: runId)
                        self.currentRunId = nil
                        self.runStartedAt = nil
                        self.runThreads[runId] = nil
                        self.isStopping = false  // UX-MAC_AGENT-STOP: terminal; clear stopping flag
                    }
                } else {
                    self.status = status
                }
            }
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

    private func refreshSR1TranslationStateFromTimeline() {
        var ids = sr1TranslatedMessageIds
        var originals = sr1OriginalTextsByMessageId
        for (rawId, translation) in timeline.sr1TranslationsByMessageId {
            guard let uuid = UUID(uuidString: rawId) else { continue }
            let id = AgentMessageID(uuid)
            ids.insert(id)
            originals[id] = translation.originalText
        }
        if ids != sr1TranslatedMessageIds {
            sr1TranslatedMessageIds = ids
        }
        if originals != sr1OriginalTextsByMessageId {
            sr1OriginalTextsByMessageId = originals
        }
    }
}

// PERF-MAC_AGENT-010: lock-protected buffer used by runCoordinator(_:didReceive:)
// to coalesce streaming events. Safe to access from both the coordinator's
// background thread (append) and the main actor (drain).
final class StreamEventBatch: @unchecked Sendable {
    private struct Entry {
        let event: AssistantEvent
        let run: AgentRunID
        let threadId: AgentThreadID
    }
    private let lock = NSLock()
    private var buffer: [Entry] = []
    private var flushScheduled = false

    /// Appends an event. Returns `true` iff the caller should schedule a flush Task
    /// (i.e. the buffer was empty before this append — first event of the tick).
    func append(event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(Entry(event: event, run: run, threadId: threadId))
        if flushScheduled { return false }
        flushScheduled = true
        return true
    }

    /// Drains and returns all buffered entries, resetting the buffer and the
    /// scheduled flag so the next incoming event will schedule a new flush.
    func drain() -> [(event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID)] {
        lock.lock()
        defer { lock.unlock() }
        let out = buffer.map { ($0.event, $0.run, $0.threadId) }
        buffer.removeAll(keepingCapacity: true)
        flushScheduled = false
        return out
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
    public static func suggestions(
        for text: String,
        cursorOffset: Int? = nil,
        snapshot: AgentProviderSnapshot?,
        localSlashCommands: [String],
        limit: Int = 8
    ) -> [AgentComposerSuggestion] {
        let token = activeToken(in: text, cursorOffset: cursorOffset)
        guard token.hasPrefix("/") || token.hasPrefix("$") else { return [] }
        let query = String(token.dropFirst()).lowercased()
        if token.hasPrefix("$") {
            return ranked(snapshot?.skills ?? [], query: query)
                .prefix(limit)
                .map {
                    AgentComposerSuggestion(
                        title: "$\($0)",
                        subtitle: "\(snapshot?.displayName ?? "Provider") skill",
                        insertText: "$\($0) ",
                        kind: .skill
                    )
                }
        }
        let providerCommands = snapshot?.slashCommands ?? []
        let allCommands = Array(Set(localSlashCommands + providerCommands)).sorted()
        return ranked(allCommands, query: query)
            .prefix(limit)
            .map { command in
                let source = localSlashCommands.contains(command) ? "RemoteCode command" : "\(snapshot?.displayName ?? "Provider") command"
                return AgentComposerSuggestion(title: command, subtitle: source, insertText: "\(command) ", kind: .slashCommand)
            }
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
        return unique
            .filter { $0.lowercased().contains(query) }
            .sorted { lhs, rhs in
                let l = lhs.lowercased()
                let r = rhs.lowercased()
                let lp = l.hasPrefix(query) || l.hasPrefix("/\(query)")
                let rp = r.hasPrefix(query) || r.hasPrefix("/\(query)")
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
        let tokenText: String
        if let window = usage.contextWindow, window > 0 {
            let pct = min(999, max(0, Int((Double(usage.totalTokens) / Double(window) * 100).rounded())))
            tokenText = "Context \(pct)% · \(usage.totalTokens) / \(window) tokens"
        } else {
            tokenText = "Context \(usage.totalTokens) tokens"
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

    /// Sanitize + cap inline tool/skill output: strip ANSI escape codes (Bash output is full
    /// of them and they render as literal garbage in a Text view) and cap length so one noisy
    /// command can't blow up the transcript. Full text remains selectable / in the stored event.
    static func cappedDetail(_ text: String, limit: Int = 6_000) -> String {
        let clean = stripANSI(text)
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
        guard item.type == .imageView,
              let path = item.resourcePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return AgentImageViewPresentation(
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            resourceURL: URL(fileURLWithPath: path)
        )
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
    // macos:32: caret-anchored suggestion popup state. selection nil == nothing
    // highlighted; dismissed == user pressed Esc for the current token. caretRect
    // is in the editor's own coordinate space (origin top-left in SwiftUI overlay).
    @State private var suggestionSelectedIndex: Int? = nil
    @State private var suggestionPopupDismissed = false
    @State private var composerCaretRect: CGRect = .zero
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
    // UX-XPLAT-007: checkpoint revert confirmation — staged turn count until user confirms.
    @State private var pendingRevertCheckpointTurnCount: Int?
    // P3: user-message "show more" — message ids the user has expanded past 28 lines.
    @State private var expandedUserMessages: Set<AgentMessageID> = []
    @State private var showModelOptions = false
    @State private var showAllModelOptions = false
    // UX-MAC_AGENT-013: inline custom-model entry replaces the blocking NSAlert.
    @State private var showCustomModelField = false
    @State private var customModelDraft = ""
    /// P1/F4: number of hidden pre-run transcript items revealed read-only.
    /// Reset to zero on each new run and paged so one tap cannot render a huge history.
    @State private var transcriptHistoryRevealCount = 0

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
        "The agent runs tools and edits without asking for this thread until you change it."

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
        var hiddenLiveItemCount: Int
        var shouldRenderFinal: Bool
    }

    static func computeTurnRenderInputs(turn: AssistantTurnSnapshot,
                                        persistedAssistantTexts: [String],
                                        proposedPlans allPlans: [AssistantProposedPlan],
                                        running: Bool) -> TurnRenderInputs {
        let turnPlans = allPlans.filter {
            $0.turnId == turn.turnId && !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let renderable = renderableItems(in: turn, persistedAssistantTexts: persistedAssistantTexts)
            .filter { !($0.type == .plan && !turnPlans.isEmpty) }
        let runningTurn = !turn.finished && running
        let visibleRenderable = visibleLiveTurnItems(renderable, running: runningTurn)
        let hiddenLiveItemCount = renderable.count - visibleRenderable.count
        // Derive the final-answer item ids ONCE and split renderable items into the
        // visible answer vs the "Worked" log, instead of computing finalIDs twice.
        let finalIDs = turn.finished
            ? completedFinalAssistantItemIDs(in: turn, renderableItems: renderable, persistedAssistantTexts: persistedAssistantTexts)
            : []
        let workItems = turn.finished ? renderable.filter { !finalIDs.contains($0.id) } : []
        let visibleAssistant = turn.finished ? renderable.filter { finalIDs.contains($0.id) } : []
        let visibleBlocks = turnRenderBlocks(turn.finished ? visibleAssistant : visibleRenderable)
        let completedWorkBlocks = turnRenderBlocks(workItems)
        let shouldRenderFinal = turn.finalAssistantMessage != nil
            && shouldRenderFinalAssistantMessage(turn, persistedAssistantTexts: persistedAssistantTexts)
        return TurnRenderInputs(turnPlans: turnPlans,
                                visibleBlocks: visibleBlocks,
                                completedWorkBlocks: completedWorkBlocks,
                                hiddenLiveItemCount: hiddenLiveItemCount,
                                shouldRenderFinal: shouldRenderFinal)
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

    static let userMessagePreviewCharacterLimit = 1_200
    nonisolated static let runningTranscriptContextSlack: TimeInterval = 2
    // PERF-MAC_AGENT-023: idle/completed threads render their transcript in an
    // eager (non-Lazy) VStack, so a very long thread re-builds and re-lays-out the
    // whole history on every routine invalidation (focus, hover, scroll, the
    // one-shot completion tick) — pathologically slow on huge threads. Bound the
    // idle render to a recent tail, mirroring the running-state window; the older
    // slice stays one tap away via the existing "earlier transcript items" reveal.
    nonisolated static let idleTranscriptWindowCount = 30
    nonisolated static let hiddenTranscriptRevealPageCount = 50
    static let liveTurnRenderableItemLimit = 48
    static let liveTurnBodyCharacterLimit = 2_000
    static let liveTurnOutputCharacterLimit = 1_500
    static let liveTurnSummaryCharacterLimit = 240
    static let commandPreviewCharacterLimit = 1_200

    static func userMessageDisplayText(_ text: String) -> String {
        guard text.count > userMessagePreviewCharacterLimit else { return text }
        let omitted = text.count - userMessagePreviewCharacterLimit
        return "\(text.prefix(userMessagePreviewCharacterLimit))\n\n... \(omitted) more characters hidden. Use Copy message for the full prompt."
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
            return Self.rematerializedTranscriptEntries(
                cached: transcriptCache.entries,
                turns: vm.timeline.turns
            )
        }
        let merged = Self.mergeTranscriptEntries(messages: vm.messages, turns: vm.timeline.turns)
        transcriptCache.signature = signature
        transcriptCache.entries = merged
        return merged
    }

    /// F1: rewrite the cached `.turn` entries with the CURRENT timeline snapshots
    /// (matched by turnId) while preserving the cached order. The transcript cache
    /// memoizes only the merge/sort, not the payloads: turn content mutates on every
    /// streaming delta / state flip / completion without changing the structural
    /// signature, so a cache hit must not serve the stale value copies.
    nonisolated static func rematerializedTranscriptEntries(
        cached: [TranscriptEntry],
        turns: [AssistantTurnSnapshot]
    ) -> [TranscriptEntry] {
        guard !turns.isEmpty else { return cached }
        var turnsById = [String: AssistantTurnSnapshot](minimumCapacity: turns.count)
        for turn in turns { turnsById[turn.turnId] = turn }
        return cached.map { entry in
            guard case .turn(let stale) = entry, let live = turnsById[stale.turnId] else {
                return entry
            }
            return .turn(live)
        }
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
    /// - Running: the time-cutoff live window (entries at/after `runStartedAt`
    ///   minus `runningSlack`), with a 2-entry floor — unchanged behavior.
    /// - Idle/completed: the most recent `idleWindowCount` entries when the thread
    ///   is longer than that, so a huge thread no longer re-renders in full on
    ///   every invalidation. The pre-window slice is surfaced by the existing
    ///   `hiddenTranscriptSlice` + reveal row, so no history is dropped.
    nonisolated static func visibleTranscriptWindow(
        entries: [TranscriptEntry],
        status: AgentRunStatus,
        runStartedAt: Date?,
        idleWindowCount: Int = idleTranscriptWindowCount,
        runningSlack: TimeInterval = runningTranscriptContextSlack
    ) -> [TranscriptEntry] {
        if status == .running {
            // Running path is unchanged: the time-cutoff live window, with the
            // existing 2-entry floor and the "return all" fallbacks preserved.
            guard let startedAt = runStartedAt, entries.count > 2 else { return entries }
            let cutoff = startedAt.addingTimeInterval(-runningSlack).timeIntervalSince1970
            let liveEntries = entries.filter { $0.sortTime >= cutoff }
            return liveEntries.isEmpty ? Array(entries.suffix(2)) : liveEntries
        }
        guard entries.count > idleWindowCount else { return entries }
        return Array(entries.suffix(idleWindowCount))
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
        guard turn.finished else {
            return computeTurnRenderInputsCounted(turn: turn, running: running)
        }
        let plansKey = "\(vm.timeline.proposedPlans.count)|\(vm.timeline.proposedPlans.last?.id ?? "-")"
        let signature = Self.finishedTurnRenderSignature(turn: turn, assistantTextsKey: assistantTextsKey, plansKey: plansKey)
        if let cached = turnRenderCache.entries[turn.turnId], cached.signature == signature {
            return cached.value
        }
        let value = computeTurnRenderInputsCounted(turn: turn, running: running)
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
    nonisolated static func finishedTurnRenderSignature(turn: AssistantTurnSnapshot,
                                                        assistantTextsKey: String,
                                                        plansKey: String) -> String {
        "\(turn.turnId)|i\(turn.items.count)|\(assistantTextsKey)|pl\(plansKey)"
    }

    private func computeTurnRenderInputsCounted(turn: AssistantTurnSnapshot, running: Bool) -> TurnRenderInputs {
        #if DEBUG
        Self.turnRenderComputeCountForTesting &+= 1
        #endif
        return Self.computeTurnRenderInputs(
            turn: turn,
            persistedAssistantTexts: persistedAssistantTexts,
            proposedPlans: vm.timeline.proposedPlans,
            running: running
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
            if vm.providerSnapshots.isEmpty {
                await vm.loadProviderSnapshots()
                // F10: the snapshot path drops the live/fallback signal —
                // run the VM's own fetch so availableModelsAreFallback (and
                // with it the "built-in defaults" warning + Refresh row) is
                // populated on startup, not only after a manual retry.
                await vm.loadModels()
            }
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AgentThreadTitle.display(t.title)).font(DS.Font.bodyDense.weight(t.hasUnread ? .semibold : .regular))
                            .foregroundColor(DS.Palette.text).lineLimit(1)
                        Text("\(t.provider.rawValue) · \(t.model)")
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
            if let message = Self.visibleStatusMessage(vm.statusMessage) {
                inlineStatusBanner(message, identifier: "agent.status.message")
            }
            if let message = vm.providerThreadSnapshotStatusMessage {
                inlineStatusBanner(message, identifier: "agent.provider.snapshot.stale") {
                    vm.retryProviderThreadSnapshotRead()
                }
            }
            if let banner = Self.standaloneQueueStatusBanner(vm.queueStatusMessage, queuedCount: vm.queuedMessages.count) {
                inlineStatusBanner(
                    banner.message,
                    identifier: "agent.queue.status",
                    offersCopy: banner.offersCopy,
                    retry: banner.offersRetry ? { Task { await vm.send() } } : nil
                )
            }
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
            DSPill(vm.isAwaitingBackgroundWork ? "awaiting" : vm.status.rawValue,
                   tone: vm.isAwaitingBackgroundWork ? .warning : statusTone(vm.status))
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
        vm.modelOptionsForSelectedProvider.first(where: { $0.id == vm.model })?.label ?? vm.model
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
                                transcriptHistoryRevealCount,
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
                            // Full thread is loaded up front (no infinite-scroll paging),
                            // so there are no top/bottom history sentinels and no per-row
                            // body hydrate/evict.
                            if hiddenCount > 0 {
                                runningHiddenTranscriptRow(
                                    hiddenCount,
                                    revealedCount: revealedHiddenCount,
                                    pageCount: Self.hiddenTranscriptRevealPageCount,
                                    onReveal: {
                                        transcriptHistoryRevealCount = min(
                                            hiddenCount,
                                            transcriptHistoryRevealCount + Self.hiddenTranscriptRevealPageCount
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
                                        messageRow(message)
                                    case .turn(let turn):
                                        turnView(turn)
                                    }
                                }
                            }
                            ForEach(entries) { entry in
                                switch entry {
                                case .message(let message):
                                    messageRow(message)
                                case .turn(let turn):
                                    turnView(turn)
                                }
                            }
                            if let plan = vm.activePlan {
                                activePlanRow(plan)
                            }
                            if vm.messages.isEmpty && vm.timeline.turns.isEmpty && vm.timeline.error == nil {
                                emptyConversation
                            }
                            if vm.selectedThreadRunIsStartingOrRunning { workingStatus }
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
            .onChange(of: vm.focusTick) { _ in scheduleTimelineScrollToBottom(proxy, force: true) }
            .onChange(of: vm.messages.count) { _ in
                scheduleTimelineScrollToBottom(proxy)
            }
            .onChange(of: vm.timeline.turns.count) { _ in
                scheduleTimelineScrollToBottom(proxy)
                // PERF-MAC_AGENT-012: drop expansion ids for items that no longer
                // exist (turns are memory-capped at AssistantTimelineState.liveTurnLimit)
                // so the sets don't leak over a long session. Runs only on a turn
                // add/remove, not per text delta.
                DispatchQueue.main.async {
                    pruneExpandedItemIds()
                }
            }
            .onChange(of: vm.status) { _ in scheduleTimelineScrollToBottom(proxy) }
            // P1: collapse revealed history whenever a new run starts so the
            // window resets to the live context automatically.
            .onChange(of: vm.runStartedAt) { newValue in
                if newValue != nil { transcriptHistoryRevealCount = 0 }
            }
            // PERF-MAC_AGENT-023: also collapse on thread switch. Idle threads now
            // bound their render to a recent tail (visibleTranscriptWindow), so a
            // revealed flag carried into a different long thread would eagerly
            // render its whole history with no user action — reintroducing the hang.
            .onChange(of: vm.selectedThreadId) { _ in
                transcriptHistoryRevealCount = 0
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

    // UX-MAC_AGENT-BG-AWAIT: when a thread ends while the agent is still waiting on
    // a background job it launched, the run reads "awaiting" (not a green
    // "completed"); this banner lets the user resume it. Full-access threads are
    // also auto-nudged by the coordinator, so this is mainly the supervised path.
    @ViewBuilder
    private var backgroundAwaitBanner: some View {
        if vm.isAwaitingBackgroundWork {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "hourglass")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Palette.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent is waiting on a background task")
                        .font(DS.Font.caption.weight(.semibold))
                        .foregroundColor(DS.Palette.textSecondary)
                    Text("The run ended while standing by. Resume it to check the task and finish.")
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
                    Button(inlineState == .stopping ? "Stopping..." : "Stop") { vm.stop() }
                        .buttonStyle(.plain)
                        .font(DS.Font.body.weight(.medium))
                        .foregroundColor(inlineState == .stopping ? DS.Palette.textTertiary : DS.Palette.danger)
                        .disabled(inlineState == .stopping)
                        .help(inlineState == .stopping ? "Stopping..." : "Stop running agent (press Esc to interrupt)")
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
            return "\(count) earlier transcript items hidden - tap to view \(nextCount)"
        }
        if revealedCount < count {
            return "\(revealedCount) of \(count) earlier transcript items visible - tap to view more"
        }
        return "\(count) earlier transcript items visible, read-only"
    }

    nonisolated static func hiddenTranscriptRevealAccessibilityLabel(
        count: Int,
        revealedCount: Int
    ) -> String {
        if revealedCount <= 0 {
            return "\(count) earlier transcript items hidden"
        }
        if revealedCount < count {
            return "\(revealedCount) of \(count) earlier transcript items visible"
        }
        return "\(count) earlier transcript items visible, read-only"
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
    // blank-page friction and hint at what the agent can do.
    private static let emptyConversationStarters: [(icon: String, title: String, prompt: String)] = [
        ("magnifyingglass", "Explain this codebase", "Give me a high-level tour of this codebase: the main modules, how they fit together, and where to start reading."),
        ("ant", "Find and fix a bug", "Find a bug in the current changes and fix it. Show me the diff and explain the root cause."),
        ("checklist", "Plan a change", "I want to add a feature. Help me plan it step by step before writing any code."),
        ("text.alignleft", "Write tests", "Add tests for the most recently changed files. Cover the edge cases.")
    ]

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
                ForEach(Self.emptyConversationStarters, id: \.title) { starter in
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
            HStack(alignment: .top, spacing: DS.Space.sm) {
                Image(systemName: recoverable ? "exclamationmark.triangle" : "xmark.octagon")
                    .font(.system(size: 11))
                    .foregroundColor(recoverable ? DS.Palette.warning : DS.Palette.danger)
                Text(err)
                    .font(DS.Font.monoSmall)
                    .foregroundColor(recoverable ? DS.Palette.warning : DS.Palette.danger)
                    .lineSpacing(3).textSelection(.enabled)
                Spacer(minLength: 0)
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
                Text(recoveryStatus)
                    .font(DS.Font.caption)
                    .foregroundColor(recoveryStatus.hasPrefix("Could not") || recoveryStatus.hasPrefix("Sign-in unavailable")
                        ? DS.Palette.danger
                        : DS.Palette.textSecondary)
                    .textSelection(.enabled)
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

    static func completedWorkLabel(_ turn: AssistantTurnSnapshot) -> String {
        if let duration = turnDurationLabel(turn) {
            return "Worked for \(duration)"
        }
        return "Worked"
    }

    @ViewBuilder
    private func messageRow(_ msg: AgentMessage) -> some View {
        switch msg.role {
        case .user:
            let displayText = Self.userMessageDisplayText(msg.content)
            let messageExpanded = expandedUserMessages.contains(msg.id)
            // P3: messages longer than 28 lines get a "Show more" toggle so the
            // user can read the full text without the copy-only hint.
            let lineCount = displayText.components(separatedBy: "\n").count
            let showExpandToggle = !messageExpanded && lineCount > 28
            HStack(spacing: 0) {
                Spacer(minLength: 32)
                VStack(alignment: .trailing, spacing: DS.Space.xs) {
                    Text(displayText)
                        .font(DS.Font.body)
                        .foregroundColor(DS.Palette.text)
                        .textSelection(.enabled)
                        .lineLimit(messageExpanded ? nil : 28)
                        .truncationMode(.tail)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .background(DS.Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxWidth: 600, alignment: .trailing)
                        .accessibilityIdentifier("agent.userMessageBubble")
                    if showExpandToggle {
                        Button {
                            expandedUserMessages.insert(msg.id)
                        } label: {
                            Text("Show more")
                                .font(DS.Font.caption)
                                .foregroundColor(DS.Palette.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show full message")
                        .accessibilityIdentifier("agent.userMessage.showMore.\(msg.id.value.uuidString)")
                    }
                    // UX-MAC_AGENT-017: subtle relative timestamp so long threads
                    // show when each message was sent.
                    HStack(spacing: DS.Space.xs) {
                        Button { copyToPasteboard(msg.content) } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityLabel("Copy message")
                        .help("Copy message")
                        Text(Self.relativeTimestamp(msg.createdAt))
                            .font(DS.Font.caption2)
                            .foregroundColor(DS.Palette.textTertiary)
                            .help(Self.absoluteTimestamp(msg.createdAt))
                    }
                }
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
            if turn.finished, !inputs.completedWorkBlocks.isEmpty {
                completedWorkDisclosure(turn: turn, blocks: inputs.completedWorkBlocks)
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
            ForEach(inputs.turnPlans) { plan in
                proposedPlanRow(plan)
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
    private func completedWorkDisclosure(turn: AssistantTurnSnapshot, blocks: [TurnRenderBlock]) -> some View {
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
                    Text(Self.completedWorkLabel(turn))
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
            .accessibilityIdentifier("agent.completedWork.\(turn.turnId)")

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
                Spacer(minLength: 0)
            }
            if let imagePresentation,
               let image = NSImage(contentsOf: imagePresentation.resourceURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
                    .accessibilityIdentifier("agent.image.preview.\(item.id)")
            }
            if let imagePresentation {
                HStack(spacing: DS.Space.sm) {
                    Button("Open") {
                        NSWorkspace.shared.open(imagePresentation.resourceURL)
                    }
                    .accessibilityIdentifier("agent.image.open.\(item.id)")
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([imagePresentation.resourceURL])
                    }
                    .accessibilityIdentifier("agent.image.reveal.\(item.id)")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
    }

    @ViewBuilder
    private func toolRow(_ item: AssistantItem) -> some View {
        let presentation = AgentTimelineItemPresentation.make(for: item)
        let command = AgentTimelineItemPresentation.toolCommandPreview(for: item)
        let output = presentation.detail
        let hasOutput = (output?.isEmpty == false)
        // A long command is also worth expanding even when there's no output yet.
        let canExpand = hasOutput || (command.map { $0.count > 160 || $0.contains("\n") } ?? false)
        let expanded = expandedTools.contains(item.id)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button {
                guard canExpand else { return }
                if expanded { expandedTools.remove(item.id) } else { expandedTools.insert(item.id) }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: presentation.icon)
                        .font(.system(size: 10)).foregroundColor(DS.Palette.textSecondary)
                    (Text("\(presentation.verb) ")
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
                     + Text(presentation.label)
                        .font(DS.Font.mono).foregroundColor(DS.Palette.text))
                    .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if canExpand {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8)).foregroundColor(DS.Palette.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(canExpand ? (expanded ? "Hide details" : "Show command and output") : "No further detail")

            // The command / input that ran (e.g. the bash command) — the key context that
            // was missing. Always visible (truncated when collapsed); full when expanded.
            // UX-MAC_AGENT-OPEN-SPLIT: when the input is a file path or URL, a trailing
            // button opens it in a split panel (Files / Browser) to the right.
            if let command, !command.isEmpty {
                HStack(alignment: .top, spacing: DS.Space.xs) {
                    Text(command)
                        .font(DS.Font.monoSmall).foregroundColor(DS.Palette.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(expanded ? nil : 3)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                        }
                        .buttonStyle(.plain)
                        .help("Open in split panel")
                        .accessibilityIdentifier("agent.tool.openInSplit.\(item.id)")
                    }
                }
                .padding(.horizontal, DS.Space.sm).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            // Output, collapsed by default and capped so a noisy command (or a Skill dump)
            // can't blow up the transcript. Full text stays selectable.
            if expanded, let o = output, !o.isEmpty {
                Text(AgentTimelineItemPresentation.cappedDetail(o))
                    .font(DS.Font.mono).foregroundColor(DS.Palette.textSecondary)
                    .textSelection(.enabled)
                    .padding(DS.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        let headerIcon = streaming ? "circle.dotted" : (failed ? "exclamationmark.triangle" : "terminal")
        VStack(alignment: .leading, spacing: DS.Space.xs) {
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
            .help(expanded ? "Collapse commands" : "Expand \(items.count) commands")

            // Live peek at the current command without forcing the group open.
            if streaming, !expanded, let latest = items.last {
                let preview = AgentTimelineItemPresentation.toolCommandPreview(for: latest)
                    ?? AgentTimelineItemPresentation.make(for: latest).label
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
                        ForEach(items, id: \.id) { item in toolRow(item) }
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
                    Text(message)
                        .font(DS.Font.caption)
                        .foregroundColor(message.contains("failed") ? DS.Palette.danger : DS.Palette.textSecondary)
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
                "Cancel queued message?",
                isPresented: Binding(
                    get: { queuedMessagePendingCancel != nil },
                    set: { if !$0 { queuedMessagePendingCancel = nil } }
                )
            ) {
                Button("Cancel queued message", role: .destructive) {
                    if let queuedMessagePendingCancel {
                        vm.cancelQueuedMessage(queuedMessagePendingCancel)
                    }
                    queuedMessagePendingCancel = nil
                }
                Button("Keep message", role: .cancel) {
                    queuedMessagePendingCancel = nil
                }
            }
        }
    }

    private func inlineStatusBanner(
        _ message: String,
        identifier: String,
        offersCopy: Bool = true,
        retry: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(DS.Palette.danger)
            Text(message)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.text)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if offersCopy {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(identifier).copy")
            }
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(identifier).retry")
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.danger.opacity(0.09))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
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
                        Text("Force")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("Force queued message \(message.position) now")
                    .accessibilityIdentifier("agent.queued.force.\(message.id.value.uuidString)")
                    Button {
                        vm.editQueuedMessage(message)
                    } label: {
                        Image(systemName: "pencil")
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Edit queued message \(message.position)")
                        .accessibilityIdentifier("agent.queued.edit.\(message.id.value.uuidString)")
                    Button {
                        if message.attachments.isEmpty && message.text.count < 120 {
                            vm.cancelQueuedMessage(message)
                        } else {
                            queuedMessagePendingCancel = message
                        }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(DS.Palette.danger)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(DS.Palette.danger)
                    .foregroundColor(DS.Palette.danger)
                    .accessibilityLabel("Cancel queued message \(message.position)")
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
                placeholder: "Ask \(vm.provider.rawValue.capitalized) for changes…",
                isEnabled: vm.selectedProviderCanRun,
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
                onCaretRectChanged: { rect in composerCaretRect = rect },
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
            .overlay(alignment: .topLeading) { suggestionPopup }
            // macos:32: reset selection + un-dismiss whenever the suggestion set
            // changes identity/count (new token, or token edited into a new list).
            .onChange(of: vm.composerSuggestions.map(\.id)) { _ in
                suggestionSelectedIndex = ComposerSuggestionNavigation.reset()
            }
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
            attachmentButton
            modelMenu
            permissionMenu
            executionMenu
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
            sendStopButton
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

    // macos:32: caret-anchored, keyboard-navigable suggestion popup. Replaces the
    // former horizontal chip row. Anchored to the caret rect, positioned ABOVE the
    // caret when there is room, else below.
    @ViewBuilder
    private var suggestionPopup: some View {
        let suggestions = vm.composerSuggestions
        if ComposerSuggestionNavigation.isOpen(count: suggestions.count, dismissed: suggestionPopupDismissed) {
            let rowHeight: CGFloat = 30
            let popupHeight = min(CGFloat(suggestions.count), 6) * rowHeight
            let placeAbove = composerCaretRect.minY >= popupHeight + 6
            let yOffset = placeAbove
                ? composerCaretRect.minY - popupHeight - 4
                : composerCaretRect.maxY + 4
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: suggestions.count > 6) {
                    VStack(spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            suggestionRow(suggestion, highlighted: index == suggestionSelectedIndex)
                                .frame(height: rowHeight)
                        }
                    }
                }
                .frame(height: popupHeight)
            }
            .frame(width: 280)
            .background(DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
            .shadow(color: Color.black.opacity(0.18), radius: 8, y: 2)
            .offset(x: max(0, composerCaretRect.minX), y: yOffset)
            .accessibilityIdentifier("agent.suggestion.popup")
            .allowsHitTesting(true)
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
                Text(message)
                    .font(DS.Font.caption)
                    .foregroundColor(message.hasPrefix("PR preparation failed") ? DS.Palette.danger : DS.Palette.textSecondary)
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
        .help(vm.providerLocked ? "Model · reasoning effort · service tier" : "Provider · model · reasoning effort · service tier")
    }

    private var modelOptionsPopover: some View {
        // P2: "Retry loading models" must remain tappable even mid-run so a
        // failed model-list fetch can be retried without stopping the run.
        // Only mutation rows (set provider/model/effort/tier) are disabled
        // while running; the retry and recovery rows are excluded.
        let running = vm.selectedThreadRunIsStartingOrRunning
        let configurationLocked = running || !vm.selectedProviderCanRun
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            // UX-MAC_AGENT-016: readable while running; mutation rows disable below.
            if running {
                Text("Read-only while running")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if !vm.providerLocked {
                if !vm.providerSnapshots.isEmpty {
                    compactMenuSection("Source")
                    ForEach(vm.providerSnapshots.filter(\.enabled), id: \.id) { snapshot in
                        // Resolve via selectedProviderSnapshot so a stale
                        // providerInstanceId ("codex" vs "codex-cli") still
                        // marks exactly one Source row.
                        compactMenuRow(
                            snapshot.displayName,
                            selected: snapshot.id == vm.selectedProviderSnapshot?.id
                        ) {
                            vm.setProviderInstance(snapshot.id)
                        }
                        .disabled(configurationLocked)
                    }
                    compactMenuDivider
                } else {
                    compactMenuSection("Source")
                    ForEach(AgentProvider.allCases, id: \.self) { provider in
                        compactMenuRow(vm.providerDisplayName(provider), selected: provider == vm.provider) {
                            vm.setProvider(provider)
                            Task { await vm.loadModels(); await MainActor.run { vm.persistThreadConfig() } }
                        }
                        .disabled(configurationLocked)
                    }
                    compactMenuDivider
                }
            } else {
                // UX-MAC_AGENT-003: the source is fixed after the first
                // message. Show a disabled row that names the locked source so
                // the picker doesn't simply vanish with no explanation.
                compactMenuSection("Source")
                lockedSourceRow
                compactMenuDivider
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
                Text(modelListStatus)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.danger)
            }
            if let providerSnapshotStatus = vm.providerSnapshotStatusMessage {
                Text(providerSnapshotStatus)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.danger)
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
            if vm.supportsReasoningForSelectedModel {
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
            if vm.supportsServiceTierForSelectedModel {
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
                Text(providerStatus)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.danger)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if let actionTitle = vm.providerRecoveryActionTitle {
                compactMenuRow(vm.providerRecoveryActionRunning ? "Working..." : actionTitle, selected: false) {
                    Task { await vm.performProviderRecoveryAction() }
                }
                .disabled(vm.providerRecoveryActionRunning)
            }
            if let actionStatus = vm.providerRecoveryStatusMessage {
                Text(actionStatus)
                    .font(DS.Font.caption)
                    .foregroundColor(actionStatus.hasPrefix("Update failed") || actionStatus.hasPrefix("Could not") || actionStatus.hasPrefix("Sign-in unavailable")
                        ? DS.Palette.danger
                        : DS.Palette.textSecondary)
            }
        }
        .padding(DS.Space.sm)
        .background(DS.Palette.surfaceOverlay)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("agent.model.popover")
    }

    private var modelMenuLabel: some View {
        HStack(spacing: DS.Space.xs) {
            Text(modelLabel).font(DS.Font.caption.weight(.medium)).foregroundColor(DS.Palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if vm.supportsReasoningForSelectedModel {
                Text("·").foregroundColor(DS.Palette.textTertiary)
                Text(effortLabel).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if vm.serviceTier == .fast {
                Text("·").foregroundColor(DS.Palette.textTertiary)
                Text(serviceTierLabel).font(DS.Font.caption).foregroundColor(DS.Palette.warning)
                    .lineLimit(1)
            }
            // IMP-MAC_AGENT-014: surface the model's context window on the pill so
            // the active limit is visible at a glance without opening the popover.
            if let ctx = vm.selectedModelContextWindowLabel {
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

    // UX-MAC_AGENT-003: disabled row explaining why the source can't change.
    private var lockedSourceRow: some View {
        let name = vm.providerSnapshots.isEmpty
            ? vm.providerDisplayName(vm.provider)
            : vm.providerInstanceDisplayName(vm.providerInstanceId)
        return HStack(spacing: DS.Space.sm) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 12)
                .foregroundColor(DS.Palette.textTertiary)
            Text("\(name) (locked after first message)")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.xs)
        .padding(.vertical, DS.Space.xs)
        .frame(width: compactModelMenuWidth, alignment: .leading)
        .help("The source is fixed once a thread has a conversation. Start a new thread to use a different source.")
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
        var titles: [String] = []
        if !vm.providerLocked {
            if !vm.providerSnapshots.isEmpty {
                titles.append(contentsOf: vm.providerSnapshots.filter(\.enabled).map(\.displayName))
            } else {
                titles.append(contentsOf: AgentProvider.allCases.map { vm.providerDisplayName($0) })
            }
        }
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
        if vm.supportsReasoningForSelectedModel {
            titles.append(contentsOf: vm.supportedReasoningEffortsForSelectedModel.map(\.displayName))
        }
        if vm.supportsServiceTierForSelectedModel {
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
        let separatorCount = max(0, currentModelMenuLabelParts.count - 1)
        let spacing = CGFloat(separatorCount + 1) * DS.Space.xs
        return min(max(ceil(measured + chevronWidth + spacing), 44), 260)
    }

    private var currentModelMenuLabelParts: [String] {
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
        .disabled(btnState == .stopping)
        .accessibilityLabel(btnState == .stopping ? "Stopping..." : "Stop running agent")
        .accessibilityIdentifier("agent.composer.stop")
        .help(btnState == .stopping ? "Stopping..." : "Stop running agent")
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
    // attach them to the next message. Returns true if any provider is a file.
    private func loadDroppedFileAttachments(from providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { vm.addAttachments([url.path]) }
            }
        }
        return true
    }

    private var sendIdleDisabled: Bool {
        !vm.selectedProviderCanRun
            || (vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && vm.attachments.isEmpty)
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
            if let plan = vm.activePlan {
                activePlanSidebarCard(plan)
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            }
            if let proposedPlan = vm.latestProposedPlan {
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
            if vm.activePlan == nil, vm.latestProposedPlan == nil, vm.checkpoints.isEmpty {
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
                            Text(message)
                                .font(DS.Font.caption)
                                .foregroundColor(message.hasPrefix("Revert failed") ? DS.Palette.danger : DS.Palette.textSecondary)
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

// macos:32: pure, value-type navigation logic for the caret-anchored suggestion
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
    let isEnabled: Bool
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
        textView.isEditable = isEnabled
        textView.placeholderString = placeholder
        // Do not clobber an in-progress dead-key / IME composition: replacing
        // `string` while marked text is active aborts accents (ç/á/é) and CJK.
        if textView.string != text, !textView.hasMarkedText() {
            context.coordinator.applyExternalText(text, to: textView)
        }
        context.coordinator.recalculateHeight()
        scroll.hasVerticalScroller = height >= Self.maxHeight
        if isEnabled, context.coordinator.appliedFocusTick != focusTick {
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

    public init(workspaceID: WorkspaceID, cwd: String, coordinator: AgentRunCoordinator, threadRepo: AgentThreadRepository, messageRepo: AgentMessageRepository, draftRepo: AgentThreadDraftRepository? = nil, attachmentStore: AgentAttachmentStore? = nil, queuedMessageRepo: AgentQueuedMessageRepository? = nil, pendingCallbackRepo: ProviderPendingCallbackRepository? = nil, proposedPlanRepo: AgentProposedPlanRepository? = nil, checkpointRepo: AgentTurnCheckpointRepository? = nil, promptHistoryStore: PromptHistoryStore? = nil, customModelStore: AgentCustomModelStore? = nil, planNotesStore: PlanNotesStore? = nil, title: String = "Agent App", initialThreadId: AgentThreadID? = nil) {
        var metadata = ["workspace": workspaceID.value.uuidString, "cwd": cwd]
        if let initialThreadId { metadata["selected_thread"] = initialThreadId.value.uuidString }
        self.descriptor = SurfaceDescriptor(type: .agentApp, title: title, iconName: "sparkle", metadata: metadata)
        self.viewModel = AgentAppViewModel(workspaceID: workspaceID, cwd: cwd, coordinator: coordinator, threadRepo: threadRepo, messageRepo: messageRepo, draftRepo: draftRepo, attachmentStore: attachmentStore, queuedMessageRepo: queuedMessageRepo, pendingCallbackRepo: pendingCallbackRepo, proposedPlanRepo: proposedPlanRepo, checkpointRepo: checkpointRepo, promptHistoryStore: promptHistoryStore, customModelStore: customModelStore, planNotesStore: planNotesStore, initialThreadId: initialThreadId)
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
    public func close() { onClose?(); onClose = nil }
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
        switch url.scheme?.lowercased() {
        case "http", "https":
            openLinkMention(url)
            return true
        case "file":
            openFileMention(url.path)
            return true
        default:
            return false
        }
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

    /// Resolves a raw file mention to an existing absolute path: strips a
    /// `:line(:col)` suffix, expands `~`, resolves relative tokens against `root`,
    /// falls back to a bounded workspace search for bare filenames, then to the
    /// nearest existing ancestor directory (a mention of a since-deleted file still
    /// lands near it). nil when nothing on disk plausibly matches.
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
        // Nearest existing ancestor — but never degrade to "/" or to the workspace
        // root itself: a mention that resolves nowhere near anything real is a
        // false positive, not a navigation target.
        let standardizedRoot = (root as NSString).standardizingPath
        var dir = candidate
        while dir.count > 1 {
            dir = (dir as NSString).deletingLastPathComponent
            if dir.isEmpty || dir == "/" || dir == standardizedRoot { return nil }
            if fileManager.fileExists(atPath: dir) { return dir }
        }
        return nil
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
