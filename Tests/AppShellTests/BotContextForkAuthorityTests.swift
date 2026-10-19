import XCTest
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

@MainActor
final class BotContextForkAuthorityTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let context: AppContext
        let router: AppCommandRouter
        let thread: AgentThread
        let bot: BotDefinition
        let conversation: BotConversation
        let host: String
        let revision: Int64
    }

    private struct Counts: Equatable {
        let threads: Int64
        let runs: Int64
        let messages: Int
        let queued: Int
        let intents: Int
    }

    private func scratchRoot(_ label: String) throws -> URL {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"])
        let root = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("ContextFork-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func makeContext(_ root: URL) throws -> AppContext {
        try AppContext(channel: .debug, dbPathOverride: root.appendingPathComponent("owned.sqlite").path,
            appSupportOverride: root.appendingPathComponent("support").path,
            privateAccountAPI: SilentWakeRecordingAPI(), performLaunchRunReconciliation: false,
            contextualSecretStore: InMemoryBotSecretStore())
    }

    private func fixture(_ label: String, existingThread: Bool = false, pinContext: Bool = true) throws -> Fixture {
        let root = try scratchRoot(label)
        let context = try makeContext(root)
        let router = AppCommandRouter(context: context)
        context.router = router
        let bot = try context.botStore.create(name: "Fork", title: "Fork", description: "", soul: "", provider: .distill, model: "test")
        let host = context.liveActivityHostIdentity.serverId
        let grant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: .general, actions: [.read, .send], expectedRevision: 0)
        var thread = AgentThread(title: "Pinned", provider: .distill, model: "test")
        thread.status = .completed
        let conversation = BotConversation(botID: bot.id, title: "Pinned", linkedAgentThreadID: thread.id)
        if existingThread {
            try context.threadRepo.upsert(thread)
            XCTAssertTrue(try context.threadRepo.lockActorIfUnlocked(id: thread.id, actor: .bot(bot.id), lockedAt: Date(), executionTarget: .vm))
            XCTAssertTrue(try context.threadRepo.setGuestRuntime(id: thread.id, BotGuestRuntime.distillV1))
            if pinContext {
                _ = try context.botStore.createContextualConversation(conversation, hostID: host, context: .general, policyRevision: grant.policyRevision)
            }
        } else {
            try context.botStore.createContextualConversation(conversation, newThread: thread, hostID: host, context: .general, policyRevision: grant.policyRevision)
        }
        return Fixture(root: root, context: context, router: router, thread: thread, bot: bot, conversation: conversation, host: host, revision: grant.policyRevision)
    }

    private func counts(_ context: AppContext, _ threadID: AgentThreadID) throws -> Counts {
        let query = try context.db.prepare("SELECT COUNT(*) FROM agent_threads;")
        defer { query.reset() }
        XCTAssertTrue(try query.step())
        let threads = query.columnInt64(0)
        let runQuery = try context.db.prepare("SELECT COUNT(*) FROM agent_runs WHERE thread_id = ? COLLATE NOCASE;")
        defer { runQuery.reset() }
        try runQuery.bind(1, threadID.value.uuidString)
        XCTAssertTrue(try runQuery.step())
        let runs = runQuery.columnInt64(0)
        let messages = try context.messageRepo.list(threadId: threadID).count
        let queued = try context.queuedMessageRepo.list(threadId: threadID).count
        let intentQuery = try context.db.prepare("SELECT COUNT(*) FROM agent_thread_fork_intents;")
        defer { intentQuery.reset() }
        XCTAssertTrue(try intentQuery.step())
        let intents = Int(intentQuery.columnInt64(0))
        return Counts(threads: threads, runs: Int64(runs), messages: messages, queued: queued, intents: intents)
    }

    private func assertRouterDenied(_ fixture: Fixture, message: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await fixture.router.forkAgentThread(sourceThreadId: fixture.thread.id, messageID: nil)
            XCTFail("fork must refuse contextual source", file: file, line: line)
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, -32602, file: file, line: line)
            XCTAssertTrue(error.message.contains(message), file: file, line: line)
        } catch {
            XCTFail("unexpected fork error: \(error)", file: file, line: line)
        }
        do {
            _ = try await fixture.router.sideAgentThread(sourceThreadId: fixture.thread.id, text: "side")
            XCTFail("side must refuse contextual source", file: file, line: line)
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, -32602, file: file, line: line)
            XCTAssertTrue(error.message.contains(message), file: file, line: line)
        } catch {
            XCTFail("unexpected side error: \(error)", file: file, line: line)
        }
    }

    func test_routerForkAndSideRejectActiveRevokedAndReopenedContextWithoutMutation() async throws {
        let f = try fixture("router")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try counts(f.context, f.thread.id)
        try await assertRouterDenied(f, message: "cannot be forked or continued")
        XCTAssertEqual(try counts(f.context, f.thread.id), before)
        _ = try f.context.botStore.revokeContext(hostID: f.host, botID: f.bot.id, context: .general, expectedRevision: f.revision)
        try await assertRouterDenied(f, message: "authority is inactive or invalid")
        XCTAssertEqual(try counts(f.context, f.thread.id), before)
        let reopened = try makeContext(f.root)
        let reopenedRouter = AppCommandRouter(context: reopened)
        reopened.router = reopenedRouter
        let reopenedFixture = Fixture(root: f.root, context: reopened, router: reopenedRouter, thread: f.thread, bot: f.bot, conversation: f.conversation, host: f.host, revision: f.revision)
        try await assertRouterDenied(reopenedFixture, message: "authority is inactive or invalid")
        XCTAssertEqual(try counts(reopened, f.thread.id), before)
        XCTAssertEqual(try reopened.botStore.conversationContextPin(linkedTo: f.thread.id), try f.context.botStore.conversationContextPin(linkedTo: f.thread.id))
    }

    func test_coordinatorAndDurablePrepareRejectPinnedSourceWithTypedError() async throws {
        for revoke in [false, true] {
            let f = try fixture("coordinator-\(revoke)")
            defer { try? FileManager.default.removeItem(at: f.root) }
            if revoke {
                _ = try f.context.botStore.revokeContext(hostID: f.host, botID: f.bot.id, context: .general, expectedRevision: f.revision)
            }
            let before = try counts(f.context, f.thread.id)
            do {
                _ = try await f.context.coordinator.forkThread(sourceThreadId: f.thread.id, childThread: AgentThread(title: "Child", provider: .distill, model: "test"))
                XCTFail("coordinator fork must reject contextual source")
            } catch let error as AgentThreadForkPersistenceError {
                XCTAssertEqual(error, .contextualSourceUnsupported)
            }
            XCTAssertThrowsError(try f.context.threadRepo.prepareForkIntent(sourceThreadId: f.thread.id, childThread: AgentThread(title: "Intent", provider: .distill, model: "test"), idempotencyKey: UUID().uuidString)) { error in
                XCTAssertEqual(error as? AgentThreadForkPersistenceError, .contextualSourceUnsupported)
            }
            XCTAssertThrowsError(try f.context.threadRepo.persistForkedChildGraph(sourceThreadId: f.thread.id,
                childThread: AgentThread(title: "Copied child", provider: .distill, model: "test"), providerSession: nil)) { error in
                XCTAssertEqual(error as? AgentThreadForkPersistenceError, .contextualSourceUnsupported)
            }
            XCTAssertEqual(try counts(f.context, f.thread.id), before)
            XCTAssertEqual(try f.context.botStore.conversationContextPin(linkedTo: f.thread.id)?.conversationID, f.conversation.id)
        }
    }

    func test_recoveryRetainsPreparedIntentWhenSourceBecomesPinnedAndRevoked() async throws {
        let f = try fixture("recovery", existingThread: true, pinContext: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        // This intent is durable setup from an ordinary unscoped source, not provider execution.
        let child = AgentThread(title: "Interrupted child", provider: .distill, model: "test")
        let intent = try f.context.threadRepo.prepareForkIntent(sourceThreadId: f.thread.id, childThread: child, idempotencyKey: "recovery-\(UUID())")
        _ = try f.context.botStore.createContextualConversation(f.conversation, hostID: f.host, context: .general, policyRevision: f.revision)
        let countsBeforeRecovery = try counts(f.context, f.thread.id)
        _ = try f.context.botStore.revokeContext(hostID: f.host, botID: f.bot.id, context: .general, expectedRevision: f.revision)
        let reopened = try makeContext(f.root)
        let reopenedCounts = try counts(reopened, f.thread.id)
        await reopened.coordinator.reconcileForkIntentsOnLaunch()
        let recovered = try XCTUnwrap(reopened.threadRepo.listRecoverableForkIntents().first { $0.childThread.id == child.id })
        XCTAssertEqual(recovered.state, intent.state)
        XCTAssertEqual(recovered.lastError, String(describing: AgentThreadForkPersistenceError.contextualSourceUnsupported))
        XCTAssertNil(try reopened.threadRepo.get(id: child.id))
        XCTAssertEqual(try counts(reopened, f.thread.id), reopenedCounts)
        XCTAssertEqual(reopenedCounts.threads, countsBeforeRecovery.threads)
        XCTAssertEqual(try reopened.botStore.conversationContextPin(linkedTo: f.thread.id)?.conversationID, f.conversation.id)
    }

    func test_unscopedLegacyPrepareForkIntentRemainsAllowed() throws {
        let root = try scratchRoot("legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeContext(root)
        var source = AgentThread(title: "Unscoped", provider: .distill, model: "test")
        source.status = .completed
        try context.threadRepo.upsert(source)
        let child = AgentThread(title: "Legacy child", provider: .distill, model: "test")
        let intent = try context.threadRepo.prepareForkIntent(sourceThreadId: source.id, childThread: child, idempotencyKey: "legacy-\(UUID())")
        XCTAssertEqual(intent.state, .prepared)
        XCTAssertEqual(try context.threadRepo.listRecoverableForkIntents().map(\.childThread.id), [child.id])
    }
}
