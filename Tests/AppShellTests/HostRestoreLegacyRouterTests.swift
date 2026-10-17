import XCTest
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

@MainActor
final class HostRestoreLegacyRouterTests: XCTestCase {
    private struct Fixture: Decodable {
        let botA: BotID
        let botB: BotID
        let agentThread: AgentThreadID
        let botThread: AgentThreadID
        let conversation: BotConversationID
        let agentQueue: AgentQueuedMessageID
        let knownQueue: AgentQueuedMessageID
        let botQueue: String
        let stoppedRun: AgentRunID
        let importedRun: AgentRunID
    }

    private func wait(_ condition: () throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try condition()
    }

    func testRealRestoredQueuesStayHeldUntilExactExplicitForceWithoutRevivingKnownRun() async throws {
        guard ProcessInfo.processInfo.environment["RC_HOST_RESTORE_LEGACY_VERIFY"] == "1",
              let path = ProcessInfo.processInfo.environment["RC_HOST_RESTORE_LEGACY_FIXTURE_ROOT"] else {
            throw XCTSkip("set isolated legacy restored-host fixture")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard root.path.contains("/.sandbox-worktrees/"), root.path.contains("/.sandbox-state/host-legacy-") else {
            throw SQLiteError.open("legacy router verification requires an isolated fixture")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
        let defaults = UserDefaults.standard
        let oldDefaults = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("bots.") }
        defer {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("bots.") && oldDefaults[key] == nil {
                defaults.removeObject(forKey: key)
            }
            for (key, value) in oldDefaults { defaults.set(value, forKey: key) }
        }
        let context = try AppContext(channel: .debug, dbPathOverride: root.appendingPathComponent("current.sqlite").path,
                                     appSupportOverride: root.appendingPathComponent("app-support").path,
                                     privateAccountAPI: SilentWakeRecordingAPI(), performLaunchRunReconciliation: false)
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .distill)
        defer {
            for request in runner.requests { runner.finish(runID: request.runId, status: .cancelled, reply: nil) }
        }
        context.coordinator.replaceProvider(.distill, runner: runner)
        let snapshot = AgentProviderSnapshotFactory.snapshot(provider: .distill,
            models: [AgentModelDescriptor(id: "test", label: "Test", provider: .distill)],
            binaryPath: "/usr/bin/true", authenticated: true, id: "distill-acp")
        router.rememberProviderSnapshotsForSend([snapshot])
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        vm.replaceProvidersForTests([snapshot])
        let bot = try XCTUnwrap(context.botStore.get(id: fixture.botB))
        vm.openDesk(bot)
        vm.composerText = "Keep manual draft"
        let beforeAgent = try context.queuedMessageRepo.list(threadId: fixture.agentThread)
        let beforeBot = try context.botStore.listQueuedFollowUps(botID: fixture.botB)
        for _ in 0..<2 {
            try await router.drainNextQueuedAgentMessage(thread: fixture.agentThread, recoverPreparedFromPriorProcess: true)
            await router.reconcileQueuedAgentMessagesOnLaunch()
            vm.openDesk(bot)
        }
        vm.adoptLinkedRunTerminalForTests(runId: fixture.importedRun, threadId: fixture.botThread)
        let followThroughAfterFirst = vm.followThroughApplyCountForTesting
        XCTAssertGreaterThan(followThroughAfterFirst, 0)
        vm.adoptLinkedRunTerminalForTests(runId: fixture.importedRun, threadId: fixture.botThread)
        XCTAssertEqual(vm.followThroughApplyCountForTesting, followThroughAfterFirst)
        await Task.yield()
        XCTAssertTrue(runner.requests.isEmpty)
        XCTAssertEqual(vm.composerText, "Keep manual draft")
        XCTAssertEqual(try context.queuedMessageRepo.list(threadId: fixture.agentThread), beforeAgent)
        XCTAssertEqual(try context.botStore.listQueuedFollowUps(botID: fixture.botB), beforeBot)
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .agent, id: fixture.agentQueue.value.uuidString, db: context.db))
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .bot, id: fixture.botQueue, db: context.db))

        let sent = try await router.forceAgentQueuedMessageNow(id: fixture.agentQueue)
        XCTAssertEqual(sent.status, .started)
        let firstStarted = try await wait { runner.requests.count == 1 }
        XCTAssertTrue(firstStarted)
        let first = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(first.threadId, fixture.agentThread)
        XCTAssertTrue(first.prompt.contains("LEGACY_AGENT_QUEUE_PRIVATE"))
        XCTAssertFalse(try HostDatabaseRestore.requiresQueueReview(kind: .agent, id: fixture.agentQueue.value.uuidString, db: context.db))
        runner.finish(runID: first.runId, status: .completed, reply: "Reviewed Agent queue")
        let firstFinished = try await wait { context.coordinator.activeRunId(threadId: fixture.agentThread) == nil }
        XCTAssertTrue(firstFinished)
        try await router.drainNextQueuedAgentMessage(thread: fixture.agentThread, recoverPreparedFromPriorProcess: true)
        do {
            _ = try await router.forceAgentQueuedMessageNow(id: fixture.knownQueue)
            XCTFail("an old known outcome must never be started again")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, -32602)
        }
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .agent, id: fixture.knownQueue.value.uuidString, db: context.db))
        XCTAssertEqual(try context.runRepo.get(id: AgentRunID(fixture.knownQueue.value))?.status, .cancelled)
        XCTAssertEqual(runner.requests.count, 1)

        let queueUpdate = expectation(description: "committed queue acknowledgement publishes botQueueUpdated")
        let eventCursor = EventBus.shared.currentSeq
        let eventSubscription = EventBus.shared.subscribe(since: eventCursor) { event in
            guard event.knownKind == .botQueueUpdated,
                  case .object(let payload) = event.payload,
                  payload["bot_id"]?.stringValue == fixture.botB.value.uuidString.lowercased() else { return }
            queueUpdate.fulfill()
        }
        defer { EventBus.shared.unsubscribe(eventSubscription) }
        let forced = try await router.dispatchPairedBotRemote(method: "bot.queue.force_now", params: [
            "client_request_id": .string(UUID().uuidString.lowercased()),
            "host_id": .string("legacy-host"),
            "bot_id": .string(fixture.botB.value.uuidString.lowercased()),
            "id": .string(fixture.botQueue),
        ])
        XCTAssertEqual(forced.objectValue?["readback"]?.objectValue?["force_status"]?.stringValue, "queued")
        XCTAssertEqual(try context.botStore.listQueuedFollowUps(botID: fixture.botB).map(\.id), [fixture.botQueue])
        let secondStarted = try await wait { runner.requests.count == 2 }
        XCTAssertTrue(secondStarted)
        let second = try XCTUnwrap(runner.requests.last)
        XCTAssertEqual(second.threadId, fixture.botThread)
        XCTAssertTrue(second.prompt.contains("LEGACY_BOT_QUEUE_PRIVATE"))
        XCTAssertEqual(vm.composerText, "Keep manual draft")
        XCTAssertFalse(try HostDatabaseRestore.requiresQueueReview(kind: .bot, id: fixture.botQueue, db: context.db))
        await fulfillment(of: [queueUpdate], timeout: 5)
        runner.finish(runID: second.runId, status: .completed, reply: "Reviewed Bot queue")
        let secondFinished = try await wait { context.coordinator.activeRunId(threadId: fixture.botThread) == nil }
        XCTAssertTrue(secondFinished)
        vm.openDesk(bot)
        XCTAssertEqual(runner.requests.count, 2)

        let rejectedQueue = try context.botStore.enqueueQueuedFollowUp(BotQueuedFollowUpRecord(
            botID: fixture.botB,
            conversationID: fixture.conversation.value.uuidString.lowercased(),
            text: "Rejected admission stays held"
        )).id
        try HostDatabaseRestore.pauseQueue(kind: .bot, id: rejectedQueue, db: context.db)
        vm.desktopKindOverrideForTesting = .dockerDesktop
        vm.dockerGuestReadyOverrideForTesting = false
        do {
            _ = try await router.dispatchPairedBotRemote(method: "bot.queue.force_now", params: [
                "client_request_id": .string(UUID().uuidString.lowercased()),
                "host_id": .string("legacy-host"),
                "bot_id": .string(fixture.botB.value.uuidString.lowercased()),
                "id": .string(rejectedQueue),
            ])
            XCTFail("unready desktop admission must reject force")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Docker desktop is not ready"))
        }
        vm.desktopKindOverrideForTesting = nil
        vm.dockerGuestReadyOverrideForTesting = nil
        XCTAssertTrue(try context.botStore.listQueuedFollowUps(botID: fixture.botB).contains { $0.id.lowercased() == rejectedQueue.lowercased() })
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .bot, id: rejectedQueue, db: context.db))

        let cancelledQueue = try context.botStore.enqueueQueuedFollowUp(BotQueuedFollowUpRecord(
            botID: fixture.botB,
            conversationID: fixture.conversation.value.uuidString.lowercased(),
            text: "Cancel before provider acceptance"
        )).id
        let stopped = expectation(description: "cancel reserved restored-queue start")
        vm.beforeBotRunDispatchForTesting = { _ in
            vm.stopLiveRuns(for: fixture.botB, force: true) { _ in stopped.fulfill() }
        }
        let cancelledForce = try await router.dispatchPairedBotRemote(method: "bot.queue.force_now", params: [
            "client_request_id": .string(UUID().uuidString.lowercased()),
            "host_id": .string("legacy-host"),
            "bot_id": .string(fixture.botB.value.uuidString.lowercased()),
            "id": .string(cancelledQueue),
        ])
        XCTAssertEqual(cancelledForce.objectValue?["readback"]?.objectValue?["force_status"]?.stringValue, "queued")
        await fulfillment(of: [stopped], timeout: 5)
        vm.beforeBotRunDispatchForTesting = nil
        XCTAssertEqual(runner.requests.count, 2, "cancellation before acceptance must not reach provider")
        XCTAssertTrue(try context.botStore.listQueuedFollowUps(botID: fixture.botB).contains { $0.id.lowercased() == cancelledQueue.lowercased() })
        XCTAssertTrue(try HostDatabaseRestore.requiresQueueReview(kind: .bot, id: cancelledQueue, db: context.db))
        let cancelledAttempt = try XCTUnwrap(HostDatabaseRestore.queueAttempt(kind: .bot, id: cancelledQueue, db: context.db))
        XCTAssertNil(try context.runRepo.get(id: cancelledAttempt), "Stop before dispatch must not fabricate a provider run")
        vm.openDesk(bot)
        await Task.yield()
        XCTAssertEqual(runner.requests.count, 2, "cancelled reservation must not automatically retry")
        XCTAssertTrue(try context.botStore.listQueuedFollowUps(botID: fixture.botB).contains { $0.id.lowercased() == cancelledQueue.lowercased() })
        XCTAssertEqual(try context.runRepo.get(id: fixture.stoppedRun)?.status, .cancelled)
        XCTAssertEqual(try context.runRepo.get(id: fixture.importedRun)?.status, .interrupted)
        XCTAssertEqual(try context.botStore.getContextBinding(hostID: "legacy-host", botID: fixture.botA, context: .general)?.state, .revoked)
        XCTAssertTrue(try context.botStore.listContextBindings(hostID: "legacy-host", botID: fixture.botB).isEmpty)
    }
}
