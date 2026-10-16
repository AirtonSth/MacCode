import Foundation
import CoreModel

public extension BotStore {
    func createContextualConversation(_ conversation: BotConversation, hostID: String, context: BotContext, policyRevision: Int64) throws -> BotConversationContextPin {
        try createContextualConversationBody(conversation, newThread: nil, hostID: hostID, context: context, policyRevision: policyRevision)
    }

    func createContextualConversation(
        _ conversation: BotConversation,
        newThread: AgentThread,
        hostID: String,
        context: BotContext,
        policyRevision: Int64
    ) throws -> BotConversationContextPin {
        try createContextualConversationBody(conversation, newThread: newThread, hostID: hostID, context: context, policyRevision: policyRevision)
    }

    private func createContextualConversationBody(
        _ conversation: BotConversation,
        newThread: AgentThread?,
        hostID: String,
        context: BotContext,
        policyRevision: Int64
    ) throws -> BotConversationContextPin {
        guard conversation.groupID == nil,
              let threadID = conversation.linkedAgentThreadID,
              !hostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              policyRevision > 0 else {
            throw BotStoreError.notFound
        }
        if let newThread {
            guard threadID == newThread.id,
                  Self.threadMatchesContext(newThread.workspaceId, context: context),
                  newThread.actor == .none,
                  newThread.actorLockedAt == nil,
                  newThread.providerThreadId == nil,
                  newThread.parentThreadId == nil,
                  !newThread.isEphemeral,
                  newThread.provider == .distill,
                  newThread.runAsUser == nil || newThread.runAsUser?.isCurrentAccount == true else {
                throw BotStoreError.invalidInput("contextual conversation requires a fresh Distill thread")
            }
        }
        let pin = BotConversationContextPin(conversationID: conversation.id, hostID: hostID, botID: conversation.botID, context: context, policyRevision: policyRevision)
        var insertedConversation = false
        var insertedThread = false
        do {
            try db.transaction {
                guard try authorizes(hostID: hostID, botID: conversation.botID, context: context, action: .read, policyRevision: policyRevision) else {
                    throw BotStoreError.notFound
                }
                let existing = try db.prepare("SELECT 1 FROM bot_conversations WHERE id=? OR linked_agent_thread_id = ? COLLATE NOCASE LIMIT 1;")
                try existing.bind(1, conversation.id.value.uuidString.lowercased())
                try existing.bind(2, threadID.value.uuidString.lowercased())
                defer { existing.reset() }
                guard try !existing.step() else { throw BotStoreError.invalidInput("context pin requires a new conversation and thread") }
                if let newThread {
                    let existingThread = try db.prepare("SELECT 1 FROM agent_threads WHERE id=? COLLATE NOCASE LIMIT 1;")
                    try existingThread.bind(1, threadID.value.uuidString)
                    defer { existingThread.reset() }
                    guard try !existingThread.step() else { throw BotStoreError.invalidInput("contextual conversation requires a new thread") }
                    let repository = AgentThreadRepository(db: db)
                    try repository.upsert(newThread)
                    insertedThread = true
                    guard try repository.lockActorIfUnlocked(
                        id: threadID,
                        actor: .bot(conversation.botID),
                        lockedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                        executionTarget: .vm
                    ), try repository.setGuestRuntime(id: threadID, BotGuestRuntime.distillV1) else {
                        throw BotStoreError.invalidInput("could not lock contextual thread")
                    }
                }
                try upsertConversation(conversation)
                insertedConversation = true
                let insert = try db.prepare("INSERT INTO bot_conversation_contexts(conversation_id, host_id, bot_id, context_key, policy_revision, context_version, thread_id) VALUES(?, ?, ?, ?, ?, ?, ?);")
                defer { insert.reset() }
                try insert.bind(1, conversation.id.value.uuidString.lowercased())
                try insert.bind(2, hostID)
                try insert.bind(3, conversation.botID.value.uuidString.lowercased())
                try insert.bind(4, context.storageKey)
                try insert.bind(5, policyRevision)
                try insert.bind(6, Int64(BotContext.contractVersion))
                try insert.bind(7, threadID.value.uuidString.lowercased())
                _ = try insert.step()
            }
        } catch {
            if insertedConversation || insertedThread { forgetLinkedThreads([threadID]) }
            throw error
        }
        return pin
    }

    func conversationContextPin(conversationID: BotConversationID) throws -> BotConversationContextPin? {
        let query = try db.prepare("SELECT host_id, bot_id, context_key, policy_revision, context_version, thread_id, typeof(policy_revision), typeof(context_version) FROM bot_conversation_contexts WHERE conversation_id=?;")
        defer { query.reset() }
        try query.bind(1, conversationID.value.uuidString.lowercased())
        guard try query.step() else { return nil }
        guard query.columnText(6) == "integer",
              query.columnText(7) == "integer",
              query.columnInt64(4) == Int64(BotContext.contractVersion),
              let host = query.columnText(0), let botRaw = query.columnText(1), let botUUID = UUID(uuidString: botRaw),
              let key = query.columnText(2), let context = Self.decodeContext(key),
              query.columnInt64(3) > 0, query.columnText(5) != nil else {
            throw BotStoreError.invalidInput("unsupported conversation context pin")
        }
        return BotConversationContextPin(conversationID: conversationID, hostID: host, botID: BotID(botUUID), context: context, policyRevision: query.columnInt64(3))
    }

    func conversationContextPin(linkedTo threadID: AgentThreadID) throws -> BotConversationContextPin? {
        let query = try db.prepare("SELECT conversation_id FROM bot_conversation_contexts WHERE thread_id = ? COLLATE NOCASE LIMIT 1;")
        defer { query.reset() }
        try query.bind(1, threadID.value.uuidString.lowercased())
        guard try query.step() else { return nil }
        guard let raw = query.columnText(0), let uuid = UUID(uuidString: raw) else {
            throw BotStoreError.invalidInput("unsupported conversation context identity")
        }
        return try conversationContextPin(conversationID: BotConversationID(uuid))
    }

    func authorizesConversation(_ conversation: BotConversation, hostID: String, action: BotContextAction) throws -> Bool {
        guard let pin = try conversationContextPin(conversationID: conversation.id) else { return false }
        guard pin.hostID == hostID, pin.botID == conversation.botID else { return false }
        return try authorizes(hostID: pin.hostID, botID: pin.botID, context: pin.context, action: action, policyRevision: pin.policyRevision)
    }

    private static func threadMatchesContext(_ workspaceID: WorkspaceID?, context: BotContext) -> Bool {
        switch context {
        case .general: return workspaceID == nil
        case .workspace(let expected): return workspaceID == expected
        }
    }

    private static func decodeContext(_ key: String) -> BotContext? {
        if key == "general:v1" { return .general }
        let prefix = "workspace:v1:"
        guard key.hasPrefix(prefix), let id = UUID(uuidString: String(key.dropFirst(prefix.count))) else { return nil }
        return .workspace(WorkspaceID(id))
    }
}
