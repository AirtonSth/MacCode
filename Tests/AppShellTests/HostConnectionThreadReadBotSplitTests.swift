import Combine
import XCTest
@testable import AppShell
@testable import AgentRuntime
@testable import CoreModel
@testable import Persistence
@testable import SocketServer

/// C5 (H2a/b): paired-device `agent.thread.read` v1 and `bot.*` reads leave the
/// main thread, and bot writes republish only the queue they changed.
///
/// WHY: every iPhone poll of a thread tail or a bot receipt used to run its
/// SQLite read on MainActor, behind the process-wide mirror lock, and every
/// bot poll rescanned and republished the whole fleet's queued follow-ups.
/// That froze the Mac UI and serialized all other RPCs for the read's length.
@MainActor
final class HostConnectionThreadReadBotSplitTests: XCTestCase {
    private func makeContext() throws -> AppContext {
        let dir = NSTemporaryDirectory() + "RC2HostC5-" + UUID().uuidString
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return try AppContext(channel: .debug, appSupportOverride: dir)
    }

    private func makeRouter(_ context: AppContext) -> AppCommandRouter {
        let router = AppCommandRouter(context: context)
        context.router = router
        return router
    }

    /// One completed run with `count` turnStarted events whose ids carry `marker`.
    private func seedThread(_ context: AppContext, marker: String, count: Int = 6) throws -> (AgentThreadID, AgentRunID) {
        let thread = AgentThread(title: "thread \(marker)", provider: .codex, model: "gpt-5")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-5",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try context.runRepo.upsert(run)
        for seq in 1...count {
            try context.runRepo.appendStreamEvent(
                runId: run.id,
                seq: seq,
                kind: "turnStarted",
                payloadJSON: #"{"turnStarted":{"turnId":"\#(marker)-turn-\#(seq)"}}"#
            )
        }
        return (thread.id, run.id)
    }

    private func v1Read(_ dispatcher: JSONRPCDispatcher, _ thread: AgentThreadID, id: Int) async -> JSONRPCResponse {
        await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(id),
            method: "agent.thread.read",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "response_version": .number(1),
                "include_event_watermark": .bool(true),
            ]
        ))
    }

    private func turnIDs(_ response: JSONRPCResponse) -> [String] {
        (response.result?.objectValue?["events"]?.arrayValue ?? []).compactMap {
            $0.objectValue?["turnStarted"]?.objectValue?["turnId"]?.stringValue
        }
    }

    /// Locks `lock` on a dedicated thread (NSRecursiveLock must be unlocked by
    /// its owner) until `release` is signalled.
    private func hold(_ lock: NSRecursiveLock) -> (release: DispatchSemaphore, done: DispatchSemaphore) {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            lock.lock()
            started.signal()
            _ = release.wait(timeout: .now() + 10)
            lock.unlock()
            done.signal()
        }
        started.wait()
        return (release, done)
    }

    private func holdWriter(_ writer: SQLiteDB) -> (release: DispatchSemaphore, done: DispatchSemaphore) {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            writer.performSync { db in
                try? db.execute("BEGIN IMMEDIATE;")
                started.signal()
                _ = release.wait(timeout: .now() + 10)
                try? db.execute("COMMIT;")
            }
            done.signal()
        }
        started.wait()
        return (release, done)
    }

    private func ms(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    // MARK: - agent.thread.read v1

    /// Immediate path + A→B: thread A's mirror lock is held (a long stream
    /// flush on A). A read of A must wait for it without holding MainActor; a
    /// read of B must answer at once with only B's events. When A's lock is
    /// released, A's read completes with exactly A's events.
    func test_threadReadV1_heldMirrorLockOnA_neitherBlocksMainNorReadOfB() async throws {
        let context = try makeContext()
        let router = makeRouter(context)
        let dispatcher = JSONRPCDispatcher(router: router)
        let (threadA, _) = try seedThread(context, marker: "A")
        let (threadB, _) = try seedThread(context, marker: "B")

        let held = hold(context.coordinator.mirrorEventLockForTesting(threadId: threadA))
        let readA = Task { await self.v1Read(dispatcher, threadA, id: 1) }

        // MainActor is free while A waits: this code runs, and B answers.
        let t0 = DispatchTime.now()
        let responseB = await v1Read(dispatcher, threadB, id: 2)
        let latencyB = ms(since: t0)
        XCTAssertNil(responseB.error)
        XCTAssertEqual(turnIDs(responseB), (1...6).map { "B-turn-\($0)" },
                       "B's response must carry only B's events")
        XCTAssertLessThan(latencyB, 500, "a read of B must not wait on A's mirror lock (took \(latencyB) ms)")

        try await Task.sleep(nanoseconds: 50_000_000)
        held.release.signal()
        let responseA = await readA.value
        held.done.wait()
        XCTAssertNil(responseA.error)
        XCTAssertEqual(turnIDs(responseA), (1...6).map { "A-turn-\($0)" },
                       "A's late response must carry exactly A's events, never B's")
        XCTAssertNotNil(responseA.result?.objectValue?["event_watermark"])
    }

    /// The same read while A's lock is held must not have answered early: the
    /// barrier still orders it after A's in-flight write.
    func test_threadReadV1_sameThreadWaitsForItsMirrorLock() async throws {
        let context = try makeContext()
        let router = makeRouter(context)
        let dispatcher = JSONRPCDispatcher(router: router)
        let (threadA, _) = try seedThread(context, marker: "A")

        let held = hold(context.coordinator.mirrorEventLockForTesting(threadId: threadA))
        let finished = LockedFlag()
        let readA = Task { () -> JSONRPCResponse in
            let response = await self.v1Read(dispatcher, threadA, id: 1)
            finished.set()
            return response
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(finished.value, "the v1 barrier must wait for A's mirror lock")
        held.release.signal()
        let response = await readA.value
        held.done.wait()
        XCTAssertEqual(turnIDs(response).count, 6)
    }

    /// Failure: an undecodable row in A fails A's read with a JSON-RPC error
    /// (strict decoding is kept off main) and does not affect B.
    func test_threadReadV1_corruptRowFailsOnlyThatThread() async throws {
        let context = try makeContext()
        let router = makeRouter(context)
        let dispatcher = JSONRPCDispatcher(router: router)
        let (threadA, runA) = try seedThread(context, marker: "A")
        let (threadB, _) = try seedThread(context, marker: "B")
        try context.runRepo.appendStreamEvent(runId: runA, seq: 7, kind: "corrupt", payloadJSON: #"{"notAnEvent":1}"#)

        let responseA = await v1Read(dispatcher, threadA, id: 1)
        XCTAssertNil(responseA.result)
        XCTAssertNotNil(responseA.error, "a strict-decode failure must surface, not return a partial tail")

        let responseB = await v1Read(dispatcher, threadB, id: 2)
        XCTAssertNil(responseB.error)
        XCTAssertEqual(turnIDs(responseB).count, 6)
    }

    // MARK: - bot.*

    private func makeBots(_ context: AppContext, router: AppCommandRouter, count: Int) throws -> (BotsViewModel, [BotDefinition]) {
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let bots = try (0..<count).map { try vm.create(name: "Bot \($0)", title: "C5") }
        return (vm, bots)
    }

    private func enqueueDirectly(_ context: AppContext, bot: BotID, text: String) throws {
        _ = try context.botStore.enqueueQueuedFollowUp(BotQueuedFollowUpRecord(
            botID: bot,
            text: text,
            payloadJSON: "{}",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
    }

    private func id(_ bot: BotDefinition) -> String { bot.id.value.uuidString.lowercased() }

    /// Reads report the store's truth but never rescan or republish the desk's
    /// queued follow-ups (that is a write's job).
    func test_pairedBotReads_doNotReloadQueuedFollowUps() async throws {
        let context = try makeContext()
        let router = makeRouter(context)
        let (vm, bots) = try makeBots(context, router: router, count: 1)
        let bot = bots[0]
        try enqueueDirectly(context, bot: bot.id, text: "written behind the desk's back")
        let fleetReloads = vm.queuedFollowUpsFleetReloadCountForTesting

        let queue = try await router.dispatchPairedBotRemote(method: "bot.queue.list", params: ["bot_id": .string(id(bot))])
        XCTAssertEqual(queue.objectValue?["items"]?.arrayValue?.count, 1, "the read itself sees the persisted row")
        for method in ["bot.list", "bot.get", "bot.settings.get", "bot.conversation.list", "bot.routine.list", "bot.attention.list"] {
            _ = try await router.dispatchPairedBotRemote(method: method, params: ["bot_id": .string(id(bot))])
        }
        _ = try await router.dispatchPairedBotRemote(method: "bot.receipt.status", params: ["client_request_id": .string("unknown")])

        XCTAssertEqual(vm.queuedFollowUpsFleetReloadCountForTesting, fleetReloads, "reads must not run the fleet reload")
        XCTAssertTrue(vm.queuedFollowUpsForTesting(botID: bot.id).isEmpty, "reads must not reload the desk's queue")
    }

    /// `bot.conversation.list` resolves each row's desk routing through a
    /// callback that reads MainActor-owned `BotsViewModel` state, so it must
    /// never run in the detached off-main read path.
    func test_pairedConversationList_runsOnMainActor_becauseDeskRoutingReadsViewModelState() {
        XCTAssertTrue(AppCommandRouter.pairedBotMainActorReadMethods.contains("bot.conversation.list"))
        XCTAssertFalse(AppCommandRouter.pairedBotOffMainReadMethods.contains("bot.conversation.list"))
        XCTAssertTrue(
            AppCommandRouter.pairedBotOffMainReadMethods.isDisjoint(with: AppCommandRouter.pairedBotMainActorReadMethods),
            "a read is either off-main or MainActor-bound, never both"
        )
    }

    /// A write reloads only its own bot's queue, not the fleet.
    func test_pairedBotWrite_reloadsOnlyTheAffectedBot() async throws {
        let context = try makeContext()
        let router = makeRouter(context)
        let (vm, bots) = try makeBots(context, router: router, count: 2)
        let (x, y) = (bots[0], bots[1])
        try enqueueDirectly(context, bot: x.id, text: "x follow-up")
        try enqueueDirectly(context, bot: y.id, text: "y follow-up")
        let fleetReloads = vm.queuedFollowUpsFleetReloadCountForTesting

        let pinned = try await router.dispatchPairedBotRemote(method: "bot.set_pinned", params: [
            "client_request_id": .string("c5-pin-x"),
            "bot_id": .string(id(x)),
            "pinned": .bool(true),
        ])
        XCTAssertEqual(pinned.objectValue?["status"]?.stringValue, "completed")
        XCTAssertEqual(vm.queuedFollowUpsForTesting(botID: x.id).map(\.text), ["x follow-up"])
        XCTAssertTrue(vm.queuedFollowUpsForTesting(botID: y.id).isEmpty, "another bot's queue is not this write's business")
        XCTAssertEqual(vm.queuedFollowUpsFleetReloadCountForTesting, fleetReloads)
    }

    /// A write whose bot queue is unchanged publishes nothing; a changed one
    /// publishes once with the new rows.
    func test_pairedBotWrite_publishesQueueOnlyWhenItsRowsChanged() async throws {
        let context = try makeContext()
        let router = makeRouter(context)
        let (vm, bots) = try makeBots(context, router: router, count: 1)
        let bot = bots[0]
        vm.selectedBotID = bot.id
        try enqueueDirectly(context, bot: bot.id, text: "first")
        _ = try await router.dispatchPairedBotRemote(method: "bot.set_pinned", params: [
            "client_request_id": .string("c5-pin-1"), "bot_id": .string(id(bot)), "pinned": .bool(true),
        ])
        XCTAssertEqual(vm.queuedFollowUps.map(\.text), ["first"])

        var emissions: [[String]] = []
        let cancellable = vm.$queuedFollowUps.dropFirst().sink { emissions.append($0.map(\.text)) }
        defer { cancellable.cancel() }

        _ = try await router.dispatchPairedBotRemote(method: "bot.set_pinned", params: [
            "client_request_id": .string("c5-pin-2"), "bot_id": .string(id(bot)), "pinned": .bool(false),
        ])
        XCTAssertTrue(emissions.isEmpty, "an unchanged queue must not republish")

        try enqueueDirectly(context, bot: bot.id, text: "second")
        _ = try await router.dispatchPairedBotRemote(method: "bot.set_pinned", params: [
            "client_request_id": .string("c5-pin-3"), "bot_id": .string(id(bot)), "pinned": .bool(true),
        ])
        XCTAssertEqual(emissions, [["first", "second"]])
    }

    /// Immediate path + A→B: while the writer connection is busy, bot reads
    /// wait off MainActor (this test keeps running on main), and two
    /// concurrent reads each answer with their own bot once it frees.
    func test_pairedBotReads_waitOffMain_andEachAnswersForItsOwnBot() async throws {
        let context = try makeContext()
        let router = makeRouter(context)
        let (_, bots) = try makeBots(context, router: router, count: 2)
        let (x, y) = (bots[0], bots[1])
        _ = try await router.dispatchPairedBotRemote(method: "bot.list", params: [:])

        let held = holdWriter(context.db)
        let finished = LockedFlag()
        let readX = Task { () -> JSONValue in
            defer { finished.set() }
            return try await router.dispatchPairedBotRemote(method: "bot.get", params: ["bot_id": .string(self.id(x))])
        }
        let readY = Task { try await router.dispatchPairedBotRemote(method: "bot.get", params: ["bot_id": .string(self.id(y))]) }

        let t0 = DispatchTime.now()
        await MainActor.run {}
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertLessThan(ms(since: t0), 1_000, "MainActor must stay free while bot reads wait on SQLite")
        XCTAssertFalse(finished.value, "the read waits for the writer, it is not answered from nowhere")

        held.release.signal()
        let resultX = try await readX.value
        let resultY = try await readY.value
        held.done.wait()
        XCTAssertEqual(resultX.objectValue?["id"]?.stringValue, id(x))
        XCTAssertEqual(resultY.objectValue?["id"]?.stringValue, id(y))
    }

    /// Failure: an off-main read for a missing bot surfaces the authority's
    /// JSON-RPC error code unchanged.
    func test_pairedBotRead_missingBot_throwsNotFound() async throws {
        let context = try makeContext()
        let router = makeRouter(context)
        _ = try makeBots(context, router: router, count: 1)
        do {
            _ = try await router.dispatchPairedBotRemote(
                method: "bot.get",
                params: ["bot_id": .string(UUID().uuidString.lowercased())]
            )
            XCTFail("a missing bot must not answer")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, BotRemoteControlAuthority.Error.notFound.code)
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
