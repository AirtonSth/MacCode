import AppKit
import CoreModel
import Foundation
import Persistence
import SocketServer
import Surfaces
import SwiftUI

/// Titio: the pet as a chat Bot. It is an ordinary host Bot (handle `titio`)
/// so its desk, persistence, provider tools and iOS mirroring are the Bot
/// desk's; the host catalog adds the read-state and action tools it needs.
public enum TitioBot {
    public static let handle = TitioIdentity.handle
    public static let name = TitioIdentity.name
    public static let title = TitioIdentity.title
    public static let description = TitioIdentity.description
    public static let soul = TitioIdentity.soul

    /// Finds or creates the single Titio Bot.
    @discardableResult
    public static func ensure(store: BotStore, appSupportDirectory: URL) throws -> BotDefinition {
        if let existing = try store.list(includeHidden: true).first(where: { $0.handle == handle && $0.deletedAt == nil }) {
            // Titio stays pinned and visible, like the CEO slot.
            if !existing.pinned { try store.setPinned(id: existing.id, pinned: true) }
            if existing.hidden { try store.setHidden(id: existing.id, hidden: false) }
            return try store.get(id: existing.id) ?? existing
        }
        let bot = try store.create(
            name: name,
            title: title,
            description: description,
            handle: handle,
            soul: soul
        )
        try store.setPinned(id: bot.id, pinned: true)
        try? BotHome(appSupportDirectory: appSupportDirectory, bot: bot).ensure(
            name: bot.name, handle: bot.handle, title: bot.title, description: bot.description, soul: soul
        )
        return try store.get(id: bot.id) ?? bot
    }

    /// Finds or creates Titio's Notifications conversation (hub spec §8). Its
    /// id lives in `titio_inbox_state`; a deleted (or foreign) row is
    /// recreated with the title for `language` and the inbox counters reset.
    /// Store-only, so it runs off the MainActor. `created` is true when a new
    /// row was written (the caller publishes `bot.conversation.updated`).
    public static func ensureInboxConversation(
        store: BotStore,
        notices: TitioNoticeRepository,
        bot: BotDefinition,
        language: TitioNoticeLanguage,
        now: Date = Date()
    ) throws -> (conversation: BotConversation, created: Bool) {
        let state = try notices.inboxState()
        if let raw = state.conversationID,
           let uuid = UUID(uuidString: raw),
           let existing = try store.conversation(id: BotConversationID(uuid)),
           existing.botID == bot.id, existing.groupID == nil {
            guard existing.hidden else { return (existing, false) }
            var visible = existing
            visible.hidden = false
            try store.upsertConversation(visible)
            return (visible, false)
        }
        let conversation = BotConversation(
            botID: bot.id,
            title: TitioNoticeCopy.inboxTitle(language: language),
            createdAt: now,
            updatedAt: now
        )
        try store.upsertConversation(conversation)
        try notices.updateInboxState {
            $0.conversationID = conversation.id.value.uuidString.lowercased()
            $0.unreadCount = 0
            $0.armedReplyKey = nil
            $0.armedAt = nil
        }
        return (conversation, true)
    }

    /// The pet's idle frame: the still fallback for Titio's animated avatar.
    @MainActor public static let avatarImage: NSImage? = {
        guard let bundle = try? AppShellResourceBundle.bundle(),
              let url = bundle.url(forResource: "titio-avatar", withExtension: "png", subdirectory: "Pet")
                ?? bundle.url(forResource: "titio-avatar", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// Every Bot avatar for Titio is the animated pet, with no plate behind it.
    @MainActor public static func installAvatar() {
        BotsAvatarView.viewOverride = { avatarHandle, size in
            avatarHandle == handle ? AnyView(TitioAvatarView(size: size)) : nil
        }
    }

    /// The draft "Restore Factory Settings" publishes: Titio's built-in
    /// identity, instructions, avatar, notifications and reply style, like
    /// `BotStore.restoreTitioFactorySettings` (the paired-device path). Its
    /// desktop, conversations, files and schedules are not part of it.
    public static func factoryDraft(for bot: BotDefinition, current: BotStudioDraft) -> BotStudioDraft {
        var draft = current
        draft.botID = bot.id
        draft.name = name
        draft.title = title
        draft.description = description
        draft.handle = handle
        draft.avatarSymbol = BotBlobatarSpec.default.token
        draft.soul = soul
        draft.notificationsEnabled = true
        draft.slugFollowsName = false
        draft.verbosity = TitioIdentity.verbosity
        draft.cavemanEnabled = TitioIdentity.cavemanEnabled
        return draft
    }
}

extension AppCommandRouter {
    /// Opens Titio's desk, creating the Bot on first use.
    @discardableResult
    public func openTitio() throws -> BotID {
        guard let ctx = context else { throw JSONRPCError.internalError }
        let bot = try TitioBot.ensure(store: ctx.botStore, appSupportDirectory: ctx.appSupportDirectory)
        botsViewModel?.reload()
        _ = try openBotsDesk(botID: bot.id)
        return bot.id
    }

    /// Option+Space quick chat: starts a new Titio conversation with `text`
    /// and opens it, like starting a chat from the pet.
    @discardableResult
    public func sendTitioQuickMessage(_ text: String) -> BotConversationID? {
        guard let ctx = context, let botsViewModel else { return nil }
        do {
            let bot = try TitioBot.ensure(store: ctx.botStore, appSupportDirectory: ctx.appSupportDirectory)
            let sent = try botsViewModel.enqueueHostMessage(botID: bot.id, text: text, conversationID: nil)
            let conversation = sent.objectValue?["conversation_id"]?.stringValue
                .flatMap(UUID.init).map(BotConversationID.init)
            _ = try? openBotsDesk(botID: bot.id, conversationID: conversation)
            return conversation
        } catch {
            NSSound.beep()
            return nil
        }
    }

    public func listHostActivity() async throws -> JSONValue {
        guard let ctx = context else { throw JSONRPCError.internalError }
        let workspaces = try await listWorkspacesAuthoritative()
        let names = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.name) })
        let iso = ISO8601DateFormatter()
        let threads: [JSONValue] = try ctx.threadRepo.list(workspaceId: nil).map { thread in
            let running = (try? activeAgentRun(thread: thread.id)) ?? nil
            return .object([
                "id": .string(thread.id.value.uuidString.lowercased()),
                "title": .string(thread.title),
                "workspace": thread.workspaceId.flatMap { names[$0] }.map(JSONValue.string) ?? .null,
                "provider": .string(thread.provider.rawValue),
                "status": .string(running != nil ? "running" : thread.status.rawValue),
                "updated_at": .string(iso.string(from: thread.updatedAt)),
            ])
        }
        let bots: [JSONValue] = try ctx.botStore.list().map { bot in
            let conversations = (try? ctx.botStore.listConversations(botID: bot.id)) ?? []
            return .object([
                "id": .string(bot.id.value.uuidString.lowercased()),
                "name": .string(bot.name),
                "handle": .string(bot.handle),
                "conversations": .array(conversations.prefix(20).map { c in
                    .object([
                        "id": .string(c.id.value.uuidString.lowercased()),
                        "title": .string(c.title),
                        "state": .string(c.attentionState.rawValue),
                    ])
                }),
            ])
        }
        let store = ScheduledTaskStore(db: ctx.db)
        let active = Set(try store.listActiveRuns().map(\.taskID))
        let tasks: [JSONValue] = try store.list().map { task in
            .object([
                "id": .string(task.id.uuidString.lowercased()),
                "title": .string(task.title),
                "workspace": .string(names[task.workspaceID] ?? task.workspacePathSnapshot),
                "enabled": .bool(task.isEnabled),
                "next_run_at": task.nextRunAt.map { .string(iso.string(from: $0)) } ?? .null,
                "running": .bool(active.contains(task.id)),
            ])
        }
        let attention: [JSONValue] = try ctx.botStore.listAttention().map {
            .object(["title": .string($0.title), "detail": .string($0.detail)])
        }
        return .object([
            "workspaces": .array(workspaces.map { .object(["id": .string($0.id.value.uuidString.lowercased()), "name": .string($0.name)]) }),
            "threads": .array(threads),
            "bots": .array(bots),
            "scheduled_tasks": .array(tasks),
            "needs_you": .array(attention),
        ])
    }

    public func delegateHostBot(
        bot query: String,
        text: String,
        conversationID: BotConversationID?,
        callerThread: AgentThreadID,
        callerRun: AgentRunID
    ) async throws -> JSONValue {
        guard let ctx = context else { throw JSONRPCError.internalError }
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@")).lowercased()
        let bots = try ctx.botStore.list()
        guard let bot = bots.first(where: { $0.handle.lowercased() == key })
                ?? bots.first(where: { $0.name.lowercased() == key }) else {
            throw JSONRPCError(code: -32044, message: "No RemoteCode Bot named \(query).")
        }
        return try await sendHostBot(
            botID: bot.id, text: text, conversationID: conversationID,
            callerThread: callerThread, callerRun: callerRun
        )
    }

    public func runNextHostScheduledTask(workspace query: String, taskID: UUID?) throws -> JSONValue {
        guard let ctx = context else { throw JSONRPCError.internalError }
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let workspace = ctx.state.workspaces.values.first(where: {
            $0.id.value.uuidString.lowercased() == key || $0.name.lowercased() == key
        }) else {
            throw JSONRPCError(code: -32044, message: "No RemoteCode workspace named \(query).")
        }
        let tasks = try ScheduledTaskStore(db: ctx.db).list().filter { $0.workspaceID == workspace.id }
        let task: ScheduledTask?
        if let taskID {
            task = tasks.first { $0.id == taskID }
        } else {
            task = tasks.filter(\.isEnabled).min { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
        }
        guard let task else {
            throw JSONRPCError(code: -32044, message: "Workspace \(workspace.name) has no scheduled task to run.")
        }
        guard let scheduler = scheduledTaskScheduler else {
            throw JSONRPCError(code: -32045, message: "The in-app scheduler is not ready.")
        }
        let claim = try scheduler.claimAndRunNow(taskID: task.id)
        return .object([
            "run_id": .string(claim.run.id.uuidString.lowercased()),
            "task_id": .string(task.id.uuidString.lowercased()),
            "title": .string(task.title),
            "workspace": .string(workspace.name),
            "queued": .bool(true),
        ])
    }
}
