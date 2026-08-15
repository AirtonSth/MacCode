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
            "bot_skill_bindings",
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
        XCTAssertEqual(revision.compatibleRouteSet, ["default"])
        XCTAssertEqual(revision.revisionNumber, 1)
        XCTAssertEqual(
            revision.digest,
            BotRevision.digest(botID: created.id, draft: BotRevisionDraft(
                name: "Piper",
                title: "Scout",
                description: "Looks around",
                soul: "Be brief.",
                provider: .claude,
                providerInstanceID: "claude",
                model: "opus",
                compatibleRouteSet: ["default"]
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
