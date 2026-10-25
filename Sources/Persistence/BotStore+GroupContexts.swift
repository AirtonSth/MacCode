import Foundation
import CoreModel

public extension BotStore {
    /// A room's existing thread is the durable group scope. General legacy
    /// groups retain nil; a workspace room never silently changes its context.
    func groupWorkspaceID(groupID: BotGroupID) throws -> WorkspaceID? {
        guard let group = try group(id: groupID),
              let room = try AgentThreadRepository(db: db).get(id: group.roomThreadID) else { throw BotStoreError.notFound }
        return room.workspaceId
    }

    /// Infer only an unambiguous common ownership scope. A general participant
    /// may join that scope only through its explicit existing access grant.
    func proposedGroupWorkspace(botIDs: [BotID]) throws -> WorkspaceID? {
        var owners: Set<WorkspaceID> = []
        for id in botIDs {
            guard let bot = try get(id: id), bot.deletedAt == nil else { throw BotStoreError.notFound }
            if let workspace = bot.workspaceID { owners.insert(workspace) }
        }
        guard owners.count <= 1 else {
            throw BotStoreError.invalidInput("These bots belong to different workspaces. Choose bots owned by one workspace; General bots need explicit access to that workspace.")
        }
        return owners.first
    }

    /// Validate member edits and sends without granting or reviving access.
    func validateGroupWorkspaceAccess(groupID: BotGroupID, botIDs: [BotID], hostID: String) throws {
        if let workspace = try groupWorkspaceID(groupID: groupID) {
            try validateGroupWorkspaceBindings(botIDs: botIDs, hostID: hostID, workspaceID: workspace, grantMissingOwned: false)
        } else {
            guard try proposedGroupWorkspace(botIDs: botIDs) == nil else {
                throw BotStoreError.invalidInput("A General group cannot run workspace-exclusive bots. Assign an empty group to that workspace or create a new workspace group.")
            }
        }
    }

    /// Adopt only a provably empty, unstarted room. Even one historical message,
    /// turn, linked member thread or pin makes changing its context unsafe.
    /// IDs, participant rows and the existing room are preserved.
    @discardableResult
    func adoptEmptyGroupWorkspace(groupID: BotGroupID, expectedRevision: Int, workspaceID: WorkspaceID,
        hostID: String, now: Date = Date()) throws -> BotGroupConversation {
        let adopted = try db.transaction {
            guard let group = try group(id: groupID) else { throw BotStoreError.notFound }
            guard group.revision == expectedRevision, group.revision < Int.max else { throw BotStoreError.revisionConflict }
            let repository = AgentThreadRepository(db: db)
            guard let room = try repository.get(id: group.roomThreadID), room.workspaceId == nil,
                  room.providerThreadId == nil, room.actor == .none, room.actorLockedAt == nil,
                  room.status != .running else {
                throw BotStoreError.invalidInput("Only an empty, unstarted General group can move to a workspace.")
            }
            let empty = try db.prepare("""
                SELECT 1 FROM agent_messages WHERE thread_id=? COLLATE NOCASE
                UNION ALL SELECT 1 FROM agent_runs WHERE thread_id=? COLLATE NOCASE
                UNION ALL SELECT 1 FROM agent_queued_messages WHERE thread_id=? COLLATE NOCASE
                UNION ALL SELECT 1 FROM bot_group_turns WHERE group_id=?
                UNION ALL SELECT 1 FROM bot_conversations WHERE group_id=? AND linked_agent_thread_id IS NOT NULL
                UNION ALL SELECT 1 FROM bot_conversation_contexts p JOIN bot_conversations c ON c.id=p.conversation_id WHERE c.group_id=?
                LIMIT 1;
                """)
            defer { empty.reset() }
            for index in 1...3 { try empty.bind(Int32(index), group.roomThreadID.value.uuidString) }
            for index in 4...6 { try empty.bind(Int32(index), groupID.value.uuidString.lowercased()) }
            guard try !empty.step() else {
                throw BotStoreError.invalidInput("This General group already has history or work. Keep it here and create a new workspace group.")
            }
            let participants = try listGroupParticipants(groupID: groupID).map(\.botID)
            try validateGroupWorkspaceBindings(botIDs: participants, hostID: hostID, workspaceID: workspaceID, grantMissingOwned: true)
            let scope = try db.prepare("UPDATE agent_threads SET workspace_id=? WHERE id=? COLLATE NOCASE AND workspace_id IS NULL;")
            defer { scope.reset() }
            try scope.bind(1, workspaceID.value.uuidString)
            try scope.bind(2, group.roomThreadID.value.uuidString)
            _ = try scope.step()
            let revision = try db.prepare("UPDATE bot_group_conversations SET revision=revision+1,updated_at=? WHERE id=? AND revision=?;")
            defer { revision.reset() }
            try revision.bind(1, ISO8601DateFormatter().string(from: now))
            try revision.bind(2, groupID.value.uuidString.lowercased())
            try revision.bind(3, expectedRevision)
            _ = try revision.step()
            guard let saved = try self.group(id: groupID) else { throw BotStoreError.notFound }
            return saved
        }
        AgentThreadRepository.bumpIdentityRevision()
        return adopted
    }

    /// A narrow alternative to ordinary contextual conversation creation: group
    /// membership already owns the hidden conversation. It may acquire its first
    /// thread/pin only, atomically, under the room's existing workspace authority.
    @discardableResult
    func bindWorkspaceGroupMemberThread(groupID: BotGroupID, botID: BotID, newThread: AgentThread,
        hostID: String, policyRevision: Int64, destination: BotExecutionDestination) throws -> BotConversation {
        var insertedThread = false
        do {
            return try db.transaction {
                guard let workspace = try groupWorkspaceID(groupID: groupID), newThread.workspaceId == workspace,
                      let participant = try listGroupParticipants(groupID: groupID).first(where: { $0.botID == botID }),
                      var conversation = try self.conversation(id: participant.memberConversationID),
                      conversation.groupID == groupID, conversation.botID == botID,
                      conversation.linkedAgentThreadID == nil,
                      try conversationContextPin(conversationID: conversation.id) == nil,
                      newThread.actor == .none, newThread.actorLockedAt == nil, newThread.providerThreadId == nil,
                      newThread.parentThreadId == nil, !newThread.isEphemeral,
                      newThread.runAsUser == nil || newThread.runAsUser?.isCurrentAccount == true else {
                    throw BotStoreError.invalidInput("A workspace group needs a new member thread with its original workspace access.")
                }
                let context = BotContext.workspace(workspace)
                guard try authorizes(hostID: hostID, botID: botID, context: context, action: .read, policyRevision: policyRevision),
                      try authorizes(hostID: hostID, botID: botID, context: context, action: .send, policyRevision: policyRevision) else {
                    throw BotStoreError.invalidInput("This bot's workspace access is inactive or changed. Update its access before starting a new group.")
                }
                let repository = AgentThreadRepository(db: db)
                guard try repository.get(id: newThread.id) == nil else { throw BotStoreError.revisionConflict }
                let pin = BotConversationContextPin(conversationID: conversation.id, hostID: hostID,
                    botID: botID, context: context, policyRevision: policyRevision)
                try validateExecutionDestination(destination, botID: botID, workspaceID: workspace, contextPin: pin)
                try repository.upsert(newThread)
                insertedThread = true
                if destination.target == .vm, newThread.provider == .distill {
                    guard try repository.setGuestRuntime(id: newThread.id, BotGuestRuntime.distillV1) else { throw BotStoreError.notFound }
                }
                guard try repository.lockActorIfUnlocked(id: newThread.id, actor: .bot(botID), lockedAt: Date(), executionTarget: destination.target) else {
                    throw BotStoreError.revisionConflict
                }
                try pinExecutionDestination(threadID: newThread.id, botID: botID, destination: destination, replace: true)
                conversation.linkedAgentThreadID = newThread.id
                try upsertConversation(conversation)
                let insert = try db.prepare("INSERT INTO bot_conversation_contexts(conversation_id,host_id,bot_id,context_key,policy_revision,context_version,thread_id) VALUES(?,?,?,?,?,?,?);")
                defer { insert.reset() }
                try insert.bind(1, conversation.id.value.uuidString.lowercased())
                try insert.bind(2, hostID)
                try insert.bind(3, botID.value.uuidString.lowercased())
                try insert.bind(4, context.storageKey)
                try insert.bind(5, policyRevision)
                try insert.bind(6, BotContext.contractVersion)
                try insert.bind(7, newThread.id.value.uuidString.lowercased())
                _ = try insert.step()
                return conversation
            }
        } catch {
            if insertedThread { forgetLinkedThreads([newThread.id]) }
            throw error
        }
    }
}

extension BotStore {
    /// Called only inside a group create/adopt transaction. Missing authority
    /// can be created minimally for the bot's existing owned workspace; explicit
    /// revoked/incomplete grants and other bots' access remain untouched.
    func validateGroupWorkspaceBindings(botIDs: [BotID], hostID: String, workspaceID: WorkspaceID, grantMissingOwned: Bool) throws {
        guard !hostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BotStoreError.invalidInput("The current host is unavailable.") }
        for id in botIDs {
            guard let bot = try get(id: id), bot.deletedAt == nil else { throw BotStoreError.notFound }
            if let grant = try getContextBinding(hostID: hostID, botID: id, context: .workspace(workspaceID)) {
                guard grant.state == .active, grant.actions.isSuperset(of: [.read, .send]) else {
                    throw BotStoreError.invalidInput("\(bot.name) needs active read and send access to this workspace. Its existing access has not been changed.")
                }
            } else if grantMissingOwned, bot.workspaceID == workspaceID {
                _ = try grantContextWithinTransaction(hostID: hostID, botID: id, context: .workspace(workspaceID), actions: [.read, .send], expectedRevision: nil)
            } else {
                throw BotStoreError.invalidInput("\(bot.name) has no explicit read and send access to this group's workspace.")
            }
        }
    }
}
