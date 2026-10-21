import XCTest
import CoreModel
@testable import Persistence

final class BotStoreTests: XCTestCase {
    func test_storeErrorsKeepTheirActionableMessageAcrossLocalizedBridges() {
        let error: Error = BotStoreError.invalidInput("This bot belongs to another workspace.")
        XCTAssertEqual(error.localizedDescription, "This bot belongs to another workspace.")
        XCTAssertEqual((BotStoreError.notFound as NSError).localizedDescription, "Bot was not found.")
    }

    func test_contextGrantOverridesLegacyWorkspaceButCannotCrossWorkspaceVMScope() throws {
        let legacy = WorkspaceID()
        let workspace = WorkspaceID()
        let bot = try store.create(name: "Developer", title: "", description: "", workspaceID: legacy)
        let grant = try store.grantContext(hostID: "host", botID: bot.id, context: .workspace(workspace),
                                          actions: [.read, .send], expectedRevision: nil)
        let thread = AgentThread(workspaceId: workspace, title: "Task", provider: .distill, model: "auto")
        try AgentThreadRepository(db: db).upsert(thread)
        let pin = try store.createContextualConversation(
            BotConversation(botID: bot.id, title: "Task", linkedAgentThreadID: thread.id),
            hostID: "host", context: .workspace(workspace), policyRevision: grant.policyRevision
        )
        XCTAssertNoThrow(try store.validateExecutionDestination(.ownVM, botID: bot.id, workspaceID: workspace, contextPin: pin))
        XCTAssertThrowsError(try store.validateExecutionDestination(.ownVM, botID: bot.id, workspaceID: workspace))
        let scopedVM = try store.saveVirtualMachine(name: "Legacy", workspaceID: legacy)
        XCTAssertThrowsError(try store.validateExecutionDestination(.virtualMachine(scopedVM.id),
            botID: bot.id, workspaceID: workspace, contextPin: pin))
        _ = try store.revokeContext(hostID: "host", botID: bot.id, context: .workspace(workspace), expectedRevision: grant.policyRevision)
        XCTAssertThrowsError(try store.validateExecutionDestination(.ownVM, botID: bot.id, workspaceID: workspace, contextPin: pin))
    }

    func test_sameSecondReplyResolvesQuestionButReplayingTheOriginalPromptDoesNot() throws {
        let bot = try store.create(name: "Worker", title: "", description: "")
        let thread = AgentThread(title: "Task", provider: .distill, model: "auto")
        try AgentThreadRepository(db: db).upsert(thread)
        let conversation = BotConversation(botID: bot.id, title: "Task", attentionState: .needsAttention, linkedAgentThreadID: thread.id)
        try store.upsertConversation(conversation)
        let messages = AgentMessageRepository(db: db)
        let prompt = AgentMessage(threadId: thread.id, role: .user, content: "Start.", createdAt: Date(timeIntervalSince1970: 100.1))
        try messages.append(prompt)
        let question = BotAttentionItem(botID: bot.id, conversationID: conversation.id, kind: .question,
                                        title: "Reply", createdAt: Date(timeIntervalSince1970: 100.2))
        try store.upsertAttention(question)
        try messages.append(prompt)
        XCTAssertEqual(try store.listAttention().map(\.id), [question.id])
        try messages.append(AgentMessage(threadId: thread.id, role: .user, content: "Use staging.", createdAt: Date(timeIntervalSince1970: 100.3)))
        XCTAssertTrue(try BotStore(db: db).listAttention().isEmpty)
        XCTAssertNotNil(try store.listAttention(includeAcknowledged: true).first?.acknowledgedAt)
        XCTAssertNotEqual(try store.conversation(id: conversation.id)?.attentionState, .needsAttention)
    }

    func test_sharedVMScopesPersistAndOnlyExclusiveWorkspaceBotsCanUseThem() throws {
        let workspace = WorkspaceID()
        let general = try store.create(name: "General", title: "", description: "")
        let exclusive = try store.create(name: "Exclusive", title: "", description: "", workspaceID: workspace)
        let other = try store.create(name: "Other", title: "", description: "", workspaceID: WorkspaceID())
        let shared = try store.saveVirtualMachine(name: "Research")
        let scoped = try store.saveVirtualMachine(name: "Build", workspaceID: workspace)
        XCTAssertNoThrow(try store.setExecutionDestination(.virtualMachine(shared.id), botID: general.id))
        XCTAssertNoThrow(try store.setExecutionDestination(.virtualMachine(scoped.id), botID: exclusive.id))
        XCTAssertThrowsError(try store.setExecutionDestination(.virtualMachine(scoped.id), botID: general.id))
        XCTAssertThrowsError(try store.setExecutionDestination(.virtualMachine(scoped.id), botID: other.id))
        XCTAssertThrowsError(try store.saveVirtualMachine(name: " research "))
        XCTAssertThrowsError(try store.saveVirtualMachine(id: scoped.id, name: "Moved", workspaceID: nil))
        let restored = BotStore(db: db)
        XCTAssertEqual(try restored.executionDestination(botID: exclusive.id), .virtualMachine(scoped.id))
        let copy = try restored.duplicate(id: exclusive.id)
        XCTAssertEqual(try restored.executionDestination(botID: copy.id), .virtualMachine(scoped.id))
    }

    func test_createWithoutAvatarDefaultsToAutoBlobatar_becauseNewBotsMustNotRenderAsPlainPerson() throws {
        let bot = try store.create(name: "Piper", title: "", description: "")
        XCTAssertEqual(bot.avatarSymbol, BotBlobatarSpec.default.token)
    }

    func test_conversationKeepsItsVMWhenTheDefaultChangesAndSchedulesKeepTheirOverride() throws {
        let bot = try store.create(name: "Builder", title: "", description: "")
        let machine = try store.saveVirtualMachine(name: "Build")
        try store.setExecutionDestination(.virtualMachine(machine.id), botID: bot.id)
        let threads = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "Pinned", provider: .distill, model: "auto")
        try threads.upsert(thread)
        try store.pinExecutionDestination(threadID: thread.id, botID: bot.id, destination: .virtualMachine(machine.id))
        try store.setExecutionDestination(.mac, botID: bot.id)
        XCTAssertEqual(try store.guestResourceID(botID: bot.id, threadID: thread.id), machine.storageID)
        XCTAssertEqual(try store.executionDestination(botID: bot.id), .mac)
        var spec = BotScheduleSpec(model: "auto")
        spec.executionDestination = .virtualMachine(machine.id)
        try store.saveRoutine(BotRoutineDefinition(botID: bot.id, name: "Build", prompt: "Build",
            scheduleNote: spec.displayNote(), scheduleSpecJSON: spec.encodedJSON()))
        XCTAssertEqual(try store.listRoutines(botID: bot.id).first?.definition.scheduleSpec?.executionDestination,
            .virtualMachine(machine.id))
    }

    // Legacy-provider machinery is still exercised here; Distill-only rules run with the seam cleared.
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    private var db: SQLiteDB!
    private var store: BotStore!

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = BotStore(db: db)
    }

    override func tearDown() {
        store = nil
        db = nil
    }

    func test_schemaCurrentVersionIncludesBotTables_becauseUpgradesMustCreateIdentityStorage() throws {
        XCTAssertGreaterThanOrEqual(Schema.currentVersion, 71)
        XCTAssertEqual(Schema.steps.last?.version, Schema.currentVersion)
        let statement = try db.prepare("SELECT MAX(version) FROM schema_meta;")
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.columnInt64(0), Int64(Schema.currentVersion))
        for table in [
            "bots", "bot_revisions", "bot_handles", "bot_handle_tombstones",
            "bot_conversations", "bot_memory_items", "bot_memory_item_revisions",
            "bot_attention_items", "bot_routine_definitions", "bot_routine_activations",
            "bot_skill_bindings", "bot_context_receipts", "bot_queued_follow_ups",
        ] {
            let exists = try db.prepare(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?;"
            )
            defer { exists.reset() }
            try exists.bind(1, table)
            XCTAssertTrue(try exists.step())
            XCTAssertEqual(exists.columnInt64(0), 1, "\(table) must exist after migrating to 71")
        }
    }

    func test_createListGet_roundTripStableIdentity_becauseABotIsNotAnAgentThread() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let created = try store.create(
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            handle: "@Piper",
            soul: "Be brief.",
            provider: .claude,
            model: "opus",
            now: now
        )

        XCTAssertEqual(created.handle, "piper")
        XCTAssertEqual(created.name, "Piper")
        XCTAssertNotNil(created.currentRevisionID)
        XCTAssertEqual(try store.list().map(\.id), [created.id])
        XCTAssertEqual(try store.get(id: created.id)?.handle, "piper")

        let revisionID = try XCTUnwrap(created.currentRevisionID)
        let revision = try XCTUnwrap(store.getRevision(id: revisionID))
        XCTAssertEqual(revision.permissionMode, .fullAccess)
        XCTAssertEqual(revision.desktopKind, .logicalExecutionSpace)
        XCTAssertEqual(revision.revisionNumber, 1)
        XCTAssertEqual(
            revision.digest,
            BotRevision.digest(botID: created.id, draft: BotRevisionDraft(
                name: "Piper",
                title: "Scout",
                description: "Looks around",
                soul: "Be brief."
            ))
        )
    }

    func test_publishCAS_rejectsStaleExpectedRevision_becauseTwoEditorsMustNotClobberIdentity() throws {
        let bot = try store.create(
            name: "Piper", title: "Scout", description: "", provider: .codex, now: Date(timeIntervalSince1970: 10)
        )
        let current = try XCTUnwrap(bot.currentRevisionID)
        let stale = BotRevisionID()
        let draft = BotRevisionDraft(
            name: "Piper",
            title: "Lead",
            description: "",
            soul: "Updated",
            provider: .codex,
            providerInstanceID: "codex",
            model: "gpt"
        )

        XCTAssertThrowsError(
            try store.publish(botID: bot.id, expectedCurrentRevisionID: stale, draft: draft)
        ) { error in
            XCTAssertEqual(error as? BotPublishError, .revisionConflict)
        }

        let published = try store.publish(
            botID: bot.id,
            expectedCurrentRevisionID: current,
            draft: draft,
            now: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(published.revisionNumber, 2)
        XCTAssertEqual(published.supersedesRevisionID, current)
        XCTAssertEqual(try store.get(id: bot.id)?.title, "Lead")

        let original = try XCTUnwrap(store.getRevision(id: current))
        XCTAssertEqual(original.title, "Scout")
        XCTAssertEqual(original.soul, "")

        let chrome = try store.publish(
            botID: bot.id,
            expectedCurrentRevisionID: published.id,
            draft: draft,
            avatarSymbol: "brain.head.profile",
            notificationsEnabled: false,
            now: Date(timeIntervalSince1970: 30)
        )
        XCTAssertEqual(chrome.revisionNumber, 3)
        XCTAssertEqual(try store.get(id: bot.id)?.avatarSymbol, "brain.head.profile")
        XCTAssertEqual(try store.get(id: bot.id)?.notificationsEnabled, false)
    }

    func test_updateProfile_writesNewRevisionInsteadOfMutatingOldRow() throws {
        let bot = try store.create(
            name: "Piper", title: "Scout", description: "v1", provider: .grok, now: Date(timeIntervalSince1970: 1)
        )
        let firstID = try XCTUnwrap(bot.currentRevisionID)
        let updated = try store.updateProfile(
            id: bot.id,
            name: "Piper Prime",
            description: "v2",
            now: Date(timeIntervalSince1970: 2)
        )

        XCTAssertNotEqual(updated.currentRevisionID, firstID)
        XCTAssertEqual(updated.name, "Piper Prime")
        XCTAssertEqual(try store.getRevision(id: firstID)?.name, "Piper")
        XCTAssertEqual(try store.getRevision(id: firstID)?.description, "v1")
    }

    func test_deleteConversations_dropsOnlyThatBot_becauseClearAllIsPerTeammate() throws {
        // WHY: dest Clear All must erase this teammate's dest threads and
        // leave every other bot's conversations on disk.
        let piper = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        let quinn = try store.create(name: "Quinn", title: "CRM", description: "", provider: .grok)
        try store.upsertConversation(BotConversation(botID: piper.id, title: "Standup"))
        try store.upsertConversation(BotConversation(botID: piper.id, title: "Follow-up"))
        try store.upsertConversation(BotConversation(botID: quinn.id, title: "Inbox"))
        try store.deleteConversations(botID: piper.id)
        XCTAssertEqual(try store.listConversations(botID: piper.id).count, 0)
        XCTAssertEqual(try store.listConversations(botID: quinn.id).map(\.title), ["Inbox"])
    }

    func test_listAttentionHidesDeletedConversationItems_becauseAnErasedThreadCannotNeedTheUser() throws {
        // WHY: conversation-scoped Attention rows are retained as history,
        // but Clear All removes the thread that could make them actionable.
        // Live consumers must not turn that archive into a Needs-you badge.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .grok)
        let conversation = BotConversation(botID: bot.id, title: "Old request")
        try store.upsertConversation(conversation)
        let scoped = BotAttentionItem(
            botID: bot.id,
            conversationID: conversation.id,
            kind: .question,
            title: "Needs you"
        )
        let unscoped = BotAttentionItem(botID: bot.id, kind: .handoff, title: "Direct handoff")
        try store.upsertAttention(scoped)
        try store.upsertAttention(unscoped)

        try store.deleteConversations(botID: bot.id)

        XCTAssertEqual(try store.listAttention().map(\.id), [unscoped.id])
        XCTAssertEqual(
            Set(try store.listAttention(includeAcknowledged: true).map(\.id)),
            Set([scoped.id, unscoped.id]),
            "archival reads may retain the erased thread receipt"
        )
    }

    func test_orphanedLinkedConversationCannotNeedTheUser_becauseItsProviderThreadNoLongerExists() throws {
        // WHY: deleting an Agent thread can leave the Bot conversation as
        // history. That archived row has no live provider and must not keep a
        // stale Needs-you or unread badge on the Bot roster.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .grok)
        let thread = AgentThread(title: "Delegated request", provider: .grok, model: "test")
        let threads = AgentThreadRepository(db: db)
        try threads.upsert(thread)
        let conversation = BotConversation(
            botID: bot.id,
            title: "Delegated request",
            unread: true,
            attentionState: .needsAttention,
            linkedAgentThreadID: thread.id
        )
        try store.upsertConversation(conversation)
        try AgentRunRepository(db: db).upsert(
            AgentRun(threadId: thread.id, provider: .grok, model: "test", status: .failed)
        )
        let attention = BotAttentionItem(
            botID: bot.id,
            conversationID: conversation.id,
            kind: .question,
            title: "Needs you"
        )
        try store.upsertAttention(attention)

        XCTAssertEqual(try store.listAttention().map(\.id), [attention.id])
        XCTAssertEqual(try store.conversation(id: conversation.id)?.attentionState, .needsAttention)

        try threads.delete(id: thread.id)

        XCTAssertTrue(try store.listAttention().isEmpty)
        XCTAssertEqual(
            try store.listAttention(includeAcknowledged: true).map(\.id),
            [attention.id],
            "archival receipts stay readable even when they are no longer actionable"
        )
        let archived = try XCTUnwrap(store.conversation(id: conversation.id))
        XCTAssertEqual(archived.linkedAgentThreadID, thread.id)
        XCTAssertEqual(archived.attentionState, .none)
        XCTAssertFalse(archived.unread)
        XCTAssertTrue(try store.listConversations(attentionStates: [.needsAttention]).isEmpty)
    }

    func test_emptyLinkedConversationCannotNeedTheUser_becauseNoProviderWorkExists() throws {
        // WHY: the retired direct-mention path left linked thread shells with no
        // message or run. A shell cannot contain an actionable Bot question and
        // must not keep a permanent Needs-you badge on the roster.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .grok)
        let thread = AgentThread(title: "Unused delegation", provider: .grok, model: "test")
        try AgentThreadRepository(db: db).upsert(thread)
        let conversation = BotConversation(
            botID: bot.id,
            title: "Unused delegation",
            unread: true,
            attentionState: .needsAttention,
            linkedAgentThreadID: thread.id
        )
        try store.upsertConversation(conversation)
        let attention = BotAttentionItem(
            botID: bot.id,
            conversationID: conversation.id,
            kind: .question,
            title: "Needs you"
        )
        try store.upsertAttention(attention)

        XCTAssertTrue(try store.listAttention().isEmpty)
        let empty = try XCTUnwrap(store.conversation(id: conversation.id))
        XCTAssertEqual(empty.attentionState, .none)
        XCTAssertFalse(empty.unread)
        XCTAssertTrue(try store.listConversations(attentionStates: [.needsAttention]).isEmpty)
        XCTAssertEqual(try store.listAttention(includeAcknowledged: true).map(\.id), [attention.id])

        try AgentRunRepository(db: db).upsert(
            AgentRun(threadId: thread.id, provider: .grok, model: "test", status: .failed)
        )

        XCTAssertEqual(try store.listAttention().map(\.id), [attention.id])
        XCTAssertEqual(try store.conversation(id: conversation.id)?.attentionState, .needsAttention)
    }

    func test_conversationsLinked_matchesSingleLookups_becauseActiveBotsMustKeepExactLinksAndStatus() throws {
        // WHY: Active/Finished Bots may collapse many thread lookups into one
        // SQLite query only if every requested thread resolves to the exact row
        // and derived status that the existing single-thread lookup returns.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .grok)
        let liveThread = AgentThread(title: "Live", provider: .grok, model: "test")
        let staleThread = AgentThreadID()
        let missingThread = AgentThreadID()
        let corruptThread = AgentThreadID()
        try AgentThreadRepository(db: db).upsert(liveThread)
        try AgentRunRepository(db: db).upsert(
            AgentRun(threadId: liveThread.id, provider: .grok, model: "test", status: .running)
        )

        let liveConversation = BotConversation(
            botID: bot.id,
            title: "Live conversation",
            unread: true,
            attentionState: .needsAttention,
            linkedAgentThreadID: liveThread.id
        )
        let staleConversation = BotConversation(
            botID: bot.id,
            title: "Stale conversation",
            unread: true,
            attentionState: .needsAttention,
            linkedAgentThreadID: staleThread
        )
        try store.upsertConversation(liveConversation)
        try store.upsertConversation(staleConversation)
        try store.upsertConversation(BotConversation(
            botID: bot.id,
            title: "Later duplicate link",
            linkedAgentThreadID: staleThread
        ))
        let corruptConversation = BotConversation(
            botID: bot.id,
            title: "Corrupt conversation",
            linkedAgentThreadID: corruptThread
        )
        try store.upsertConversation(corruptConversation)
        let corrupt = try db.prepare("UPDATE bot_conversations SET id = 'not-a-uuid' WHERE id = ?;")
        defer { corrupt.reset() }
        try corrupt.bind(1, corruptConversation.id.value.uuidString.lowercased())
        _ = try corrupt.step()

        let requested: Set<AgentThreadID> = [liveThread.id, staleThread, missingThread, corruptThread]
        let expected = Dictionary(uniqueKeysWithValues: requested.compactMap { threadID in
            try? store.conversationLinked(to: threadID).map { (threadID, $0) }
        })
        let actual = try store.conversationsLinked(to: requested)

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual[liveThread.id]?.attentionState, .needsAttention)
        XCTAssertEqual(actual[liveThread.id]?.unread, true)
        XCTAssertEqual(actual[staleThread]?.attentionState, BotAttentionState.none)
        XCTAssertEqual(actual[staleThread]?.unread, false)
        XCTAssertEqual(actual[staleThread]?.id, staleConversation.id)
        XCTAssertNil(actual[missingThread])
        XCTAssertNil(actual[corruptThread])
        XCTAssertEqual(try store.conversationsLinked(to: []), [:])
    }

    func test_cachedBotID_tracksLinkedThreadWithoutSQLiteLookup() throws {
        // WHY: run-status broadcasts must not SQLite-lookup threads that never
        // belonged to a bot. Upsert and conversation reads fill an in-memory map.
        let bot = try store.create(
            name: "Piper", title: "Scout", description: "", provider: .grok
        )
        let threadID = AgentThreadID()
        let conversation = BotConversation(
            botID: bot.id,
            title: "Live conversation",
            linkedAgentThreadID: threadID
        )
        let queries = store.conversationLinkedQueryCountForTesting
        try store.upsertConversation(conversation)
        XCTAssertEqual(store.cachedBotID(linkedTo: threadID), bot.id)
        XCTAssertNil(store.cachedBotID(linkedTo: AgentThreadID()))
        XCTAssertEqual(store.conversationLinkedQueryCountForTesting, queries)

        let other = BotStore(db: db)
        XCTAssertNil(other.cachedBotID(linkedTo: threadID))
        _ = try other.listConversations(botID: bot.id)
        XCTAssertEqual(other.cachedBotID(linkedTo: threadID), bot.id)
        XCTAssertEqual(other.conversationLinkedQueryCountForTesting, 0)

        var cleared = conversation
        cleared.linkedAgentThreadID = nil
        try store.upsertConversation(cleared)
        XCTAssertNil(store.cachedBotID(linkedTo: threadID))
        XCTAssertEqual(store.conversationLinkedQueryCountForTesting, queries)

        _ = try store.conversationLinked(to: threadID)
        XCTAssertEqual(store.conversationLinkedQueryCountForTesting, queries + 1)
    }

    func test_conversationsLinked_chunksAboveSafeSQLiteVariableBound_becauseActiveRunsAreUnbounded() throws {
        // WHY: Active thread snapshots have no cardinality cap. A batch wider
        // than SQLite's safe bind-variable budget must split without losing a
        // linked conversation from either side of the chunk boundary.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .grok)
        let threadIDs = (0...200).map { _ in AgentThreadID() }
        try db.transaction {
            for (index, threadID) in threadIDs.enumerated() {
                try store.upsertConversation(BotConversation(
                    botID: bot.id,
                    title: "Conversation \(index)",
                    linkedAgentThreadID: threadID
                ))
            }
        }

        var batchSQL = Set<String>()
        db.beforeStatementStepForTesting = { sql in
            if sql.contains("WHERE linked_agent_thread_id IN (") {
                batchSQL.insert(sql)
            }
        }
        let actual = try store.conversationsLinked(to: Set(threadIDs))
        db.beforeStatementStepForTesting = nil

        XCTAssertEqual(actual.count, threadIDs.count)
        XCTAssertEqual(Set(actual.keys), Set(threadIDs))
        XCTAssertEqual(batchSQL.count, 2, "201 IDs must execute as bounded 200 + 1 chunks")
        XCTAssertEqual(batchSQL.map { $0.filter { $0 == "?" }.count }.max(), 200)
    }

    func test_conversationsByID_matchesFailSoftPointLookups_becauseOneCorruptHandoffMustNotHidePeers() throws {
        // WHY: live handoff origin checks are batched. One corrupt durable row
        // must still look missing without discarding healthy requested origins.
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .grok)
        let first = BotConversation(botID: bot.id, title: "First")
        let second = BotConversation(botID: bot.id, title: "Second")
        let corrupt = BotConversation(botID: bot.id, title: "Corrupt")
        try store.upsertConversation(first)
        try store.upsertConversation(second)
        try store.upsertConversation(corrupt)
        let damage = try db.prepare(
            "UPDATE bot_conversations SET attention_state = 'invalid' WHERE id = ?;"
        )
        defer { damage.reset() }
        try damage.bind(1, corrupt.id.value.uuidString.lowercased())
        _ = try damage.step()
        let missing = BotConversationID()
        let requested: Set<BotConversationID> = [first.id, second.id, corrupt.id, missing]
        let expected = Dictionary(uniqueKeysWithValues: requested.compactMap { id in
            try? store.conversation(id: id).map { (id, $0) }
        })

        var batchSQL = Set<String>()
        db.beforeStatementStepForTesting = { sql in
            if sql.contains("FROM bot_conversations"), sql.contains("WHERE id IN (") {
                batchSQL.insert(sql)
            }
        }
        let actual = try store.conversations(ids: requested)
        db.beforeStatementStepForTesting = nil

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(Set(actual.keys), [first.id, second.id])
        XCTAssertNil(actual[corrupt.id])
        XCTAssertNil(actual[missing])
        XCTAssertEqual(batchSQL.count, 1)
        XCTAssertEqual(try store.conversations(ids: []), [:])
    }

    func test_duplicate_copiesProfileAndRoutinesButNotMemoryOrConversations() throws {
        let bot = try store.create(
            name: "Piper", title: "Scout", description: "Looks around",
            avatarSymbol: "bird", provider: .claude, now: Date(timeIntervalSince1970: 1)
        )
        _ = try store.putMemory(
            botID: bot.id, content: "Prefers dark mode", provenance: "user",
            trusted: true, source: "chat"
        )
        try store.upsertConversation(BotConversation(botID: bot.id, title: "Standup"))
        let routine = BotRoutineDefinition(
            botID: bot.id, name: "Morning", prompt: "Summarize overnight",
            scheduleNote: BotRoutineCopy.testRunHonestyCaption,
            scheduleSpecJSON: "{\"frequency\":\"daily\"}"
        )
        try store.saveRoutine(routine)
        try store.setRoutineEnabled(id: routine.id, enabled: true)
        try store.setSkillBinding(
            BotSkillBinding(
                botID: bot.id,
                skillID: "weekly-account-health",
                enabled: true,
                digest: "abc123",
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        )

        let copy = try store.duplicate(id: bot.id, now: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(copy.name, "Piper copy")
        XCTAssertNotEqual(copy.handle, bot.handle)
        XCTAssertEqual(copy.avatarSymbol, "bird")
        XCTAssertTrue(copy.handle.hasPrefix("piper-copy") || copy.handle.hasPrefix("piper"))
        XCTAssertEqual(try store.listMemory(botID: copy.id).count, 0)
        XCTAssertEqual(try store.listConversations(botID: copy.id).count, 0)
        XCTAssertEqual(try store.listMemory(botID: bot.id).count, 1)
        XCTAssertEqual(try store.listConversations(botID: bot.id).count, 1)

        let copiedRoutines = try store.listRoutines(botID: copy.id)
        XCTAssertEqual(copiedRoutines.count, 1)
        XCTAssertEqual(copiedRoutines[0].definition.name, "Morning")
        XCTAssertEqual(copiedRoutines[0].definition.scheduleSpecJSON, "{\"frequency\":\"daily\"}")
        XCTAssertTrue(copiedRoutines[0].activation.isEnabled)
        XCTAssertNotEqual(copiedRoutines[0].definition.id, routine.id)

        let copiedSkills = try store.listSkillBindings(botID: copy.id)
        XCTAssertEqual(copiedSkills.map(\.skillID), ["weekly-account-health"])
        XCTAssertEqual(copiedSkills.first?.enabled, true)
        XCTAssertEqual(copiedSkills.first?.digest, "abc123")
        XCTAssertEqual(try store.listSkillBindings(botID: bot.id).count, 1)
    }

    func test_setSkillBinding_rejectsPathSkillID_becauseEnablementIsCatalogNotFilesystem() throws {
        let bot = try store.create(name: "Piper", title: "", description: "", provider: .claude)
        XCTAssertThrowsError(
            try store.setSkillBinding(
                BotSkillBinding(botID: bot.id, skillID: "/tmp/skill.md", enabled: true)
            )
        ) { error in
            XCTAssertEqual(error as? BotStoreError, .invalidRow("skill id must be a catalog id, not a path"))
        }
    }

    func test_removeSkillBinding_dropsOnlyThatCatalogId_becauseDisableIsNotUnbind() throws {
        // WHY: Off still leaves the row on Studio Skills. Remove must delete
        // the binding so the teammate no longer lists that catalog id.
        let bot = try store.create(name: "Piper", title: "", description: "", provider: .claude)
        try store.setSkillBinding(BotSkillBinding(botID: bot.id, skillID: "keep-me", enabled: true))
        try store.setSkillBinding(BotSkillBinding(botID: bot.id, skillID: "drop-me", enabled: false))
        try store.removeSkillBinding(botID: bot.id, skillID: "drop-me")
        XCTAssertEqual(try store.listSkillBindings(botID: bot.id).map(\.skillID), ["keep-me"])
    }

    func test_contextReceiptRoundTrip_becausePreviewMustMatchThePersistedCall() throws {
        // WHY: Brain Inspector Source/Effective is a lie if the last receipt
        // cannot be reopened after restart.
        let bot = try store.create(
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be brief.",
            provider: .claude,
            model: "opus"
        )
        let revision = try XCTUnwrap(store.getRevision(id: try XCTUnwrap(bot.currentRevisionID)))
        let conversation = BotConversation(botID: bot.id, title: "Desk")
        try store.upsertConversation(conversation)
        let trusted = try store.putMemory(
            botID: bot.id, content: "Prefers dark mode", provenance: "user",
            trusted: true, source: "chat"
        )
        var forgotten = try store.putMemory(
            botID: bot.id, content: "Old secret", provenance: "user",
            trusted: true, source: "chat"
        )
        try store.forgetMemory(id: forgotten.id)
        forgotten = try XCTUnwrap(store.getMemory(id: forgotten.id))
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Summarize overnight",
            memoryFiles: [
                BotMemoryFileText(path: "MEMORY.md", body: "- Prefers dark mode\n"),
            ],
            conversationID: conversation.id
        )
        try store.insertContextReceipt(receipt)

        let loaded = try XCTUnwrap(
            store.latestContextReceipt(botID: bot.id, conversationID: conversation.id)
        )
        XCTAssertEqual(loaded.payloadDigest, receipt.payloadDigest)
        XCTAssertEqual(loaded.compiledPayload, receipt.compiledPayload)
        XCTAssertTrue(loaded.compiledPayload.contains("Prefers dark mode"))
        XCTAssertTrue(loaded.compiledPayload.contains("### MEMORY.md"))
        XCTAssertFalse(loaded.compiledPayload.contains("Old secret"))
        XCTAssertEqual(
            loaded.memoryLayers.first(where: { $0.text.contains("Prefers dark mode") })?.included,
            true
        )
    }

    func test_saveRoutinePersistsScheduleRoutingAndRecurrence() throws {
        let bot = try store.create(name: "Piper", title: "Scout", description: "", provider: .claude)
        var spec = BotScheduleSpec(
            provider: .grok,
            providerInstanceID: "grok",
            model: "",
            reasoningEffort: .medium,
            routingMode: .auto,
            frequency: .weekdays
        )
        spec.localTimeHour = 9
        spec.localTimeMinute = 0
        let definition = BotRoutineDefinition(
            botID: bot.id,
            name: "Morning scan",
            prompt: "Scan overnight",
            scheduleNote: spec.displayNote(),
            scheduleSpecJSON: spec.encodedJSON()
        )
        try store.saveRoutine(definition)
        let loaded = try XCTUnwrap(store.listRoutines(botID: bot.id).first?.definition)
        XCTAssertEqual(loaded.scheduleNote, "Weekdays 09:00")
        let decoded = try XCTUnwrap(loaded.scheduleSpec)
        XCTAssertEqual(decoded.provider, .grok)
        XCTAssertEqual(decoded.routingMode, .auto)
        XCTAssertEqual(decoded.reasoningEffort, .medium)
        XCTAssertEqual(decoded.frequency, .weekdays)
        XCTAssertEqual(try decoded.makeRecurrence(), .weekdays(at: ScheduledLocalTime(hour: 9, minute: 0)!))
    }

    func test_delete_tombstonesHandleSoReuseIsNotSilent() throws {
        let bot = try store.create(
            name: "Piper", title: "Scout", description: "", handle: "piper",
            provider: .claude, now: Date(timeIntervalSince1970: 1)
        )
        try store.delete(id: bot.id, now: Date(timeIntervalSince1970: 2))

        XCTAssertTrue(try store.list().isEmpty)
        let tombstoned = try XCTUnwrap(store.get(id: bot.id))
        XCTAssertNotNil(tombstoned.deletedAt)
        XCTAssertTrue(tombstoned.hidden)

        XCTAssertThrowsError(
            try store.create(
                name: "Piper", title: "Scout", description: "", handle: "piper", provider: .claude
            )
        ) { error in
            XCTAssertEqual(
                error as? BotPublishError,
                .handleConflict,
                "reusing a tombstoned handle would attach history to a different teammate"
            )
        }
        XCTAssertEqual(try store.list(includeDeleted: true).map(\.id), [bot.id])
    }

    func test_renameHandleUpdatesLiveRowAndFreesOldSlug() throws {
        let bot = try store.create(
            name: "CEO", title: "", description: "", handle: "new-agent-19",
            provider: .claude
        )
        let renamed = try store.renameHandle(id: bot.id, handle: "ceo")
        XCTAssertEqual(renamed.handle, "ceo")
        XCTAssertEqual(try store.get(id: bot.id)?.handle, "ceo")
        let recycled = try store.create(
            name: "Other", title: "", description: "", handle: "new-agent-19",
            provider: .claude
        )
        XCTAssertEqual(recycled.handle, "new-agent-19")
        XCTAssertThrowsError(try store.renameHandle(id: recycled.id, handle: "ceo")) { error in
            XCTAssertEqual(error as? BotPublishError, .handleConflict)
        }
    }

    func test_memoryCorrectAndForget_keepsPriorRevision_becauseCorrectionsAreNotRewrites() throws {
        let bot = try store.create(name: "Piper", title: "", description: "", provider: .claude)
        let first = try store.putMemory(
            botID: bot.id, content: "Likes tea", provenance: "user",
            trusted: true, source: "chat"
        )
        let corrected = try store.correctMemory(id: first.id, content: "Likes coffee")

        XCTAssertNotEqual(corrected.currentRevisionID, first.currentRevisionID)
        XCTAssertEqual(corrected.content, "Likes coffee")
        let revisions = try store.listMemoryRevisions(itemID: first.id)
        XCTAssertEqual(revisions.map(\.content), ["Likes tea", "Likes coffee"])
        XCTAssertEqual(revisions[1].supersedesRevisionID, first.currentRevisionID)

        try store.forgetMemory(id: first.id)
        XCTAssertTrue(try store.listMemory(botID: bot.id).isEmpty)
        XCTAssertNotNil(try store.getMemory(id: first.id)?.forgottenAt)
        XCTAssertEqual(try store.listMemoryRevisions(itemID: first.id).count, 2)
    }

    func test_attentionList_hidesAcknowledgedByDefault_becauseInboxIsOpenWork() throws {
        let bot = try store.create(name: "Piper", title: "", description: "", provider: .claude)
        let open = BotAttentionItem(botID: bot.id, kind: .question, title: "Which repo?")
        let done = BotAttentionItem(botID: bot.id, kind: .approval, title: "Push?")
        try store.upsertAttention(open)
        try store.upsertAttention(done)
        try store.acknowledgeAttention(id: done.id, now: Date(timeIntervalSince1970: 9))

        XCTAssertEqual(try store.listAttention().map(\.id), [open.id])
        XCTAssertEqual(Set(try store.listAttention(includeAcknowledged: true).map(\.id)), [open.id, done.id])
    }

    func test_liveAccountCap_blocksThe51stBot_becauseDirectoryMustStayHumanScale() throws {
        for index in 1...BotDefinition.liveAccountCap {
            _ = try store.create(
                name: "Bot \(index)",
                title: "",
                description: "",
                handle: "bot-\(index)",
                provider: .claude
            )
        }
        XCTAssertThrowsError(
            try store.create(name: "Overflow", title: "", description: "", handle: "overflow", provider: .claude)
        ) { error in
            XCTAssertEqual(error as? BotPublishError, .accountCap)
        }
        XCTAssertEqual(try store.list().count, BotDefinition.liveAccountCap)
    }

    func test_recreateStoreOnSameDatabase_restoresIdentity_becauseWorkflowMustSurviveRelaunch() throws {
        let path = NSTemporaryDirectory() + "rc-botstore-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let firstDB = try SQLiteDB(path: path)
        try Schema.migrate(firstDB)
        let firstStore = BotStore(db: firstDB)
        let created = try firstStore.create(
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            handle: "piper",
            provider: .claude,
            now: Date(timeIntervalSince1970: 1_700_000_100)
        )
        _ = try firstStore.putMemory(
            botID: created.id, content: "Keep it short", provenance: "user",
            trusted: true, source: "chat"
        )

        let reopenedDB = try SQLiteDB(path: path)
        let reopened = BotStore(db: reopenedDB)
        let loaded = try XCTUnwrap(reopened.get(id: created.id))
        XCTAssertEqual(loaded.handle, "piper")
        XCTAssertEqual(loaded.name, "Piper")
        XCTAssertEqual(loaded.currentRevisionID, created.currentRevisionID)
        XCTAssertEqual(try reopened.listMemory(botID: created.id).map(\.content), ["Keep it short"])
    }

    func test_deleteAcknowledgesOnlyThatBotsAttention_becauseDeletedWorkCannotStayActionable() throws {
        let deleted = try store.create(name: "Piper", title: "", description: "", provider: .claude)
        let survivor = try store.create(name: "Quinn", title: "", description: "", provider: .grok)
        try store.upsertConversation(BotConversation(botID: deleted.id, title: "Chat"))
        let routine = BotRoutineDefinition(botID: deleted.id, name: "Ping", prompt: "Ping")
        try store.saveRoutine(routine)
        let deletedQuestion = BotAttentionItem(
            botID: deleted.id,
            kind: .question,
            title: "Which workspace?"
        )
        let survivorQuestion = BotAttentionItem(
            botID: survivor.id,
            kind: .question,
            title: "Which branch?"
        )
        try store.upsertAttention(deletedQuestion)
        try store.upsertAttention(survivorQuestion)
        let deletedAt = Date(timeIntervalSince1970: 1_700_000_500)

        try store.delete(id: deleted.id, now: deletedAt)

        XCTAssertTrue(try store.listConversations(botID: deleted.id).isEmpty)
        XCTAssertTrue(try store.listRoutines(botID: deleted.id).isEmpty)
        XCTAssertEqual(try store.listAttention().map(\.id), [survivorQuestion.id])
        let audit = try store.listAttention(includeAcknowledged: true)
        XCTAssertEqual(Set(audit.map(\.id)), Set([deletedQuestion.id, survivorQuestion.id]))
        XCTAssertEqual(audit.first { $0.id == deletedQuestion.id }?.acknowledgedAt, deletedAt)
        XCTAssertNil(audit.first { $0.id == survivorQuestion.id }?.acknowledgedAt)
    }

    func test_createWithoutHandleUniquesDerivedHandle_becauseRepeatedNewAgentMustNotCollide() throws {
        let first = try store.create(name: "New Agent", title: "", description: "", provider: .claude)
        let second = try store.create(name: "New Agent", title: "", description: "", provider: .claude)
        XCTAssertEqual(first.handle, "new-agent")
        XCTAssertEqual(second.handle, "new-agent-2")
    }

    func test_queuedFollowUps_roundTripAndDeleteWithBot() throws {
        let bot = try store.create(name: "Piper", title: "", description: "", provider: .claude)
        let first = try store.enqueueQueuedFollowUp(
            BotQueuedFollowUpRecord(botID: bot.id, text: "one", payloadJSON: "{\"n\":1}")
        )
        _ = try store.enqueueQueuedFollowUp(
            BotQueuedFollowUpRecord(botID: bot.id, text: "two")
        )
        XCTAssertEqual(try store.listQueuedFollowUps(botID: bot.id).map(\.text), ["one", "two"])
        XCTAssertEqual(first.sortOrder, 0)
        let drained = try store.dequeueQueuedFollowUp(botID: bot.id)
        XCTAssertEqual(drained?.text, "one")
        XCTAssertEqual(try store.listQueuedFollowUps(botID: bot.id).map(\.text), ["two"])
        try store.replaceQueuedFollowUps(
            botID: bot.id,
            items: [BotQueuedFollowUpRecord(botID: bot.id, text: "kept")]
        )
        XCTAssertEqual(try store.listQueuedFollowUps(botID: bot.id).map(\.text), ["kept"])
        try store.delete(id: bot.id)
        XCTAssertTrue(try store.listQueuedFollowUps(botID: bot.id).isEmpty)
    }

    func test_listCached_servesRepeatReadsWithoutRequery_becauseBodiesMustNotHitSQLitePerKeystroke() throws {
        // WHY (perf AA-01): the transcript body and every composer keystroke read
        // the mentionable-bot catalog; that read used to be a synchronous SQLite
        // list() behind the stream-persist writer, so typing hitched during runs.
        // The cached read must not re-query while no bot write happened and must
        // refresh after every bot write.
        let piper = try store.create(name: "Piper", title: "Scout", description: "", handle: "piper")
        let quinn = try store.create(name: "Quinn", title: "CRM", description: "", handle: "quinn")

        let first = try store.listCached()
        XCTAssertEqual(Set(first.map(\.id)), Set([piper.id, quinn.id]))
        XCTAssertEqual(
            store.listQueryCountForTesting, 1,
            "the first cached read performs exactly one SQLite list()"
        )

        for _ in 0..<30 { _ = try store.listCached() }
        XCTAssertEqual(
            store.listQueryCountForTesting, 1,
            "30 body passes / keystrokes with no bot write must be served from memory (0 re-queries)"
        )

        let rio = try store.create(name: "Rio", title: "Ops", description: "", handle: "rio")
        let second = try store.listCached()
        XCTAssertEqual(store.listQueryCountForTesting, 2, "a bot write bumps the revision and forces one re-query")
        XCTAssertTrue(
            second.contains { $0.id == rio.id },
            "a bot created after the cache must appear on the next read (the cache must not pin stale data)"
        )

        try store.setHidden(id: rio.id, hidden: true)
        XCTAssertFalse(
            try store.listCached().contains { $0.id == rio.id },
            "hiding a bot must refresh the cached visible list"
        )
        XCTAssertEqual(store.listQueryCountForTesting, 3)

        try store.delete(id: quinn.id)
        XCTAssertFalse(
            try store.listCached().contains { $0.id == quinn.id },
            "deleting a bot must refresh the cached visible list"
        )
        XCTAssertEqual(store.listQueryCountForTesting, 4)
    }

    func test_listCached_coversProfileRenameAndDuplicate_becauseEveryCatalogWriteInvalidates() throws {
        // WHY (perf AA-01): a stale mention catalog after a rename/duplicate would
        // surface outdated handles in @autocomplete; every bot-definition write
        // path must bump the revision.
        let piper = try store.create(name: "Piper", title: "Scout", description: "", handle: "piper")
        _ = try store.listCached()

        _ = try store.updateProfile(id: piper.id, name: "Piper II", title: "Scout", description: "")
        let renamed = try store.listCached()
        XCTAssertEqual(renamed.first { $0.id == piper.id }?.name, "Piper II")

        _ = try store.renameHandle(id: piper.id, handle: "piperprime")
        XCTAssertEqual(try store.listCached().first { $0.id == piper.id }?.handle, "piperprime")

        _ = try store.duplicate(id: piper.id)
        XCTAssertEqual(try store.listCached().count, 2, "a duplicated bot must appear on the next cached read")

        try store.setPinned(id: piper.id, pinned: true)
        _ = try store.listCached()
        // Pinning does not change membership; it only proves the write path still refreshes.
        XCTAssertEqual(try store.listCached().count, 2)
    }

    func test_reorder_writesIndexForListedAndKeepsUnlistedAfterInRelativeOrder_becauseDragOrderMustPersist() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func make(_ name: String, _ offset: TimeInterval) throws -> BotDefinition {
            try store.create(name: name, title: "t", description: "d", handle: name.lowercased(), soul: "s",
                             provider: .claude, model: "opus", now: t0.addingTimeInterval(offset))
        }
        let a = try make("Aaa", 0), b = try make("Bbb", 10), c = try make("Ccc", 20), d = try make("Ddd", 30)
        XCTAssertNil(try store.get(id: a.id)?.sortOrder, "never-ordered bots have no sort_order")

        try store.reorder(orderedIDs: [c.id, a.id])

        XCTAssertEqual(try store.get(id: c.id)?.sortOrder, 0)
        XCTAssertEqual(try store.get(id: a.id)?.sortOrder, 1)
        // Unlisted keep relative (newest-first) order after the listed ones.
        XCTAssertEqual(try store.get(id: d.id)?.sortOrder, 2)
        XCTAssertEqual(try store.get(id: b.id)?.sortOrder, 3)
        XCTAssertEqual(BotOrdering.sorted(try store.list()).map(\.id), [c.id, a.id, d.id, b.id])

        XCTAssertThrowsError(try store.reorder(orderedIDs: [BotID()]), "unknown id must not silently reorder")
        XCTAssertEqual(try store.get(id: c.id)?.sortOrder, 0)
    }

    func test_migrationAddsBotSortOrderColumnAtV99_becauseOldDatabasesMustUpgrade() throws {
        XCTAssertEqual(Schema.botSortOrderSchemaVersion, 99)
        XCTAssertEqual(Schema.steps.last?.version, Schema.currentVersion)
        let statement = try db.prepare("PRAGMA table_info(bots);")
        defer { statement.reset() }
        var columns: [String: String] = [:]
        while try statement.step() { columns[statement.columnText(1) ?? ""] = statement.columnText(2) }
        XCTAssertEqual(columns["sort_order"], "INTEGER")
    }
}
