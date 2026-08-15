import AppKit
import CoreModel
import DesignSystemKit
import Persistence
import SwiftUI

// MARK: - Drafts & rows

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

public enum BotsScreen: String, Equatable {
    case fleet
    case studio
    case desk
    case attention
}

public enum BotDetailTab: String, CaseIterable, Identifiable {
    case desk
    case memory
    case routines

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .desk: return "Desk"
        case .memory: return "Memory"
        case .routines: return "Routines"
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
    @Published public var screen: BotsScreen = .fleet
    @Published public var detailTab: BotDetailTab = .desk
    @Published public var studioDraft = BotStudioDraft()
    @Published public var composerText: String = ""
    @Published public private(set) var deskMessages: [BotDeskMessage] = []
    @Published public private(set) var conversations: [BotConversation] = []
    @Published public private(set) var selectedConversation: BotConversation?
    @Published public private(set) var attentionItems: [BotAttentionItem] = []
    @Published public private(set) var memoryItems: [BotMemoryItem] = []
    @Published public private(set) var routines: [BotRoutine] = []
    @Published public var memoryDraft: String = ""
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

    public let desktopHonestyLabel = BotDesktopKind.logicalExecutionSpaceHonestyLabel

    private let context: AppContext
    private let router: AppCommandRouter?
    private let botStore: BotStore
    private let settingsStore: SettingsStore
    private var messagesByBot: [BotID: [BotDeskMessage]] = [:]
    private var attentionStateByBot: [BotID: BotAttentionState] = [:]

    public init(context: AppContext, router: AppCommandRouter? = nil) {
        self.context = context
        self.router = router
        self.botStore = context.botStore
        self.settingsStore = SettingsStore(db: context.db)
        reload()
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
        attentionStateByBot[bot.id] ?? .none
    }

    public func reload() {
        refreshFlags()
        reloadFleet()
        reloadAttention()
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
        screen = .studio
    }

    public func openFleet() {
        screen = .fleet
        reloadFleet()
        reloadAttention()
    }

    public func openDesk(_ bot: BotDefinition) {
        selectedBotID = bot.id
        detailTab = .desk
        screen = .desk
        markOpenedConversationRead(botID: bot.id)
        reloadSelectedBot(id: bot.id)
    }

    private func markOpenedConversationRead(botID: BotID) {
        do {
            let items = try botStore.listConversations(botID: botID)
            for var conversation in items where conversation.unread || conversation.attentionState == .unreadActivity {
                conversation.unread = false
                if conversation.attentionState == .unreadActivity {
                    conversation.attentionState = .none
                }
                conversation.updatedAt = Date()
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
            _ = try botStore.publish(
                botID: botID,
                expectedCurrentRevisionID: studioDraft.expectedRevisionID ?? bot.currentRevisionID,
                draft: draft
            )
            let updated = try botStore.updateProfile(
                id: botID,
                name: name,
                title: studioDraft.title,
                description: studioDraft.description,
                avatarSymbol: studioDraft.avatarSymbol,
                notificationsEnabled: studioDraft.notificationsEnabled
            )
            selectedBotID = updated.id
            reloadFleet()
            reloadSelectedBot(id: updated.id)
            screen = .desk
            detailTab = .desk
            return updated
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
        screen = .desk
        detailTab = .desk
        reloadSelectedBot(id: created.id)
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
            }
            reloadFleet()
            reloadAttention()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func send(_ text: String? = nil) {
        let message = (text ?? composerText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        guard let bot = selectedBot else { return }
        composerText = ""
        lastSendStartedProviderRun = false
        do {
            let conversation = try persistUserMessage(bot: bot, text: message)
            appendDeskMessage(BotDeskMessage(role: .user, text: message), botID: bot.id)
            if let router = resolvedRouter(),
               let revision = try currentRevision(for: bot) {
                Task { [weak self] in
                    guard let self else { return }
                    let started = await self.startSupervisedRun(
                        bot: bot,
                        revision: revision,
                        conversation: conversation,
                        userText: message,
                        router: router
                    )
                    if let runId = started {
                        self.lastSendStartedProviderRun = true
                        self.appendDeskMessage(
                            BotDeskMessage(role: .assistant, text: "Working…"),
                            botID: bot.id
                        )
                        await self.followLinkedRun(
                            bot: bot,
                            conversation: conversation,
                            runId: runId
                        )
                    } else {
                        self.recordNeedsAttention(bot: bot, conversation: conversation, userText: message)
                    }
                }
            } else {
                recordNeedsAttention(bot: bot, conversation: conversation, userText: message)
            }
        } catch {
            errorMessage = String(describing: error)
        }
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
        do {
            try botStore.requestRoutineTestRun(id: id)
            if let botID = selectedBotID { reloadRoutines(botID: botID) }
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
        case .grok: return "grok-4.5"
        }
    }

    // MARK: - Internals

    private func resolvedRouter() -> AppCommandRouter? {
        if let router { return router }
        let existing: AppCommandRouter? = context.router
        return existing
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
            rebuildAttentionStates()
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
        do {
            conversations = try botStore.listConversations(botID: id)
            selectedConversation = conversations.first
            reloadMemory(botID: id)
            reloadRoutines(botID: id)
            restoreDeskMessages(botID: id)
        } catch {
            errorMessage = String(describing: error)
        }
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

    private func restoreDeskMessages(botID: BotID) {
        let cached = messagesByBot[botID] ?? []
        var persisted: [BotDeskMessage] = []
        if let conversation = selectedConversation,
           let threadID = conversation.linkedAgentThreadID,
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
        let visible = BotsDeskFollowThrough.visibleDeskMessages(cached: cached, persisted: persisted)
        if visible.isEmpty, let conversation = selectedConversation, !conversation.title.isEmpty {
            deskMessages = [BotDeskMessage(role: .user, text: conversation.title, createdAt: conversation.createdAt)]
        } else {
            deskMessages = visible
        }
        messagesByBot[botID] = deskMessages
    }

    private func appendDeskMessage(_ message: BotDeskMessage, botID: BotID) {
        deskMessages.append(message)
        messagesByBot[botID, default: []].append(message)
    }

    @discardableResult
    private func persistUserMessage(bot: BotDefinition, text: String) throws -> BotConversation {
        var conversation = selectedConversation ?? conversations.first ?? BotConversation(
            botID: bot.id,
            title: Self.titleFromFirstMessage(text)
        )
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
            selectedConversation = next
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
        router: AppCommandRouter
    ) async -> AgentRunID? {
        let workspaceID = bot.workspaceID
            ?? context.state.window.selectedWorkspaceID
            ?? context.state.window.workspaces.first
        let model = revision.model.isEmpty ? Self.defaultModel(for: revision.provider) : revision.model
        do {
            let thread: AgentThread
            if let linked = conversation.linkedAgentThreadID,
               let existing = try context.threadRepo.get(id: linked) {
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
                providerInstanceId: revision.providerInstanceID
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
        for _ in 0..<120 {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
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

    private func applyFollowThrough(
        bot: BotDefinition,
        conversation: BotConversation,
        run: AgentRun?
    ) {
        restoreDeskMessages(botID: bot.id)
        let status = run?.status ?? .interrupted
        var next = selectedConversation ?? conversation
        next.attentionState = BotsDeskFollowThrough.conversationState(for: status)
        next.updatedAt = Date()
        do {
            try botStore.upsertConversation(next)
            selectedConversation = next
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
}

// MARK: - Root view

public struct BotsRootView: View {
    @ObservedObject private var vm: BotsViewModel

    public init(vm: BotsViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
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
        .frame(minWidth: 980, minHeight: 680)
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

    // MARK: Fleet

    private var fleetScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            fleetHeader
            if !vm.isControlPlaneActive {
                DSEmptyState(
                    icon: "person.2",
                    title: "Turn on Bot control plane in Settings",
                    subtitle: "Bots stay off until the control plane is enabled."
                )
            } else if vm.fleet.isEmpty {
                DSEmptyState(
                    icon: "person.2",
                    title: vm.searchText.isEmpty ? "No bots yet" : "No matching bots",
                    subtitle: vm.searchText.isEmpty
                        ? "Create a Bot, give it a job, send a first task."
                        : "Try another search or show hidden teammates."
                )
            } else {
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
                    Text(bot.title.isEmpty ? "No job yet" : bot.title)
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
            HStack(spacing: DS.Space.lg) {
                backButton { vm.openFleet() }
                Text(vm.studioDraft.isNew ? "New Bot" : "Bot Studio")
                    .font(DS.Font.title2.weight(.semibold))
                    .foregroundColor(DS.Palette.text)
                Spacer()
                Button("Cancel") { vm.openFleet() }
                    .buttonStyle(DSSecondaryButtonStyle())
                Button(vm.studioDraft.isNew ? "Create Bot" : "Save Bot") {
                    do { _ = try vm.saveStudio() } catch { vm.errorMessage = String(describing: error) }
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(!vm.isControlPlaneActive)
                .accessibilityIdentifier("bots.studio.save")
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.vertical, DS.Space.xl)
            .dsBar(edge: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    studioIdentity
                    studioProvider
                    studioSoul
                    studioDesktop
                    studioNotifications
                }
                .padding(DS.Space.xxl)
                .frame(maxWidth: 860, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var studioIdentity: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSectionHeaderG("Identity")
            labeledField("Name") {
                studioField(placeholder: "e.g. Piper", text: $vm.studioDraft.name)
                    .onChange(of: vm.studioDraft.name) { name in
                        if vm.studioDraft.isNew, vm.studioDraft.handle.isEmpty || handleMatchesDerivedName {
                            vm.studioDraft.handle = BotHandle.derive(from: name) ?? vm.studioDraft.handle
                        }
                    }
            }
            labeledField("Job / title") {
                studioField(placeholder: "What this teammate does", text: $vm.studioDraft.title)
            }
            labeledField("Description") {
                studioMultiline(text: $vm.studioDraft.description, minHeight: 72)
            }
            labeledField("Handle") {
                studioField(placeholder: "piper", text: $vm.studioDraft.handle)
                    .disabled(!vm.studioDraft.isNew)
            }
            labeledField("Avatar") {
                studioField(placeholder: "person.crop.circle", text: $vm.studioDraft.avatarSymbol)
            }
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var handleMatchesDerivedName: Bool {
        vm.studioDraft.handle == (BotHandle.derive(from: vm.studioDraft.name) ?? "")
    }

    private var studioProvider: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSectionHeaderG("Provider")
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
            labeledField("Model") {
                studioField(placeholder: "Model id", text: $vm.studioDraft.model)
            }
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var studioSoul: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSectionHeaderG("Soul / instructions")
            studioMultiline(text: $vm.studioDraft.soul, minHeight: 140)
            Text("Published with the Bot. This is not an Agent thread.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var studioDesktop: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSectionHeaderG("Desktop")
            desktopOption(
                kind: .logicalExecutionSpace,
                title: "Logical execution space",
                enabled: true
            )
            desktopOption(
                kind: .dedicatedLocalVM,
                title: "Dedicated local VM Desktop",
                enabled: vm.isDesktopVMActive,
                notShipped: !vm.isDesktopVMActive
            )
            desktopOption(
                kind: .managedRemoteMac,
                title: "Managed remote Mac Desktop",
                enabled: vm.isDesktopRemoteActive,
                notShipped: !vm.isDesktopRemoteActive
            )
            Text(vm.desktopHonestyLabel)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private func desktopOption(
        kind: BotDesktopKind,
        title: String,
        enabled: Bool,
        notShipped: Bool = false
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

    // MARK: Desk

    private var deskScreen: some View {
        Group {
            if let bot = vm.selectedBot {
                VStack(spacing: 0) {
                    deskHeader(bot)
                    deskTabs
                    Group {
                        switch vm.detailTab {
                        case .desk:
                            deskChat(bot)
                        case .memory:
                            memoryTab
                        case .routines:
                            routinesTab
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                fleetScreen.onAppear { vm.openFleet() }
            }
        }
    }

    private func deskHeader(_ bot: BotDefinition) -> some View {
        HStack(spacing: DS.Space.lg) {
            backButton { vm.openFleet() }
            Image(systemName: bot.avatarSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DS.Palette.accent)
                .frame(width: 32, height: 32)
                .background(DS.Palette.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.Space.sm) {
                    Text(bot.name)
                        .font(DS.Font.title2.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                    Text("@\(bot.handle)")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                    attentionBadge(vm.attentionState(for: bot))
                }
                Text(bot.title.isEmpty ? "Desk" : bot.title)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
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

    private var deskTabs: some View {
        HStack(spacing: DS.Space.md) {
            ForEach(BotDetailTab.allCases) { tab in
                if tab == .memory && !vm.isMemoryActive {
                    EmptyView()
                } else {
                    let selected = vm.detailTab == tab
                    Button {
                        vm.detailTab = tab
                    } label: {
                        Text(tab.title)
                            .font(DS.Font.body.weight(selected ? .semibold : .regular))
                            .foregroundColor(selected ? DS.Palette.onAccent : DS.Palette.textSecondary)
                            .padding(.horizontal, DS.Space.lg)
                            .padding(.vertical, DS.Space.sm)
                            .background(selected ? DS.Palette.accent : DS.Palette.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.vertical, DS.Space.lg)
    }

    private func deskChat(_ bot: BotDefinition) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.lg) {
                    if vm.deskMessages.isEmpty {
                        Text("Message \(bot.name) to give it a first task.")
                            .font(DS.Font.body)
                            .foregroundColor(DS.Palette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, DS.Space.xl)
                    }
                    ForEach(vm.deskMessages) { message in
                        deskBubble(message, bot: bot)
                    }
                }
                .padding(.horizontal, DS.Space.xxl)
                .padding(.vertical, DS.Space.xl)
            }
            composerBar(bot)
        }
    }

    private func deskBubble(_ message: BotDeskMessage, bot: BotDefinition) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(message.role == .user ? "You" : bot.name)
                .font(DS.Font.caption.weight(.semibold))
                .foregroundColor(DS.Palette.textTertiary)
            Text(message.text)
                .font(DS.Font.body)
                .foregroundColor(DS.Palette.text)
                .textSelection(.enabled)
                .padding(DS.Space.lg)
                .frame(maxWidth: 720, alignment: .leading)
                .background(message.role == .user ? DS.Palette.surfaceRaised : DS.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                )
        }
    }

    private func composerBar(_ bot: BotDefinition) -> some View {
        HStack(alignment: .bottom, spacing: DS.Space.md) {
            TextField("Message \(bot.name)…", text: $vm.composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .font(DS.Font.body)
                .foregroundColor(DS.Palette.text)
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.md)
                .background(DS.Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                )
                .accessibilityIdentifier("bots.desk.composer")
                .onSubmit { vm.send() }
            Button("Send") { vm.send() }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(vm.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("bots.desk.send")
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.vertical, DS.Space.lg)
        .dsBar(edge: .top)
    }

    // MARK: Memory

    private var memoryTab: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSectionHeaderG("Brain / Memory")
            if vm.isMemoryActive {
                HStack(alignment: .top, spacing: DS.Space.md) {
                    studioMultiline(text: $vm.memoryDraft, minHeight: 56)
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
    }

    private func memoryRow(_ item: BotMemoryItem) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(item.content)
                .font(DS.Font.body)
                .foregroundColor(DS.Palette.text)
                .textSelection(.enabled)
            HStack(spacing: DS.Space.md) {
                Text(item.provenance)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                if vm.isMemoryActive {
                    Button("Correct") {
                        let next = promptCorrection(current: item.content)
                        if let next { vm.correctMemory(id: item.id, content: next) }
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                    Button("Forget", role: .destructive) {
                        vm.forgetMemory(id: item.id)
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                }
            }
        }
        .dsPanel(padding: DS.Space.lg)
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
            if !vm.isAutonomyActive {
                Text("Enabling a schedule does not run while RemoteCode is closed.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
            labeledField("Name") { studioField(placeholder: "Morning scan", text: $vm.routineName) }
            labeledField("Prompt") { studioMultiline(text: $vm.routinePrompt, minHeight: 72) }
            labeledField("When") { studioField(placeholder: "Weekdays 9:00", text: $vm.routineScheduleNote) }
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
                Toggle(routine.activation.isEnabled ? "On" : "Paused", isOn: Binding(
                    get: { routine.activation.isEnabled },
                    set: { vm.setRoutineEnabled(id: routine.definition.id, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
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

    private func studioMultiline(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(DS.Font.body)
            .foregroundColor(DS.Palette.text)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
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
