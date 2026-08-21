import XCTest
import CoreModel
@testable import Persistence

final class BotStoreTests: XCTestCase {
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
            "bot_skill_bindings", "bot_context_receipts",
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
        XCTAssertEqual(revision.permissionMode, .supervised)
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
            scheduleNote: BotRoutineCopy.testRunHonestyCaption
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

    func test_deleteRemovesConversationsAndRoutinesFromLiveRoster_butKeepsAttention() throws {
        let bot = try store.create(name: "Piper", title: "", description: "", provider: .claude)
        try store.upsertConversation(BotConversation(botID: bot.id, title: "Chat"))
        let routine = BotRoutineDefinition(botID: bot.id, name: "Ping", prompt: "Ping")
        try store.saveRoutine(routine)
        try store.upsertAttention(BotAttentionItem(botID: bot.id, kind: .handoff, title: "Need you"))

        try store.delete(id: bot.id)

        XCTAssertTrue(try store.listConversations(botID: bot.id).isEmpty)
        XCTAssertTrue(try store.listRoutines(botID: bot.id).isEmpty)
        XCTAssertEqual(try store.listAttention().map(\.title), ["Need you"])
    }

    func test_createWithoutHandleUniquesDerivedHandle_becauseRepeatedNewAgentMustNotCollide() throws {
        let first = try store.create(name: "New Agent", title: "", description: "", provider: .claude)
        let second = try store.create(name: "New Agent", title: "", description: "", provider: .claude)
        XCTAssertEqual(first.handle, "new-agent")
        XCTAssertEqual(second.handle, "new-agent-2")
    }
}
