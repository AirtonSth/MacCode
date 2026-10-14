import CoreModel
import Foundation
import Persistence
import SocketServer

/// Titio: the pet as a chat Bot. It is an ordinary host Bot (handle `titio`)
/// so its desk, persistence, provider tools and iOS mirroring are the Bot
/// desk's; the host catalog adds the read-state and action tools it needs.
public enum TitioBot {
    public static let handle = "titio"
    public static let name = "Titio"
    public static let soul = """
    You are Titio, the RemoteCode assistant that lives in the pet. Answer anything about what is happening in RemoteCode: call rc_activity_list first for workspaces, threads, Bots, scheduled tasks and what needs the user, and name the real items you find. Act through the named rc_* tools: rc_bot_delegate to ask another Bot by name, rc_scheduled_task_run_next to fire a workspace's next scheduled task, and the other rc_* tools for workspaces, threads and Bots. For anything outside RemoteCode use your normal tools. Reply in the user's language.
    """

    /// Finds or creates the single Titio Bot.
    @discardableResult
    public static func ensure(store: BotStore, appSupportDirectory: URL) throws -> BotDefinition {
        if let existing = try store.list(includeHidden: true).first(where: { $0.handle == handle && $0.deletedAt == nil }) {
            return existing
        }
        let bot = try store.create(
            name: name,
            title: "RemoteCode assistant",
            description: "Ask about anything in RemoteCode or ask it to act.",
            handle: handle,
            soul: soul
        )
        try? BotHome(appSupportDirectory: appSupportDirectory, bot: bot).ensure(
            name: bot.name, handle: bot.handle, title: bot.title, description: bot.description, soul: soul
        )
        return bot
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
