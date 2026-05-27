import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import CoreModel
import Persistence
import AgentRuntime
import DesignSystemKit

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
    private var customModelSelections = Set<String>()
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
    /// When the active run started — drives the "Working for Xs" line.
    @Published public var runStartedAt: Date?

    public let workspaceID: WorkspaceID
    public let cwd: String
    public let coordinator: AgentRunCoordinator
    public let threadRepo: AgentThreadRepository
    public let messageRepo: AgentMessageRepository
    public let pendingCallbackRepo: ProviderPendingCallbackRepository?
    public let proposedPlanRepo: AgentProposedPlanRepository?
    public let checkpointRepo: AgentTurnCheckpointRepository?
    public let promptHistoryStore: PromptHistoryStore?
    private var promptHistory: [String] = []
    private var promptHistoryCursor: Int?
    private var terminalRunIds = Set<AgentRunID>()

    public init(
        workspaceID: WorkspaceID,
        cwd: String,
        coordinator: AgentRunCoordinator,
        threadRepo: AgentThreadRepository,
        messageRepo: AgentMessageRepository,
        pendingCallbackRepo: ProviderPendingCallbackRepository? = nil,
        proposedPlanRepo: AgentProposedPlanRepository? = nil,
        checkpointRepo: AgentTurnCheckpointRepository? = nil,
        promptHistoryStore: PromptHistoryStore? = nil
    ) {
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.coordinator = coordinator
        self.threadRepo = threadRepo
        self.messageRepo = messageRepo
        self.pendingCallbackRepo = pendingCallbackRepo
        self.proposedPlanRepo = proposedPlanRepo
        self.checkpointRepo = checkpointRepo
        self.promptHistoryStore = promptHistoryStore
        self.promptHistory = promptHistoryStore?.load(workspaceID: workspaceID) ?? []
        self.coordinator.addObserver(self)
        reloadThreads()
        loadGitBranch()
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

    public func selectThread(_ id: AgentThreadID) {
        selectedThreadId = id
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
        messageWindow = Self.baseMessageWindow
        loadWindow(id)
        timeline = AssistantTimelineState()
        let persistedEvents = coordinator.latestStreamEvents(threadId: id)
        let replayEvents = providerThreadSnapshotEvents(threadId: id).map {
            mergePersistedContextTelemetry(snapshot: $0, persisted: persistedEvents)
        } ?? persistedEvents
        for event in replayEvents {
            timeline.apply(event)
        }
        rehydrateProposedPlans(threadId: id)
        rehydratePendingCallbacks(threadId: id)
        reloadCheckpoints()
        suppressPersistedFinalDuplicatedByTimeline()
        timelineUpdateTick = 0
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
            checkpointStatusMessage = "Reverted to checkpoint \(turnCount)."
            messageWindow = Self.baseMessageWindow
            loadWindow(selectedThreadId)
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

    // MARK: B4 — bounded message window

    static let baseMessageWindow = 50
    private var messageWindow = AgentAppViewModel.baseMessageWindow
    @Published public var hasMoreOlder: Bool = false

    private func loadWindow(_ id: AgentThreadID) {
        let total = (try? messageRepo.count(threadId: id)) ?? 0
        messages = ((try? messageRepo.listRecent(threadId: id, limit: messageWindow)) ?? [])
            .map(Self.displayMessage)
        hasMoreOlder = total > messages.count
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

    public func loadEarlierMessages() {
        guard let id = selectedThreadId else { return }
        messageWindow += Self.baseMessageWindow
        loadWindow(id)
    }

    /// B7: count of threads with an in-flight run, for the rail header.
    public var activeThreadCount: Int { threads.filter { $0.status == .running }.count }

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
            if response == .approveForSession {
                setPermissionMode(.fullAccess)
            }
        } catch {
            timeline.apply(.error(message: "Provider request response failed: \(error)", recoverable: true))
            timeline.apply(.requestResolved(requestId: request.id, state: .stale))
        }
        timelineUpdateTick += 1
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
        }
        timelineUpdateTick += 1
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
                self.providerSnapshots = snapshots
                if self.selectedProviderSnapshot == nil {
                    self.providerInstanceId = snapshots.first(where: { $0.provider == self.provider })?.id ?? self.provider.rawValue
                }
                if let current = self.selectedProviderSnapshot {
                    self.provider = current.provider
                    self.availableModels = current.models
                    if !self.modelSelectionIsValid(self.model, in: current.models) {
                        self.model = current.models.first?.id ?? self.model
                    }
                    self.normalizeSelectedModelOptions()
                }
            }
        } catch {
            await MainActor.run {
                self.providerSnapshotStatusMessage = "Provider snapshot failed. Retry from the model menu."
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
            && customModelSelections.contains(model)
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
        guard !providerLocked else { return }
        self.model = model
        normalizeSelectedModelOptions()
        persistThreadConfig()
    }

    public func setCustomModel(_ raw: String) {
        guard !providerLocked else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportsCustomModelForSelectedProvider else { return }
        if !trimmed.isEmpty { customModelSelections.insert(trimmed) }
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
        timelineUpdateTick = 0
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
        timelineUpdateTick = 0
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
        for m in (try? messageRepo.list(threadId: tid)) ?? [] {
            try? messageRepo.append(AgentMessage(threadId: copy.id, role: m.role, content: m.content))
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
        loadWindow(tid)
        suppressPersistedFinalDuplicatedByTimeline()
        prompt = ""
        timelineUpdateTick = 0
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

    private func persistFinalAssistantIfMissing(_ text: String, threadId: AgentThreadID) {
        let text = AssistantTimelineState.cappedText(text)
        let existing = (try? messageRepo.list(threadId: threadId)) ?? []
        guard !existing.contains(where: { $0.role == .assistant && $0.content == text }) else { return }
        try? messageRepo.append(AgentMessage(threadId: threadId, role: .assistant, content: text))
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
            self.timelineUpdateTick &+= 1
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
                    self.loadWindow(finishedTid)
                    self.suppressPersistedFinalDuplicatedByTimeline()
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
            self.loadGitBranch()   // the run may have changed the tree
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
                self.status = status
                if status == .running {
                    self.terminalRunIds.remove(runId)
                    self.currentRunId = runId
                    if self.runStartedAt == nil { self.runStartedAt = Date() }
                } else if Self.isTerminalRunStatus(status) {
                    self.terminalRunIds.insert(runId)
                    self.currentRunId = nil
                    self.runStartedAt = nil
                    self.runThreads[runId] = nil
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

public struct AgentAppView: View {
    private static let threadRailWidth: CGFloat = 220
    @ObservedObject var vm: AgentAppViewModel
    @State private var renamingThreadId: AgentThreadID?
    @State private var renameText: String = ""
    @State private var expandedTools: Set<String> = []
    @State private var selectedThreadIds: Set<AgentThreadID> = []
    @State private var lastSelectedThreadId: AgentThreadID?
    @State private var draggingThreadId: AgentThreadID?
    @State private var timelineSticksToBottom = true
    @State private var showScrollDownButton = false
    @State private var userIsDraggingTimeline = false
    @State private var pendingScrollDownReveal: Task<Void, Never>?
    @State private var composerEditorHeight: CGFloat = PromptComposerEditor.minHeight
    @State private var showThreadRail = true
    @State private var proposedPlanExpanded = false
    @State private var showWorkLog = false

    public init(vm: AgentAppViewModel) { self.vm = vm }

    static func shouldRenderFinalAssistantMessage(_ turn: AssistantTurnSnapshot, persistedAssistantTexts: [String] = []) -> Bool {
        guard let final = turn.finalAssistantMessage, !final.isEmpty else { return false }
        if assistantText(final, matchesAny: persistedAssistantTexts) { return false }
        return !turn.items.contains {
            guard $0.type == .assistantMessage else { return false }
            return assistantText($0.body, matches: final)
        }
    }

    static func shouldRenderAssistantItemBody(_ body: String, persistedAssistantTexts: [String] = []) -> Bool {
        !body.isEmpty && !assistantText(body, matchesAny: persistedAssistantTexts)
    }

    private static func assistantText(_ text: String, matchesAny candidates: [String]) -> Bool {
        candidates.contains { assistantText(text, matches: $0) }
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

    private static func normalizedAssistantText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compactAssistantText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private var transcriptEntries: [TranscriptEntry] {
        (vm.messages.map(TranscriptEntry.message) + vm.timeline.turns.map(TranscriptEntry.turn))
            .sorted { lhs, rhs in
                if lhs.sortTime == rhs.sortTime { return lhs.id < rhs.id }
                return lhs.sortTime < rhs.sortTime
            }
    }

    private var persistedAssistantTexts: [String] {
        vm.messages.compactMap { $0.role == .assistant ? $0.content : nil }
    }

    public var body: some View {
        HSplitView {
            if showThreadRail {
                threadRail
                    .frame(width: Self.threadRailWidth)
            }
            conversationColumn
                .frame(minWidth: 460)
            if vm.showPlanSidebar {
                planSidebar.frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            }
        }
        .background(DS.Palette.bg)
        .task { await vm.loadProviderSnapshots() }
        .onDeleteCommand { deleteSelectedThreads() }
    }

    // MARK: Thread rail

    private var threadRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader(vm.activeThreadCount > 0 ? "Threads · \(vm.activeThreadCount) active" : "Threads",
                            trailing: AnyView(
                HStack(spacing: DS.Space.xs) {
                    DSIconButton("sidebar.left", help: "Hide threads") { showThreadRail = false }
                    DSIconButton("plus", help: "New thread") { vm.createThread(title: "New thread") }
                }
            ))
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            if vm.threads.isEmpty {
                DSEmptyState(icon: "bubble.left.and.bubble.right",
                             title: "No threads",
                             subtitle: "Send a prompt to start a Codex or Claude thread.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
                        ForEach(vm.threads, id: \.id) { t in threadRow(t) }
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
                        // A3: spinner while this thread has a run in flight.
                        ProgressView().controlSize(.small).scaleEffect(0.5)
                            .frame(width: 8, height: 8)
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
            .onDrag {
                draggingThreadId = t.id
                return NSItemProvider(object: t.id.value.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: AgentThreadDropDelegate(vm: vm, draggingThreadId: $draggingThreadId, target: t))
            .contextMenu {
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
            if !vm.timeline.workActivities.isEmpty {
                workLogRow
                    .padding(.horizontal, 22)
                    .padding(.vertical, DS.Space.md)
                    .background(DS.Palette.bg)
            }
            timeline
            composer
        }
        .background(DS.Palette.bg)
        // C6: Esc interrupts an in-flight run (remotecode.io parity).
        .onExitCommand { if vm.status == .running { vm.stop() } }
    }

    // Thin context header. Run-config (provider/model/permission) lives in
    // the composer footer now, Codex-style.
    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            if !showThreadRail {
                DSIconButton("sidebar.left", help: "Show threads") { showThreadRail = true }
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
                vm.showPlanSidebar.toggle()
            }
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
        .dsBar(edge: .bottom)
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
                        VStack(alignment: .leading, spacing: 32) {
                            pendingCallbackRows
                            ForEach(transcriptEntries) { entry in
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
                            Color.clear
                                .frame(height: 1)
                                .id("BOTTOM")
                                .background(
                                    GeometryReader { marker in
                                        Color.clear.preference(
                                            key: TimelineBottomPreferenceKey.self,
                                            value: marker.frame(in: .named("agentTimeline")).maxY
                                        )
                                    }
                                )
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 32)
                        .frame(maxWidth: 920, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .coordinateSpace(name: "agentTimeline")
                    .background(DS.Palette.bg)
                    .onPreferenceChange(TimelineBottomPreferenceKey.self) { bottomY in
                        updateTimelineBottomVisibility(bottomY: bottomY, viewportHeight: viewport.size.height)
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { _ in userIsDraggingTimeline = true }
                            .onEnded { _ in userIsDraggingTimeline = false }
                    )
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
                    .help("Scroll to latest message")
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .onAppear { scrollTimelineToBottom(proxy) }
            .onChange(of: vm.focusTick) { _ in scrollTimelineToBottom(proxy, force: true) }
            .onChange(of: vm.messages.count) { _ in scrollTimelineToBottom(proxy) }
            .onChange(of: vm.timeline.turns.count) { _ in scrollTimelineToBottom(proxy) }
            .onChange(of: vm.timelineUpdateTick) { _ in scrollTimelineToBottom(proxy) }
            .onChange(of: vm.status) { _ in scrollTimelineToBottom(proxy) }
        }
    }

    @ViewBuilder
    private var pendingCallbackRows: some View {
        ForEach(vm.openPendingRequests) { request in
            pendingRequestRow(request)
        }
        ForEach(vm.openPendingUserInputs) { request in
            pendingUserInputRow(request)
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
                Spacer(minLength: 0)
            }
            Text(request.title)
                .font(DS.Font.bodyDense.weight(.semibold))
                .foregroundColor(DS.Palette.text)
                .lineLimit(2)
            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(DS.Font.monoSmall)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if stale {
                Text("Restart the turn to continue.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.warning)
            } else {
                HStack(spacing: DS.Space.sm) {
                    Button("Approve") { vm.respondToPendingRequest(request, response: .approve) }
                    Button("Approve Session") { vm.respondToPendingRequest(request, response: .approveForSession) }
                    Button("Decline") { vm.respondToPendingRequest(request, response: .decline(nil)) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .accessibilityIdentifier("agent.pendingRequest.\(request.id)")
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

    private func scrollTimelineToBottom(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard force || timelineSticksToBottom else { return }
        cancelPendingScrollDownReveal()
        timelineSticksToBottom = true
        showScrollDownButton = false
        withAnimation(DS.Motion.micro) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
    }

    private func updateTimelineBottomVisibility(bottomY: CGFloat, viewportHeight: CGFloat) {
        let atBottom = bottomY <= viewportHeight + 36
        if atBottom {
            cancelPendingScrollDownReveal()
            timelineSticksToBottom = true
            showScrollDownButton = false
            return
        }

        if userIsDraggingTimeline {
            cancelPendingScrollDownReveal()
            timelineSticksToBottom = false
            showScrollDownButton = true
            return
        }

        guard pendingScrollDownReveal == nil else { return }
        pendingScrollDownReveal = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            timelineSticksToBottom = false
            showScrollDownButton = true
            pendingScrollDownReveal = nil
        }
    }

    private func cancelPendingScrollDownReveal() {
        pendingScrollDownReveal?.cancel()
        pendingScrollDownReveal = nil
    }

    // "Working for 2m 21s" + hairline, while a run is in flight.
    private var workingStatus: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            TimelineView(.periodic(from: vm.runStartedAt ?? Date(), by: 1)) { _ in
                HStack(spacing: DS.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Working for \(elapsedString)")
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
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

    @ViewBuilder
    private func assistantProse(_ text: String) -> some View {
        AgentMessageMarkdownView(text: text)
            .foregroundColor(DS.Palette.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyConversation: some View {
        Text("No timeline yet. Send a prompt.")
            .font(DS.Font.body)
            .foregroundColor(DS.Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func errorRow(_ err: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundColor(DS.Palette.danger)
            Text(err)
                .font(DS.Font.monoSmall).foregroundColor(DS.Palette.danger)
                .lineSpacing(3).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func messageRow(_ msg: AgentMessage) -> some View {
        switch msg.role {
        case .user:
            HStack(spacing: 0) {
                Spacer(minLength: 32)
                VStack(alignment: .trailing, spacing: DS.Space.xs) {
                    Text(msg.content)
                        .font(DS.Font.body)
                        .foregroundColor(DS.Palette.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .background(DS.Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxWidth: 600, alignment: .trailing)
                        .accessibilityIdentifier("agent.userMessageBubble")
                    Button { copyToPasteboard(msg.content) } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityLabel("Copy message")
                    .help("Copy message")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            assistantProse(msg.content)
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
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            ForEach(turn.items.filter { !($0.type == .plan && !turnPlans.isEmpty) }, id: \.id) { item in itemRow(item) }
            ForEach(turnPlans) { plan in
                proposedPlanRow(plan)
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
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(item.state == .streaming ? "Thinking…" : "Thought")
                    .font(DS.Font.caption2.weight(.semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                let text = item.body.isEmpty ? (AgentTimelineItemPresentation.make(for: item).detail ?? "") : item.body
                if !text.isEmpty {
                    Text(text)
                        .font(DS.Font.bodyDense)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    private func toolRow(_ item: AssistantItem) -> some View {
        let presentation = AgentTimelineItemPresentation.make(for: item)
        let hasOutput = (presentation.detail?.isEmpty == false)
        let expanded = expandedTools.contains(item.id)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Button {
                guard hasOutput else { return }
                if expanded { expandedTools.remove(item.id) } else { expandedTools.insert(item.id) }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: presentation.icon)
                        .font(.system(size: 10)).foregroundColor(DS.Palette.textSecondary)
                    (Text("\(presentation.verb) ")
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
                     + Text(presentation.label)
                        .font(DS.Font.mono).foregroundColor(DS.Palette.textSecondary))
                    .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if hasOutput {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8)).foregroundColor(DS.Palette.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hasOutput ? (expanded ? "Hide tool output" : "Show tool output") : "Tool output unavailable")
            if expanded, let o = presentation.detail, !o.isEmpty {
                Text(o)
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

    // MARK: Composer

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
                placeholder: "Ask \(vm.provider.rawValue.capitalized) for changes…",
                isEnabled: vm.status != .running,
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

    private var composerToolbar: some View {
        HStack(spacing: DS.Space.md) {
            Button(action: pickAttachments) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textSecondary)
            .help("Attach files").accessibilityLabel("Attach files")
            .disabled(vm.status == .running)
            permissionMenu
            executionMenu
            Spacer(minLength: DS.Space.sm)
            if vm.status == .running {
                ProgressView().controlSize(.small).scaleEffect(0.55)
            }
            modelMenu
            sendStopButton
        }
        .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
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
    }

    private var modelMenu: some View {
        Menu {
            if !vm.providerLocked {
                if !vm.providerSnapshots.isEmpty {
                    Picker("Source", selection: Binding(
                        get: { vm.providerInstanceId },
                        set: { vm.setProviderInstance($0) }
                    )) {
                        ForEach(vm.providerSnapshots.filter(\.enabled), id: \.id) { snapshot in
                            Text(snapshot.displayName).tag(snapshot.id)
                        }
                    }
                    .disabled(vm.status == .running)
                } else {
                    Picker("Source", selection: Binding(
                        get: { vm.provider },
                        set: { provider in
                            vm.setProvider(provider)
                            Task { await vm.loadModels(); await MainActor.run { vm.persistThreadConfig() } }
                        }
                    )) {
                        ForEach(AgentProvider.allCases, id: \.self) { provider in
                            Text(vm.providerDisplayName(provider)).tag(provider)
                        }
                    }
                    .disabled(vm.status == .running)
                }
            }
            let modelOptions = vm.modelOptionsForSelectedProvider
            if vm.modelListLoading {
                Text("Loading models...")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            if vm.modelListStatusMessage != nil || vm.providerSnapshotStatusMessage != nil {
                Button("Retry loading models") {
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
            if !modelOptions.isEmpty {
                Picker("Model", selection: $vm.model) {
                    ForEach(modelOptions, id: \.id) { m in Text(m.label).tag(m.id) }
                    if vm.supportsCustomModelForSelectedProvider,
                       !vm.model.isEmpty,
                       !modelOptions.contains(where: { $0.id == vm.model }) {
                        Text("Custom: \(vm.model)").tag(vm.model)
                    }
                }
                .onChange(of: vm.model) { newValue in vm.setModel(newValue) }
                .disabled(vm.status == .running || vm.providerLocked)
            }
            if vm.supportsCustomModelForSelectedProvider {
                TextField("Custom model", text: Binding(
                    get: { vm.model },
                    set: { vm.setCustomModel($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .disabled(vm.status == .running || vm.providerLocked)
            }
            if let contextWindow = vm.selectedModelContextWindowLabel {
                Text(contextWindow)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            if vm.supportsReasoningForSelectedModel || vm.supportsServiceTierForSelectedModel {
                Divider()
            }
            if vm.supportsReasoningForSelectedModel {
                Picker("Reasoning effort", selection: $vm.reasoningEffort) {
                    ForEach(vm.supportedReasoningEffortsForSelectedModel, id: \.self) { e in
                        Text(e.displayName).tag(e)
                    }
                }
                .onChange(of: vm.reasoningEffort) { newValue in vm.setReasoningEffort(newValue) }
            }
            if vm.supportsServiceTierForSelectedModel {
                Picker("Service tier", selection: $vm.serviceTier) {
                    Text("Auto").tag(AgentServiceTier.auto)
                    Text("Fast").tag(AgentServiceTier.fast)
                }
                .onChange(of: vm.serviceTier) { newValue in vm.setServiceTier(newValue) }
            }
            if let providerStatus = vm.providerStatusMessage {
                Divider()
                Text(providerStatus)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.danger)
            }
            if let accountStatus = vm.providerAccountStatusMessage {
                Text(accountStatus)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            if let actionTitle = vm.providerRecoveryActionTitle {
                Button(vm.providerRecoveryActionRunning ? "Working..." : actionTitle) {
                    Task { await vm.performProviderRecoveryAction() }
                }
                .disabled(vm.providerRecoveryActionRunning)
            }
            if let actionStatus = vm.providerRecoveryStatusMessage {
                Text(actionStatus)
                    .font(DS.Font.caption)
                    .foregroundColor(actionStatus.hasPrefix("Update failed") ? DS.Palette.danger : DS.Palette.textSecondary)
            }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Text(modelLabel).font(DS.Font.caption.weight(.medium)).foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                if vm.supportsReasoningForSelectedModel {
                    Text("·").foregroundColor(DS.Palette.textTertiary)
                    Text(effortLabel).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                        .lineLimit(1)
                }
                if vm.serviceTier == .fast {
                    Text("·").foregroundColor(DS.Palette.textTertiary)
                    Text(serviceTierLabel).font(DS.Font.caption).foregroundColor(DS.Palette.warning)
                        .lineLimit(1)
                }
                if let contextWindow = vm.selectedModelContextWindowLabel {
                    Text("·").foregroundColor(DS.Palette.textTertiary)
                    Text(contextWindow).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
            }
            .fixedSize()
            .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
            .background(DS.Palette.surfaceRaised)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(vm.status == .running)
        .help(vm.providerLocked ? "Model · reasoning effort · service tier" : "Provider · model · reasoning effort · service tier")
    }

    private var sendStopButton: some View {
        Button {
            if vm.status == .running { vm.stop() } else { Task { await vm.send() } }
        } label: {
            ZStack {
                Circle()
                    .fill(vm.status == .running ? DS.Palette.text
                          : (sendIdleDisabled ? DS.Palette.surfaceRaised : DS.Palette.accent))
                    .frame(width: 28, height: 28)
                Image(systemName: vm.status == .running ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(vm.status == .running ? DS.Palette.bg
                                     : (sendIdleDisabled ? DS.Palette.textTertiary : DS.Palette.onAccent))
            }
        }
        .buttonStyle(.plain)
        .disabled(vm.status != .running && sendIdleDisabled)
        .keyboardShortcut(.return, modifiers: [.command])
        .accessibilityLabel(vm.status == .running ? "Stop" : "Send")
        .help(vm.status == .running ? "Stop running agent" : "Send prompt")
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                ForEach(vm.attachments, id: \.self) { path in
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "doc").font(.system(size: 9))
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
                DSIconButton("xmark", help: "Hide plan") { vm.showPlanSidebar = false }
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
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if event.keyCode == 126 { return .previousHistory }
            if event.keyCode == 125 { return .nextHistory }
        }
        guard event.keyCode == 36 || event.keyCode == 76 else { return .ignore }
        return event.modifierFlags.contains(.shift) ? .insertNewline : .send
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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, height: $height, onTextEdited: onTextEdited)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var height: CGFloat
        let onTextEdited: () -> Void
        weak var textView: PromptComposerTextView?
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

private struct TimelineBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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

    public init(workspaceID: WorkspaceID, cwd: String, coordinator: AgentRunCoordinator, threadRepo: AgentThreadRepository, messageRepo: AgentMessageRepository, pendingCallbackRepo: ProviderPendingCallbackRepository? = nil, proposedPlanRepo: AgentProposedPlanRepository? = nil, checkpointRepo: AgentTurnCheckpointRepository? = nil, promptHistoryStore: PromptHistoryStore? = nil, title: String = "Agent App") {
        self.descriptor = SurfaceDescriptor(type: .agentApp, title: title, iconName: "sparkle", metadata: ["workspace": workspaceID.value.uuidString, "cwd": cwd])
        self.viewModel = AgentAppViewModel(workspaceID: workspaceID, cwd: cwd, coordinator: coordinator, threadRepo: threadRepo, messageRepo: messageRepo, pendingCallbackRepo: pendingCallbackRepo, proposedPlanRepo: proposedPlanRepo, checkpointRepo: checkpointRepo, promptHistoryStore: promptHistoryStore)
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
