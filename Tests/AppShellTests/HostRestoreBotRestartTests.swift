import XCTest
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

@MainActor
final class HostRestoreBotRestartTests: XCTestCase {

    private struct RetainedQueue: Codable {
        let botID: BotID
        let queueID: String
        let conversationID: String
        let body: String
        let attemptRunID: AgentRunID
    }

    private func waitForFailure(context: AppContext, queueID: String) async throws -> AgentRunID {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let attempt = try HostDatabaseRestore.queueAttempt(kind: .bot, id: queueID, db: context.db),
               try context.runRepo.get(id: attempt)?.status == .failed,
               try HostDatabaseRestore.requiresQueueReview(kind: .bot, id: queueID, db: context.db) {
                return attempt
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw SQLiteError.execute("Bot Force did not persist failed attempt")
    }

    private func seedFailedAttempt(appSupport: String) async throws -> RetainedQueue {
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            privateAccountAPI: SilentWakeRecordingAPI(),
            performLaunchRunReconciliation: false
        )
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = FailingBotQueueRunner()
        context.coordinator.replaceProvider(.distill, runner: runner)
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [AgentModelDescriptor(id: "test", label: "Test", provider: .distill)],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "distill-acp"
        )
        router.rememberProviderSnapshotsForSend([snapshot])
        router.preflightListedProviderSnapshotsForTesting = false
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        vm.replaceProvidersForTests([snapshot])

        let bot = try context.botStore.create(name: "Restart proof", title: "", description: "", soul: "", provider: .distill, model: "test", desktopKind: .logicalExecutionSpace)
        let botID = bot.id
        let thread = AgentThread(title: "Restart queue", provider: .distill, model: "test")
        try context.threadRepo.upsert(thread)
        XCTAssertTrue(try context.threadRepo.setActor(id: thread.id, actor: .bot(botID), lockedAt: Date(), executionTarget: .mac))
        let conversation = BotConversation(botID: botID, title: "Restart queue", linkedAgentThreadID: thread.id)
        try context.botStore.upsertConversation(conversation)
        vm.openDesk(bot)
        let body = "Failed attempt must remain held after restart"
        let queued = try context.botStore.enqueueQueuedFollowUp(BotQueuedFollowUpRecord(
            botID: botID,
            conversationID: conversation.id.value.uuidString.lowercased(),
            text: body
        ))
        let force = try await router.dispatchPairedBotRemote(method: "bot.queue.force_now", params: [
            "client_request_id": .string(UUID().uuidString.lowercased()),
            "host_id": .string("restart-host"),
            "bot_id": .string(botID.value.uuidString.lowercased()),
            "id": .string(queued.id),
        ])
        XCTAssertEqual(force.objectValue?["readback"]?.objectValue?[
            "force_status"]?.stringValue, "queued")

        let attempt = try await waitForFailure(context: context, queueID: queued.id)
        XCTAssertEqual(runner.startCount, 1)
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .bot, id: queued.id, db: context.db))
        XCTAssertEqual(try context.botStore.listQueuedFollowUps(botID: botID).map(\.id), [queued.id])
        return RetainedQueue(
            botID: botID,
            queueID: queued.id,
            conversationID: conversation.id.value.uuidString.lowercased(),
            body: body,
            attemptRunID: attempt
        )
    }

    func test_childPersistFailedAttempt() async throws {
        guard let appSupport = ProcessInfo.processInfo.environment["RC_BOT_QUEUE_RESTART_SUPPORT"] else {
            throw XCTSkip("child-process restart fixture only")
        }
        let retained = try await seedFailedAttempt(appSupport: appSupport)
        try JSONEncoder().encode(retained).write(to: URL(fileURLWithPath: appSupport).appendingPathComponent("retained.json"))
    }

    func testReopenHoldsFailedBotAttemptAndForceDoesNotStartProvider() async throws {
        let appSupport = NSTemporaryDirectory() + "rc-host-restore-bot-restart-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let logURL = URL(fileURLWithPath: appSupport).appendingPathComponent("child.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "AppShellTests.HostRestoreBotRestartTests/test_childPersistFailedAttempt", Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["RC_BOT_QUEUE_RESTART_SUPPORT"] = appSupport
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + 60) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
            XCTFail("restart fixture process exceeded 60 seconds")
            return
        }
        guard process.terminationStatus == 0 else {
            XCTFail("restart fixture failed: \(try String(contentsOf: logURL, encoding: .utf8))")
            return
        }
        let retained = try JSONDecoder().decode(RetainedQueue.self, from: Data(contentsOf: URL(fileURLWithPath: appSupport).appendingPathComponent("retained.json")))
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            privateAccountAPI: SilentWakeRecordingAPI(),
            performLaunchRunReconciliation: false
        )
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = FailingBotQueueRunner()
        context.coordinator.replaceProvider(.distill, runner: runner)
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        defer { withExtendedLifetime(vm) {} }

        let queued = try XCTUnwrap(context.botStore.listQueuedFollowUps(botID: retained.botID).first)
        XCTAssertEqual(queued.id, retained.queueID)
        XCTAssertEqual(queued.conversationID, retained.conversationID)
        XCTAssertEqual(queued.text, retained.body)
        XCTAssertEqual(try HostDatabaseRestore.queueAttempt(kind: .bot, id: retained.queueID, db: context.db), retained.attemptRunID)
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .bot, id: retained.queueID, db: context.db))
        XCTAssertEqual(try context.runRepo.get(id: retained.attemptRunID)?.status, .failed)

        do {
            let unexpected = try await router.dispatchPairedBotRemote(method: "bot.queue.force_now", params: [
                "client_request_id": .string(UUID().uuidString.lowercased()),
                "host_id": .string("restart-host"),
                "bot_id": .string(retained.botID.value.uuidString.lowercased()),
                "id": .string(retained.queueID),
            ])
            XCTFail("known failed Bot attempt must not be retried after AppContext reopen: \(unexpected)")
        } catch {
            XCTAssertTrue(String(describing: error).contains("requires reconciliation"))
        }
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .bot, id: retained.queueID, db: context.db))
        XCTAssertEqual(try HostDatabaseRestore.queueAttempt(kind: .bot, id: retained.queueID, db: context.db), retained.attemptRunID)
        XCTAssertEqual(runner.startCount, 0, "rejected known attempt must not start provider again")
    }
}

private final class FailingBotQueueRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .distill
    private let lock = NSLock()
    private var starts = 0

    var startCount: Int { lock.withLock { starts } }
    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        lock.withLock { starts += 1 }
        throw AgentRunError.spawnFailed("intentional Bot queue start failure")
    }
}
