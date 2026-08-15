import AppKit
import AgentRuntime
import CoreModel
import DesignSystemKit
import Persistence
import Surfaces
import SwiftUI

// MARK: - Drafts & rows

public struct BotQueuedFollowUp: Equatable, Identifiable, Codable {
    public let id: UUID
    public var text: String
    public var attachments: [AgentAttachment]

    public init(id: UUID = UUID(), text: String, attachments: [AgentAttachment] = []) {
        self.id = id
        self.text = text
        self.attachments = attachments
    }
}

public struct BotStudioDraft: Equatable {
    public var botID: BotID?
    public var name: String
    public var title: String
    public var description: String
    public var handle: String
    public var avatarSymbol: String
    public var soul: String
    public var provider: AgentProvider
    public var providerInstanceID: String
    public var model: String
    public var notificationsEnabled: Bool
    public var desktopKind: BotDesktopKind
    public var expectedRevisionID: BotRevisionID?

    public init(
        botID: BotID? = nil,
        name: String = "",
        title: String = "",
        description: String = "",
        handle: String = "",
        avatarSymbol: String = "person.crop.circle",
        soul: String = "",
        provider: AgentProvider = .claude,
        providerInstanceID: String = "claude",
        model: String = "",
        notificationsEnabled: Bool = true,
        desktopKind: BotDesktopKind = .logicalExecutionSpace,
        expectedRevisionID: BotRevisionID? = nil
    ) {
        self.botID = botID
        self.name = name
        self.title = title
        self.description = description
        self.handle = handle
        self.avatarSymbol = avatarSymbol
        self.soul = soul
        self.provider = provider
        self.providerInstanceID = providerInstanceID
        self.model = model
        self.notificationsEnabled = notificationsEnabled
        self.desktopKind = desktopKind
        self.expectedRevisionID = expectedRevisionID
    }

    public var isNew: Bool { botID == nil }
}

public struct BotDeskMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public let text: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

public struct BotDeskWorkLogRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let detail: String
    public let statusLabel: String
    public let createdAt: Date
    public let runID: AgentRunID

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        statusLabel: String,
        createdAt: Date = Date(),
        runID: AgentRunID
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.statusLabel = statusLabel
        self.createdAt = createdAt
        self.runID = runID
    }
}

public enum BotDeskTimelineItem: Identifiable, Equatable, Sendable {
    case message(BotDeskMessage)
    case workLog(BotDeskWorkLogRow)
    case liveTurn(AssistantTurnSnapshot, hideAssistantOutput: Bool)

    public var id: String {
        switch self {
        case .message(let message): return "msg-\(message.id.uuidString)"
        case .workLog(let row): return "log-\(row.id.uuidString)"
        case .liveTurn(let turn, _): return "turn-\(turn.turnId)"
        }
    }

    public var createdAt: Date {
        switch self {
        case .message(let message): return message.createdAt
        case .workLog(let row): return row.createdAt
        case .liveTurn(let turn, _): return AgentChatLiveTurnChrome.turnSortDate(turn)
        }
    }

    var stableOrder: Int {
        switch self {
        case .message(let message):
            return message.role == .user ? 0 : 3
        case .liveTurn:
            return 1
        case .workLog:
            return 2
        }
    }
}

public enum BotsScreen: String, Equatable {
    case fleet
    case studio
    case desk
    case attention
}

public enum BotDeskInspectorTab: String, CaseIterable, Identifiable {
    case memory
    case routines

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .memory: return "Memory"
        case .routines: return "Routines"
        }
    }

    public var accessibilityIdentifier: String {
        switch self {
        case .memory: return "bots.desk.inspector.tab.memory"
        case .routines: return "bots.desk.inspector.tab.routines"
        }
    }
}

public enum BotStudioTab: String, CaseIterable, Identifiable {
    case profile
    case memory
    case skills
    case routines
    case security
    case desktop

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .profile: return "Profile"
        case .memory: return "Memory"
        case .skills: return "Skills"
        case .routines: return "Routines"
        case .security: return BotsChrome.Label.security
        case .desktop: return "Desktop"
        }
    }

    public var accessibilityIdentifier: String {
        switch self {
        case .profile: return "bots.studio.tab.profile"
        case .memory: return "bots.studio.tab.memory"
        case .skills: return "bots.studio.tab.skills"
        case .routines: return "bots.studio.tab.routines"
        case .security: return "bots.studio.tab.security"
        case .desktop: return "bots.studio.tab.desktop"
        }
    }
}

// MARK: - View model

@MainActor
public final class BotsViewModel: ObservableObject {
    public static let assistantPlaceholder = BotsDeskFollowThrough.noRouterPlaceholder

    @Published public private(set) var bots: [BotDefinition] = []
    @Published public var searchText: String = ""
    @Published public var showHidden: Bool = false { didSet { reloadFleet() } }
    @Published public var selectedBotID: BotID?
    @Published public var screen: BotsScreen = .fleet {
        didSet { persistScreen() }
    }
    @Published public var inspectorTab: BotDeskInspectorTab = .memory {
        didSet { persistInspectorTab() }
    }
    @Published public var studioTab: BotStudioTab = .profile {
        didSet { persistStudioTab() }
    }
    @Published public var studioDraft = BotStudioDraft()
    @Published public var composerText: String = ""
    @Published public var attachments: [AgentAttachment] = []
    @Published public var isStopping = false
    @Published public private(set) var queuedFollowUps: [BotQueuedFollowUp] = []
    @Published public private(set) var deskMessages: [BotDeskMessage] = []
    @Published public private(set) var deskWorkLog: [BotDeskWorkLogRow] = []
    @Published public private(set) var deskLiveTimeline = AssistantTimelineState()
    @Published public private(set) var deskStreamEventCount = 0
    @Published public private(set) var deskSendInFlight = false
    @Published public private(set) var deskSendInFlightStartedAt: Date?
    @Published public private(set) var conversations: [BotConversation] = []
    @Published public private(set) var selectedConversation: BotConversation?
    @Published public private(set) var attentionItems: [BotAttentionItem] = []
    @Published public private(set) var memoryItems: [BotMemoryItem] = []
    @Published public private(set) var skillBindings: [BotSkillBinding] = []
    @Published public private(set) var selectedRevision: BotRevision?
    @Published public private(set) var routines: [BotRoutine] = []
    @Published public var memoryDraft: String = ""
    @Published public var skillDraft: String = ""
    @Published public var routineName: String = ""
    @Published public var routinePrompt: String = ""
    @Published public var routineScheduleNote: String = ""
    @Published public var errorMessage: String?
    @Published public private(set) var providers: [AgentProviderSnapshot] = []
    @Published public private(set) var isControlPlaneActive = true
    @Published public private(set) var isMemoryActive = true
    @Published public private(set) var isAutonomyActive = false
    @Published public private(set) var isDesktopVMActive = false
    @Published public private(set) var isDesktopRemoteActive = false
    @Published public private(set) var lastSendStartedProviderRun = false
    @Published public var pendingDeleteID: BotID?
    public var onLeaveBots: (() -> Void)?

    public let desktopHonestyLabel = BotDesktopKind.logicalExecutionSpaceHonestyLabel

    private let context: AppContext
    private let router: AppCommandRouter?
    private let botStore: BotStore
    private let settingsStore: SettingsStore
    private var messagesByBot: [BotID: [BotDeskMessage]] = [:]
    private var attentionStateByBot: [BotID: BotAttentionState] = [:]
    private var lastPreviewByBot: [BotID: String] = [:]
    private var lastUpdatedByBot: [BotID: Date] = [:]
    private var lastLinkedRunIDByBot: [BotID: AgentRunID] = [:]
    private var liveTimelineByBot: [BotID: AssistantTimelineState] = [:]
    private var liveStreamCountByBot: [BotID: Int] = [:]
    private var queuedFollowUpsByBot: [BotID: [BotQueuedFollowUp]] = [:]
    private var deskLiveTurnWatch: Task<Void, Never>?

    public init(context: AppContext, router: AppCommandRouter? = nil) {
        self.context = context
        self.router = router
        self.botStore = context.botStore
        self.settingsStore = SettingsStore(db: context.db)
        restoreQueuedFollowUpsIfNeeded()
        restoreInspectorTabIfNeeded()
        restoreStudioTabIfNeeded()
        reload()
        restoreScreenIfNeeded()
        context.coordinator.addObserver(self)
    }

    deinit {
        deskLiveTurnWatch?.cancel()
        context.coordinator.removeObserver(self)
    }

    public var selectedBot: BotDefinition? {
        bots.first { $0.id == selectedBotID } ?? (selectedBotID.flatMap { try? botStore.get(id: $0) })
    }

    public var fleet: [BotDefinition] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [BotDefinition]
        if query.isEmpty {
            filtered = bots
        } else {
            filtered = bots.filter { bot in
                bot.name.lowercased().contains(query)
                    || bot.handle.lowercased().contains(query)
                    || bot.title.lowercased().contains(query)
                    || bot.description.lowercased().contains(query)
            }
        }
        return filtered.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public var openAttentionCount: Int { attentionItems.count }

    public func attentionState(for bot: BotDefinition) -> BotAttentionState {
        let state = attentionStateByBot[bot.id] ?? .none
        if isViewing(bot.id), state == .unreadActivity { return .none }
        return state
    }

    public func isViewing(_ botID: BotID) -> Bool {
        selectedBotID == botID && screen == .desk
    }

    public func rosterPreview(for bot: BotDefinition) -> String {
        if let preview = lastPreviewByBot[bot.id], !preview.isEmpty {
            return BotsDeskFollowThrough.displayUserText(from: preview)
        }
        if !bot.title.isEmpty { return bot.title }
        return "No job yet"
    }

    public func rosterTimestamp(for bot: BotDefinition) -> Date? {
        lastUpdatedByBot[bot.id]
    }

    public func currentGoal(for bot: BotDefinition) -> String {
        if let conversation = selectedConversation, conversation.botID == bot.id,
           !conversation.title.isEmpty {
            return BotsDeskFollowThrough.displayUserText(from: conversation.title)
        }
        let preview = rosterPreview(for: bot)
        if preview == "No job yet" { return "No current goal" }
        return preview
    }

    public func activityRows(for bot: BotDefinition) -> [BotActivityRow] {
        let cached = messagesByBot[bot.id] ?? []
        let source = cached.isEmpty && selectedBotID == bot.id ? deskMessages : cached
        let rows = source.suffix(4).map { message in
            BotActivityRow(id: message.id, text: message.text, createdAt: message.createdAt)
        }
        if !rows.isEmpty { return Array(rows) }
        if let preview = lastPreviewByBot[bot.id], let stamp = lastUpdatedByBot[bot.id] {
            return [BotActivityRow(text: preview, createdAt: stamp)]
        }
        return []
    }

    public var deskPaintsLiveTurnChrome: Bool {
        AgentChatLiveTurnChrome.paintsLiveTurnChrome(deskLiveTimeline)
    }

    public var deskHasStreamingTools: Bool {
        AgentChatLiveTurnChrome.hasStreamingTools(in: deskLiveTimeline)
    }

    public var deskTimeline: [BotDeskTimelineItem] {
        BotsDeskFollowThrough.timeline(
            messages: deskMessages,
            workLog: deskWorkLog,
            turns: deskLiveTimeline.turns,
            hideWorkLog: deskPaintsLiveTurnChrome,
            hideWorkingPlaceholder: deskPaintsLiveTurnChrome || deskRunIsLive
        )
    }

    public func modelLabel(for bot: BotDefinition) -> String? {
        if selectedBotID == bot.id,
           let model = trimmedNonEmpty(selectedRevision?.model) {
            return model
        }
        if let revisionID = bot.currentRevisionID,
           let revision = try? botStore.getRevision(id: revisionID) {
            return trimmedNonEmpty(revision.model)
        }
        return nil
    }

    public func permissionLabel(for bot: BotDefinition) -> String {
        "Supervised"
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func reload() {
        refreshFlags()
        reloadFleet()
        reloadAttention()
        restoreSelectedBotIfNeeded()
        if let selectedBotID {
            reloadSelectedBot(id: selectedBotID)
        }
        Task { [weak self] in
            guard let self else { return }
            if let router = self.resolvedRouter() {
                self.providers = await router.listAgentProviderSnapshots()
            }
        }
    }

    public func beginCreate() {
        guard isControlPlaneActive else {
            errorMessage = "Turn on Bot control plane in Settings"
            return
        }
        do {
            // Match the bar: create opens a teammate immediately; profile is optional.
            let bot = try create(name: "New Agent", title: "", description: "")
            openDesk(bot)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func beginEdit(_ bot: BotDefinition) {
        let revision = bot.currentRevisionID.flatMap { try? botStore.getRevision(id: $0) }
        studioDraft = BotStudioDraft(
            botID: bot.id,
            name: bot.name,
            title: bot.title,
            description: bot.description,
            handle: bot.handle,
            avatarSymbol: bot.avatarSymbol,
            soul: revision?.soul ?? "",
            provider: revision?.provider ?? .claude,
            providerInstanceID: revision?.providerInstanceID ?? (revision?.provider.rawValue ?? "claude"),
            model: revision?.model ?? "",
            notificationsEnabled: bot.notificationsEnabled,
            desktopKind: revision?.desktopKind ?? .logicalExecutionSpace,
            expectedRevisionID: bot.currentRevisionID
        )
        if studioDraft.model.isEmpty {
            applyDefaultModel(for: studioDraft.provider)
        }
        selectedBotID = bot.id
        studioTab = .profile
        screen = .studio
        persistSelection()
        reloadSelectedBot(id: bot.id)
    }

    public func openFleet() {
        screen = .fleet
        reloadFleet()
        reloadAttention()
        restoreSelectedBotIfNeeded()
        if let selectedBotID {
            reloadSelectedBot(id: selectedBotID)
        }
        persistSelection()
    }

    public func openHome(_ bot: BotDefinition) {
        selectedBotID = bot.id
        screen = .fleet
        persistSelection()
        reloadAttention()
        reloadSelectedBot(id: bot.id)
    }

    public func openDesk(_ bot: BotDefinition) {
        selectedBotID = bot.id
        screen = .desk
        persistSelection()
        markOpenedConversationRead(botID: bot.id)
        reloadSelectedBot(id: bot.id)
        syncQueuedFollowUps()
        drainQueuedFollowUp()
    }

    private func markOpenedConversationRead(botID: BotID) {
        do {
            let items = try botStore.listConversations(botID: botID)
            for var conversation in items where conversation.unread || conversation.attentionState == .unreadActivity {
                conversation.unread = false
                if conversation.attentionState == .unreadActivity {
                    conversation.attentionState = .none
                }
                try botStore.upsertConversation(conversation)
            }
            for item in try botStore.listAttention() where item.botID == botID && item.acknowledgedAt == nil && item.kind == .unread {
                try botStore.acknowledgeAttention(id: item.id)
            }
            reloadAttention()
            reloadFleet()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func openAttention() {
        reloadAttention()
        screen = .attention
    }

    public func openAttention(_ item: BotAttentionItem) {
        do {
            try botStore.acknowledgeAttention(id: item.id)
        } catch {
            errorMessage = String(describing: error)
        }
        reloadAttention()
        if let bot = (try? botStore.get(id: item.botID)) ?? bots.first(where: { $0.id == item.botID }) {
            openDesk(bot)
        } else {
            screen = .fleet
        }
    }

    public func acknowledge(_ item: BotAttentionItem) {
        do {
            try botStore.acknowledgeAttention(id: item.id)
            reloadAttention()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    @discardableResult
    public func create(
        name: String,
        title: String = "",
        description: String = "",
        handle: String? = nil,
        soul: String = "",
        provider: AgentProvider = .claude,
        providerInstanceID: String? = nil,
        model: String = "",
        avatarSymbol: String = "person.crop.circle",
        notificationsEnabled: Bool = true
    ) throws -> BotDefinition {
        guard isControlPlaneActive else {
            errorMessage = "Turn on Bot control plane in Settings"
            throw BotPublishError.controlPlaneDisabled
        }
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultModel(for: provider)
            : model
        let bot = try botStore.create(
            name: name,
            title: title,
            description: description,
            handle: handle,
            avatarSymbol: avatarSymbol,
            soul: soul,
            provider: provider,
            providerInstanceID: providerInstanceID ?? provider.rawValue,
            model: resolvedModel,
            workspaceID: context.state.window.selectedWorkspaceID,
            notificationsEnabled: notificationsEnabled
        )
        selectedBotID = bot.id
        reloadFleet()
        return bot
    }

    @discardableResult
    public func saveStudio() throws -> BotDefinition {
        let name = studioDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Name is required."
            throw BotPublishError.invalidRevision
        }
        let handle = studioDraft.handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let desktop = resolvedDesktopKind(studioDraft.desktopKind)
        if let botID = studioDraft.botID {
            guard let bot = try botStore.get(id: botID), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            let draft = BotRevisionDraft(
                name: name,
                title: studioDraft.title,
                description: studioDraft.description,
                soul: studioDraft.soul,
                provider: studioDraft.provider,
                providerInstanceID: studioDraft.providerInstanceID.isEmpty
                    ? studioDraft.provider.rawValue
                    : studioDraft.providerInstanceID,
                model: studioDraft.model.isEmpty ? Self.defaultModel(for: studioDraft.provider) : studioDraft.model,
                permissionMode: .supervised,
                desktopKind: desktop
            )
            let published = try botStore.publish(
                botID: botID,
                expectedCurrentRevisionID: studioDraft.expectedRevisionID ?? bot.currentRevisionID,
                draft: draft,
                avatarSymbol: studioDraft.avatarSymbol,
                notificationsEnabled: studioDraft.notificationsEnabled
            )
            studioDraft.expectedRevisionID = published.id
            selectedBotID = botID
            reloadFleet()
            reloadSelectedBot(id: botID)
            screen = .studio
            return try botStore.get(id: botID) ?? bot
        }
        let created = try create(
            name: name,
            title: studioDraft.title,
            description: studioDraft.description,
            handle: handle.isEmpty ? nil : handle,
            soul: studioDraft.soul,
            provider: studioDraft.provider,
            providerInstanceID: studioDraft.providerInstanceID.isEmpty ? nil : studioDraft.providerInstanceID,
            model: studioDraft.model,
            avatarSymbol: studioDraft.avatarSymbol,
            notificationsEnabled: studioDraft.notificationsEnabled
        )
        beginEdit(created)
        return created
    }

    @discardableResult
    public func duplicate(id: BotID) throws -> BotDefinition {
        guard isControlPlaneActive else {
            errorMessage = "Turn on Bot control plane in Settings"
            throw BotPublishError.controlPlaneDisabled
        }
        let copy = try botStore.duplicate(id: id)
        selectedBotID = copy.id
        reloadFleet()
        return copy
    }

    public func setPinned(id: BotID, pinned: Bool) {
        do {
            try botStore.setPinned(id: id, pinned: pinned)
            reloadFleet()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setHidden(id: BotID, hidden: Bool) {
        do {
            try botStore.setHidden(id: id, hidden: hidden)
            if hidden, selectedBotID == id {
                selectedBotID = nil
                screen = .fleet
                persistSelection()
            }
            reloadFleet()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func delete(id: BotID) {
        do {
            try botStore.delete(id: id)
            if selectedBotID == id {
                selectedBotID = nil
                screen = .fleet
                persistSelection()
            }
            queuedFollowUpsByBot[id] = nil
            persistQueuedFollowUps()
            syncQueuedFollowUps()
            reloadFleet()
            reloadAttention()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public var deskRunIsLive: Bool {
        deskWorkLog.contains { $0.statusLabel == "Working" }
    }

    public var deskShowsLoading: Bool {
        deskSendInFlight && !deskRunIsLive
    }

    public var deskSendEnabled: Bool {
        AgentChatTranscriptChrome.admitsSend(text: composerText, attachmentCount: attachments.count)
    }

    public func deskWorkingStartedAt() -> Date? {
        if let started = deskWorkLog.first(where: { $0.statusLabel == "Working" })?.createdAt {
            return started
        }
        if let turn = deskLiveTimeline.turns.last(where: { !$0.finished }) {
            return AgentChatLiveTurnChrome.turnSortDate(turn)
        }
        return nil
    }

    public func deskWorkingLabel(now: Date = Date()) -> String? {
        AgentChatTranscriptChrome.deskWorkingLabel(
            runIsLive: deskRunIsLive,
            startedAt: deskWorkingStartedAt(),
            hasStreamingTools: deskHasStreamingTools,
            now: now
        )
    }

    public func refreshDeskLiveTurn() {
        guard let id = selectedBotID else { return }
        restoreDeskLiveTurn(botID: id)
    }

    func applyDeskLiveEventForTesting(_ event: AssistantEvent, threadId: AgentThreadID) {
        applyIncomingDeskEvent(event, threadId: threadId)
    }

    public func addAttachments(_ paths: [String]) {
        do {
            let staged = try attachmentStore().stage(paths: paths)
            var known = Set(attachments.map(\.path))
            for attachment in staged where known.insert(attachment.path).inserted {
                attachments.append(attachment)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func removeAttachment(_ attachment: AgentAttachment) {
        attachments.removeAll { $0 == attachment }
    }

    public func removeQueuedFollowUp(_ item: BotQueuedFollowUp) {
        guard let botID = selectedBotID else { return }
        queuedFollowUpsByBot[botID]?.removeAll { $0.id == item.id }
        if queuedFollowUpsByBot[botID]?.isEmpty == true {
            queuedFollowUpsByBot[botID] = nil
        }
        persistQueuedFollowUps()
        syncQueuedFollowUps()
    }

    public func stopDeskRun() {
        guard let threadID = selectedConversation?.linkedAgentThreadID else { return }
        isStopping = true
        do {
            try resolvedRouter()?.stopAgentRun(thread: threadID)
        } catch {
            errorMessage = String(describing: error)
            isStopping = false
        }
    }

    @discardableResult
    public func send(_ text: String? = nil) -> Bool {
        let attached = attachments
        let message = (text ?? composerText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentChatTranscriptChrome.admitsSend(text: message, attachmentCount: attached.count) else { return false }
        guard let bot = selectedBot else { return false }
        composerText = ""
        attachments = []
        lastSendStartedProviderRun = false
        if deskRunIsLive, text == nil {
            enqueueFollowUp(
                BotQueuedFollowUp(text: message, attachments: attached),
                botID: bot.id
            )
            return true
        }
        do {
            let display = AgentChatTranscriptChrome.displayUserLine(text: message, attachments: attached)
            let conversation = try persistUserMessage(bot: bot, text: display)
            appendDeskMessage(BotDeskMessage(role: .user, text: display), botID: bot.id)
            if let router = resolvedRouter(),
               let revision = try currentRevision(for: bot) {
                deskSendInFlight = true
                deskSendInFlightStartedAt = Date()
                Task { [weak self] in
                    guard let self else { return }
                    let started = await self.startSupervisedRun(
                        bot: bot,
                        revision: revision,
                        conversation: conversation,
                        userText: message,
                        attachments: attached,
                        router: router
                    )
                    self.deskSendInFlight = false
                    if let runId = started {
                        self.lastSendStartedProviderRun = true
                        self.lastLinkedRunIDByBot[bot.id] = runId
                        self.restoreDeskWorkLog(botID: bot.id)
                        self.restoreDeskLiveTurn(botID: bot.id)
                        await self.followLinkedRun(
                            bot: bot,
                            conversation: conversation,
                            runId: runId
                        )
                    } else {
                        self.deskSendInFlightStartedAt = nil
                        self.recordNeedsAttention(bot: bot, conversation: conversation, userText: message)
                    }
                }
            } else {
                recordNeedsAttention(bot: bot, conversation: conversation, userText: message)
            }
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    public func addSkill() {
        let skillID = skillDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skillID.isEmpty, let bot = selectedBot else { return }
        do {
            try botStore.setSkillBinding(
                BotSkillBinding(botID: bot.id, skillID: skillID, enabled: true)
            )
            skillDraft = ""
            skillBindings = try botStore.listSkillBindings(botID: bot.id)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setSkillEnabled(skillID: String, enabled: Bool) {
        guard let bot = selectedBot else { return }
        do {
            try botStore.setSkillBinding(
                BotSkillBinding(botID: bot.id, skillID: skillID, enabled: enabled)
            )
            skillBindings = try botStore.listSkillBindings(botID: bot.id)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public var studioWorkspaceLabel: String {
        let id = selectedBot?.workspaceID ?? context.state.window.selectedWorkspaceID
        if let id, let name = context.state.workspaces[id]?.name, !name.isEmpty {
            return name
        }
        return "None"
    }

    public var studioRouteLabel: String {
        switch studioDraft.provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        }
    }

    public var studioDesktopSummary: String {
        switch resolvedDesktopKind(studioDraft.desktopKind) {
        case .logicalExecutionSpace:
            return "Logical execution space"
        case .dedicatedLocalVM:
            return "Dedicated local VM"
        case .managedRemoteMac:
            return "Managed remote Mac"
        }
    }

    public var studioApprovalLabel: String { "Supervised" }

    public var studioHasUnpublishedChanges: Bool {
        guard let revision = selectedRevision else { return studioDraft.isNew }
        let bot = selectedBot
        return studioDraft.name != revision.name
            || studioDraft.title != revision.title
            || studioDraft.description != revision.description
            || studioDraft.soul != revision.soul
            || studioDraft.provider != revision.provider
            || studioDraft.model != revision.model
            || studioDraft.desktopKind != revision.desktopKind
            || studioDraft.notificationsEnabled != (bot?.notificationsEnabled ?? true)
            || studioDraft.avatarSymbol != (bot?.avatarSymbol ?? "person.crop.circle")
    }

    public func addMemory() {
        guard isMemoryActive else { return }
        let content = memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, let bot = selectedBot else { return }
        do {
            _ = try botStore.putMemory(
                botID: bot.id,
                content: content,
                provenance: "user",
                trusted: true,
                source: "studio"
            )
            memoryDraft = ""
            reloadMemory(botID: bot.id)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func correctMemory(id: BotMemoryItemID, content: String) {
        guard isMemoryActive else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try botStore.correctMemory(id: id, content: trimmed)
            if let botID = selectedBotID { reloadMemory(botID: botID) }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func forgetMemory(id: BotMemoryItemID) {
        guard isMemoryActive else { return }
        do {
            try botStore.forgetMemory(id: id)
            if let botID = selectedBotID { reloadMemory(botID: botID) }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func saveRoutine() {
        guard let bot = selectedBot else { return }
        let name = routineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = routinePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else {
            errorMessage = "Routine name and prompt are required."
            return
        }
        do {
            try botStore.saveRoutine(
                BotRoutineDefinition(
                    botID: bot.id,
                    name: name,
                    prompt: prompt,
                    scheduleNote: routineScheduleNote
                )
            )
            routineName = ""
            routinePrompt = ""
            routineScheduleNote = ""
            reloadRoutines(botID: bot.id)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setRoutineEnabled(id: BotRoutineID, enabled: Bool) {
        do {
            try botStore.setRoutineEnabled(id: id, enabled: enabled)
            if let botID = selectedBotID { reloadRoutines(botID: botID) }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func requestRoutineTestRun(id: BotRoutineID) {
        guard let routine = routines.first(where: { $0.definition.id == id }) else { return }
        let instruction = routine.definition.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            errorMessage = "Routine instruction is required."
            return
        }
        do {
            try botStore.requestRoutineTestRun(id: id)
            if let botID = selectedBotID { reloadRoutines(botID: botID) }
            if let bot = selectedBot, screen != .desk {
                openDesk(bot)
            }
            // Test run is a live supervised turn. Enabling a schedule still
            // does not execute while RemoteCode is closed.
            send(instruction)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func applyDefaultModel(for provider: AgentProvider) {
        if let snapshot = providers.first(where: { $0.provider == provider }),
           let model = snapshot.models.first?.id {
            studioDraft.model = model
            studioDraft.providerInstanceID = snapshot.id
            return
        }
        studioDraft.model = Self.defaultModel(for: provider)
        studioDraft.providerInstanceID = provider.rawValue
    }

    public static func defaultModel(for provider: AgentProvider) -> String {
        switch provider {
        case .claude: return "opus"
        case .codex: return AgentDefaultModelSelection.codexBuiltInDefault
        case .grok: return "grok-4.6"
        }
    }

    // MARK: - Internals

    private func resolvedRouter() -> AppCommandRouter? {
        if let router { return router }
        let existing: AppCommandRouter? = context.router
        return existing
    }

    private func attachmentStore() -> AgentAttachmentStore {
        AgentAttachmentStore(
            root: context.appSupportDirectory.appendingPathComponent("agent-attachments", isDirectory: true)
        )
    }

    private func refreshFlags() {
        let settings = settingsStore.load()
        isControlPlaneActive = settings.isBotControlPlaneActive
        isMemoryActive = settings.isBotMemoryActive
        isAutonomyActive = settings.isBotAutonomyActive
        isDesktopVMActive = settings.isBotDesktopVMActive
        isDesktopRemoteActive = settings.isBotDesktopRemoteActive
    }

    private func reloadFleet() {
        do {
            bots = try botStore.list(includeHidden: showHidden)
            var previews: [BotID: String] = [:]
            var updated: [BotID: Date] = [:]
            for bot in bots {
                if let last = messagesByBot[bot.id]?.last, !last.text.isEmpty {
                    previews[bot.id] = last.text
                    updated[bot.id] = last.createdAt
                    continue
                }
                guard let conversation = try botStore.listConversations(botID: bot.id).first else { continue }
                if let threadID = conversation.linkedAgentThreadID,
                   let stored = try? context.messageRepo.listRecent(threadId: threadID, limit: 8),
                   let last = stored.last(where: { $0.role == .user || $0.role == .assistant }) {
                    previews[bot.id] = last.role == .user
                        ? BotsDeskFollowThrough.displayUserText(from: last.content)
                        : last.content
                    updated[bot.id] = last.createdAt
                } else if !conversation.title.isEmpty {
                    previews[bot.id] = conversation.title
                    updated[bot.id] = conversation.updatedAt
                }
            }
            lastPreviewByBot = previews
            lastUpdatedByBot = updated
            rebuildAttentionStates()
            pruneQueuedFollowUpsToFleet()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func reloadAttention() {
        do {
            attentionItems = try botStore.listAttention()
            rebuildAttentionStates()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func rebuildAttentionStates() {
        var states: [BotID: BotAttentionState] = [:]
        for item in attentionItems where item.acknowledgedAt == nil {
            states[item.botID] = .needsAttention
        }
        for bot in bots {
            if states[bot.id] == .needsAttention { continue }
            let conversations = (try? botStore.listConversations(botID: bot.id)) ?? []
            if conversations.contains(where: { $0.attentionState == .needsAttention }) {
                states[bot.id] = .needsAttention
            } else if conversations.contains(where: { $0.attentionState == .working }) {
                states[bot.id] = .working
            } else if conversations.contains(where: { $0.unread || $0.attentionState == .unreadActivity }) {
                states[bot.id] = .unreadActivity
            } else {
                states[bot.id] = BotAttentionState.none
            }
        }
        attentionStateByBot = states
    }

    private func reloadSelectedBot(id: BotID) {
        deskLiveTurnWatch?.cancel()
        deskLiveTurnWatch = nil
        deskSendInFlight = false
        deskLiveTimeline = liveTimelineByBot[id] ?? AssistantTimelineState()
        deskStreamEventCount = liveStreamCountByBot[id] ?? 0
        deskMessages = messagesByBot[id] ?? []
        do {
            conversations = try botStore.listConversations(botID: id)
            selectedConversation = conversations.first
            if let bot = try botStore.get(id: id) {
                selectedRevision = try currentRevision(for: bot)
            } else {
                selectedRevision = nil
            }
            skillBindings = try botStore.listSkillBindings(botID: id)
            reloadMemory(botID: id)
            reloadRoutines(botID: id)
            restoreDeskMessages(botID: id)
            restoreDeskWorkLog(botID: id)
            restoreDeskLiveTurn(botID: id)
            syncQueuedFollowUps()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func providerChipTitle(_ provider: AgentProvider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        }
    }

    public func providerLabel(for bot: BotDefinition) -> String? {
        resolvedProvider(for: bot).map(providerChipTitle)
    }

    public func resolvedProvider(for bot: BotDefinition) -> AgentProvider? {
        if selectedBotID == bot.id, let provider = selectedRevision?.provider {
            return provider
        }
        if let revisionID = bot.currentRevisionID,
           let revision = try? botStore.getRevision(id: revisionID) {
            return revision.provider
        }
        return nil
    }

    private static let selectedBotDefaultsKey = "bots.selectedBotID"
    private static let inspectorTabDefaultsKey = "bots.inspectorTab"
    private static let screenDefaultsKey = "bots.screen"
    private static let studioTabDefaultsKey = "bots.studioTab"
    private static let queuedFollowUpsDefaultsKey = "bots.queuedFollowUps"

    private func persistSelection() {
        UserDefaults.standard.set(selectedBotID?.value.uuidString.lowercased(), forKey: Self.selectedBotDefaultsKey)
    }

    private func persistInspectorTab() {
        UserDefaults.standard.set(inspectorTab.rawValue, forKey: Self.inspectorTabDefaultsKey)
    }

    private func persistScreen() {
        UserDefaults.standard.set(screen.rawValue, forKey: Self.screenDefaultsKey)
    }

    private func persistStudioTab() {
        UserDefaults.standard.set(studioTab.rawValue, forKey: Self.studioTabDefaultsKey)
    }

    private func persistQueuedFollowUps() {
        let payload = Dictionary(uniqueKeysWithValues: queuedFollowUpsByBot.map {
            ($0.key.value.uuidString.lowercased(), $0.value)
        })
        if payload.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.queuedFollowUpsDefaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: Self.queuedFollowUpsDefaultsKey)
        }
    }

    private func restoreQueuedFollowUpsIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: Self.queuedFollowUpsDefaultsKey),
              let payload = try? JSONDecoder().decode([String: [BotQueuedFollowUp]].self, from: data)
        else { return }
        var restored: [BotID: [BotQueuedFollowUp]] = [:]
        for (raw, items) in payload {
            guard let uuid = UUID(uuidString: raw) else { continue }
            let kept = items.filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !$0.attachments.isEmpty
            }
            if !kept.isEmpty {
                restored[BotID(uuid)] = kept
            }
        }
        queuedFollowUpsByBot = restored
    }

    private func pruneQueuedFollowUpsToFleet() {
        let live = Set(bots.map(\.id))
        let next = queuedFollowUpsByBot.filter { live.contains($0.key) }
        guard next.count != queuedFollowUpsByBot.count else { return }
        queuedFollowUpsByBot = next
        persistQueuedFollowUps()
        syncQueuedFollowUps()
    }

    private func restoreInspectorTabIfNeeded() {
        guard let raw = UserDefaults.standard.string(forKey: Self.inspectorTabDefaultsKey),
              let tab = BotDeskInspectorTab(rawValue: raw) else { return }
        inspectorTab = tab
    }

    private func restoreStudioTabIfNeeded() {
        guard let raw = UserDefaults.standard.string(forKey: Self.studioTabDefaultsKey),
              let tab = BotStudioTab(rawValue: raw) else { return }
        studioTab = tab
    }

    private func restoreScreenIfNeeded() {
        guard let raw = UserDefaults.standard.string(forKey: Self.screenDefaultsKey),
              let saved = BotsScreen(rawValue: raw) else { return }
        let persistedSelection = UserDefaults.standard.string(forKey: Self.selectedBotDefaultsKey)
        let selectionMatches = selectedBotID?.value.uuidString.lowercased() == persistedSelection
        switch saved {
        case .fleet:
            return
        case .desk:
            guard selectionMatches, let bot = selectedBot else { return }
            openDesk(bot)
        case .studio:
            guard selectionMatches, let bot = selectedBot else { return }
            let tab = studioTab
            beginEdit(bot)
            studioTab = tab
        case .attention:
            openAttention()
        }
    }

    private func restoreSelectedBotIfNeeded() {
        if let selectedBotID, fleet.contains(where: { $0.id == selectedBotID }) {
            return
        }
        if let raw = UserDefaults.standard.string(forKey: Self.selectedBotDefaultsKey),
           let uuid = UUID(uuidString: raw),
           fleet.contains(where: { $0.id == BotID(uuid) }) {
            selectedBotID = BotID(uuid)
            return
        }
        selectedBotID = fleet.first?.id
    }

    public var liveMemoryCount: Int {
        memoryItems.filter { $0.forgottenAt == nil }.count
    }

    public var enabledSkillCount: Int {
        skillBindings.filter(\.enabled).count
    }

    public var enabledRoutineCount: Int {
        routines.filter(\.activation.isEnabled).count
    }

    public var pendingApprovalCount: Int {
        attentionItems.filter { $0.acknowledgedAt == nil && $0.kind == .approval && $0.botID == selectedBotID }.count
    }

    private func reloadMemory(botID: BotID) {
        do {
            memoryItems = try botStore.listMemory(botID: botID)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func reloadRoutines(botID: BotID) {
        do {
            routines = try botStore.listRoutines(botID: botID)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func conversationForBot(_ botID: BotID) -> BotConversation? {
        if let selected = selectedConversation, selected.botID == botID {
            return selected
        }
        return (try? botStore.listConversations(botID: botID).first)
    }

    private func threadBelongsToAnotherBot(_ threadID: AgentThreadID, botID: BotID) -> Bool {
        guard let owner = try? botStore.conversationLinked(to: threadID) else { return false }
        return owner.botID != botID
    }

    private func restoreDeskMessages(botID: BotID) {
        let cached = messagesByBot[botID] ?? []
        let conversation = conversationForBot(botID)
        var persisted: [BotDeskMessage] = []
        if let threadID = conversation?.linkedAgentThreadID,
           let stored = try? context.messageRepo.listRecent(threadId: threadID, limit: 80),
           !stored.isEmpty {
            persisted = stored.compactMap { message -> BotDeskMessage? in
                let role: BotDeskMessage.Role
                let text: String
                switch message.role {
                case .user:
                    role = .user
                    text = BotsDeskFollowThrough.displayUserText(from: message.content)
                case .assistant:
                    role = .assistant
                    text = message.content
                default:
                    return nil
                }
                return BotDeskMessage(role: role, text: text, createdAt: message.createdAt)
            }
        }
        var visible = BotsDeskFollowThrough.visibleDeskMessages(cached: cached, persisted: persisted)
        if visible.isEmpty, let conversation, !conversation.title.isEmpty {
            visible = [BotDeskMessage(role: .user, text: conversation.title, createdAt: conversation.createdAt)]
        }
        messagesByBot[botID] = visible
        if selectedBotID == botID {
            deskMessages = visible
        }
        if let last = visible.last, !last.text.isEmpty {
            lastPreviewByBot[botID] = last.text
            lastUpdatedByBot[botID] = last.createdAt
        }
    }

    private func restoreDeskLiveTurn(botID: BotID) {
        let conversation = conversationForBot(botID)
        guard let threadID = conversation?.linkedAgentThreadID else {
            liveTimelineByBot[botID] = AssistantTimelineState()
            liveStreamCountByBot[botID] = 0
            if selectedBotID == botID {
                deskLiveTimeline = AssistantTimelineState()
                deskStreamEventCount = 0
                deskLiveTurnWatch?.cancel()
                deskLiveTurnWatch = nil
            }
            return
        }
        applyDeskLiveReplay(botID: botID, threadID: threadID, force: true)
        if selectedBotID == botID, screen == .desk, deskRunIsLive {
            startDeskLiveTurnWatch(botID: botID, threadID: threadID)
        }
    }

    private func applyDeskLiveReplay(botID: BotID, threadID: AgentThreadID, force: Bool = false) {
        let count = context.coordinator.countStreamEvents(threadId: threadID)
        if !force, liveStreamCountByBot[botID] == count {
            if selectedBotID == botID {
                deskLiveTimeline = liveTimelineByBot[botID] ?? deskLiveTimeline
                deskStreamEventCount = liveStreamCountByBot[botID] ?? count
            }
            return
        }
        let events = context.coordinator.latestStreamEvents(threadId: threadID)
        let state = AgentChatLiveTurnChrome.timelineByReplaying(events)
        // Only compare against THIS bot's timeline. Using deskLiveTimeline here
        // kept the previous bot's richer Worked rows after a roster switch.
        let current = liveTimelineByBot[botID] ?? AssistantTimelineState()
        if AgentChatLiveTurnChrome.isRicher(current, than: state) {
            liveStreamCountByBot[botID] = max(count, liveStreamCountByBot[botID] ?? 0)
            if selectedBotID == botID {
                deskLiveTimeline = current
                deskStreamEventCount = liveStreamCountByBot[botID] ?? count
            }
            return
        }
        liveTimelineByBot[botID] = state
        liveStreamCountByBot[botID] = count
        if selectedBotID == botID {
            deskLiveTimeline = state
            deskStreamEventCount = count
        }
    }

    private func applyIncomingDeskEvent(_ event: AssistantEvent, threadId: AgentThreadID) {
        guard screen == .desk,
              let botID = selectedBotID,
              selectedConversation?.linkedAgentThreadID == threadId
        else { return }
        var next = deskLiveTimeline
        next.apply(event)
        next.enforceAggregateHotTextBudget()
        deskLiveTimeline = next
        liveTimelineByBot[botID] = next
    }

    private func refreshDeskLiveTurnIfCountChanged(botID: BotID, threadID: AgentThreadID) {
        applyDeskLiveReplay(botID: botID, threadID: threadID, force: false)
    }

    private func startDeskLiveTurnWatch(botID: BotID, threadID: AgentThreadID) {
        deskLiveTurnWatch?.cancel()
        deskLiveTurnWatch = Task { [weak self] in
            var lastCount = -1
            while !Task.isCancelled {
                guard let self else { return }
                guard self.selectedBotID == botID, self.screen == .desk else { return }
                let count = self.context.coordinator.countStreamEvents(threadId: threadID)
                if count != lastCount {
                    lastCount = count
                    self.applyDeskLiveReplay(botID: botID, threadID: threadID, force: true)
                }
                let run = self.linkedRun(for: threadID, botID: botID)
                if let run, BotsDeskFollowThrough.isTerminal(run.status) {
                    self.applyDeskLiveReplay(botID: botID, threadID: threadID, force: true)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func restoreDeskWorkLog(botID: BotID, preferredRun: AgentRun? = nil) {
        let conversation = conversationForBot(botID)
        guard let threadID = conversation?.linkedAgentThreadID else {
            if selectedBotID == botID { deskWorkLog = [] }
            return
        }
        let run: AgentRun?
        if let preferredRun, preferredRun.threadId == threadID {
            run = preferredRun
        } else {
            run = linkedRun(for: threadID, botID: botID)
        }
        let rows = BotsDeskFollowThrough.workLogRows(for: run)
        if selectedBotID == botID {
            deskWorkLog = rows
        }
    }

    private func linkedRun(for threadID: AgentThreadID, botID: BotID) -> AgentRun? {
        if let active = try? context.runRepo.latestActive(for: threadID) {
            return active
        }
        if let runID = lastLinkedRunIDByBot[botID],
           let stored = try? context.runRepo.get(id: runID),
           stored.threadId == threadID {
            return stored
        }
        return (try? context.runRepo.listRecentFinished(limit: 80))?
            .first(where: { $0.threadId == threadID })
    }

    private func appendDeskMessage(_ message: BotDeskMessage, botID: BotID) {
        if selectedBotID == botID {
            deskMessages.append(message)
        }
        messagesByBot[botID, default: []].append(message)
        lastPreviewByBot[botID] = message.text
        lastUpdatedByBot[botID] = message.createdAt
    }

    @discardableResult
    private func persistUserMessage(bot: BotDefinition, text: String) throws -> BotConversation {
        var conversation: BotConversation
        if let selected = selectedConversation, selected.botID == bot.id {
            conversation = selected
        } else if let existing = (try? botStore.listConversations(botID: bot.id))?.first {
            conversation = existing
        } else {
            conversation = BotConversation(
                botID: bot.id,
                title: Self.titleFromFirstMessage(text)
            )
        }
        if conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conversation.title = Self.titleFromFirstMessage(text)
        }
        conversation.updatedAt = Date()
        conversation.unread = false
        try botStore.upsertConversation(conversation)
        selectedConversation = conversation
        conversations = try botStore.listConversations(botID: bot.id)
        return conversation
    }

    private func recordNeedsAttention(bot: BotDefinition, conversation: BotConversation, userText: String) {
        do {
            var next = conversation
            next.attentionState = .needsAttention
            next.updatedAt = Date()
            try botStore.upsertConversation(next)
            if selectedConversation?.id == next.id {
                selectedConversation = next
            }
            try botStore.upsertAttention(
                BotAttentionItem(
                    botID: bot.id,
                    conversationID: next.id,
                    kind: .question,
                    title: "Needs you",
                    detail: userText
                )
            )
            appendDeskMessage(
                BotDeskMessage(role: .assistant, text: Self.assistantPlaceholder),
                botID: bot.id
            )
            reloadAttention()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func currentRevision(for bot: BotDefinition) throws -> BotRevision? {
        guard let revisionID = bot.currentRevisionID else { return nil }
        return try botStore.getRevision(id: revisionID)
    }

    private func startSupervisedRun(
        bot: BotDefinition,
        revision: BotRevision,
        conversation: BotConversation,
        userText: String,
        attachments: [AgentAttachment] = [],
        router: AppCommandRouter
    ) async -> AgentRunID? {
        let workspaceID = bot.workspaceID
            ?? context.state.window.selectedWorkspaceID
            ?? context.state.window.workspaces.first
        let model = revision.model.isEmpty ? Self.defaultModel(for: revision.provider) : revision.model
        do {
            let thread: AgentThread
            if let linked = conversation.linkedAgentThreadID,
               let existing = try context.threadRepo.get(id: linked),
               !threadBelongsToAnotherBot(linked, botID: bot.id) {
                thread = existing
            } else {
                thread = try router.createAgentThread(
                    workspace: workspaceID,
                    title: conversation.title,
                    provider: revision.provider,
                    model: model,
                    permissionMode: .supervised,
                    reasoningEffort: revision.reasoningEffort,
                    providerInstanceId: revision.providerInstanceID,
                    surfaceID: nil,
                    routingConfiguration: nil,
                    quiet: true
                )
                var linked = conversation
                linked.linkedAgentThreadID = thread.id
                linked.attentionState = .working
                linked.updatedAt = Date()
                try botStore.upsertConversation(linked)
                selectedConversation = linked
            }
            if selectedBotID == bot.id, screen == .desk {
                startDeskLiveTurnWatch(botID: bot.id, threadID: thread.id)
            }
            let memory = (try? botStore.listMemory(botID: bot.id)) ?? []
            let skills = (try? botStore.listSkillBindings(botID: bot.id)) ?? []
            let prompt = BotsDeskFollowThrough.composeRunPrompt(
                bot: bot,
                revision: revision,
                userText: userText,
                memory: memory,
                skills: skills
            )
            let result = try await router.sendAgentMessage(
                thread: thread.id,
                text: prompt,
                provider: revision.provider,
                model: model,
                permissionMode: .supervised,
                reasoningEffort: revision.reasoningEffort,
                providerInstanceId: revision.providerInstanceID,
                attachments: attachments
            )
            return result.runId
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    private func followLinkedRun(
        bot: BotDefinition,
        conversation: BotConversation,
        runId: AgentRunID
    ) async {
        let threadID = conversation.linkedAgentThreadID
            ?? selectedConversation?.linkedAgentThreadID
        if let threadID {
            startDeskLiveTurnWatch(botID: bot.id, threadID: threadID)
        }
        for _ in 0..<120 {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let threadID {
                refreshDeskLiveTurnIfCountChanged(botID: bot.id, threadID: threadID)
            }
            let run = try? context.runRepo.get(id: runId)
            let activeId = threadID.flatMap { context.coordinator.activeRunId(threadId: $0) }
            let terminal = run.map { BotsDeskFollowThrough.isTerminal($0.status) } ?? false
            if terminal || (activeId != runId && run != nil) {
                applyFollowThrough(bot: bot, conversation: conversation, run: run)
                return
            }
        }
        applyFollowThrough(bot: bot, conversation: conversation, run: try? context.runRepo.get(id: runId))
    }

    private func enqueueFollowUp(_ item: BotQueuedFollowUp, botID: BotID) {
        queuedFollowUpsByBot[botID, default: []].append(item)
        persistQueuedFollowUps()
        syncQueuedFollowUps()
    }

    private func syncQueuedFollowUps() {
        queuedFollowUps = selectedBotID.flatMap { queuedFollowUpsByBot[$0] } ?? []
    }

    private func drainQueuedFollowUp() {
        guard let bot = selectedBot else { return }
        guard !deskRunIsLive else { return }
        guard let next = queuedFollowUpsByBot[bot.id]?.first else {
            syncQueuedFollowUps()
            return
        }
        composerText = next.text
        attachments = next.attachments
        guard send() else { return }
        queuedFollowUpsByBot[bot.id]?.removeAll { $0.id == next.id }
        if queuedFollowUpsByBot[bot.id]?.isEmpty == true {
            queuedFollowUpsByBot[bot.id] = nil
        }
        persistQueuedFollowUps()
        syncQueuedFollowUps()
    }

    private func applyFollowThrough(
        bot: BotDefinition,
        conversation: BotConversation,
        run: AgentRun?
    ) {
        var next = conversation
        if let selected = selectedConversation, selected.id == conversation.id {
            next = selected
        } else if let stored = try? botStore.listConversations(botID: bot.id).first(where: { $0.id == conversation.id }) {
            next = stored
            if next.linkedAgentThreadID == nil {
                next.linkedAgentThreadID = conversation.linkedAgentThreadID
            }
        }
        restoreDeskMessages(botID: bot.id)
        if let run {
            lastLinkedRunIDByBot[bot.id] = run.id
        }
        restoreDeskWorkLog(botID: bot.id, preferredRun: run)
        restoreDeskLiveTurn(botID: bot.id)
        let status = run?.status ?? .interrupted
        let viewingDesk = isViewing(bot.id)
        next.attentionState = BotsDeskFollowThrough.conversationState(for: status, viewingDesk: viewingDesk)
        if viewingDesk {
            next.unread = false
        } else if status == .completed {
            next.unread = true
        }
        next.updatedAt = Date()
        do {
            try botStore.upsertConversation(next)
            if selectedConversation?.id == next.id {
                selectedConversation = next
            }
            if let kind = BotsDeskFollowThrough.attentionKind(for: status) {
                try botStore.upsertAttention(
                    BotAttentionItem(
                        botID: bot.id,
                        conversationID: next.id,
                        kind: kind,
                        title: status == .cancelled ? "Run cancelled" : "Run needs you",
                        detail: run?.errorMessage ?? "The supervised turn ended without a clean completion."
                    )
                )
            }
            reloadAttention()
            reloadFleet()
        } catch {
            errorMessage = String(describing: error)
        }
        isStopping = false
        deskSendInFlight = false
        if BotsDeskFollowThrough.isTerminal(status) {
            deskSendInFlightStartedAt = nil
            if isViewing(bot.id) {
                drainQueuedFollowUp()
            }
        }
    }

    private func resolvedDesktopKind(_ requested: BotDesktopKind) -> BotDesktopKind {
        let flags = settingsStore.load().botControlPlaneFlags
        if requested.isSelectable(flags: flags) { return requested }
        return .logicalExecutionSpace
    }

    private static func titleFromFirstMessage(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 72 { return collapsed }
        return String(collapsed.prefix(72))
    }

    static func composeRunPrompt(bot: BotDefinition, revision: BotRevision, userText: String) -> String {
        BotsDeskFollowThrough.composeRunPrompt(bot: bot, revision: revision, userText: userText)
    }

    func applyFollowThroughForTests(
        bot: BotDefinition,
        conversation: BotConversation,
        status: AgentRunStatus
    ) {
        applyFollowThrough(
            bot: bot,
            conversation: conversation,
            run: AgentRun(
                threadId: conversation.linkedAgentThreadID ?? AgentThreadID(),
                provider: .claude,
                model: "test",
                status: status,
                finishedAt: Date()
            )
        )
    }
}

extension BotsViewModel: AgentRunObserver {
    nonisolated public func runCoordinator(
        _ c: AgentRunCoordinator,
        didReceive event: AssistantEvent,
        run: AgentRunID,
        threadId: AgentThreadID
    ) {
        Task { @MainActor [weak self] in
            self?.applyIncomingDeskEvent(event, threadId: threadId)
        }
    }

    nonisolated public func runCoordinator(
        _ c: AgentRunCoordinator,
        didFinish runId: AgentRunID,
        threadId: AgentThreadID,
        status: AgentRunStatus,
        finalMessage: String?,
        providerThreadId: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.screen == .desk, let botID = self.selectedBotID else { return }
            guard self.selectedConversation?.linkedAgentThreadID == threadId else { return }
            self.restoreDeskWorkLog(botID: botID)
            self.restoreDeskLiveTurn(botID: botID)
        }
    }

    nonisolated public func runCoordinator(
        _ c: AgentRunCoordinator,
        didChangeStatus status: AgentRunStatus,
        runId: AgentRunID,
        threadId: AgentThreadID
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.screen == .desk, let botID = self.selectedBotID else { return }
            guard self.selectedConversation?.linkedAgentThreadID == threadId else { return }
            self.restoreDeskWorkLog(botID: botID)
            if BotsDeskFollowThrough.isTerminal(status) {
                self.restoreDeskLiveTurn(botID: botID)
            }
        }
    }
}

// MARK: - Shared sidebar chrome

/// One control for the single shell sidebar: Agentic (workspaces) or Bots (roster).
public struct BotsModeSwitcher: View {
    public var isBotsSelected: Bool
    public var onSelectAgentic: () -> Void
    public var onSelectBots: () -> Void

    public init(
        isBotsSelected: Bool,
        onSelectAgentic: @escaping () -> Void,
        onSelectBots: @escaping () -> Void
    ) {
        self.isBotsSelected = isBotsSelected
        self.onSelectAgentic = onSelectAgentic
        self.onSelectBots = onSelectBots
    }

    public var body: some View {
        HStack(spacing: 2) {
            segment(
                title: BotsChrome.Label.agentic,
                selected: !isBotsSelected,
                identifier: "bots.chrome.agentic",
                action: onSelectAgentic
            )
            segment(
                title: BotsChrome.Label.bots,
                selected: isBotsSelected,
                identifier: "bots.chrome.bots",
                action: onSelectBots
            )
        }
        .padding(2)
        .background(DS.Palette.bg)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bots.chrome.mode")
        .accessibilityLabel("Sidebar mode")
        .accessibilityValue(isBotsSelected ? BotsChrome.Label.bots : BotsChrome.Label.agentic)
    }

    private func segment(
        title: String,
        selected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.Font.caption.weight(selected ? .semibold : .regular))
                .foregroundColor(selected ? DS.Palette.text : DS.Palette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(selected ? DS.Palette.surfaceRaised : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control - 1, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// Roster body shared by the shell sidebar and the detached Bots window.
public struct BotsRosterList: View {
    @ObservedObject private var vm: BotsViewModel

    public init(vm: BotsViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.xs) {
                Button(action: vm.beginCreate) {
                    actionRow(symbol: "plus", title: BotsChrome.Label.newBot)
                }
                .buttonStyle(.plain)
                .disabled(!vm.isControlPlaneActive)
                .help("Create a named teammate")
                .accessibilityIdentifier("bots.new")
                Button(action: vm.openAttention) {
                    Image(systemName: vm.openAttentionCount == 0 ? "bell" : "bell.badge")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(vm.openAttentionCount == 0 ? DS.Palette.textSecondary : DS.Palette.warning)
                        .frame(width: 42, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    vm.openAttentionCount == 0
                        ? "Attention"
                        : "Attention \(vm.openAttentionCount)"
                )
                .accessibilityLabel(
                    vm.openAttentionCount == 0
                        ? "Attention"
                        : "Attention \(vm.openAttentionCount)"
                )
                .accessibilityIdentifier("bots.roster.attention")
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.bottom, DS.Space.lg)

            HStack(spacing: DS.Space.sm) {
                Text(BotsChrome.Label.myBots)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.bottom, DS.Space.sm)

            HStack(spacing: DS.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityHidden(true)
                TextField(BotsChrome.Label.search, text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.text)
                    .accessibilityLabel(BotsChrome.Label.search)
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(DS.Palette.surfaceRaised.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Palette.lineStrong.opacity(0.5), lineWidth: DS.Border.hairline)
                    )
            )
            .padding(.horizontal, DS.Space.md)
            .padding(.bottom, DS.Space.sm)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.lg) {
                    if vm.fleet.isEmpty {
                        Text(vm.searchText.isEmpty ? "No bots yet" : "No matches")
                            .font(DS.Font.body)
                            .foregroundColor(DS.Palette.textTertiary)
                            .padding(.horizontal, DS.Space.md)
                            .padding(.vertical, DS.Space.sm)
                    } else {
                        ForEach(vm.fleet, id: \.id) { bot in
                            rosterRow(bot)
                        }
                    }
                }
                .padding(.horizontal, DS.Space.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("bots.roster")
    }

    private func actionRow(symbol: String, title: String) -> some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .frame(width: 20, height: 20)
                .foregroundColor(DS.Palette.text)
            Text(title)
                .font(DS.Font.body)
                .foregroundColor(DS.Palette.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: 42)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(Color.white.opacity(0.001))
        )
    }

    private func rosterRow(_ bot: BotDefinition) -> some View {
        let selected = vm.selectedBotID == bot.id && vm.screen != .attention
        let state = vm.attentionState(for: bot)
        let preview = vm.rosterPreview(for: bot)
        return Button {
            vm.openDesk(bot)
        } label: {
            HStack(spacing: DS.Space.sm) {
                ZStack(alignment: .bottomTrailing) {
                    BotsAvatarView(name: bot.name, handle: bot.handle, size: 22)
                    Circle()
                        .fill(state == .working ? DS.Palette.warning : DS.Palette.success)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(DS.Palette.surface, lineWidth: 1))
                }
                .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bot.name)
                        .font(selected ? DS.Font.bodyStrong : DS.Font.body)
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                    Text(preview)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let provider = vm.providerLabel(for: bot) {
                    Text(provider)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(selected ? DS.Palette.selection.opacity(0.75) : Color.white.opacity(0.001))
            )
            .overlay(alignment: .leading) {
                if selected {
                    DS.Palette.accent
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                        .padding(.vertical, 5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(bot.name) · \(BotsChrome.statusTitle(for: state))")
        .accessibilityLabel(bot.name)
        .accessibilityValue("\(BotsChrome.statusTitle(for: state)). \(preview)")
        .accessibilityIdentifier("bots.roster.row.\(bot.handle)")
    }
}

// MARK: - Root view

public struct BotsRootView: View {
    @ObservedObject private var vm: BotsViewModel
    /// Standalone Bots window keeps its own rail. The main shell hosts the
    /// roster inside the single sidebar instead.
    private let embedsRosterRail: Bool

    public init(vm: BotsViewModel, embedsRosterRail: Bool = true) {
        self.vm = vm
        self.embedsRosterRail = embedsRosterRail
    }

    public var body: some View {
        HStack(spacing: 0) {
            if showsRosterRail {
                rosterRail
                Rectangle()
                    .fill(DS.Palette.line)
                    .frame(width: 1)
                    .accessibilityHidden(true)
            }
            Group {
                switch vm.screen {
                case .fleet:
                    fleetScreen
                case .studio:
                    studioScreen
                case .desk:
                    deskScreen
                case .attention:
                    attentionScreen
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: embedsRosterRail ? 980 : 700, minHeight: 680)
        .background(DS.Palette.bg)
        .alert("Bots", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { vm.pendingDeleteID != nil },
                set: { if !$0 { vm.pendingDeleteID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = vm.pendingDeleteID {
                    vm.delete(id: id)
                }
                vm.pendingDeleteID = nil
            }
            Button("Cancel", role: .cancel) { vm.pendingDeleteID = nil }
        } message: {
            Text("This teammate is removed from the fleet. Conversations and routines are deleted.")
        }
        .onAppear { vm.reload() }
    }

    private var deleteTitle: String {
        if let id = vm.pendingDeleteID, let bot = vm.bots.first(where: { $0.id == id }) {
            return "Delete \(bot.name)?"
        }
        return "Delete this Bot?"
    }

    private var showsRosterRail: Bool {
        embedsRosterRail && vm.isControlPlaneActive
    }

    private var rosterRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            BotsModeSwitcher(
                isBotsSelected: true,
                onSelectAgentic: { vm.onLeaveBots?() },
                onSelectBots: {}
            )
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.xl)
            BotsRosterList(vm: vm)
        }
        .frame(width: BotsChrome.rosterWidth)
        .background(DS.Palette.surface)
    }

    // MARK: Fleet

    private var fleetScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !vm.isControlPlaneActive {
                fleetHeader
                DSEmptyState(
                    icon: "person.2",
                    title: "Turn on Bot control plane in Settings",
                    subtitle: "Bots stay off until the control plane is enabled."
                )
            } else if vm.fleet.isEmpty {
                fleetHeader
                DSEmptyState(
                    icon: "person.2",
                    title: vm.searchText.isEmpty ? "No bots yet" : "No matching bots",
                    subtitle: vm.searchText.isEmpty
                        ? "Create a Bot, give it a job, send a first task."
                        : "Try another search or show hidden teammates."
                )
            } else if let bot = vm.selectedBot {
                fleetHome(bot)
            } else {
                fleetHeader
                ScrollView {
                    LazyVStack(spacing: DS.Space.md) {
                        ForEach(vm.fleet, id: \.id) { bot in
                            fleetRow(bot)
                        }
                    }
                    .padding(.horizontal, DS.Space.xxl)
                    .padding(.bottom, DS.Space.xxl)
                }
            }
        }
    }

    private func fleetHome(_ bot: BotDefinition) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                fleetHomeHeader(bot)
                fleetHomeRouting(bot)
                HStack(alignment: .top, spacing: DS.Space.xl) {
                    VStack(alignment: .leading, spacing: DS.Space.lg) {
                        fleetHomeGoal(bot)
                        fleetHomeActivity(bot)
                        fleetHomeRoutine(bot)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    fleetHomeDesktop(bot)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                }
                fleetHomeStats()
            }
            .padding(DS.Space.xxl)
        }
        .accessibilityIdentifier("bots.home")
    }

    private func fleetHomeHeader(_ bot: BotDefinition) -> some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            BotsAvatarView(name: bot.name, handle: bot.handle, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: DS.Space.sm) {
                    Text(bot.name)
                        .font(DS.Font.title2.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                        .accessibilityIdentifier("bots.home.name")
                    Circle()
                        .fill(DS.Palette.success)
                        .frame(width: 8, height: 8)
                    Text(BotsChrome.statusTitle(for: vm.attentionState(for: bot)))
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                    attentionBadge(vm.attentionState(for: bot))
                }
                Text(bot.title.isEmpty ? "No job yet" : bot.title)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
                    .accessibilityIdentifier("bots.home.title")
            }
            Spacer(minLength: DS.Space.lg)
            Button(action: { vm.openDesk(bot) }) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "bubble.left")
                    Text(BotsChrome.Label.openChat)
                }
            }
            .buttonStyle(BotsPrimaryButtonStyle())
            .accessibilityIdentifier("bots.home.chat")
        }
    }

    private func fleetHomeRouting(_ bot: BotDefinition) -> some View {
        HStack(spacing: DS.Space.md) {
            Text("Routing")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
            ForEach([AgentProvider.claude, .codex, .grok], id: \.self) { provider in
                let selected = vm.resolvedProvider(for: bot) == provider
                Text(vm.providerChipTitle(provider))
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(selected ? BotsChrome.onPrimary : DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.lg)
                    .frame(minHeight: 32)
                    .background(selected ? BotsChrome.primary : DS.Palette.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityIdentifier(selected ? "bots.home.provider" : "bots.home.route.\(provider.rawValue)")
            }
            Spacer(minLength: 0)
            Button("Studio") { vm.beginEdit(bot) }
                .buttonStyle(DSSecondaryButtonStyle())
                .accessibilityIdentifier("bots.home.studio")
        }
    }

    private func fleetHomeGoal(_ bot: BotDefinition) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Label(BotsChrome.Label.currentGoal, systemImage: "target")
                .font(DS.Font.bodyStrong)
                .foregroundColor(DS.Palette.text)
            Text(vm.currentGoal(for: bot))
                .font(DS.Font.body)
                .foregroundColor(DS.Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dsPanel(padding: DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("bots.home.goal")
    }

    private func fleetHomeActivity(_ bot: BotDefinition) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Label(BotsChrome.Label.todaysActivity, systemImage: "waveform.path.ecg")
                .font(DS.Font.bodyStrong)
                .foregroundColor(DS.Palette.text)
            let rows = vm.activityRows(for: bot)
            if rows.isEmpty {
                Text("No activity yet")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textTertiary)
            } else {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
                        Circle()
                            .fill(BotsChrome.primary)
                            .frame(width: 6, height: 6)
                        Text(row.text)
                            .font(DS.Font.body)
                            .foregroundColor(DS.Palette.text)
                            .lineLimit(2)
                        Spacer(minLength: DS.Space.sm)
                        Text(row.createdAt, style: .time)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                }
            }
        }
        .dsPanel(padding: DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("bots.home.activity")
    }

    private func fleetHomeRoutine(_ bot: BotDefinition) -> some View {
        let routine = vm.routines.first(where: { $0.activation.isEnabled })
        return VStack(alignment: .leading, spacing: DS.Space.md) {
            Label(BotsChrome.Label.nextRoutine, systemImage: "calendar")
                .font(DS.Font.bodyStrong)
                .foregroundColor(DS.Palette.text)
            if let routine {
                Text(routine.definition.name)
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Text(routine.definition.scheduleNote.isEmpty ? "No schedule yet" : routine.definition.scheduleNote)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            } else {
                Text("No active routine for \(bot.name)")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textTertiary)
            }
            Text(BotRoutineCopy.testRunHonestyCaption)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dsPanel(padding: DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("bots.home.routine")
    }

    private func fleetHomeStats() -> some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            fleetStatCard(
                title: "Memory",
                value: "\(vm.liveMemoryCount)",
                detail: vm.isMemoryActive ? "facts" : "off",
                identifier: "bots.home.memory"
            )
            fleetStatCard(
                title: "Skills",
                value: "\(vm.enabledSkillCount)",
                detail: "enabled",
                identifier: "bots.home.skills"
            )
            fleetStatCard(
                title: "Routines",
                value: "\(vm.enabledRoutineCount)",
                detail: "no app-closed runs",
                identifier: "bots.home.routines"
            )
            fleetStatCard(
                title: "Approvals",
                value: "\(vm.pendingApprovalCount)",
                detail: "pending",
                identifier: "bots.home.approvals"
            )
        }
    }

    private func fleetStatCard(title: String, value: String, detail: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
            Text(value)
                .font(DS.Font.title2.weight(.semibold))
                .foregroundColor(DS.Palette.text)
            Text(detail)
                .font(DS.Font.caption2)
                .foregroundColor(DS.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanel(padding: DS.Space.lg)
        .accessibilityIdentifier(identifier)
    }

    private func fleetHomeDesktop(_ bot: BotDefinition) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm) {
                Label(BotsChrome.Label.desktop, systemImage: "desktopcomputer")
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Spacer(minLength: 0)
                DSPill("Logical space", tone: .neutral)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0x2A1848), Color(hex: 0x7B5CFF).opacity(0.55), Color(hex: 0x171D24)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                VStack(spacing: DS.Space.md) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundColor(.white.opacity(0.9))
                        .accessibilityHidden(true)
                    Text("Logical execution space")
                        .font(DS.Font.bodyStrong)
                        .foregroundColor(.white)
                    Text(vm.desktopHonestyLabel)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.warning)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("bots.home.desktop.honesty")
                }
                .padding(DS.Space.lg)
            }
            .frame(maxWidth: .infinity, minHeight: 188)
            if let model = vm.selectedRevision?.model, !model.isEmpty {
                Text(model)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
        }
        .dsPanel(padding: DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("bots.home.desktop")
        .accessibilityLabel("Desktop for \(bot.name). \(vm.desktopHonestyLabel)")
    }

    private var fleetHeader: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            HStack(alignment: .center, spacing: DS.Space.lg) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Bots")
                        .font(DS.Font.title.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                    Text("Named teammates with their own job, memory, and desk")
                        .font(DS.Font.body)
                        .foregroundColor(DS.Palette.textSecondary)
                }
                Spacer(minLength: DS.Space.lg)
                HStack(spacing: DS.Space.md) {
                    Button(action: vm.openAttention) {
                        Label(
                            vm.openAttentionCount == 0
                                ? "Attention"
                                : "Attention \(vm.openAttentionCount)",
                            systemImage: "bell"
                        )
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("bots.attention")

                    Button(action: vm.beginCreate) {
                        Label("New Bot", systemImage: "plus")
                    }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(!vm.isControlPlaneActive)
                    .accessibilityIdentifier("bots.new")
                }
            }

            HStack(spacing: DS.Space.md) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityHidden(true)
                    TextField("Search bots", text: $vm.searchText)
                        .textFieldStyle(.plain)
                        .foregroundColor(DS.Palette.text)
                }
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.md)
                .background(DS.Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                )
                .frame(maxWidth: 320)

                Spacer(minLength: DS.Space.lg)
                Toggle("Show hidden", isOn: $vm.showHidden)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .accessibilityIdentifier("bots.showHidden")
            }
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.top, DS.Space.xxl)
        .padding(.bottom, DS.Space.xl)
    }

    private func fleetRow(_ bot: BotDefinition) -> some View {
        Button {
            vm.openDesk(bot)
        } label: {
            HStack(spacing: DS.Space.lg) {
                Image(systemName: bot.avatarSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DS.Palette.accent)
                    .frame(width: 40, height: 40)
                    .background(DS.Palette.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.sm) {
                        Text(bot.name)
                            .font(DS.Font.bodyStrong)
                            .foregroundColor(DS.Palette.text)
                            .lineLimit(1)
                        Text("@\(bot.handle)")
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textTertiary)
                        if bot.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(DS.Palette.textTertiary)
                                .accessibilityLabel("Pinned")
                        }
                        if bot.hidden {
                            DSPill("Hidden", tone: .neutral)
                        }
                    }
                    Text(vm.rosterPreview(for: bot))
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                attentionBadge(vm.attentionState(for: bot))

                Menu {
                    Button(bot.pinned ? "Unpin" : "Pin") {
                        vm.setPinned(id: bot.id, pinned: !bot.pinned)
                    }
                    Button(bot.hidden ? "Unhide" : "Hide") {
                        vm.setHidden(id: bot.id, hidden: !bot.hidden)
                    }
                    Button("Duplicate") {
                        _ = try? vm.duplicate(id: bot.id)
                    }
                    Button("Edit") {
                        vm.beginEdit(bot)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        vm.pendingDeleteID = bot.id
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Bot actions")
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.lg)
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bots.fleet.row.\(bot.handle)")
    }

    @ViewBuilder
    private func attentionBadge(_ state: BotAttentionState) -> some View {
        switch state {
        case .needsAttention:
            DSPill("Needs attention", tone: .warning)
        case .unreadActivity:
            DSPill("Unread", tone: .accent)
        case .working:
            DSPill("Working", tone: .success)
        case .none:
            EmptyView()
        }
    }

    // MARK: Studio

    private var studioScreen: some View {
        VStack(spacing: 0) {
            studioHeader
            studioTabs
            Group {
                switch vm.studioTab {
                case .profile:
                    studioProfile
                case .memory:
                    memoryTab
                case .skills:
                    skillsTab
                case .routines:
                    routinesTab
                case .security:
                    studioSecurity
                case .desktop:
                    ScrollView {
                        studioDesktop
                            .padding(DS.Space.xxl)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("bots.studio")
    }

    private var studioHeader: some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            if !showsRosterRail {
                backButton { vm.openFleet() }
            }
            Image(systemName: vm.studioDraft.avatarSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(DS.Palette.accent)
                .frame(width: 40, height: 40)
                .background(DS.Palette.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: DS.Space.sm) {
                    Text("Bot Studio")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                    if vm.studioHasUnpublishedChanges {
                        DSPill("Draft", tone: .warning)
                    }
                }
                Text(vm.studioDraft.name.isEmpty ? "New Bot" : vm.studioDraft.name)
                    .font(DS.Font.title2.weight(.semibold))
                    .foregroundColor(DS.Palette.text)
                    .accessibilityIdentifier("bots.studio.name")
                Text(vm.studioDraft.title.isEmpty ? "No job yet" : vm.studioDraft.title)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
                    .accessibilityIdentifier("bots.studio.role")
            }
            Spacer(minLength: DS.Space.lg)
            Button(BotsChrome.Label.saveBot) {
                do { _ = try vm.saveStudio() } catch { vm.errorMessage = String(describing: error) }
            }
            .buttonStyle(BotsPrimaryButtonStyle())
            .disabled(!vm.isControlPlaneActive)
            .accessibilityIdentifier("bots.studio.save")
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.vertical, DS.Space.xl)
        .dsBar(edge: .bottom)
    }

    private var studioTabs: some View {
        HStack(spacing: DS.Space.xl) {
            ForEach(BotStudioTab.allCases) { tab in
                if tab == .memory && !vm.isMemoryActive {
                    EmptyView()
                } else {
                    let selected = vm.studioTab == tab
                    Button {
                        vm.studioTab = tab
                    } label: {
                        VStack(spacing: 6) {
                            Text(tab.title)
                                .font(DS.Font.body.weight(selected ? .semibold : .regular))
                                .foregroundColor(selected ? BotsChrome.primary : DS.Palette.textSecondary)
                            Rectangle()
                                .fill(selected ? BotsChrome.primary : Color.clear)
                                .frame(height: 2)
                        }
                        .frame(minHeight: BotsChrome.hitTarget, alignment: .bottom)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier(tab.accessibilityIdentifier)
                }
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.xxl)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Palette.line).frame(height: 1)
        }
    }

    private var studioProfile: some View {
        ScrollView {
            HStack(alignment: .top, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    studioIdentity
                    studioProvider
                    studioSoul
                    studioNotifications
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    studioSummary
                    studioDesktop
                }
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            }
            .padding(DS.Space.xxl)
        }
    }

    private var studioIdentity: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSectionHeaderG("Role & Identity")
            studioFormRow("Name") {
                studioField(placeholder: "e.g. Piper", text: $vm.studioDraft.name)
                    .onChange(of: vm.studioDraft.name) { name in
                        if vm.studioDraft.isNew, vm.studioDraft.handle.isEmpty || handleMatchesDerivedName {
                            vm.studioDraft.handle = BotHandle.derive(from: name) ?? vm.studioDraft.handle
                        }
                    }
            }
            studioFormRow("Role") {
                studioField(placeholder: "What this teammate does", text: $vm.studioDraft.title)
            }
            studioFormRow("Description") {
                studioMultiline(text: $vm.studioDraft.description, minHeight: 72)
                    .accessibilityIdentifier("bots.studio.description")
            }
            studioFormRow("Handle") {
                studioField(placeholder: "piper", text: $vm.studioDraft.handle)
                    .disabled(!vm.studioDraft.isNew)
            }
            studioFormRow("Avatar") {
                studioField(placeholder: "person.crop.circle", text: $vm.studioDraft.avatarSymbol)
            }
        }
        .dsPanel(padding: DS.Space.lg)
        .accessibilityIdentifier("bots.studio.identity")
    }

    private var handleMatchesDerivedName: Bool {
        vm.studioDraft.handle == (BotHandle.derive(from: vm.studioDraft.name) ?? "")
    }

    private var studioProvider: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSectionHeaderG("Provider routing")
            studioFormRow("Default route") {
                Picker("Provider", selection: $vm.studioDraft.provider) {
                    Text("Claude").tag(AgentProvider.claude)
                    Text("Codex").tag(AgentProvider.codex)
                    Text("Grok").tag(AgentProvider.grok)
                }
                .pickerStyle(.segmented)
                .onChange(of: vm.studioDraft.provider) { provider in
                    vm.applyDefaultModel(for: provider)
                }
                .accessibilityIdentifier("bots.studio.provider")
            }
            studioFormRow("Model") {
                studioField(placeholder: "Model id", text: $vm.studioDraft.model)
            }
            Text("One published route. Fallback order is not shipped in P1a.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
        }
        .dsPanel(padding: DS.Space.lg)
        .accessibilityIdentifier("bots.studio.routing")
    }

    private var studioSoul: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSectionHeaderG(BotsChrome.Label.instructions)
            studioMultiline(text: $vm.studioDraft.soul, minHeight: 140)
            Text("Published with the Bot. This is not an Agent thread.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
        }
        .dsPanel(padding: DS.Space.lg)
        .accessibilityIdentifier("bots.studio.soul")
    }

    private var studioDesktop: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSectionHeaderG("Desktop")
            desktopOption(
                kind: .logicalExecutionSpace,
                title: "Logical execution space",
                enabled: true,
                identifier: "bots.studio.desktop.logical"
            )
            desktopOption(
                kind: .dedicatedLocalVM,
                title: "Dedicated local VM Desktop",
                enabled: vm.isDesktopVMActive,
                notShipped: !vm.isDesktopVMActive,
                identifier: "bots.studio.desktop.vm"
            )
            desktopOption(
                kind: .managedRemoteMac,
                title: "Managed remote Mac Desktop",
                enabled: vm.isDesktopRemoteActive,
                notShipped: !vm.isDesktopRemoteActive,
                identifier: "bots.studio.desktop.remote"
            )
            Text(vm.desktopHonestyLabel)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bots.studio.desktop.honesty")
        }
        .dsPanel(padding: DS.Space.lg)
        .accessibilityIdentifier("bots.studio.desktop")
    }

    private func desktopOption(
        kind: BotDesktopKind,
        title: String,
        enabled: Bool,
        notShipped: Bool = false,
        identifier: String
    ) -> some View {
        Button {
            guard enabled else { return }
            vm.studioDraft.desktopKind = kind
        } label: {
            HStack(alignment: .top, spacing: DS.Space.md) {
                Image(systemName: vm.studioDraft.desktopKind == kind ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(enabled ? DS.Palette.accent : DS.Palette.textTertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.sm) {
                        Text(title)
                            .font(DS.Font.bodyStrong)
                            .foregroundColor(enabled ? DS.Palette.text : DS.Palette.textTertiary)
                        if notShipped {
                            DSPill("Not shipped", tone: .neutral)
                        }
                    }
                    Text(kind.honestyLabel)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Space.md)
            .background(DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
    }

    private var studioSecurity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                DSSectionHeaderG(BotsChrome.Label.security)
                Text("Approval policy and effect grants stay off until P1b. This tab is readable only.")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
                Text("No Allow once / Deny actions are live. Desktop isolation is not a security boundary.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .dsPanel(padding: DS.Space.lg)
            .padding(DS.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("bots.studio.security")
    }

    private var studioNotifications: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Notifications")
            Toggle("Notify when this Bot needs you", isOn: $vm.studioDraft.notificationsEnabled)
                .toggleStyle(.switch)
                .foregroundColor(DS.Palette.text)
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var studioSummary: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Configuration summary")
            studioSummaryRow("Workspace", vm.studioWorkspaceLabel)
            studioSummaryRow("Role", vm.studioDraft.title.isEmpty ? "No job yet" : vm.studioDraft.title)
            studioSummaryRow("Default route", vm.studioRouteLabel)
            studioSummaryRow("Model", vm.studioDraft.model.isEmpty ? "Default" : vm.studioDraft.model)
            studioSummaryRow("Approval mode", vm.studioApprovalLabel)
            studioSummaryRow("Desktop", vm.studioDesktopSummary)
            studioSummaryRow("Memory", "\(vm.liveMemoryCount) facts")
            studioSummaryRow("Skills", "\(vm.enabledSkillCount) enabled")
            studioSummaryRow("Routines", "\(vm.enabledRoutineCount) · no app-closed runs")
            studioSummaryRow("Notifications", vm.studioDraft.notificationsEnabled ? "On" : "Off")
            Text(vm.desktopHonestyLabel)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dsPanel(padding: DS.Space.lg)
        .accessibilityIdentifier("bots.studio.summary")
    }

    private func studioSummaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
            Text(label)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
            Spacer(minLength: DS.Space.sm)
            Text(value)
                .font(DS.Font.caption.weight(.medium))
                .foregroundColor(DS.Palette.text)
                .multilineTextAlignment(.trailing)
        }
    }

    private func studioFormRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            Text(label)
                .font(DS.Font.caption.weight(.medium))
                .foregroundColor(DS.Palette.textSecondary)
                .frame(width: 112, alignment: .leading)
                .padding(.top, 10)
            content()
        }
    }

    // MARK: Desk

    private var deskScreen: some View {
        Group {
            if let bot = vm.selectedBot {
                VStack(spacing: 0) {
                    deskHeader(bot)
                    deskChat(bot)
                }
                .accessibilityIdentifier("bots.desk")
            } else {
                fleetScreen.onAppear { vm.openFleet() }
            }
        }
    }

    private func deskHeader(_ bot: BotDefinition) -> some View {
        HStack(spacing: DS.Space.lg) {
            if !showsRosterRail {
                backButton { vm.openFleet() }
            }
            Image(systemName: bot.avatarSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DS.Palette.accent)
                .frame(width: 32, height: 32)
                .background(DS.Palette.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.sm) {
                    Text(bot.name)
                        .font(DS.Font.title2.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                        .accessibilityIdentifier("bots.desk.name")
                    Text("@\(bot.handle)")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .accessibilityIdentifier("bots.desk.handle")
                    if let provider = vm.providerLabel(for: bot) {
                        DSPill(provider, tone: .accent)
                            .accessibilityIdentifier("bots.desk.provider")
                    }
                    if let model = vm.modelLabel(for: bot) {
                        Text(model)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textTertiary)
                            .accessibilityIdentifier("bots.desk.model")
                    }
                    DSPill(vm.permissionLabel(for: bot), tone: .neutral)
                        .accessibilityIdentifier("bots.desk.permission")
                    attentionBadge(vm.attentionState(for: bot))
                }
                Text(bot.title.isEmpty ? "No job yet" : bot.title)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .accessibilityIdentifier("bots.desk.job")
            }
            Spacer(minLength: DS.Space.lg)
            Button("Studio") { vm.beginEdit(bot) }
                .buttonStyle(DSSecondaryButtonStyle())
                .accessibilityIdentifier("bots.desk.studio")
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.vertical, DS.Space.xl)
        .dsBar(edge: .bottom)
    }

    private func deskChat(_ bot: BotDefinition) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                deskTimeline(bot)
                if !vm.queuedFollowUps.isEmpty {
                    deskQueuedFollowUps
                }
                composerBar(bot)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle()
                .fill(DS.Palette.line)
                .frame(width: 1)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                deskDesktopPane(bot)
                deskInspector(bot)
            }
            .frame(minWidth: BotsChrome.desktopPaneWidth, idealWidth: 360, maxWidth: 420)
        }
    }

    private func deskDesktopPane(_ bot: BotDefinition) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                Label("\(bot.name) Desktop", systemImage: "desktopcomputer")
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Spacer(minLength: 0)
                DSPill("Logical space", tone: .neutral)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0x2A1848), Color(hex: 0x7B5CFF).opacity(0.45), Color(hex: 0x171D24)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                VStack(spacing: DS.Space.sm) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundColor(.white.opacity(0.92))
                    Text("Logical execution space")
                        .font(DS.Font.bodyStrong)
                        .foregroundColor(.white)
                    Text(vm.desktopHonestyLabel)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.warning)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("bots.desk.desktop.honesty")
                }
                .padding(DS.Space.lg)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        }
        .padding(DS.Space.lg)
        .dsBar(edge: .bottom)
        .accessibilityIdentifier("bots.desk.desktop")
        .accessibilityLabel("Desktop for \(bot.name). \(vm.desktopHonestyLabel)")
    }

    private func deskInspector(_ bot: BotDefinition) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                ForEach(BotDeskInspectorTab.allCases) { tab in
                    if tab == .memory && !vm.isMemoryActive {
                        EmptyView()
                    } else {
                        let selected = resolvedInspectorTab == tab
                        Button {
                            vm.inspectorTab = tab
                        } label: {
                            Text(tab.title)
                                .font(DS.Font.caption.weight(selected ? .semibold : .regular))
                                .foregroundColor(selected ? DS.Palette.onAccent : DS.Palette.textSecondary)
                                .padding(.horizontal, DS.Space.md)
                                .padding(.vertical, DS.Space.sm)
                                .background(selected ? DS.Palette.accent : DS.Palette.surfaceRaised)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier(tab.accessibilityIdentifier)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.lg)
            .padding(.bottom, DS.Space.md)

            Group {
                switch resolvedInspectorTab {
                case .memory:
                    inspectorMemory
                case .routines:
                    inspectorRoutines
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Palette.surface)
        .accessibilityIdentifier("bots.desk.inspector")
    }

    private var resolvedInspectorTab: BotDeskInspectorTab {
        if vm.inspectorTab == .memory && !vm.isMemoryActive {
            return .routines
        }
        return vm.inspectorTab
    }

    private var inspectorMemory: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            if vm.isMemoryActive {
                HStack(spacing: DS.Space.sm) {
                    studioField(placeholder: "Remember a fact", text: $vm.memoryDraft)
                        .accessibilityIdentifier("bots.memory.field")
                    Button("Add") { vm.addMemory() }
                        .buttonStyle(DSPrimaryButtonStyle())
                        .disabled(vm.memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("bots.memory.add")
                }
            } else {
                Text("Memory mutations are off. Turn on Bot memory in Settings.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
            if vm.memoryItems.isEmpty {
                Text("No remembered facts yet.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.sm) {
                        ForEach(vm.memoryItems, id: \.id) { item in
                            memoryRow(item, compact: true)
                        }
                    }
                }
                .accessibilityIdentifier("bots.memory.list")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.bottom, DS.Space.md)
        .accessibilityIdentifier("bots.desk.inspector.memory")
    }

    private var inspectorRoutines: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text(BotRoutineCopy.testRunHonestyCaption)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("bots.routines.honesty")
                labeledField("Name") {
                    studioField(placeholder: "Morning scan", text: $vm.routineName)
                        .accessibilityIdentifier("bots.routines.name")
                }
                labeledField("Instruction") {
                    studioMultiline(text: $vm.routinePrompt, minHeight: 56, maxHeight: 96)
                        .accessibilityIdentifier("bots.routines.instruction")
                }
                labeledField("When") {
                    studioField(placeholder: "Weekdays 9:00", text: $vm.routineScheduleNote)
                        .accessibilityIdentifier("bots.routines.when")
                }
                Button("Save routine") { vm.saveRoutine() }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("bots.routines.save")
                if vm.routines.isEmpty {
                    Text("No routines yet.")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                } else {
                    ForEach(vm.routines, id: \.definition.id) { routine in
                        routineRow(routine)
                    }
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.bottom, DS.Space.md)
        }
        .accessibilityIdentifier("bots.desk.inspector.routines")
    }

    private func deskTimeline(_ bot: BotDefinition) -> some View {
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.xl) {
                    if vm.deskTimeline.isEmpty {
                        Text("Message \(bot.name) to give it a first task.")
                            .font(DS.Font.body)
                            .foregroundColor(DS.Palette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, DS.Space.xl)
                    }
                    ForEach(vm.deskTimeline) { item in
                        switch item {
                        case .message(let message):
                            deskBubble(message, columnWidth: geo.size.width)
                        case .workLog(let row):
                            deskWorkLogRow(row)
                        case .liveTurn(let turn, let hideAssistantOutput):
                            AgentChatLiveTurnView(
                                turn: turn,
                                live: vm.deskRunIsLive && !turn.finished,
                                hideAssistantOutput: hideAssistantOutput
                            )
                        }
                    }
                    if vm.deskShowsLoading {
                        AgentChatLoadingStatusStrip()
                    } else if vm.deskRunIsLive, let started = vm.deskWorkingStartedAt() {
                        AgentChatWorkingStatusStrip(
                            startedAt: started,
                            isStopping: vm.isStopping,
                            onStop: { vm.stopDeskRun() }
                        )
                    }
                }
                .padding(.horizontal, DS.Space.xxl)
                .padding(.vertical, DS.Space.xl)
            }
        }
        .accessibilityIdentifier("bots.desk.timeline")
    }

    private func deskBubble(_ message: BotDeskMessage, columnWidth: CGFloat) -> some View {
        Group {
            if message.role == .user {
                AgentChatUserBubble(
                    text: message.text,
                    createdAt: message.createdAt,
                    columnWidth: columnWidth,
                    accessibilityIdentifier: "agent.userMessageBubble",
                    roleIdentifier: "bots.desk.role.user"
                )
            } else {
                AgentChatAssistantReply(
                    text: message.text,
                    roleIdentifier: "bots.desk.role.assistant"
                )
            }
        }
    }

    private func deskWorkLogRow(_ row: BotDeskWorkLogRow) -> some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Text(row.createdAt, style: .time)
                .font(DS.Font.caption2)
                .foregroundColor(DS.Palette.textTertiary)
                .frame(width: 56, alignment: .trailing)
            HStack(alignment: .center, spacing: DS.Space.md) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(DS.Font.bodyStrong)
                        .foregroundColor(DS.Palette.text)
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                DSPill(row.statusLabel, tone: workLogTone(row.statusLabel))
            }
            .dsPanel(padding: DS.Space.lg)
        }
        .accessibilityIdentifier("bots.desk.workLog")
        .accessibilityLabel("work log \(row.title) \(row.statusLabel)")
    }

    private func workLogTone(_ status: String) -> DSPill.Tone {
        switch status {
        case "Working", "Done":
            return .success
        case "Needs you":
            return .warning
        default:
            return .neutral
        }
    }

    private var deskQueuedFollowUps: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Palette.accent)
                    .accessibilityHidden(true)
                Text("Queued")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.accent)
                Text("\(vm.queuedFollowUps.count)")
                    .font(DS.Font.caption.monospacedDigit())
                    .foregroundColor(DS.Palette.textTertiary)
                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("bots.desk.queued.header")
            ForEach(vm.queuedFollowUps) { item in
                HStack(alignment: .top, spacing: DS.Space.md) {
                    Text(AgentChatTranscriptChrome.displayUserLine(
                        text: item.text,
                        attachments: item.attachments
                    ))
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(3)
                    Spacer(minLength: DS.Space.sm)
                    Button("Remove") { vm.removeQueuedFollowUp(item) }
                        .buttonStyle(.plain)
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.textSecondary)
                        .accessibilityIdentifier("bots.desk.queued.remove")
                }
            }
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.vertical, DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.bg)
        .accessibilityIdentifier("bots.desk.queued")
    }

    private func composerBar(_ bot: BotDefinition) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            AgentChatComposerBar(
                text: $vm.composerText,
                attachments: vm.attachments,
                placeholder: AgentChatTranscriptChrome.composerPlaceholder(
                    providerDisplayName: vm.providerLabel(for: bot) ?? bot.name
                ),
                sendEnabled: vm.deskSendEnabled,
                runActive: vm.deskRunIsLive,
                isStopping: vm.isStopping,
                workingLabel: vm.deskWorkingLabel(now: context.date),
                attachEnabled: true,
                onSend: { vm.send() },
                onStop: { vm.stopDeskRun() },
                onAttach: { vm.addAttachments($0) },
                onRemoveAttachment: { vm.removeAttachment($0) },
                composerIdentifier: "bots.desk.composer",
                sendIdentifier: "bots.desk.send"
            )
        }
    }

    // MARK: Memory

    private var memoryTab: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSectionHeaderG("Brain / Memory")
            if vm.isMemoryActive {
                HStack(alignment: .top, spacing: DS.Space.md) {
                    studioMultiline(text: $vm.memoryDraft, minHeight: 56, maxHeight: 72)
                    Button("Add") { vm.addMemory() }
                        .buttonStyle(DSPrimaryButtonStyle())
                        .disabled(vm.memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("bots.memory.add")
                }
            } else {
                Text("Memory mutations are off. Turn on Bot memory in Settings.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
            if vm.memoryItems.isEmpty {
                Text("No remembered facts yet.")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textTertiary)
            } else {
                ForEach(vm.memoryItems, id: \.id) { item in
                    memoryRow(item)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.xxl)
        .accessibilityIdentifier("bots.studio.memory")
    }

    private var skillsTab: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSectionHeaderG("Skills")
            Text("Catalog ids only. A skill id is not a filesystem path.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
            HStack(alignment: .center, spacing: DS.Space.md) {
                studioField(placeholder: "weekly-account-health", text: $vm.skillDraft)
                Button("Add") { vm.addSkill() }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(vm.skillDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.selectedBot == nil)
                    .accessibilityIdentifier("bots.studio.skills.add")
            }
            if vm.skillBindings.isEmpty {
                Text("No skills bound yet.")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textTertiary)
            } else {
                ForEach(vm.skillBindings, id: \.skillID) { binding in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(binding.skillID)
                                .font(DS.Font.bodyStrong)
                                .foregroundColor(DS.Palette.text)
                            Text(binding.enabled ? "Enabled" : "Off")
                                .font(DS.Font.caption)
                                .foregroundColor(DS.Palette.textTertiary)
                        }
                        Spacer()
                        Toggle(binding.enabled ? "On" : "Off", isOn: Binding(
                            get: { binding.enabled },
                            set: { vm.setSkillEnabled(skillID: binding.skillID, enabled: $0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .dsPanel(padding: DS.Space.lg)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.xxl)
        .accessibilityIdentifier("bots.studio.skills")
    }

    private func memoryRow(_ item: BotMemoryItem, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(item.content)
                .font(DS.Font.body)
                .foregroundColor(DS.Palette.text)
                .textSelection(.enabled)
            HStack(spacing: DS.Space.sm) {
                Text(item.provenance)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                Spacer(minLength: 0)
                if vm.isMemoryActive {
                    Button("Correct") {
                        let next = promptCorrection(current: item.content)
                        if let next { vm.correctMemory(id: item.id, content: next) }
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("bots.memory.correct")
                    Button("Forget", role: .destructive) {
                        vm.forgetMemory(id: item.id)
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("bots.memory.forget")
                }
            }
        }
        .dsPanel(padding: compact ? DS.Space.md : DS.Space.lg)
    }

    private func promptCorrection(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Correct memory"
        alert.informativeText = "Corrections write a new revision; they do not rewrite the old one."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    // MARK: Routines

    private var routinesTab: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSectionHeaderG("Routines")
            Text(BotRoutineCopy.testRunHonestyCaption)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bots.routines.honesty")
            if !vm.isAutonomyActive {
                Text("Enabling a schedule does not run while RemoteCode is closed.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
            labeledField("Name") {
                studioField(placeholder: "Morning scan", text: $vm.routineName)
                    .accessibilityIdentifier("bots.routines.name")
            }
            labeledField("Instruction") {
                studioMultiline(text: $vm.routinePrompt, minHeight: 72, maxHeight: 140)
                    .accessibilityIdentifier("bots.routines.instruction")
            }
            labeledField("When") {
                studioField(placeholder: "Weekdays 9:00", text: $vm.routineScheduleNote)
                    .accessibilityIdentifier("bots.routines.when")
            }
            Button("Save routine") { vm.saveRoutine() }
                .buttonStyle(DSSecondaryButtonStyle())
                .accessibilityIdentifier("bots.routines.save")

            if vm.routines.isEmpty {
                Text("No routines yet.")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textTertiary)
            } else {
                ForEach(vm.routines, id: \.definition.id) { routine in
                    routineRow(routine)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.xxl)
    }

    private func routineRow(_ routine: BotRoutine) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Text(routine.definition.name)
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Spacer()
                Toggle("Active", isOn: Binding(
                    get: { routine.activation.isEnabled },
                    set: { vm.setRoutineEnabled(id: routine.definition.id, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("bots.routines.active")
            }
            Text(routine.definition.prompt)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
            if !routine.definition.scheduleNote.isEmpty {
                Text(routine.definition.scheduleNote)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
            Button("Test run") { vm.requestRoutineTestRun(id: routine.definition.id) }
                .buttonStyle(DSSecondaryButtonStyle())
                .accessibilityIdentifier("bots.routines.test")
            if let at = routine.activation.lastTestRunRequestedAt {
                Text("Test run requested \(at.formatted(date: .abbreviated, time: .shortened))")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
            }
        }
        .dsPanel(padding: DS.Space.lg)
    }

    // MARK: Attention

    private var attentionScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.lg) {
                backButton { vm.openFleet() }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Attention")
                        .font(DS.Font.title2.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                    Text("Open a teammate, then acknowledge")
                        .font(DS.Font.body)
                        .foregroundColor(DS.Palette.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.vertical, DS.Space.xl)
            .dsBar(edge: .bottom)

            if vm.attentionItems.isEmpty {
                DSEmptyState(
                    icon: "bell",
                    title: "Nothing needs you",
                    subtitle: "When a Bot is blocked or waiting, it shows up here."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.md) {
                        ForEach(vm.attentionItems, id: \.id) { item in
                            Button {
                                vm.openAttention(item)
                            } label: {
                                HStack(alignment: .top, spacing: DS.Space.lg) {
                                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                                        Text(item.title)
                                            .font(DS.Font.bodyStrong)
                                            .foregroundColor(DS.Palette.text)
                                        if !item.detail.isEmpty {
                                            Text(item.detail)
                                                .font(DS.Font.caption)
                                                .foregroundColor(DS.Palette.textSecondary)
                                                .lineLimit(3)
                                        }
                                        Text(item.kind.rawValue)
                                            .font(DS.Font.caption2)
                                            .foregroundColor(DS.Palette.textTertiary)
                                    }
                                    Spacer()
                                    Button("Acknowledge") {
                                        vm.acknowledge(item)
                                    }
                                    .buttonStyle(DSSecondaryButtonStyle())
                                }
                                .dsPanel(padding: DS.Space.lg)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("bots.attention.row.\(item.id.value.uuidString.lowercased())")
                        }
                    }
                    .padding(DS.Space.xxl)
                }
            }
        }
    }

    // MARK: Shared chrome

    private func backButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Palette.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label)
                .font(DS.Font.caption.weight(.medium))
                .foregroundColor(DS.Palette.textSecondary)
            content()
        }
    }

    private func studioField(placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
            .background(DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
    }

    private func studioMultiline(text: Binding<String>, minHeight: CGFloat, maxHeight: CGFloat? = nil) -> some View {
        TextEditor(text: text)
            .font(DS.Font.body)
            .foregroundColor(DS.Palette.text)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.md)
            .background(DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
    }
}

// MARK: - Optional detached window (fallback if the shell presenter is missing)

public final class BotsWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: BotsViewModel

    public init(context: AppContext, router: AppCommandRouter) {
        self.viewModel = BotsViewModel(context: context, router: router)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bots"
        window.minSize = NSSize(width: 980, height: 680)
        window.center()
        window.backgroundColor = DS.NS.bg
        window.contentView = NSHostingView(rootView: BotsRootView(vm: viewModel))
        window.setAccessibilityIdentifier("bots.window")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func show() {
        viewModel.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
