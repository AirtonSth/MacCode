import XCTest
import CoreModel
@testable import Persistence

final class BotConversationContextTests: XCTestCase {
    private func makeStore() throws -> (SQLiteDB, BotStore, BotDefinition) {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let bot = try store.create(name: "Context bot", title: "Context", description: "", handle: "context-bot", soul: "", provider: .claude, model: "opus")
        return (db, store, bot)
    }

    func test_pinIsImmutableAndRevalidatedAgainstCurrentBinding() throws {
        let (db, store, bot) = try makeStore()
        let context = BotContext.general
        let binding = try store.grantContext(hostID: "host", botID: bot.id, context: context, actions: [.read, .send], expectedRevision: nil)
        let threadID = AgentThreadID()
        let conversation = BotConversation(botID: bot.id, title: "Pinned", linkedAgentThreadID: threadID)
        let pin = try store.createContextualConversation(conversation, hostID: "host", context: context, policyRevision: binding.policyRevision)

        XCTAssertEqual(try store.conversationContextPin(linkedTo: threadID), pin)
        XCTAssertTrue(try store.authorizesConversation(conversation, hostID: "host", action: .send))
        XCTAssertFalse(try store.authorizesConversation(conversation, hostID: "other-host", action: .send))
        XCTAssertThrowsError(try store.createContextualConversation(conversation, hostID: "host", context: context, policyRevision: binding.policyRevision))
        var updated = conversation
        updated.title = "Renamed"
        updated.unread = true
        try store.upsertConversation(updated)
        XCTAssertEqual(try store.conversation(id: conversation.id)?.title, "Renamed")
        XCTAssertEqual(try store.conversationContextPin(linkedTo: threadID), pin)

        let moved = BotConversation(id: conversation.id, botID: bot.id, title: "Moved", linkedAgentThreadID: AgentThreadID())
        XCTAssertThrowsError(try store.upsertConversation(moved))
        let stolen = BotConversation(botID: bot.id, title: "Steals pinned thread", linkedAgentThreadID: threadID)
        XCTAssertThrowsError(try store.upsertConversation(stolen))
        let stealUpdate = BotConversation(id: BotConversationID(), botID: bot.id, title: "legacy", linkedAgentThreadID: nil)
        try store.upsertConversation(stealUpdate)
        let stealChanged = BotConversation(id: stealUpdate.id, botID: bot.id, title: "legacy", linkedAgentThreadID: threadID)
        XCTAssertThrowsError(try store.upsertConversation(stealChanged))

        _ = try store.revokeContext(hostID: "host", botID: bot.id, context: context, expectedRevision: binding.policyRevision)
        XCTAssertFalse(try store.authorizesConversation(conversation, hostID: "host", action: .send))
        XCTAssertEqual(try BotStore(db: db).conversationContextPin(conversationID: conversation.id), pin)
    }

    func test_newThreadAndConversationAreAtomicallyPinned() throws {
        let (_, store, bot) = try makeStore()
        let workspace = WorkspaceID()
        let context = BotContext.workspace(workspace)
        let grant = try store.grantContext(hostID: "host", botID: bot.id, context: context, actions: [.read], expectedRevision: nil)
        let threadID = AgentThreadID()
        let conversation = BotConversation(botID: bot.id, title: "Fresh", linkedAgentThreadID: threadID)
        let thread = AgentThread(id: threadID, workspaceId: workspace, title: "Fresh", provider: .distill, model: "distill")

        let pin = try store.createContextualConversation(conversation, newThread: thread, hostID: "host", context: context, policyRevision: grant.policyRevision)

        XCTAssertEqual(try store.conversationContextPin(linkedTo: threadID), pin)
        let stored = try XCTUnwrap(AgentThreadRepository(db: store.db).get(id: threadID))
        XCTAssertEqual(stored.actor, .bot(bot.id))
        XCTAssertNotNil(stored.actorLockedAt)
        XCTAssertEqual(stored.executionTarget, .vm)
        XCTAssertEqual(try AgentThreadRepository(db: store.db).guestPlacement(of: threadID)?.guestRuntime, BotGuestRuntime.distillV1)
        XCTAssertNil(stored.providerThreadId)
    }

    func test_freshThreadValidationRejectsMismatchesAndStoredRows() throws {
        let (db, store, bot) = try makeStore()
        let workspace = WorkspaceID()
        let context = BotContext.workspace(workspace)
        let grant = try store.grantContext(hostID: "host", botID: bot.id, context: context, actions: [.read], expectedRevision: nil)
        let invalidThreads = [
            AgentThread(workspaceId: nil, title: "Wrong workspace", provider: .distill, model: "distill"),
            AgentThread(workspaceId: workspace, title: "Wrong actor", provider: .distill, model: "distill", actor: .bot(bot.id)),
            AgentThread(workspaceId: workspace, title: "Wrong provider", provider: .claude, model: "claude"),
            AgentThread(workspaceId: workspace, title: "Existing session", provider: .distill, model: "distill", providerThreadId: "session")
        ]
        for thread in invalidThreads {
            let conversation = BotConversation(botID: bot.id, title: thread.title, linkedAgentThreadID: thread.id)
            XCTAssertThrowsError(try store.createContextualConversation(conversation, newThread: thread, hostID: "host", context: context, policyRevision: grant.policyRevision))
            XCTAssertNil(try store.conversation(id: conversation.id))
            XCTAssertNil(try AgentThreadRepository(db: db).get(id: thread.id))
            XCTAssertNil(store.cachedBotID(linkedTo: thread.id))
        }

        let generalThread = AgentThread(workspaceId: workspace, title: "General context mismatch", provider: .distill, model: "distill")
        let generalConversation = BotConversation(botID: bot.id, title: "General context mismatch", linkedAgentThreadID: generalThread.id)
        let generalGrant = try store.grantContext(hostID: "host", botID: bot.id, context: .general, actions: [.read], expectedRevision: nil)
        XCTAssertThrowsError(try store.createContextualConversation(generalConversation, newThread: generalThread, hostID: "host", context: .general, policyRevision: generalGrant.policyRevision))

        let storedThread = AgentThread(workspaceId: workspace, title: "Already stored empty", provider: .distill, model: "distill")
        try AgentThreadRepository(db: db).upsert(storedThread)
        let storedConversation = BotConversation(botID: bot.id, title: "Stored row", linkedAgentThreadID: storedThread.id)
        XCTAssertThrowsError(try store.createContextualConversation(storedConversation, newThread: storedThread, hostID: "host", context: context, policyRevision: grant.policyRevision))
        XCTAssertNil(try store.conversation(id: storedConversation.id))
        XCTAssertEqual(try AgentThreadRepository(db: db).get(id: storedThread.id)?.id, storedThread.id)
        XCTAssertEqual(try AgentThreadRepository(db: db).get(id: storedThread.id)?.title, storedThread.title)
    }

    func test_legacyLinkedThreadCannotBePinnedAndNoNewConversationIsInserted() throws {
        let (_, store, bot) = try makeStore()
        let threadID = AgentThreadID()
        let legacy = BotConversation(botID: bot.id, title: "Legacy", linkedAgentThreadID: threadID)
        try store.upsertConversation(legacy)
        let grant = try store.grantContext(hostID: "host", botID: bot.id, context: .general, actions: [.read], expectedRevision: nil)
        let contextual = BotConversation(botID: bot.id, title: "Should fail", linkedAgentThreadID: threadID)
        XCTAssertThrowsError(try store.createContextualConversation(contextual, hostID: "host", context: .general, policyRevision: grant.policyRevision))
        XCTAssertNil(try store.conversation(id: contextual.id))
        XCTAssertNil(try store.conversationContextPin(linkedTo: threadID))
    }

    func test_twoWorkspaceContextsCreateDistinctCanonicalConversations() throws {
        let (_, store, bot) = try makeStore()
        let workspaceIDA = WorkspaceID()
        let workspaceIDB = WorkspaceID()
        let workspaceA = BotContext.workspace(workspaceIDA)
        let workspaceB = BotContext.workspace(workspaceIDB)
        let grantA = try store.grantContext(hostID: "host", botID: bot.id, context: workspaceA, actions: [.read], expectedRevision: nil)
        let grantB = try store.grantContext(hostID: "host", botID: bot.id, context: workspaceB, actions: [.read], expectedRevision: nil)
        let threadA = AgentThread(workspaceId: workspaceIDA, title: "A", provider: .distill, model: "distill")
        let threadB = AgentThread(workspaceId: workspaceIDB, title: "B", provider: .distill, model: "distill")
        let first = BotConversation(botID: bot.id, title: "A", linkedAgentThreadID: threadA.id)
        let second = BotConversation(botID: bot.id, title: "B", linkedAgentThreadID: threadB.id)
        let pinA = try store.createContextualConversation(first, newThread: threadA, hostID: "host", context: workspaceA, policyRevision: grantA.policyRevision)
        let pinB = try store.createContextualConversation(second, newThread: threadB, hostID: "host", context: workspaceB, policyRevision: grantB.policyRevision)
        XCTAssertNotEqual(pinA.conversationID, pinB.conversationID)
        XCTAssertEqual(try store.conversationContextPin(linkedTo: try XCTUnwrap(first.linkedAgentThreadID)), pinA)
        XCTAssertEqual(try store.conversationContextPin(linkedTo: try XCTUnwrap(second.linkedAgentThreadID)), pinB)
    }

    func test_unsupportedAndFractionalPinValuesFailClosed() throws {
        let (db, store, bot) = try makeStore()
        let grant = try store.grantContext(hostID: "host", botID: bot.id, context: .general, actions: [.read], expectedRevision: nil)
        let conversation = BotConversation(botID: bot.id, title: "Pinned", linkedAgentThreadID: AgentThreadID())
        _ = try store.createContextualConversation(conversation, hostID: "host", context: .general, policyRevision: grant.policyRevision)
        try db.execute("DROP TRIGGER bot_conversation_contexts_immutable;")
        try db.execute("PRAGMA ignore_check_constraints=ON;")
        let corrupt = try db.prepare("UPDATE bot_conversation_contexts SET context_version=1.5 WHERE conversation_id=?;")
        try corrupt.bind(1, conversation.id.value.uuidString.lowercased())
        _ = try corrupt.step()
        XCTAssertThrowsError(try store.conversationContextPin(conversationID: conversation.id))
        let corruptRevision = try db.prepare("UPDATE bot_conversation_contexts SET context_version=1, policy_revision=1.5 WHERE conversation_id=?;")
        try corruptRevision.bind(1, conversation.id.value.uuidString.lowercased())
        _ = try corruptRevision.step()
        XCTAssertThrowsError(try store.conversationContextPin(conversationID: conversation.id))
    }

    func test_failedPinInsertRollsBackConversationAndNewCacheEntry() throws {
        let (db, store, bot) = try makeStore()
        let grant = try store.grantContext(hostID: "host", botID: bot.id, context: .general, actions: [.read], expectedRevision: nil)
        let threadID = AgentThreadID()
        let conversation = BotConversation(botID: bot.id, title: "Rollback", linkedAgentThreadID: threadID)
        let thread = AgentThread(id: threadID, title: "Rollback", provider: .distill, model: "distill")
        let existingID = AgentThreadID()
        let existingConversation = BotConversation(botID: bot.id, title: "Existing", linkedAgentThreadID: existingID)
        try store.upsertConversation(existingConversation)
        try db.execute("CREATE TRIGGER reject_test_pin BEFORE INSERT ON bot_conversation_contexts BEGIN SELECT RAISE(ABORT, 'test rejection'); END;")
        XCTAssertThrowsError(try store.createContextualConversation(conversation, newThread: thread, hostID: "host", context: .general, policyRevision: grant.policyRevision))
        XCTAssertNil(try store.conversation(id: conversation.id))
        XCTAssertNil(try AgentThreadRepository(db: db).get(id: threadID))
        XCTAssertNil(store.cachedBotID(linkedTo: threadID))
        XCTAssertEqual(try store.conversation(id: existingConversation.id)?.id, existingConversation.id)
        XCTAssertEqual(try store.conversation(id: existingConversation.id)?.title, existingConversation.title)
        XCTAssertEqual(store.cachedBotID(linkedTo: existingID), bot.id)
    }

    func test_pinAndConversationSurviveFileBackedReopen() throws {
        let path = NSTemporaryDirectory().appending("BotConversationContext-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let botID: BotID
        let conversation: BotConversation
        let pin: BotConversationContextPin
        let thread: AgentThread
        do {
            let db = try SQLiteDB(path: path)
            try Schema.migrate(db)
            let store = BotStore(db: db)
            let bot = try store.create(name: "Context bot", title: "Context", description: "", handle: "context-bot", soul: "", provider: .claude, model: "opus")
            botID = bot.id
            let context = BotContext.general
            let grant = try store.grantContext(hostID: "host", botID: bot.id, context: context, actions: [.read], expectedRevision: nil)
            thread = AgentThread(title: "History", provider: .distill, model: "distill")
            conversation = BotConversation(botID: bot.id, title: "History", linkedAgentThreadID: thread.id, createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200))
            pin = try store.createContextualConversation(conversation, newThread: thread, hostID: "host", context: context, policyRevision: grant.policyRevision)
        }
        let reopenedDB = try SQLiteDB(path: path)
        try Schema.migrate(reopenedDB)
        let reopenedStore = BotStore(db: reopenedDB)
        XCTAssertEqual(try reopenedStore.get(id: botID)?.id, botID)
        XCTAssertEqual(try reopenedStore.conversation(id: conversation.id), conversation)
        XCTAssertEqual(try reopenedStore.conversationContextPin(conversationID: conversation.id), pin)
        XCTAssertEqual(try reopenedStore.conversationContextPin(linkedTo: try XCTUnwrap(conversation.linkedAgentThreadID)), pin)
        XCTAssertEqual(try AgentThreadRepository(db: reopenedDB).get(id: thread.id)?.id, thread.id)
    }

    func test_legacyConversationHasNoPinAndUnsupportedVersionFailsClosed() throws {
        let (db, store, bot) = try makeStore()
        let legacy = BotConversation(botID: bot.id, title: "Legacy", linkedAgentThreadID: AgentThreadID())
        try store.upsertConversation(legacy)
        XCTAssertNil(try store.conversationContextPin(linkedTo: try XCTUnwrap(legacy.linkedAgentThreadID)))
        let grant = try store.grantContext(hostID: "host", botID: bot.id, context: .general, actions: [.read], expectedRevision: nil)
        let pinned = BotConversation(botID: bot.id, title: "Pinned", linkedAgentThreadID: AgentThreadID())
        _ = try store.createContextualConversation(pinned, hostID: "host", context: .general, policyRevision: grant.policyRevision)
        try db.execute("DROP TRIGGER bot_conversation_contexts_immutable;")
        let tamper = try db.prepare("UPDATE bot_conversation_contexts SET context_version=999 WHERE conversation_id=?;")
        try tamper.bind(1, pinned.id.value.uuidString.lowercased())
        _ = try tamper.step()
        XCTAssertThrowsError(try store.conversationContextPin(conversationID: pinned.id))
    }

    func test_creationRequiresCurrentReadBindingAndLeavesNoConversationOnFailure() throws {
        let (_, store, bot) = try makeStore()
        let conversation = BotConversation(botID: bot.id, title: "Denied", linkedAgentThreadID: AgentThreadID())
        XCTAssertThrowsError(try store.createContextualConversation(conversation, hostID: "host", context: .general, policyRevision: 1))
        XCTAssertNil(try store.conversation(id: conversation.id))
    }
}
