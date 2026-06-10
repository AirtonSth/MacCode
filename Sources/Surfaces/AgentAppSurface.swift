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
    @Published public var prompt: String = ""
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
    public var onQueuedMessageEvent: ((String, AgentQueuedMessage) -> Void)?
    public var providerSnapshotLoader: (() async throws -> [AgentProviderSnapshot])?
    public var modelListLoader: ((AgentProvider) async throws -> [AgentModelDescriptor])?
    public var providerLaunchConfig: ((AgentProvider, String?) -> (binary: String?, environment: [String: String]))?
    public var providerRecoveryAction: ((AgentProvider, String?) async throws -> String)?
    public var pullRequestThreadPreparer: ((String, AgentProvider, String, AgentPermissionMode, AgentReasoningEffort, AgentServiceTier, AgentModelSelection?, String?) async throws -> AgentThread)?
    @Published public var providerRecoveryActionRunning = false
    @Published public var providerRecoveryStatusMessage: String?
    @Published public var modelListLoading = false
    @Published public var modelListStatusMessage: String?
    @Published public var providerSnapshotStatusMessage: String?
    @Published public var pullRequestURL: String = ""
    @Published public var pullRequestPreparing = false
    @Published public var pullRequestStatusMessage: String?
    @Published public var checkpoints: [AgentTurnCheckpointSummary] = []
    @Published public var selectedCheckpointTurnCount: Int?
    @Published public var selectedCheckpointPath: String?
    @Published public var checkpointDiffPreview: String = ""
    @Published public var checkpointStatusMessage: String?
    /// B3: file paths attached to the next message (composer chips).
    @Published public var attachments: [String] = []
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

    public let workspaceID: WorkspaceID
    public let cwd: String
    public let coordinator: AgentRunCoordinator
    public let threadRepo: AgentThreadRepository
    public let messageRepo: AgentMessageRepository
    public let queuedMessageRepo: AgentQueuedMessageRepository?
    public let pendingCallbackRepo: ProviderPendingCallbackRepository?
    public let proposedPlanRepo: AgentProposedPlanRepository?
    public let checkpointRepo: AgentTurnCheckpointRepository?
    public let promptHistoryStore: PromptHistoryStore?
    public let customModelStore: AgentCustomModelStore?
    private var promptHistory: [String] = []
    private var promptHistoryCursor: Int?
    private var terminalRunIds = Set<AgentRunID>()
    private var timelineUpdateTickTask: Task<Void, Never>?

    public init(
        workspaceID: WorkspaceID,
        cwd: String,
        coordinator: AgentRunCoordinator,
        threadRepo: AgentThreadRepository,
        messageRepo: AgentMessageRepository,
        queuedMessageRepo: AgentQueuedMessageRepository? = nil,
        pendingCallbackRepo: ProviderPendingCallbackRepository? = nil,
        proposedPlanRepo: AgentProposedPlanRepository? = nil,
        checkpointRepo: AgentTurnCheckpointRepository? = nil,
        promptHistoryStore: PromptHistoryStore? = nil,
        customModelStore: AgentCustomModelStore? = nil
    ) {
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.coordinator = coordinator
        self.threadRepo = threadRepo
        self.messageRepo = messageRepo
        self.queuedMessageRepo = queuedMessageRepo
        self.pendingCallbackRepo = pendingCallbackRepo
        self.proposedPlanRepo = proposedPlanRepo
        self.checkpointRepo = checkpointRepo
        self.promptHistoryStore = promptHistoryStore
        self.customModelStore = customModelStore
        self.promptHistory = promptHistoryStore?.load(workspaceID: workspaceID) ?? []
        reloadCustomModels()
        self.coordinator.addObserver(self)
        reloadThreads()
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
        threads = (try? threadRepo.list(workspaceId: workspaceID)) ?? []
        repairPlaceholderThreadTitles()
        if selectedThreadId == nil, let first = threads.first {
            selectThread(first.id)
        }
    }

    private func repairPlaceholderThreadTitles() {
        for index in threads.indices where AgentThreadTitle.isPlaceholder(threads[index].title) {
            guard let firstUserMessage = ((try? messageRepo.list(threadId: threads[index].id)) ?? [])
                .first(where: { $0.role == .user }) else { continue }
            var thread = threads[index]
            thread.title = AgentThreadTitle.titleFromFirstMessage(firstUserMessage.content)
            thread.updatedAt = Date()
            try? threadRepo.upsert(thread)
            threads[index] = thread
        }
    }

    /// IMP-MAC_AGENT-011: unsent composer text, keyed by thread, so switching
    /// threads mid-typing doesn't lose the draft.
    private var composerDraftsByThread: [AgentThreadID: String] = [:]

    public func selectThread(_ id: AgentThreadID) {
        let isThreadSwitch = selectedThreadId != id
        if isThreadSwitch {
            // IMP-MAC_AGENT-011: stash the leaving thread's draft before swapping,
            // then restore the opened thread's draft (an in-progress prompt on a
            // re-select of the same thread is left untouched).
            if let previous = selectedThreadId {
                composerDraftsByThread[previous] = prompt.isEmpty ? nil : prompt
            }
            selectedThreadId = id
            prompt = composerDraftsByThread[id] ?? ""
        } else {
            selectedThreadId = id
        }
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
            if t.status == .running {
                if runStartedAt == nil { runStartedAt = Date() }
            } else {
                currentRunId = nil
                runStartedAt = nil
            }
        }
        // B6: opening a thread marks it read (persist + reflect in the rail
        // without re-querying, which would recurse through reloadThreads).
        if var t = try? threadRepo.get(id: id), t.hasUnread {
            t.hasUnread = false
            try? threadRepo.upsert(t)
        }
        if let idx = threads.firstIndex(where: { $0.id == id }), threads[idx].hasUnread {
            threads[idx].hasUnread = false
        }
        loadAllMessages(id)
        timeline = AssistantTimelineState()
        let persistedEvents = coordinator.latestStreamEvents(threadId: id)
        let replayEvents = Self.chooseReplayEvents(
            persisted: persistedEvents,
            snapshot: providerThreadSnapshotEvents(threadId: id).map {
                mergePersistedContextTelemetry(snapshot: $0, persisted: persistedEvents)
            }
        )
        for event in replayEvents {
            timeline.apply(event)
        }
        rehydrateProposedPlans(threadId: id)
        rehydratePendingCallbacks(threadId: id)
        reloadCheckpoints()
        suppressPersistedFinalDuplicatedByTimeline()
        resetTimelineUpdateTick()
        // UX-MAC_AGENT-001: route first-responder to the composer on every
        // open/switch so the user can type without a manual click.
        focusTick &+= 1
    }

    public func reloadQueuedMessages() {
        guard let selectedThreadId, let queuedMessageRepo else {
            queuedMessages = []
            return
        }
        queuedMessages = (try? queuedMessageRepo.list(threadId: selectedThreadId)) ?? []
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
                onQueuedMessageEvent?("agent.message.queue.updated", updated)
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
        do {
            if selectedThreadCanQueuePrompt {
                guard try queuedMessageRepo.promoteToFront(id: message.id) != nil else {
                    queueStatusMessage = "Already processing."
                    reloadQueuedMessages()
                    return
                }
                queueStatusMessage = "Queued message will run next."
                reloadQueuedMessages()
                for queued in queuedMessages {
                    onQueuedMessageEvent?("agent.message.queue.updated", queued)
                }
                return
            }
            guard let queued = try queuedMessageRepo.delete(id: message.id) else {
                queueStatusMessage = "Already processing."
                reloadQueuedMessages()
                return
            }
            if editingQueuedMessage?.id == message.id {
                editingQueuedMessage = nil
                queuedMessageDraft = ""
            }
            queueStatusMessage = nil
            reloadQueuedMessages()
            onQueuedMessageEvent?("agent.message.queue.drained", queued)
            for queued in queuedMessages {
                onQueuedMessageEvent?("agent.message.queue.updated", queued)
            }
            _ = await startProviderRun(
                text: queued.text,
                attached: queued.attachments.map(\.path),
                recordHistory: false,
                interactionMode: queued.interactionMode
            )
        } catch {
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
                onQueuedMessageEvent?("agent.message.queue.cancelled", cancelled)
            } else {
                queueStatusMessage = "Already processing."
                reloadQueuedMessages()
            }
        } catch {
            queueStatusMessage = "Queue cancel failed: \(error)"
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

    public func revertSelectedCheckpoint() {
        guard let selectedThreadId, let turnCount = selectedCheckpointTurnCount else { return }
        do {
            _ = try coordinator.revertThreadToCheckpoint(threadId: selectedThreadId, checkpointTurnCount: turnCount, cwd: cwd)
            // PERF-MAC_AGENT-006: revert deleted assistant rows — drop the cache.
            lastPersistedAssistantContentByThread.removeValue(forKey: selectedThreadId)
            checkpointStatusMessage = "Reverted to checkpoint \(turnCount)."
            loadAllMessages(selectedThreadId)
            reloadCheckpoints()
            reloadThreads()
        } catch {
            checkpointStatusMessage = "Revert failed: \(error.localizedDescription)"
        }
    }

    private func providerThreadSnapshotEvents(threadId: AgentThreadID) -> [AssistantEvent]? {
        guard let events = try? coordinator.readThread(threadId: threadId), !events.isEmpty else {
            return nil
        }
        return events
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
        let all = ((try? messageRepo.list(threadId: id)) ?? []).map(Self.displayMessage)
        let (rows, blanked) = Self.applyBodyBudget(all)
        if blanked > 0 {
            // Fail loud: a thread big enough to trip the budget loses its oldest bodies.
            NSLog("[AgentApp] full-load body budget tripped: blanked \(blanked)/\(all.count) oldest message bodies to stay under \(Self.fullLoadBodyBudgetBytes) bytes")
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

    private static func displayMessage(_ message: AgentMessage) -> AgentMessage {
        var m = message
        m.content = AssistantTimelineState.cappedText(m.content)
        return m
    }

    private func suppressPersistedFinalDuplicatedByTimeline() {
        // Persisted assistant rows are the durable completed answer. The view
        // suppresses matching live timeline text instead so partial replay
        // cannot hide the final response.
    }

    /// B7: count of threads with an in-flight run, for the rail header.
    public var activeThreadCount: Int { threads.filter { $0.status == .running }.count }

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

    /// Builds the decline payload for a supervised-mode approval decision.
    /// A non-empty reason is included so the agent can steer future requests;
    /// blank/nil reason produces a plain decline with no annotation.
    nonisolated public static func declinePayload(reason: String?) -> AgentProviderRequestResponse {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .decline(trimmed.flatMap { $0.isEmpty ? nil : $0 })
    }

    public func respondToPendingRequest(_ request: AssistantPendingRequest, response: AgentProviderRequestResponse) {
        guard let threadId = selectedThreadId else { return }
        let state: AssistantRequestState
        switch response {
        case .approve, .approveForSession: state = .approved
        case .decline: state = .declined
        case .cancel: state = .cancelled
        }
        do {
            try coordinator.respondToRequest(threadId: threadId, requestId: request.id, response: response)
            timeline.apply(.requestResolved(requestId: request.id, state: state))
            // QA-MAC_AGENT-010: record approval outcomes for diagnostics.
            agentSurfaceLog.info("approval.resolved thread=\(threadId.value.uuidString, privacy: .public) request=\(request.id, privacy: .public) state=\(state.rawValue, privacy: .public)")
            if response == .approveForSession {
                setPermissionMode(.fullAccess)
            }
        } catch {
            timeline.apply(.error(message: "Provider request response failed: \(error)", recoverable: true))
            timeline.apply(.requestResolved(requestId: request.id, state: .stale))
            // Response-failure, not a prompt failure — no prompt Retry offered.
            lastErrorRecoverable = false
        }
        scheduleTimelineUpdateTick()
    }

    public func answerPendingUserInput(_ request: AssistantUserInputRequest, answer: String) {
        guard let threadId = selectedThreadId else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userInputSelections[request.id] = nil
        userInputDrafts[request.id] = nil
        do {
            try coordinator.respondToUserInput(threadId: threadId, requestId: request.id, text: trimmed)
            timeline.apply(.userInputResolved(requestId: request.id, answer: trimmed))
        } catch {
            timeline.apply(.error(message: "Provider user-input response failed: \(error)", recoverable: true))
            if let idx = timeline.pendingUserInputs.firstIndex(where: { $0.id == request.id }) {
                timeline.pendingUserInputs[idx].state = .stale
                timeline.pendingUserInputs[idx].resolvedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            }
            // Response-failure, not a prompt failure — no prompt Retry offered.
            lastErrorRecoverable = false
        }
        scheduleTimelineUpdateTick()
    }

    public func toggleUserInputOption(_ option: String, for request: AssistantUserInputRequest) {
        var selection = userInputSelections[request.id] ?? []
        if selection.contains(option) { selection.remove(option) }
        else { selection.insert(option) }
        userInputSelections[request.id] = selection
    }

    public func selectedUserInputAnswer(for request: AssistantUserInputRequest) -> String {
        (userInputSelections[request.id] ?? [])
            .filter { request.options.contains($0) }
            .sorted()
            .joined(separator: "\n")
    }

    public func loadModels() async {
        modelListLoading = true
        modelListStatusMessage = "Loading models..."
        defer { modelListLoading = false }
        do {
            let m: [AgentModelDescriptor]
            if let modelListLoader {
                m = try await modelListLoader(provider)
            } else {
                let runner: AgentProviderRunner = provider == .codex ? CodexRunner() : ClaudeRunner()
                m = await runner.listModels()
            }
            await MainActor.run {
                self.availableModels = m
                self.modelListStatusMessage = m.isEmpty ? "No models returned for \(self.providerDisplayName(self.provider)). Retry from the model menu." : nil
                // B8: a provider switch must leave a model valid for that
                // provider — never a stale id from the other provider.
                if !self.modelSelectionIsValid(self.model, in: m) {
                    self.model = m.first?.id ?? self.model
                }
                self.normalizeSelectedModelOptions()
            }
        } catch {
            await MainActor.run {
                self.modelListStatusMessage = "Model list failed. Retry from the model menu."
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
        if selectedProviderSnapshot == nil {
            providerInstanceId = snapshots.first(where: { $0.provider == provider })?.id ?? provider.rawValue
        }
        if let current = selectedProviderSnapshot {
            provider = current.provider
            availableModels = current.models
            if !modelSelectionIsValid(model, in: current.models) {
                model = current.models.first?.id ?? model
            }
            normalizeSelectedModelOptions()
        }
    }

    public func refreshProviderSnapshotsInBackground() {
        seedProviderSnapshotsForStartup()
        Task { await loadProviderSnapshots() }
    }

    private func seedProviderSnapshotsForStartup() {
        guard providerSnapshots.isEmpty else { return }
        Task {
            let codexModels = await CodexRunner().listModels()
            let fallback = [
                AgentProviderSnapshotFactory.snapshot(provider: .codex, models: codexModels, binaryPath: ""),
                AgentProviderSnapshotFactory.snapshot(provider: .claude, models: ClaudeRunner.listModels(installedVersion: nil), binaryPath: "")
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
            reasoningEffort = efforts.first ?? .medium
        }
        if !supportsServiceTierForSelectedModel {
            serviceTier = .auto
        }
    }

    public var composerSuggestions: [AgentComposerSuggestion] {
        AgentComposerSuggestions.suggestions(
            for: prompt,
            snapshot: selectedProviderSnapshot,
            localSlashCommands: Self.localSlashCommands
        )
    }

    public func applyComposerSuggestion(_ suggestion: AgentComposerSuggestion) {
        prompt = AgentComposerSuggestions.replacingActiveToken(in: prompt, with: suggestion.insertText)
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
        return Self.providerRecoveryActionTitle(for: snapshot)
    }

    public static func providerRecoveryActionTitle(for snapshot: AgentProviderSnapshot) -> String? {
        snapshot.recoveryActionTitle
    }

    public func performProviderRecoveryAction() async {
        guard let snapshot = selectedProviderSnapshot,
              let title = Self.providerRecoveryActionTitle(for: snapshot) else { return }
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
        let command: String
        if snapshot.authenticated == false {
            command = "\(snapshot.provider.rawValue) login"
        } else {
            command = snapshot.provider == .codex ? "npm install -g @openai/codex" : "npm install -g @anthropic-ai/claude-code"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        providerRecoveryStatusMessage = "Copied: \(command)"
    }

    public var contextHealthMessage: String? {
        AgentContextStatusPresentation.message(
            usage: timeline.tokenUsage,
            compactionSummary: timeline.contextCompactionSummary
        )
    }

    /// A1: the provider (source) is fixed once the thread has a
    /// conversation — only model/effort stay changeable after that.
    public var providerLocked: Bool { selectedThreadId != nil && !messages.isEmpty }
    public var executionLocked: Bool { providerLocked || status == .running }

    public func setProviderInstance(_ id: String) {
        guard let snapshot = providerSnapshots.first(where: { $0.id == id }) else { return }
        providerInstanceId = snapshot.id
        provider = snapshot.provider
        availableModels = snapshot.models
        if !modelSelectionIsValid(model, in: snapshot.models) {
            model = snapshot.models.first?.id ?? model
        }
        normalizeSelectedModelOptions()
        persistThreadConfig()
    }

    public func setProvider(_ newProvider: AgentProvider) {
        provider = newProvider
        providerInstanceId = newProvider.rawValue
        availableModels = []
        model = ""
        normalizeSelectedModelOptions()
        persistThreadConfig()
    }

    /// Persist the chosen run configuration onto the selected thread so a
    /// resumed run uses the right source, model, permission, and effort.
    public func persistThreadConfig() {
        normalizeSelectedModelOptions()
        guard let id = selectedThreadId, var t = try? threadRepo.get(id: id) else { return }
        t.provider = provider
        t.providerInstanceId = providerInstanceId
        t.model = model
        t.permissionMode = permissionMode
        t.reasoningEffort = reasoningEffort
        t.serviceTier = serviceTier
        t.modelSelection = currentModelSelection
        t.updatedAt = Date()
        try? threadRepo.upsert(t)
        if let i = threads.firstIndex(where: { $0.id == id }) {
            threads[i].provider = provider
            threads[i].providerInstanceId = providerInstanceId
            threads[i].model = model
            threads[i].permissionMode = permissionMode
            threads[i].reasoningEffort = reasoningEffort
            threads[i].serviceTier = serviceTier
            threads[i].modelSelection = currentModelSelection
        }
        onThreadConfigPersisted?(t)
    }

    public func setPermissionMode(_ mode: AgentPermissionMode) {
        permissionMode = mode
        persistThreadConfig()
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

    public func persistThreadExecutionConfig() {
        guard let id = selectedThreadId, var t = try? threadRepo.get(id: id) else { return }
        let branch = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        t.executionMode = executionMode
        t.baseBranch = executionMode == .worktree ? (branch.isEmpty ? (gitBranch ?? "main") : branch) : nil
        if executionMode == .local { t.worktreePath = nil }
        t.updatedAt = Date()
        try? threadRepo.upsert(t)
        if let i = threads.firstIndex(where: { $0.id == id }) {
            threads[i].executionMode = t.executionMode
            threads[i].baseBranch = t.baseBranch
            threads[i].worktreePath = t.worktreePath
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
        try? threadRepo.upsert(t)
        reloadThreads()
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
            selectThread(thread.id)
            pullRequestStatusMessage = "Opened \(thread.title)"
        } catch {
            pullRequestStatusMessage = "PR preparation failed: \(error)"
        }
    }

    public func renameThread(_ id: AgentThreadID, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var t = try? threadRepo.get(id: id) else { return }
        t.title = title
        t.updatedAt = Date()
        try? threadRepo.upsert(t)
        reloadThreads()
    }

    /// A2: set/clear a thread's swatch color (empty string clears).
    public func setThreadColor(_ id: AgentThreadID, _ color: String) {
        guard var t = try? threadRepo.get(id: id) else { return }
        t.color = color.isEmpty ? nil : color
        t.updatedAt = Date()
        try? threadRepo.upsert(t)
        reloadThreads()
    }

    public func setThreadPinned(_ id: AgentThreadID, _ pinned: Bool) {
        try? threadRepo.setPinned(id: id, pinned: pinned)
        reloadThreads()
    }

    public func reorderThread(_ id: AgentThreadID, before target: AgentThreadID) {
        guard id != target,
              let targetIndex = threads.firstIndex(where: { $0.id == target }) else { return }
        try? threadRepo.reorder(id: id, position: targetIndex)
        reloadThreads()
    }

    public func deleteThread(_ id: AgentThreadID) {
        try? threadRepo.delete(id: id)
        if selectedThreadId == id {
            selectedThreadId = nil
        messages = []
        timeline = AssistantTimelineState()
        resetTimelineUpdateTick()
        }
        reloadThreads()
    }

    public func deleteThreads(_ ids: Set<AgentThreadID>) {
        guard !ids.isEmpty else { return }
        try? threadRepo.delete(ids: Array(ids))
        if let selectedThreadId, ids.contains(selectedThreadId) {
            self.selectedThreadId = nil
        messages = []
        timeline = AssistantTimelineState()
        resetTimelineUpdateTick()
        }
        reloadThreads()
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
    public func exportThreadMarkdown(_ id: AgentThreadID) -> (fileName: String, contents: String)? {
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
        messages.append(m)
        try? messageRepo.append(m)
    }

    /// `/fork` — branch a new thread from the current one, copying its
    /// message history, then select it (remotecode.io `/fork` parity).
    public func forkCurrentThread() {
        guard let tid = selectedThreadId,
              let src = threads.first(where: { $0.id == tid }) else { return }
        let copy = AgentThread(workspaceId: workspaceID, title: "\(src.title) (fork)",
                               provider: src.provider, model: src.model,
                               permissionMode: src.permissionMode, reasoningEffort: src.reasoningEffort,
                               serviceTier: src.serviceTier)
        try? threadRepo.upsert(copy)
        let copyBaseDate = Date()
        for (index, m) in ((try? messageRepo.list(threadId: tid)) ?? []).enumerated() {
            try? messageRepo.append(AgentMessage(
                threadId: copy.id,
                role: m.role,
                content: m.content,
                createdAt: copyBaseDate.addingTimeInterval(Double(index) / 1000)
            ))
        }
        reloadThreads()
        selectThread(copy.id)
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
        case "fork":
            forkCurrentThread()
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
        for p in paths where !attachments.contains(p) { attachments.append(p) }
    }
    public func insertDroppedFilePaths(_ paths: [String]) {
        prompt = DroppedFilePaths.appending(DroppedFilePaths.composerInputText(for: paths), to: prompt)
        promptHistoryCursor = nil
    }
    public func promptWasEdited() {
        promptHistoryCursor = nil
    }
    public func removeAttachment(_ path: String) {
        attachments.removeAll { $0 == path }
    }

    public func send() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        recordPromptHistory(text)
        if selectedThreadCanQueuePrompt {
            await enqueuePromptWhileRunning(text: text, attached: attachments)
            return
        }
        if let slash = Self.localSlashCommandParts(text),
           (slash.command == "plan" || slash.command == "default"),
           !slash.argument.isEmpty {
            _ = handleSlashCommand("/\(slash.command)")
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
        _ = await startProviderRun(text: text, attached: attachments, recordHistory: false, interactionMode: interactionMode)
    }

    private var selectedThreadCanQueuePrompt: Bool {
        guard let selectedThreadId else { return false }
        if status == .running { return true }
        if coordinator.activeThreadIdsSnapshot().contains(selectedThreadId) { return true }
        guard let currentRunId,
              let runStatus = try? coordinator.runStatus(currentRunId) else { return false }
        return runStatus == .running || runStatus == .pending
    }

    private func enqueuePromptWhileRunning(text: String, attached: [String]) async {
        guard let selectedThreadId, let queuedMessageRepo else { return }
        let resolvedAttachments: [AgentAttachment]
        do {
            resolvedAttachments = try AgentAttachmentResolver.resolve(paths: attached)
        } catch {
            systemNote(String(describing: error))
            return
        }
        do {
            let queued = try queuedMessageRepo.enqueue(
                threadId: selectedThreadId,
                text: text,
                attachments: resolvedAttachments,
                interactionMode: interactionMode
            )
            prompt = ""
            attachments = []
            // UX-MAC_AGENT-019: a run is in flight, so this message was queued,
            // not sent now — confirm that explicitly near the composer.
            queueStatusMessage = "Queued — will run after the current turn."
            reloadQueuedMessages()
            // QA-MAC_AGENT-010: track queue depth for diagnostics.
            agentSurfaceLog.info("queue.enqueued thread=\(selectedThreadId.value.uuidString, privacy: .public) depth=\(self.queuedMessages.count, privacy: .public)")
            onQueuedMessageEvent?("agent.message.queued", queued)
        } catch {
            queueStatusMessage = "Queue send failed: \(error)"
        }
    }

    @discardableResult
    private func startProviderRun(text: String, attached: [String], recordHistory: Bool, interactionMode: AgentInteractionMode) async -> AgentRunID? {
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
        prompt = ""
        resetTimelineUpdateTick()
        lastErrorRecoverable = false  // UX-MAC_AGENT-009: clear stale Retry on new run
        let resolvedAttachments: [AgentAttachment]
        do {
            resolvedAttachments = try AgentAttachmentResolver.resolve(paths: attached)
        } catch {
            systemNote(String(describing: error))
            return nil
        }
        attachments = []
        let display = resolvedAttachments.isEmpty ? text
            : text + "\n\n📎 " + resolvedAttachments.map(\.displayName).joined(separator: ", ")
        // The coordinator is the single writer of run messages — mirror
        // the user message in-memory only (no double-persist).
        messages.append(AgentMessage(threadId: tid, role: .user, content: AssistantTimelineState.cappedText(display)))
        focusTick &+= 1
        persistThreadConfig()
        let launchConfig = providerLaunchConfig?(provider, providerInstanceId)
        let req = AgentRunRequest(
            threadId: tid,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            cwd: cwd,
            prompt: text,
            userMessageContent: display,
            attachments: resolvedAttachments,
            providerThreadId: threads.first(where: { $0.id == tid })?.providerThreadId,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            interactionMode: interactionMode,
            providerBinary: launchConfig?.binary,
            environment: launchConfig?.environment ?? [:]
        )
        do {
            let runId = try await coordinator.startRun(req)
            let runStatus = (try? coordinator.runStatus(runId)) ?? .running
            await MainActor.run {
                self.terminalRunIds.remove(runId)
                if runStatus == .running || runStatus == .pending {
                    self.currentRunId = runId
                    self.runThreads[runId] = tid
                    self.status = .running
                    self.runStartedAt = Date()
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
            await MainActor.run { self.statusMessage = "Failed to start: \(error)"; self.status = .failed }
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
        guard await startProviderRun(text: prompt, attached: [], recordHistory: false, interactionMode: .default) != nil else { return }
        try? proposedPlanRepo?.markImplemented(threadId: sourceThreadId, planId: plan.id, implementationThreadId: targetThreadId)
        var implemented = plan
        implemented.implementedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        timeline.apply(.proposedPlan(implemented))
    }

    private func recordPromptHistory(_ text: String) {
        guard !text.isEmpty else { return }
        promptHistory.append(text)
        promptHistory = Array(promptHistory.suffix(PromptHistoryStore.limit))
        promptHistoryStore?.save(promptHistory, workspaceID: workspaceID)
        promptHistoryCursor = nil
    }

    /// UX-MAC_AGENT-009: re-send the last prompt after a recoverable error
    /// without forcing the user to retype it.
    public func retryLastPrompt() async {
        guard let last = promptHistory.last, !last.isEmpty else { return }
        lastErrorRecoverable = false
        _ = await startProviderRun(text: last, attached: [], recordHistory: false, interactionMode: interactionMode)
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
    }

    /// Stop a specific thread by id, regardless of which thread is currently selected.
    /// Allows the thread rail to stop any running thread without switching selection.
    public func stopThread(_ id: AgentThreadID) {
        coordinator.stopRun(threadId: id)
    }

    // PERF-MAC_AGENT-006: last assistant text this VM persisted per thread, to
    // skip the O(history) reload when re-deduping the same completed answer.
    private var lastPersistedAssistantContentByThread: [AgentThreadID: String] = [:]

    private func persistFinalAssistantIfMissing(_ text: String, threadId: AgentThreadID) {
        let text = AssistantTimelineState.cappedText(text)
        if lastPersistedAssistantContentByThread[threadId] == text { return }
        let existing = (try? messageRepo.list(threadId: threadId)) ?? []
        guard !existing.contains(where: { $0.role == .assistant && $0.content == text }) else {
            lastPersistedAssistantContentByThread[threadId] = text
            return
        }
        try? messageRepo.append(AgentMessage(threadId: threadId, role: .assistant, content: text))
        lastPersistedAssistantContentByThread[threadId] = text
    }

    // MARK: AgentRunObserver

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {
        Task { @MainActor in
            guard threadId == self.selectedThreadId else { return }
            if !self.terminalRunIds.contains(run) {
                self.currentRunId = run
                self.runThreads[run] = threadId
                if self.status != .running { self.status = .running }
            }
            self.timeline.apply(event)
            // UX-MAC_AGENT-009: track recoverability of the latest error so the
            // transcript can offer Retry; any other event clears the flag.
            if case let .error(_, recoverable) = event {
                self.lastErrorRecoverable = recoverable
            } else {
                self.lastErrorRecoverable = false
            }
            self.scheduleTimelineUpdateTick()
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
            self.terminalRunIds.insert(runId)
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
            if status == .completed, var t = try? self.threadRepo.get(id: finishedTid) {
                // Completed work leaves an unread marker until the user
                // explicitly opens/clicks the thread row.
                t.hasUnread = true
                try? self.threadRepo.upsert(t)
            }
            if finishedTid == self.selectedThreadId {
                self.status = status
                self.currentRunId = nil
                self.runStartedAt = nil
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
            let threadWorkspace = try? self.threadRepo.get(id: threadId)?.workspaceId
            guard threadWorkspace == self.workspaceID else { return }
            if status == .running, var t = try? self.threadRepo.get(id: threadId), t.hasUnread {
                t.hasUnread = false
                try? self.threadRepo.upsert(t)
            }
            self.reloadThreads()
            if threadId == self.selectedThreadId {
                if status == .running {
                    self.status = status
                    self.terminalRunIds.remove(runId)
                    self.currentRunId = runId
                    if self.runStartedAt == nil { self.runStartedAt = Date() }
                } else if Self.isTerminalRunStatus(status) {
                    // Terminal provider status can arrive immediately before
                    // `.finished`; keep the UI in running state until the
                    // coordinator has released the active handle.
                    if !self.coordinator.activeThreadIdsSnapshot().contains(threadId) {
                        self.status = status
                        self.terminalRunIds.insert(runId)
                        self.currentRunId = nil
                        self.runStartedAt = nil
                        self.runThreads[runId] = nil
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
        snapshot: AgentProviderSnapshot?,
        localSlashCommands: [String],
        limit: Int = 8
    ) -> [AgentComposerSuggestion] {
        let token = activeToken(in: text)
        guard token.hasPrefix("/") || token.hasPrefix("$") else { return [] }
        let query = String(token.dropFirst()).lowercased()
        if token.hasPrefix("$") {
            return ranked(snapshot?.skills ?? [], query: query)
                .prefix(limit)
                .map {
                    AgentComposerSuggestion(title: "$\($0)", subtitle: "Codex skill", insertText: "$\($0) ", kind: .skill)
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

    public static func replacingActiveToken(in text: String, with replacement: String) -> String {
        guard let range = activeTokenRange(in: text) else { return replacement }
        var updated = text
        updated.replaceSubrange(range, with: replacement)
        return updated
    }

    private static func activeToken(in text: String) -> String {
        guard let range = activeTokenRange(in: text) else { return "" }
        return String(text[range])
    }

    private static func activeTokenRange(in text: String) -> Range<String.Index>? {
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

private final class TimelineScrollScheduler {
    var scheduled = false
    var forcePending = false
}

public struct AgentAppView: View {
    private static let threadRailWidthRange: ClosedRange<CGFloat> = 180...360
    private static let threadRailIdealWidth: CGFloat = 220
    private static let conversationMinimumWidth: CGFloat = 560
    private static let planSidebarIdealWidth: CGFloat = 300
    private static let timelineBottomRevealSlack: CGFloat = 4
    private static let scrollDownButtonBottomInset: CGFloat = 22
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
    @AppStorage("agent.threadRail.intent.v1") private var threadRailIntentRaw = AdaptiveSidebarIntent.auto.rawValue
    @AppStorage("agent.planSidebar.intent.v1") private var planSidebarIntentRaw = AdaptiveSidebarIntent.auto.rawValue
    @State private var showThreadRail = true
    @State private var lastAutomaticThreadRailChange: TimeInterval?
    @State private var lastAutomaticPlanSidebarChange: TimeInterval?
    @State private var proposedPlanExpanded = false
    @State private var showWorkLog = false
    @State private var expandedCompletedWorkTurns: Set<String> = []
    @State private var queuedMessagePendingCancel: AgentQueuedMessage?
    @State private var pendingSessionApproval: AssistantPendingRequest?
    @State private var expandedRequestPreviews: Set<String> = []
    @State private var declineReasonDrafts: [String: String] = [:]
    @State private var showModelOptions = false
    @State private var showAllModelOptions = false
    // UX-MAC_AGENT-013: inline custom-model entry replaces the blocking NSAlert.
    @State private var showCustomModelField = false
    @State private var customModelDraft = ""

    public init(vm: AgentAppViewModel) { self.vm = vm }

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
        if turn.finalAssistantMessage != nil,
           !shouldRenderFinalAssistantMessage(turn, persistedAssistantTexts: persistedAssistantTexts) {
            return Set(assistantItems.map(\.id))
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
    enum TurnRenderBlock: Identifiable {
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
    static let runningTranscriptContextSlack: TimeInterval = 2
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
        copy.body = cappedVisibleText(copy.body, limit: liveTurnBodyCharacterLimit)
        copy.output = cappedOptionalVisibleText(copy.output, limit: liveTurnOutputCharacterLimit)
        return copy
    }

    static func toolCommandPreview(for item: AssistantItem) -> String? {
        AgentTimelineItemPresentation.toolCommandPreview(for: item)
    }

    static func visibleLiveTurnItems(_ items: [AssistantItem], running: Bool) -> [AssistantItem] {
        guard running else { return items }
        return items.suffix(liveTurnRenderableItemLimit).map(liveRenderableCopy)
    }

    private enum TranscriptEntry: Identifiable {
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
                let started = turn.items.map(\.startedAtMs).min()
                return started.map { TimeInterval($0) / 1000 } ?? 0
            }
        }
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
            return transcriptCache.entries
        }
        let merged = (vm.messages.map(TranscriptEntry.message) + vm.timeline.turns.map(TranscriptEntry.turn))
            .sorted { lhs, rhs in
                if lhs.sortTime == rhs.sortTime { return lhs.id < rhs.id }
                return lhs.sortTime < rhs.sortTime
            }
        transcriptCache.signature = signature
        transcriptCache.entries = merged
        return merged
    }

    private var visibleTranscriptEntries: [TranscriptEntry] {
        let entries = transcriptEntries
        guard vm.status == .running,
              let startedAt = vm.runStartedAt,
              entries.count > 2 else {
            return entries
        }
        let cutoff = startedAt.addingTimeInterval(-Self.runningTranscriptContextSlack).timeIntervalSince1970
        let liveEntries = entries.filter { $0.sortTime >= cutoff }
        return liveEntries.isEmpty ? Array(entries.suffix(2)) : liveEntries
    }

    /// Cheap identity signature: changes only when a message/turn is added,
    /// removed, or reordered, not on streaming text deltas. O(turns), NOT O(messages):
    /// the full thread loads append-only (new sends land at the end), so the message
    /// side collapses to count + first/last id — capturing every add/remove/revert
    /// without walking all N messages on every body eval (critical now that N is the
    /// whole thread, not a 30-row window).
    private var transcriptSignature: String {
        var sig = "m\(vm.messages.count)|\(vm.messages.first?.id.value.uuidString ?? "-")|\(vm.messages.last?.id.value.uuidString ?? "-")|t\(vm.timeline.turns.count)|"
        for turn in vm.timeline.turns {
            sig += turn.turnId
            // A turn's sortTime derives from its items' min startedAtMs; fold item count
            // in so the sort refreshes on item add (not on pure text deltas).
            sig += "#\(turn.items.count)"
        }
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
        .task {
            if vm.providerSnapshots.isEmpty {
                await vm.loadProviderSnapshots()
            }
        }
        .onDeleteCommand { deleteSelectedThreads() }
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
                             subtitle: "Send a prompt to start a Codex or Claude thread.")
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
            let running = AgentThreadRowPresentation.isRunning(
                threadStatus: t.status,
                selected: selected,
                surfaceStatus: vm.status
            )
            let showLeadingStatus = AgentThreadRowPresentation.showsLeadingStatus(
                threadStatus: t.status,
                selected: selected,
                surfaceStatus: vm.status,
                hasUnread: t.hasUnread,
                pinned: t.pinned
            )
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
                    Button("None") { vm.setThreadColor(t.id, "") }
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
                    deleteThreads(selectedThreadIds.isEmpty ? [t.id] : selectedThreadIds)
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
            if !vm.timeline.workActivities.isEmpty {
                workLogRow
                    .padding(.horizontal, 22)
                    .padding(.vertical, DS.Space.md)
                    .background(DS.Palette.bg)
            }
            timeline
            pendingCallbackRows
            queuedMessagesSection
            composer
        }
        .background(DS.Palette.bg)
        // C6: Esc interrupts an in-flight run (remotecode.io parity).
        .onExitCommand { if vm.status == .running { vm.stop() } }
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
            DSPill(vm.status.rawValue, tone: statusTone(vm.status))
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
                Text("The agent runs tools and edits without asking for the rest of this session.")
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
        let now = Date().timeIntervalSinceReferenceDate
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
        let now = Date().timeIntervalSinceReferenceDate
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
                            let entries = visibleTranscriptEntries
                            let hiddenEntryCount = transcriptEntries.count - entries.count
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
                            if hiddenEntryCount > 0 {
                                runningHiddenTranscriptRow(hiddenEntryCount)
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
                            if vm.status == .running { workingStatus }
                            if let err = vm.timeline.error { errorRow(err) }
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
                // PERF-MAC_AGENT-012: turns trim at 80; drop expansion ids for
                // items that no longer exist so the sets don't leak over a long
                // session. Runs only on a turn add/remove, not per text delta.
                DispatchQueue.main.async {
                    pruneExpandedItemIds()
                }
            }
            .onChange(of: vm.status) { _ in scheduleTimelineScrollToBottom(proxy) }
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

    @ViewBuilder
    private var pendingCallbackRows: some View {
        if !vm.openPendingRequests.isEmpty || !vm.openPendingUserInputs.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                ForEach(vm.openPendingRequests) { request in
                    pendingRequestRow(request)
                }
                ForEach(vm.openPendingUserInputs) { request in
                    pendingUserInputRow(request)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.bg)
            .accessibilityIdentifier("agent.pendingCallbacks")
            .confirmationDialog(
                "Allow this agent to act without approvals for the rest of this session?",
                isPresented: Binding(
                    get: { pendingSessionApproval != nil },
                    set: { if !$0 { pendingSessionApproval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Allow full access", role: .destructive) {
                    if let pendingSessionApproval {
                        vm.respondToPendingRequest(pendingSessionApproval, response: .approveForSession)
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
                        Button("Approve Session") { pendingSessionApproval = request }
                            .buttonStyle(.bordered)
                            .tint(DS.Palette.warning)
                            .help("Auto-approve every request like this for the rest of this session")
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
                        get: { vm.userInputDrafts[request.id] ?? request.answer ?? "" },
                        set: { vm.userInputDrafts[request.id] = $0 }
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
                        vm.answerPendingUserInput(request, answer: vm.userInputDrafts[request.id] ?? request.answer ?? "")
                    }
                    .disabled((vm.userInputDrafts[request.id] ?? request.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if request.allowsMultipleSelection {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(spacing: DS.Space.sm) {
                        ForEach(request.options, id: \.self) { option in
                            let selected = vm.userInputSelections[request.id]?.contains(option) == true
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
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .accessibilityIdentifier("agent.pendingUserInput.\(request.id)")
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
                    Button("Stop") { vm.stop() }
                        .buttonStyle(.plain)
                        .font(DS.Font.body.weight(.medium))
                        .foregroundColor(DS.Palette.danger)
                        .help("Stop running agent (press Esc to interrupt)")
                        .accessibilityIdentifier("agent.working.stop")
                }
            }
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var elapsedString: String {
        let s = max(0, Int(Date().timeIntervalSince(vm.runStartedAt ?? Date())))
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
        AgentMessageMarkdownView(text: text)
            .foregroundColor(DS.Palette.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runningHiddenTranscriptRow(_ count: Int) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
            Text("\(count) earlier transcript items hidden while this run is active")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, 6)
        .background(DS.Palette.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityIdentifier("agent.runningHiddenTranscript")
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
            // UX-MAC_AGENT-009: recoverable failures get a Retry of the last
            // prompt; fatal ones don't.
            if recoverable {
                Button {
                    Task { await vm.retryLastPrompt() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("agent.error.retry")
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

    // UX-MAC_AGENT-018: composer chips classify by extension for the icon.
    private static let imageChipExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "webp", "svg", "avif"
    ]
    static func isImagePath(_ path: String) -> Bool {
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
            HStack(spacing: 0) {
                Spacer(minLength: 32)
                VStack(alignment: .trailing, spacing: DS.Space.xs) {
                    Text(displayText)
                        .font(DS.Font.body)
                        .foregroundColor(DS.Palette.text)
                        .textSelection(.enabled)
                        .lineLimit(28)
                        .truncationMode(.tail)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .background(DS.Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxWidth: 600, alignment: .trailing)
                        .accessibilityIdentifier("agent.userMessageBubble")
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
                assistantProse(msg.content)
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
        let turnPlans = proposedPlans(for: turn)
        let renderableItems = Self.renderableItems(in: turn, persistedAssistantTexts: persistedAssistantTexts)
            .filter { !($0.type == .plan && !turnPlans.isEmpty) }
        let runningTurn = !turn.finished && vm.status == .running
        let visibleRenderableItems = Self.visibleLiveTurnItems(renderableItems, running: runningTurn)
        let hiddenLiveItemCount = renderableItems.count - visibleRenderableItems.count
        let workItems = turn.finished ? Self.completedWorkItems(
            in: turn,
            renderableItems: renderableItems,
            persistedAssistantTexts: persistedAssistantTexts
        ) : []
        let visibleAssistantItems = turn.finished ? Self.completedVisibleAssistantItems(
            in: turn,
            renderableItems: renderableItems,
            persistedAssistantTexts: persistedAssistantTexts
        ) : []
        let blocks = Self.turnRenderBlocks(turn.finished ? visibleAssistantItems : visibleRenderableItems)
        let completedWorkBlocks = Self.turnRenderBlocks(workItems)
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            if turn.finished, !completedWorkBlocks.isEmpty {
                completedWorkDisclosure(turn: turn, blocks: completedWorkBlocks)
            }
            if !turn.finished {
                if hiddenLiveItemCount > 0 {
                    hiddenLiveTurnItemsRow(hiddenLiveItemCount)
                }
                ForEach(blocks) { block in
                    switch block {
                    case .item(let item): itemRow(item)
                    case .toolGroup(let id, let items): toolGroupRow(id: id, items: items)
                    }
                }
            }
            ForEach(turnPlans) { plan in
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
            if let final = turn.finalAssistantMessage,
               Self.shouldRenderFinalAssistantMessage(turn, persistedAssistantTexts: persistedAssistantTexts) {
                assistantProse(final)
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

    private func proposedPlans(for turn: AssistantTurnSnapshot) -> [AssistantProposedPlan] {
        vm.timeline.proposedPlans.filter {
            $0.turnId == turn.turnId && !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
        case .tool, .commandExecution, .fileChange, .mcpToolCall, .dynamicToolCall, .collabToolCall, .webSearch, .imageView, .review, .contextCompaction, .error:
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
            if let command, !command.isEmpty {
                Text(command)
                    .font(DS.Font.monoSmall).foregroundColor(DS.Palette.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(expanded ? nil : 3)
                    .truncationMode(.tail)
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
        if !vm.queuedMessages.isEmpty || vm.queueStatusMessage != nil {
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
                text: $vm.prompt,
                height: $composerEditorHeight,
                focusTick: vm.focusTick,
                placeholder: "Ask \(vm.provider.rawValue.capitalized) for changes…",
                isEnabled: true,
                onSend: { Task { await vm.send() } },
                onPreviousHistory: { vm.recallPreviousPrompt() },
                onNextHistory: { vm.recallNextPrompt() },
                onTextEdited: { vm.promptWasEdited() },
                onFileDrop: { paths in vm.insertDroppedFilePaths(paths) }
            )
            .frame(height: composerEditorHeight)
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.sm)
            .padding(.bottom, DS.Space.xs)
            .accessibilityIdentifier("agent.composer.input")
            composerSuggestions
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
            if vm.status == .running {
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
        .foregroundColor(DS.Palette.textSecondary)
        .help("Attach files").accessibilityLabel("Attach files")
        .accessibilityIdentifier("agent.attach")
    }

    @ViewBuilder
    private var composerSuggestions: some View {
        let suggestions = vm.composerSuggestions
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.sm) {
                    ForEach(suggestions) { suggestion in
                        Button { vm.applyComposerSuggestion(suggestion) } label: {
                            HStack(spacing: DS.Space.xs) {
                                Image(systemName: suggestion.kind == .skill ? "puzzlepiece.extension" : "command")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(suggestion.title)
                                    .font(DS.Font.caption.weight(.medium))
                                    .lineLimit(1)
                            }
                            .foregroundColor(DS.Palette.text)
                            .padding(.horizontal, DS.Space.sm)
                            .padding(.vertical, DS.Space.xs)
                            .background(DS.Palette.surfaceRaised)
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                        }
                        .buttonStyle(.plain)
                        .help(suggestion.subtitle)
                        .accessibilityIdentifier("agent.suggestion.\(suggestion.insertText.trimmingCharacters(in: .whitespaces))")
                    }
                }
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.xs)
            }
        }
    }

    private var permissionMenu: some View {
        Menu {
            Button("Supervised") { vm.setPermissionMode(.supervised) }
            Button("Auto-edit") { vm.setPermissionMode(.autoAcceptEdits) }
            Button("Full access") { vm.setPermissionMode(.fullAccess) }
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
        .help("Permission mode")
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
        .disabled(vm.executionLocked)
        .help(vm.executionLocked ? "Execution mode locks after the first message" : "Execution mode")
        .accessibilityIdentifier("agent.execution.menu")
    }

    private var modelMenu: some View {
        Button {
            showModelOptions.toggle()
        } label: {
            modelMenuLabel
        }
        .buttonStyle(.plain)
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
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            // UX-MAC_AGENT-016: readable while running; the rows below disable.
            if vm.status == .running {
                Text("Read-only while running")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if !vm.providerLocked {
                if !vm.providerSnapshots.isEmpty {
                    compactMenuSection("Source")
                    ForEach(vm.providerSnapshots.filter(\.enabled), id: \.id) { snapshot in
                        compactMenuRow(snapshot.displayName, selected: snapshot.id == vm.providerInstanceId) {
                            vm.setProviderInstance(snapshot.id)
                        }
                    }
                    compactMenuDivider
                } else {
                    compactMenuSection("Source")
                    ForEach(AgentProvider.allCases, id: \.self) { provider in
                        compactMenuRow(vm.providerDisplayName(provider), selected: provider == vm.provider) {
                            vm.setProvider(provider)
                            Task { await vm.loadModels(); await MainActor.run { vm.persistThreadConfig() } }
                        }
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
                let visibleModelCount = showAllModelOptions ? modelOptions.count : min(3, modelOptions.count)
                let visibleCustomModelCount = showAllModelOptions ? customModels.count : max(0, 3 - visibleModelCount)
                let visibleModels = Array(modelOptions.prefix(visibleModelCount))
                let visibleCustomModels = Array(customModels.prefix(visibleCustomModelCount))
                ForEach(visibleModels, id: \.id) { model in
                    compactMenuRow(model.label, selected: model.id == vm.model) {
                        vm.setModel(model.id)
                        showModelOptions = false
                    }
                }
                ForEach(visibleCustomModels, id: \.self) { customModel in
                    compactMenuRow(customModel, selected: customModel == vm.model) {
                        vm.setCustomModel(customModel)
                        showModelOptions = false
                    }
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
                }
            }
            if vm.supportsServiceTierForSelectedModel {
                compactMenuSection("Service tier")
                compactMenuRow("Auto", selected: vm.serviceTier == .auto) {
                    vm.setServiceTier(.auto)
                    showModelOptions = false
                }
                compactMenuRow("Fast", selected: vm.serviceTier == .fast) {
                    vm.setServiceTier(.fast)
                    showModelOptions = false
                }
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
            if let actionStatus = vm.providerRecoveryStatusMessage,
               actionStatus.hasPrefix("Update failed") {
                Text(actionStatus)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.danger)
            }
        }
        .disabled(vm.status == .running)
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
        Button {
            Task { await vm.send() }
        } label: {
            ZStack {
                Circle()
                    .fill(sendIdleDisabled ? DS.Palette.surfaceRaised : DS.Palette.accent)
                    .frame(width: 28, height: 28)
                Image(systemName: vm.status == .running ? "text.line.first.and.arrowtriangle.forward" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(sendIdleDisabled ? DS.Palette.textTertiary : DS.Palette.onAccent)
            }
        }
        .buttonStyle(.plain)
        .disabled(sendIdleDisabled)
        .keyboardShortcut(.return, modifiers: [.command])
        .accessibilityLabel(vm.status == .running ? "Queue message" : "Send")
        .accessibilityIdentifier("agent.composer.send")
        .help(vm.status == .running ? "Queue message for this thread" : "Send prompt")
    }

    private var stopButton: some View {
        Button { vm.stop() } label: {
            ZStack {
                Circle()
                    .fill(DS.Palette.danger)
                    .frame(width: 28, height: 28)
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(DS.Palette.bg)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop running agent")
        .accessibilityIdentifier("agent.composer.stop")
        .help("Stop running agent")
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                ForEach(vm.attachments, id: \.self) { path in
                    HStack(spacing: DS.Space.xs) {
                        // UX-MAC_AGENT-018: image attachments read as images.
                        Image(systemName: Self.isImagePath(path) ? "photo" : "doc").font(.system(size: 9))
                        Text((path as NSString).lastPathComponent)
                            .font(DS.Font.caption2).lineLimit(1)
                        Button { vm.removeAttachment(path) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove attachment")
                        .help("Remove attachment")
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
        panel.canChooseDirectories = true
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
        vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && vm.attachments.isEmpty
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
        deleteThreads(selectedThreadIds.isEmpty ? fallback : selectedThreadIds)
    }

    private func deleteThreads(_ ids: Set<AgentThreadID>) {
        guard !ids.isEmpty else { return }
        vm.deleteThreads(ids)
        selectedThreadIds.subtract(ids)
        if let lastSelectedThreadId, ids.contains(lastSelectedThreadId) {
            self.lastSelectedThreadId = selectedThreadIds.first
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
                                Label("Implement", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
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
                        Button(role: .destructive) {
                            vm.revertSelectedCheckpoint()
                        } label: {
                            Label("Revert", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(checkpoint.status != .ready)
                        .accessibilityIdentifier("agent.checkpoint.revert")
                    }
                }
            }
            .padding(DS.Space.md)
            .background(DS.Palette.bg)
            .accessibilityIdentifier("agent.checkpoints.card")
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
                        Label("Implement", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
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
        return modifiers.contains(.shift) ? .insertNewline : .send
    }
}

private final class PromptComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onPreviousHistory: (() -> Bool)?
    var onNextHistory: (() -> Bool)?
    var onFileDrop: (([String]) -> Void)?
    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        switch PromptComposerKeyAction.action(for: event) {
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
        textView.isEditable = isEnabled
        textView.placeholderString = placeholder
        if textView.string != text {
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
        Coordinator(text: $text, height: $height, onTextEdited: onTextEdited)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var height: CGFloat
        let onTextEdited: () -> Void
        weak var textView: PromptComposerTextView?
        var appliedFocusTick: Int?
        private var externallyAppliedText: String?

        init(text: Binding<String>, height: Binding<CGFloat>, onTextEdited: @escaping () -> Void) {
            _text = text
            _height = height
            self.onTextEdited = onTextEdited
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
        }

        func applyExternalText(_ value: String, to textView: NSTextView) {
            externallyAppliedText = value
            textView.string = value
            textView.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
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
            if g.atBottom {
                report(atBottom: true)
            } else if g.origin < lastOriginY - 0.5 {
                report(atBottom: false)
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
        threadStatus == .running || (selected && surfaceStatus == .running)
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
    /// True when the thread has a running status, meaning a stop affordance should be shown.
    public static func isEligible(threadStatus: AgentRunStatus) -> Bool {
        threadStatus == .running
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

    public init(workspaceID: WorkspaceID, cwd: String, coordinator: AgentRunCoordinator, threadRepo: AgentThreadRepository, messageRepo: AgentMessageRepository, queuedMessageRepo: AgentQueuedMessageRepository? = nil, pendingCallbackRepo: ProviderPendingCallbackRepository? = nil, proposedPlanRepo: AgentProposedPlanRepository? = nil, checkpointRepo: AgentTurnCheckpointRepository? = nil, promptHistoryStore: PromptHistoryStore? = nil, customModelStore: AgentCustomModelStore? = nil, title: String = "Agent App") {
        self.descriptor = SurfaceDescriptor(type: .agentApp, title: title, iconName: "sparkle", metadata: ["workspace": workspaceID.value.uuidString, "cwd": cwd])
        self.viewModel = AgentAppViewModel(workspaceID: workspaceID, cwd: cwd, coordinator: coordinator, threadRepo: threadRepo, messageRepo: messageRepo, queuedMessageRepo: queuedMessageRepo, pendingCallbackRepo: pendingCallbackRepo, proposedPlanRepo: proposedPlanRepo, checkpointRepo: checkpointRepo, promptHistoryStore: promptHistoryStore, customModelStore: customModelStore)
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
    public func close() {}
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
    public var isBusy: Bool { viewModel.status == .running || viewModel.activeThreadCount > 0 }
}

private struct TabColorMenuLabel: View {
    let color: TabColor

    init(_ color: TabColor) {
        self.color = color
    }

    var body: some View {
        Label {
            Text(color.label)
        } icon: {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(hex: color.hex))
                .frame(width: 12, height: 12)
        }
    }
}
