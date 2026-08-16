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

public struct BotComposerDraft: Equatable, Codable {
    public var text: String
    public var attachments: [AgentAttachment]

    public init(text: String = "", attachments: [AgentAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    public var liveAttachments: [AgentAttachment] {
        attachments.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public struct BotInspectorDraft: Equatable, Codable {
    public var memoryDraft: String
    public var skillDraft: String
    public var routineName: String
    public var routinePrompt: String
    public var routineScheduleNote: String

    public init(
        memoryDraft: String = "",
        skillDraft: String = "",
        routineName: String = "",
        routinePrompt: String = "",
        routineScheduleNote: String = ""
    ) {
        self.memoryDraft = memoryDraft
        self.skillDraft = skillDraft
        self.routineName = routineName
        self.routinePrompt = routinePrompt
        self.routineScheduleNote = routineScheduleNote
    }

    public var isEmpty: Bool {
        [memoryDraft, skillDraft, routineName, routinePrompt, routineScheduleNote]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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

    /// Home/fleet and the old Attention full-screen are not destinations.
    /// Leftover persist remaps them to Chat.
    public var resolvedDestination: BotsScreen {
        switch self {
        case .studio:
            return .studio
        case .desk, .fleet, .attention:
            return .desk
        }
    }
}

public enum BotDeskInspectorTab: String, CaseIterable, Identifiable {
    case brain
    case memory
    case routines

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .brain: return BotsChrome.Label.brain
        case .memory: return "Memory"
        case .routines: return "Routines"
        }
    }

    public var accessibilityIdentifier: String {
        switch self {
        case .brain: return "bots.desk.inspector.tab.brain"
        case .memory: return "bots.desk.inspector.tab.memory"
        case .routines: return "bots.desk.inspector.tab.routines"
        }
    }
}

public enum BotStudioTab: String, CaseIterable, Identifiable {
    case profile
    case brain
    case memory
    case skills
    case routines
    case security
    case desktop

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .profile: return "Profile"
        case .brain: return BotsChrome.Label.brain
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
        case .brain: return "bots.studio.tab.brain"
        case .memory: return "bots.studio.tab.memory"
        case .skills: return "bots.studio.tab.skills"
        case .routines: return "bots.studio.tab.routines"
        case .security: return "bots.studio.tab.security"
        case .desktop: return "bots.studio.tab.desktop"
        }
    }

    public var symbol: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .brain: return "brain.head.profile"
        case .memory: return "archivebox"
        case .skills: return "puzzlepiece.extension"
        case .routines: return "clock.arrow.2.circlepath"
        case .security: return "lock.shield"
        case .desktop: return "desktopcomputer"
        }
    }
}

public enum BotBrainInspectorPane: String, CaseIterable, Identifiable {
    case source
    case effective

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .source: return BotsChrome.Label.source
        case .effective: return BotsChrome.Label.effective
        }
    }

    public var accessibilityIdentifier: String {
        switch self {
        case .source: return "bots.brain.pane.source"
        case .effective: return "bots.brain.pane.effective"
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
    @Published public var screen: BotsScreen = .desk {
        didSet {
            let resolved = screen.resolvedDestination
            if screen != resolved {
                screen = resolved
                return
            }
            persistScreen()
        }
    }
    @Published public var inspectorTab: BotDeskInspectorTab = .memory {
        didSet { persistInspectorTab() }
    }
    @Published public var studioTab: BotStudioTab = .profile {
        didSet { persistStudioTab() }
    }
    @Published public var studioDraft = BotStudioDraft()
    @Published public var composerText: String = "" {
        didSet { persistComposerIfHydrated() }
    }
    @Published public var attachments: [AgentAttachment] = [] {
        didSet { persistComposerIfHydrated() }
    }
    @Published public var isStopping = false
    @Published public private(set) var queuedFollowUps: [BotQueuedFollowUp] = []
    @Published public private(set) var deskMessages: [BotDeskMessage] = []
    @Published public private(set) var deskWorkLog: [BotDeskWorkLogRow] = []
    @Published public private(set) var deskLiveTimeline = AssistantTimelineState()
    @Published public private(set) var deskStreamEventCount = 0
    @Published public private(set) var deskSendInFlight = false
    @Published public private(set) var deskSendInFlightStartedAt: Date?
    /// Owner of the in-flight send so roster switch does not paint Loading on the wrong desk.
    private var deskSendInFlightBotID: BotID?
    @Published public private(set) var conversations: [BotConversation] = []
    @Published public private(set) var selectedConversation: BotConversation?
    @Published public private(set) var attentionItems: [BotAttentionItem] = []
    @Published public private(set) var memoryItems: [BotMemoryItem] = []
    @Published public private(set) var skillBindings: [BotSkillBinding] = []
    @Published public private(set) var selectedRevision: BotRevision?
    @Published public private(set) var lastContextReceipt: ContextAssemblyReceipt?
    @Published public var brainPane: BotBrainInspectorPane = .source
    @Published public private(set) var routines: [BotRoutine] = []
    @Published public var memoryDraft: String = "" {
        didSet { persistInspectorIfHydrated() }
    }
    @Published public var skillDraft: String = "" {
        didSet { persistInspectorIfHydrated() }
    }
    @Published public var routineName: String = "" {
        didSet { persistInspectorIfHydrated() }
    }
    @Published public var routinePrompt: String = "" {
        didSet { persistInspectorIfHydrated() }
    }
    @Published public var routineScheduleNote: String = "" {
        didSet { persistInspectorIfHydrated() }
    }
    @Published public var errorMessage: String?
    @Published public private(set) var providers: [AgentProviderSnapshot] = []
    @Published public private(set) var isControlPlaneActive = true
    @Published public private(set) var isMemoryActive = true
    @Published public private(set) var isAutonomyActive = false
    @Published public private(set) var lastSendStartedProviderRun = false
    @Published public var pendingDeleteID: BotID?
    public var onLeaveBots: (() -> Void)?

    public var displayedDesktopKind: BotDesktopKind {
        if screen == .studio {
            return resolvedDesktopKind(studioDraft.desktopKind)
        }
        return resolvedDesktopKind(selectedRevision?.desktopKind ?? .logicalExecutionSpace)
    }

    public var desktopHonestyLabel: String {
        displayedDesktopKind.honestyLabel
    }

    public var desktopStatusPill: String {
        displayedDesktopKind.statusPill
    }

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
    private var composerDraftsByBot: [BotID: BotComposerDraft] = [:]
    private var composerHydrated = false
    private var isApplyingComposerDraft = false
    private var inspectorDraftsByBot: [BotID: BotInspectorDraft] = [:]
    private var inspectorHydrated = false
    private var isApplyingInspectorDraft = false
    private var deskLiveTurnWatch: Task<Void, Never>?

    public init(context: AppContext, router: AppCommandRouter? = nil) {
        self.context = context
        self.router = router
        self.botStore = context.botStore
        self.settingsStore = SettingsStore(db: context.db)
        restoreQueuedFollowUpsIfNeeded()
        restoreComposerDraftsIfNeeded()
        restoreInspectorDraftsIfNeeded()
        restoreInspectorTabIfNeeded()
        restoreStudioTabIfNeeded()
        reload()
        restoreScreenIfNeeded()
        if !composerHydrated {
            applyComposerDraft(for: selectedBotID)
        }
        if !inspectorHydrated {
            applyInspectorDraft(for: selectedBotID)
        }
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
            // Hermes seeds SOUL.md on first run — do not start a soulless New Agent.
            let name = "New Agent"
            let bot = try create(
                name: name,
                title: "",
                description: "",
                soul: BotStandingInstructions.fallback(name: name, title: "", description: "")
            )
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
        adoptSelectedBot(bot.id)
        studioTab = .profile
        screen = .studio
        persistSelection()
        reloadSelectedBot(id: bot.id)
    }

    /// Keep the starter soul aligned with Role & Identity until the user writes their own.
    public func refreshGeneratedStandingInstructions() {
        guard BotStandingInstructions.looksGenerated(studioDraft.soul) else { return }
        studioDraft.soul = BotStandingInstructions.fallback(
            name: studioDraft.name,
            title: studioDraft.title,
            description: studioDraft.description
        )
    }

    public func openFleet() {
        reloadFleet()
        reloadAttention()
        restoreSelectedBotIfNeeded()
        if selectedBotID == nil, let first = fleet.first {
            adoptSelectedBot(first.id)
        }
        if let bot = selectedBot {
            openDesk(bot)
        } else {
            screen = .desk
            persistSelection()
        }
    }

    public func openHome(_ bot: BotDefinition) {
        openDesk(bot)
    }

    public func openDesk(_ bot: BotDefinition) {
        adoptSelectedBot(bot.id)
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
        if let item = attentionItems.first {
            openAttention(item)
            return
        }
        if let bot = selectedBot {
            openDesk(bot)
        } else {
            screen = .desk
        }
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
            screen = .desk
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
        notificationsEnabled: Bool = true,
        desktopKind: BotDesktopKind = .logicalExecutionSpace
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
            desktopKind: resolvedDesktopKind(desktopKind),
            workspaceID: context.state.window.selectedWorkspaceID,
            notificationsEnabled: notificationsEnabled
        )
        adoptSelectedBot(bot.id)
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
        let soul = BotStandingInstructions.resolved(
            name: name,
            title: studioDraft.title,
            description: studioDraft.description,
            soul: studioDraft.soul
        )
        studioDraft.soul = soul
        if let botID = studioDraft.botID {
            guard let bot = try botStore.get(id: botID), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            let draft = BotRevisionDraft(
                name: name,
                title: studioDraft.title,
                description: studioDraft.description,
                soul: soul,
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
            adoptSelectedBot(botID)
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
            soul: soul,
            provider: studioDraft.provider,
            providerInstanceID: studioDraft.providerInstanceID.isEmpty ? nil : studioDraft.providerInstanceID,
            model: studioDraft.model,
            avatarSymbol: studioDraft.avatarSymbol,
            notificationsEnabled: studioDraft.notificationsEnabled,
            desktopKind: desktop
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
        adoptSelectedBot(copy.id)
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
                adoptSelectedBot(nil)
                screen = .fleet
                persistSelection()
            }
            reloadFleet()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func duplicateFromRoster(_ bot: BotDefinition) {
        do {
            let copy = try duplicate(id: bot.id)
            if screen == .studio {
                beginEdit(copy)
            } else {
                openDesk(copy)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func delete(id: BotID) {
        do {
            try botStore.delete(id: id)
            if selectedBotID == id {
                adoptSelectedBot(nil)
                screen = .desk
                persistSelection()
            }
            queuedFollowUpsByBot[id] = nil
            composerDraftsByBot[id] = nil
            inspectorDraftsByBot[id] = nil
            clearDeskSendInFlight(for: id)
            persistQueuedFollowUps()
            persistComposerDrafts()
            persistInspectorDrafts()
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
        guard deskSendInFlight, !deskRunIsLive else { return false }
        return deskSendInFlightBotID == nil || deskSendInFlightBotID == selectedBotID
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
                beginDeskSendInFlight(for: bot.id)
                Task { [weak self] in
                    guard let self else { return }
                    await Task.yield()
                    let started = await self.startSupervisedRun(
                        bot: bot,
                        revision: revision,
                        conversation: conversation,
                        userText: message,
                        attachments: attached,
                        router: router
                    )
                    self.clearDeskSendInFlight(for: bot.id)
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
        resolvedDesktopKind(studioDraft.desktopKind).displayTitle
    }

    public var studioApprovalLabel: String { "Supervised" }

    public var inspectedBrain: ContextAssemblyReceipt? {
        if screen == .studio {
            return previewBrain()
        }
        return lastContextReceipt ?? previewBrain()
    }

    public var inspectedBrainIsPreview: Bool {
        screen == .studio || lastContextReceipt == nil
    }

    public var inspectedBrainIsLastCall: Bool {
        screen != .studio && lastContextReceipt?.runID != nil
    }

    public func previewBrain(userText: String? = nil) -> ContextAssemblyReceipt? {
        let text = (userText ?? composerText)
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bot = selectedBot ?? studioPreviewBot() else { return nil }
        guard let revision = studioPreviewRevision(for: bot) ?? selectedRevision else { return nil }
        let memory = (try? botStore.listMemory(botID: bot.id, includeForgotten: true)) ?? memoryItems
        return BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: request,
            memory: memory,
            skills: skillBindings,
            conversationID: selectedConversation?.id
        )
    }

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
            pruneComposerDraftsToFleet()
            pruneInspectorDraftsToFleet()
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
            reloadContextReceipt(botID: id)
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
    private static let composerDraftsDefaultsKey = "bots.composerDrafts"
    private static let inspectorDraftsDefaultsKey = "bots.inspectorDrafts"

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

    private func persistComposerIfHydrated() {
        guard composerHydrated, !isApplyingComposerDraft else { return }
        captureComposerDraft()
    }

    private func adoptSelectedBot(_ id: BotID?) {
        if selectedBotID == id {
            if composerHydrated {
                captureComposerDraft()
            } else {
                applyComposerDraft(for: id)
            }
            if inspectorHydrated {
                captureInspectorDraft()
            } else {
                applyInspectorDraft(for: id)
            }
            return
        }
        if composerHydrated {
            captureComposerDraft()
        }
        if inspectorHydrated {
            captureInspectorDraft()
        }
        selectedBotID = id
        applyComposerDraft(for: id)
        applyInspectorDraft(for: id)
    }

    private func captureComposerDraft(for botID: BotID? = nil) {
        guard let botID = botID ?? selectedBotID else { return }
        let draft = BotComposerDraft(text: composerText, attachments: attachments)
        if draft.isEmpty {
            composerDraftsByBot[botID] = nil
        } else {
            composerDraftsByBot[botID] = draft
        }
        persistComposerDrafts()
    }

    private func applyComposerDraft(for botID: BotID?) {
        let draft = botID.flatMap { composerDraftsByBot[$0] }
        isApplyingComposerDraft = true
        composerText = draft?.text ?? ""
        attachments = draft?.liveAttachments ?? []
        isApplyingComposerDraft = false
        composerHydrated = true
    }

    private func persistComposerDrafts() {
        let payload = Dictionary(uniqueKeysWithValues: composerDraftsByBot.compactMap { id, draft -> (String, BotComposerDraft)? in
            draft.isEmpty ? nil : (id.value.uuidString.lowercased(), draft)
        })
        if payload.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.composerDraftsDefaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: Self.composerDraftsDefaultsKey)
        }
    }

    private func restoreComposerDraftsIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: Self.composerDraftsDefaultsKey),
              let payload = try? JSONDecoder().decode([String: BotComposerDraft].self, from: data)
        else { return }
        var restored: [BotID: BotComposerDraft] = [:]
        for (raw, draft) in payload {
            guard let uuid = UUID(uuidString: raw), !draft.isEmpty else { continue }
            restored[BotID(uuid)] = draft
        }
        composerDraftsByBot = restored
    }

    private func pruneComposerDraftsToFleet() {
        let live = Set(bots.map(\.id))
        let next = composerDraftsByBot.filter { live.contains($0.key) }
        guard next.count != composerDraftsByBot.count else { return }
        composerDraftsByBot = next
        persistComposerDrafts()
    }

    private func persistInspectorIfHydrated() {
        guard inspectorHydrated, !isApplyingInspectorDraft else { return }
        captureInspectorDraft()
    }

    private func captureInspectorDraft(for botID: BotID? = nil) {
        guard let botID = botID ?? selectedBotID else { return }
        let draft = BotInspectorDraft(
            memoryDraft: memoryDraft,
            skillDraft: skillDraft,
            routineName: routineName,
            routinePrompt: routinePrompt,
            routineScheduleNote: routineScheduleNote
        )
        if draft.isEmpty {
            inspectorDraftsByBot[botID] = nil
        } else {
            inspectorDraftsByBot[botID] = draft
        }
        persistInspectorDrafts()
    }

    private func applyInspectorDraft(for botID: BotID?) {
        let draft = botID.flatMap { inspectorDraftsByBot[$0] } ?? BotInspectorDraft()
        isApplyingInspectorDraft = true
        memoryDraft = draft.memoryDraft
        skillDraft = draft.skillDraft
        routineName = draft.routineName
        routinePrompt = draft.routinePrompt
        routineScheduleNote = draft.routineScheduleNote
        isApplyingInspectorDraft = false
        inspectorHydrated = true
    }

    private func persistInspectorDrafts() {
        let payload = Dictionary(uniqueKeysWithValues: inspectorDraftsByBot.compactMap { id, draft -> (String, BotInspectorDraft)? in
            draft.isEmpty ? nil : (id.value.uuidString.lowercased(), draft)
        })
        if payload.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.inspectorDraftsDefaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: Self.inspectorDraftsDefaultsKey)
        }
    }

    private func restoreInspectorDraftsIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: Self.inspectorDraftsDefaultsKey),
              let payload = try? JSONDecoder().decode([String: BotInspectorDraft].self, from: data)
        else { return }
        var restored: [BotID: BotInspectorDraft] = [:]
        for (raw, draft) in payload {
            guard let uuid = UUID(uuidString: raw), !draft.isEmpty else { continue }
            restored[BotID(uuid)] = draft
        }
        inspectorDraftsByBot = restored
    }

    private func pruneInspectorDraftsToFleet() {
        let live = Set(bots.map(\.id))
        let next = inspectorDraftsByBot.filter { live.contains($0.key) }
        guard next.count != inspectorDraftsByBot.count else { return }
        inspectorDraftsByBot = next
        persistInspectorDrafts()
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
        switch saved.resolvedDestination {
        case .studio:
            guard selectionMatches, let bot = selectedBot else {
                screen = .desk
                return
            }
            let tab = studioTab
            beginEdit(bot)
            studioTab = tab
        case .desk, .fleet, .attention:
            if selectionMatches, let bot = selectedBot {
                openDesk(bot)
            } else {
                screen = .desk
            }
        }
    }

    private func restoreSelectedBotIfNeeded() {
        if let selectedBotID, fleet.contains(where: { $0.id == selectedBotID }) {
            if !composerHydrated {
                applyComposerDraft(for: selectedBotID)
            }
            if !inspectorHydrated {
                applyInspectorDraft(for: selectedBotID)
            }
            return
        }
        if let raw = UserDefaults.standard.string(forKey: Self.selectedBotDefaultsKey),
           let uuid = UUID(uuidString: raw),
           fleet.contains(where: { $0.id == BotID(uuid) }) {
            adoptSelectedBot(BotID(uuid))
            return
        }
        adoptSelectedBot(fleet.first?.id)
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

    private func reloadContextReceipt(botID: BotID) {
        do {
            if let conversationID = selectedConversation?.id,
               let receipt = try botStore.latestContextReceipt(botID: botID, conversationID: conversationID) {
                lastContextReceipt = receipt
            } else {
                lastContextReceipt = try botStore.latestContextReceipt(botID: botID)
            }
        } catch {
            lastContextReceipt = nil
        }
    }

    private func studioPreviewBot() -> BotDefinition? {
        if let selectedBot { return selectedBot }
        let handle = BotHandle.normalize(studioDraft.handle) ?? "draft"
        return BotDefinition(
            handle: handle,
            name: studioDraft.name,
            title: studioDraft.title,
            description: studioDraft.description,
            avatarSymbol: studioDraft.avatarSymbol
        )
    }

    private func studioPreviewRevision(for bot: BotDefinition) -> BotRevision? {
        let draft = BotRevisionDraft(
            name: studioDraft.name,
            title: studioDraft.title,
            description: studioDraft.description,
            soul: studioDraft.soul,
            provider: studioDraft.provider,
            providerInstanceID: studioDraft.providerInstanceID.isEmpty
                ? studioDraft.provider.rawValue
                : studioDraft.providerInstanceID,
            model: studioDraft.model.isEmpty ? Self.defaultModel(for: studioDraft.provider) : studioDraft.model,
            permissionMode: .supervised,
            desktopKind: resolvedDesktopKind(studioDraft.desktopKind)
        )
        if screen != .studio, let selectedRevision { return selectedRevision }
        return BotRevision(
            id: selectedRevision?.id ?? BotRevisionID(),
            botID: bot.id,
            revisionNumber: selectedRevision?.revisionNumber ?? 0,
            name: draft.name,
            title: draft.title,
            description: draft.description,
            soul: draft.soul,
            provider: draft.provider,
            providerInstanceID: draft.providerInstanceID,
            model: draft.model,
            reasoningEffort: selectedRevision?.reasoningEffort ?? .medium,
            compatibleRouteSet: selectedRevision?.compatibleRouteSet ?? ["default"],
            permissionMode: draft.permissionMode,
            desktopKind: draft.desktopKind,
            digest: BotRevision.digest(botID: bot.id, draft: draft),
            publishedAt: selectedRevision?.publishedAt ?? Date(),
            supersedesRevisionID: selectedRevision?.id
        )
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
            let memory = (try? botStore.listMemory(botID: bot.id, includeForgotten: true)) ?? []
            let skills = (try? botStore.listSkillBindings(botID: bot.id)) ?? []
            var receipt = BotBrainCompiler.assemble(
                bot: bot,
                revision: revision,
                userText: userText,
                memory: memory,
                skills: skills,
                conversationID: conversation.id
            )
            try botStore.insertContextReceipt(receipt)
            if selectedBotID == bot.id {
                lastContextReceipt = receipt
            }
            let result = try await router.sendAgentMessage(
                thread: thread.id,
                text: receipt.compiledPayload,
                provider: revision.provider,
                model: model,
                permissionMode: .supervised,
                reasoningEffort: revision.reasoningEffort,
                providerInstanceId: revision.providerInstanceID,
                attachments: attachments
            )
            if let runId = result.runId {
                receipt.runID = runId
                try? botStore.insertContextReceipt(receipt)
                if selectedBotID == bot.id {
                    lastContextReceipt = receipt
                }
            }
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
        clearDeskSendInFlight(for: bot.id)
        if BotsDeskFollowThrough.isTerminal(status) {
            deskSendInFlightStartedAt = nil
            if isViewing(bot.id) {
                drainQueuedFollowUp()
            }
        }
    }

    private func beginDeskSendInFlight(for botID: BotID) {
        deskSendInFlightBotID = botID
        deskSendInFlight = true
        deskSendInFlightStartedAt = Date()
    }

    private func clearDeskSendInFlight(for botID: BotID) {
        guard deskSendInFlightBotID == nil || deskSendInFlightBotID == botID else { return }
        deskSendInFlight = false
        deskSendInFlightBotID = nil
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
    /// Sidebar hosts the roster in a sibling NSHostingView from BotsRootView.
    /// Attach the delete confirm here so right-click Delete is not a silent latch.
    private let attachDeleteConfirmation: Bool

    public init(vm: BotsViewModel, attachDeleteConfirmation: Bool = false) {
        self.vm = vm
        self.attachDeleteConfirmation = attachDeleteConfirmation
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
                Toggle("Show hidden", isOn: $vm.showHidden)
                    .toggleStyle(.checkbox)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityIdentifier("bots.roster.showHidden")
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
        .modifier(BotsDeleteConfirmation(vm: vm, enabled: attachDeleteConfirmation))
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
        .contextMenu {
            botManagementButtons(bot: bot, vm: vm, fromRoster: true)
        }
    }
}

@MainActor
@ViewBuilder
private func botManagementButtons(
    bot: BotDefinition,
    vm: BotsViewModel,
    fromRoster: Bool
) -> some View {
    let locked = !vm.isControlPlaneActive
    Button(bot.pinned ? "Unpin" : "Pin") {
        vm.setPinned(id: bot.id, pinned: !bot.pinned)
    }
    .disabled(locked)
    .accessibilityIdentifier("bots.menu.pin")
    Button(bot.hidden ? "Unhide" : "Hide") {
        vm.setHidden(id: bot.id, hidden: !bot.hidden)
    }
    .disabled(locked)
    .accessibilityIdentifier("bots.menu.hide")
    Button("Duplicate") {
        if fromRoster {
            vm.duplicateFromRoster(bot)
        } else {
            _ = try? vm.duplicate(id: bot.id)
        }
    }
    .disabled(locked)
    .accessibilityIdentifier("bots.menu.duplicate")
    Button("Edit") {
        vm.beginEdit(bot)
    }
    .disabled(locked)
    .accessibilityIdentifier("bots.menu.edit")
    Divider()
    Button("Delete", role: .destructive) {
        vm.pendingDeleteID = bot.id
    }
    .disabled(locked)
    .accessibilityIdentifier("bots.menu.delete")
}

private struct BotsDeleteConfirmation: ViewModifier {
    @ObservedObject var vm: BotsViewModel
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.confirmationDialog(
                title,
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
                .accessibilityIdentifier("bots.menu.delete.confirm")
                Button("Cancel", role: .cancel) { vm.pendingDeleteID = nil }
            } message: {
                Text("This teammate is removed from the fleet. Conversations and routines are deleted.")
            }
        } else {
            content
        }
    }

    private var title: String {
        if let id = vm.pendingDeleteID, let bot = vm.bots.first(where: { $0.id == id }) {
            return "Delete \(bot.name)?"
        }
        return "Delete this Bot?"
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
                switch vm.screen.resolvedDestination {
                case .studio:
                    studioScreen
                case .desk, .fleet, .attention:
                    deskScreen
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
        .modifier(BotsDeleteConfirmation(vm: vm, enabled: embedsRosterRail))
        .onAppear { vm.reload() }
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

    // MARK: Empty desk

    private var emptyDesk: some View {
        VStack(spacing: DS.Space.xl) {
            DSEmptyState(
                icon: "bubble.left.and.bubble.right",
                title: vm.isControlPlaneActive ? "Select a teammate" : "Turn on Bot control plane in Settings",
                subtitle: vm.isControlPlaneActive
                    ? "Chat opens here. Studio is the other destination."
                    : "Bots stay off until the control plane is enabled."
            )
            if vm.isControlPlaneActive {
                Button(action: vm.beginCreate) {
                    Text(BotsChrome.Label.newBot)
                        .frame(minHeight: BotsChrome.hitTarget)
                }
                .buttonStyle(BotsPrimaryButtonStyle())
                .accessibilityIdentifier("bots.desk.empty.new")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("bots.desk.empty")
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

    private var studioScreen: some View {
        VStack(spacing: 0) {
            studioHeader
            studioTabs
            Group {
                switch vm.studioTab {
                case .profile:
                    studioProfile
                case .brain:
                    studioBrain
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
                backButton {
                    if let bot = vm.selectedBot {
                        vm.openDesk(bot)
                    }
                }
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
        HStack(spacing: DS.Space.md) {
            ForEach(BotStudioTab.allCases) { tab in
                if tab == .memory && !vm.isMemoryActive {
                    EmptyView()
                } else {
                    let selected = vm.studioTab == tab
                    Button {
                        vm.studioTab = tab
                    } label: {
                        VStack(spacing: DS.Space.xs) {
                            HStack(spacing: DS.Space.xs) {
                                Image(systemName: tab.symbol)
                                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                    .accessibilityHidden(true)
                                Text(tab.title)
                                    .font(DS.Font.body.weight(selected ? .semibold : .regular))
                            }
                            .foregroundColor(selected ? DS.Palette.text : DS.Palette.textSecondary)
                            Rectangle()
                                .fill(selected ? BotsChrome.primary : Color.clear)
                                .frame(height: 2)
                        }
                        .frame(minHeight: BotsChrome.hitTarget, alignment: .bottom)
                        .padding(.horizontal, DS.Space.sm)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
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
                        vm.refreshGeneratedStandingInstructions()
                    }
            }
            studioFormRow("Role") {
                studioField(placeholder: "What this teammate does", text: $vm.studioDraft.title)
                    .onChange(of: vm.studioDraft.title) { _ in
                        vm.refreshGeneratedStandingInstructions()
                    }
            }
            studioFormRow("Description") {
                studioMultiline(text: $vm.studioDraft.description, minHeight: 72)
                    .accessibilityIdentifier("bots.studio.description")
                    .onChange(of: vm.studioDraft.description) { _ in
                        vm.refreshGeneratedStandingInstructions()
                    }
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
            Text("Empty uses the built-in teammate default. Write your own to replace it. Published with the Bot.")
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
        status: String? = nil,
        identifier: String
    ) -> some View {
        Button {
            guard enabled else { return }
            vm.studioDraft.desktopKind = kind
        } label: {
            HStack(alignment: .top, spacing: DS.Space.md) {
                Image(systemName: vm.displayedDesktopKind == kind ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(enabled ? DS.Palette.accent : DS.Palette.textTertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.sm) {
                        Text(title)
                            .font(DS.Font.bodyStrong)
                            .foregroundColor(enabled ? DS.Palette.text : DS.Palette.textTertiary)
                        if let status, !status.isEmpty {
                            DSPill(status, tone: .neutral)
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
        .frame(minHeight: BotsChrome.hitTarget)
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(vm.displayedDesktopKind == kind ? .isSelected : [])
    }

    private var studioSecurity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                DSSectionHeaderG(BotsChrome.Label.security)
                Label("Readable only. No grants run from this tab.", systemImage: "lock.shield")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    securityRow(symbol: "hand.raised", title: "Approvals", detail: "Allow once / Deny stay off until P1b.")
                    securityRow(symbol: "pencil.and.outline", title: "Host-brokered writes", detail: "Effects stay off until that phase ships.")
                    securityRow(symbol: "desktopcomputer", title: "Desktop", detail: "Logical space is not a security boundary.")
                }
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

    private func securityRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Palette.textSecondary)
                .frame(width: 28, height: BotsChrome.hitTarget, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: BotsChrome.hitTarget, alignment: .top)
    }

    private var studioNotifications: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Notifications")
            Toggle("Notify when this Bot needs you", isOn: $vm.studioDraft.notificationsEnabled)
                .toggleStyle(.switch)
                .foregroundColor(DS.Palette.text)
                .frame(minHeight: BotsChrome.hitTarget)
                .accessibilityLabel("Notify when this Bot needs you")
            Text("Alerts stay on this Mac. They are not an isolated Desktop.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
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
        HStack(alignment: .center, spacing: DS.Space.lg) {
            Text(label)
                .font(DS.Font.caption.weight(.medium))
                .foregroundColor(DS.Palette.textSecondary)
                .frame(width: 112, alignment: .leading)
                .accessibilityHidden(true)
            content()
                .accessibilityLabel(label)
        }
        .frame(minHeight: BotsChrome.hitTarget)
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
                emptyDesk
            }
        }
    }

    private func deskHeader(_ bot: BotDefinition) -> some View {
        HStack(spacing: DS.Space.lg) {
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
        let kind = vm.displayedDesktopKind
        return VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                Label("\(bot.name) Desktop", systemImage: "desktopcomputer")
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Spacer(minLength: 0)
                DSPill(vm.desktopStatusPill, tone: .neutral)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: desktopPreviewColors(kind),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                VStack(spacing: DS.Space.sm) {
                    Image(systemName: desktopPreviewSymbol(kind))
                        .font(.system(size: 26, weight: .regular))
                        .foregroundColor(.white.opacity(0.92))
                    Text(kind.displayTitle)
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

    private func desktopPreviewColors(_ kind: BotDesktopKind) -> [Color] {
        switch kind {
        case .logicalExecutionSpace, .dedicatedLocalVM, .managedRemoteMac:
            return [Color(hex: 0x2A1848), Color(hex: 0x7B5CFF).opacity(0.55), Color(hex: 0x171D24)]
        }
    }

    private func desktopPreviewSymbol(_ kind: BotDesktopKind) -> String {
        switch kind {
        case .logicalExecutionSpace, .dedicatedLocalVM, .managedRemoteMac:
            return "desktopcomputer"
        }
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
                case .brain:
                    inspectorBrain
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
            return .brain
        }
        return vm.inspectorTab
    }

    private var studioBrain: some View {
        ScrollView {
            brainInspector(compact: false)
                .padding(DS.Space.xxl)
        }
        .accessibilityIdentifier("bots.studio.brain")
    }

    private var inspectorBrain: some View {
        ScrollView {
            brainInspector(compact: true)
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.md)
        }
        .accessibilityIdentifier("bots.desk.inspector.brain")
    }

    private func brainInspector(compact: Bool) -> some View {
        let receipt = vm.inspectedBrain
        return VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm) {
                Text("What this Bot sees")
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Spacer(minLength: 0)
                if vm.inspectedBrainIsLastCall {
                    DSPill("Last call", tone: .accent)
                } else if vm.inspectedBrainIsPreview {
                    DSPill("Preview", tone: .neutral)
                } else {
                    DSPill("Compiled", tone: .neutral)
                }
            }
            Text(vm.inspectedBrainIsLastCall ? BotsChrome.Label.brainReceiptHonesty : BotsChrome.Label.brainPreviewHonesty)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bots.brain.honesty")
            HStack(spacing: DS.Space.sm) {
                ForEach(BotBrainInspectorPane.allCases) { pane in
                    let selected = vm.brainPane == pane
                    Button {
                        vm.brainPane = pane
                    } label: {
                        Text(pane.title)
                            .font(DS.Font.caption.weight(selected ? .semibold : .regular))
                            .foregroundColor(selected ? DS.Palette.onAccent : DS.Palette.textSecondary)
                            .padding(.horizontal, DS.Space.md)
                            .padding(.vertical, DS.Space.sm)
                            .background(selected ? DS.Palette.accent : DS.Palette.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: BotsChrome.hitTarget)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier(pane.accessibilityIdentifier)
                }
                Spacer(minLength: 0)
            }
            if let receipt {
                brainReceiptMeta(receipt, compact: compact)
                if vm.brainPane == .source {
                    brainSource(receipt)
                } else {
                    brainEffective(receipt)
                }
                brainWhyMemory(receipt)
                brainCapabilities(receipt)
            } else {
                Text("Save or select a Bot to compile Source and Effective Brain.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
        }
    }

    private func brainReceiptMeta(_ receipt: ContextAssemblyReceipt, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Revision \(receipt.revisionNumber) · \(vm.providerChipTitle(receipt.provider)) · \(receipt.model.isEmpty ? "model unset" : receipt.model) · \(receipt.permissionMode.rawValue)")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
            Text("payload \(receipt.payloadDigest)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(DS.Palette.textTertiary)
                .textSelection(.enabled)
                .accessibilityIdentifier("bots.brain.digest")
            if !compact {
                Text("compiler \(receipt.compilerVersion) · no opaque RemoteCode layer")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
        }
        .accessibilityIdentifier("bots.brain.receipt")
    }

    private func brainSource(_ receipt: ContextAssemblyReceipt) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            ForEach(receipt.layers) { layer in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.sm) {
                        DSPill(layer.included ? "Included" : "Excluded", tone: layer.included ? .success : .neutral)
                        Text(layer.title)
                            .font(DS.Font.caption.weight(.semibold))
                            .foregroundColor(DS.Palette.text)
                    }
                    if !layer.text.isEmpty {
                        Text(layer.text)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(layer.reason)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        }
        .accessibilityIdentifier("bots.brain.source")
    }

    private func brainEffective(_ receipt: ContextAssemblyReceipt) -> some View {
        Text(receipt.compiledPayload.isEmpty ? "(empty payload)" : receipt.compiledPayload)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(DS.Palette.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.md)
            .background(DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .accessibilityIdentifier("bots.brain.effective")
    }

    private func brainWhyMemory(_ receipt: ContextAssemblyReceipt) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Why this memory?")
                .font(DS.Font.bodyStrong)
                .foregroundColor(DS.Palette.text)
            if receipt.memoryLayers.isEmpty {
                Text("No memory items were considered.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            } else {
                ForEach(receipt.memoryLayers) { layer in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(layer.text.isEmpty ? "(empty fact)" : layer.text)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                            .textSelection(.enabled)
                        Text(layer.reason)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                }
            }
        }
        .accessibilityIdentifier("bots.brain.whyMemory")
    }

    private func brainCapabilities(_ receipt: ContextAssemblyReceipt) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("What this Bot can do")
                .font(DS.Font.bodyStrong)
                .foregroundColor(DS.Palette.text)
            Text("Supervised route only. Host-brokered writes stay off.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
            Text(receipt.desktopKind.honestyLabel)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
            let skills = receipt.layers.filter { $0.kind == .skill && $0.included }.map(\.text)
            Text(skills.isEmpty ? "No enabled skills." : "Skills: \(skills.joined(separator: ", "))")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
        }
        .accessibilityIdentifier("bots.brain.capabilities")
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
                DSEmptyState(
                    icon: "archivebox",
                    title: "No remembered facts yet",
                    subtitle: "Add a fact this teammate should keep."
                )
                .frame(maxWidth: .infinity)
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
                DSEmptyState(
                    icon: "puzzlepiece.extension",
                    title: "No skills bound yet",
                    subtitle: "Add a catalog id. Paths are not allowed."
                )
                .frame(maxWidth: .infinity)
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
                backButton {
                    if let bot = vm.selectedBot {
                        vm.openDesk(bot)
                    }
                }
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
            .frame(minHeight: BotsChrome.hitTarget)
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
