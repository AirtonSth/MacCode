import XCTest
import AgentRuntime
import CoreModel
import SocketServer
@testable import AppShell
@testable import Persistence

/// C09b: `bot.run.completed` is published before the run is settled in SQLite
/// (C09). A phone that reads on that event must still be told the run ended.
@MainActor
final class BotRunCompletedReadConsistencyTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        AgentProvider.selectableForTesting = nil
        directory = NSTemporaryDirectory() + "rc-bot-run-completed-read-\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRouting")
        UserDefaults.standard.removeObject(forKey: "bots.selectedBotID")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRouting")
        UserDefaults.standard.removeObject(forKey: "bots.selectedBotID")
        if let directory { try? FileManager.default.removeItem(atPath: directory) }
        directory = nil
    }

    private struct Fixture {
        let context: AppContext
        let router: AppCommandRouter
        let runner: ControlledBotHandoffRunner
        let vm: BotsViewModel
    }

    private func makeFixture() throws -> Fixture {
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let runner = ControlledBotHandoffRunner(provider: .distill)
        context.coordinator.replaceProvider(.distill, runner: runner)
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [
                AgentModelDescriptor(id: "main-a", label: "Main A", provider: .distill),
                AgentModelDescriptor(id: "main-b", label: "Main B", provider: .distill),
            ],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "distill-acp",
            capabilitiesOverride: AgentProviderCapabilities(supportsDistillMainEffortAuto: true)
        )
        router.rememberProviderSnapshotsForSend([snapshot])
        router.preflightListedProviderSnapshotsForTesting = false
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let suiteName = "rc2-bot-run-completed-read-" + UUID().uuidString
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        let lastModels = AgentLastModelStore(defaults: suite)
        lastModels.remember(model: "main-b", for: .distill)
        vm.lastModelStore = lastModels
        vm.replaceProvidersForTests([snapshot])
        return Fixture(context: context, router: router, runner: runner, vm: vm)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
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

    private func attentionItem(_ answer: JSONValue, botID: String) -> [String: JSONValue]? {
        answer.objectValue?["items"]?.arrayValue?.compactMap(\.objectValue).first {
            $0["bot_id"]?.stringValue == botID
        }
    }

    private func conversationRow(_ answer: JSONValue, conversationID: String) -> [String: JSONValue]? {
        answer.objectValue?["conversations"]?.arrayValue?.compactMap(\.objectValue).first {
            $0["id"]?.stringValue == conversationID
        }
    }

    /// WHY: the phone reads attention, conversations and the send receipt the
    /// moment `bot.run.completed` arrives. If the attention or conversation
    /// read is answered before the run's settle has run, it says the run is
    /// still working and the phone shows "run status unconfirmed" with the
    /// answer already on screen. The receipt read waits with them so the
    /// three answer in one order. The settle may be late for any reason; here
    /// it is still queued when the reads arrive and then has to wait for the
    /// SQLite writer.
    func test_readsIssuedOnBotRunCompletedWaitForTheQueuedSettleAndAnswerSettled() async throws {
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Piper", title: "Scout")
        let botID = bot.id.value.uuidString.lowercased()
        let sent = try await f.router.dispatchPairedBotRemote(method: "bot.send", params: [
            "client_request_id": .string("c09b-send"),
            "host_id": .string("paired-host"),
            "bot_id": .string(botID),
            "text": .string("go"),
        ])
        let sendReadback = try XCTUnwrap(sent.objectValue?["readback"]?.objectValue)
        let runID = try XCTUnwrap(sendReadback["run_id"]?.stringValue)
        let conversationID = try XCTUnwrap(sendReadback["conversation_id"]?.stringValue)
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(
            request.runId.value.uuidString.lowercased(),
            runID.lowercased(),
            "the receipt names the run the provider was given"
        )

        let reads: [(method: String, params: [String: JSONValue])] = [
            ("bot.attention.list", [:]),
            ("bot.conversation.list", ["bot_id": .string(botID)]),
            ("bot.receipt.status", ["client_request_id": .string("c09b-send")]),
        ]
        XCTAssertEqual(
            Set(reads.map { $0.method }),
            AppCommandRouter.pairedBotRunStateReadMethods,
            "every read that reports run state is driven below"
        )

        // While the run is live, the same reads report it as live.
        let liveAttention = try await f.router.dispatchPairedBotRemote(method: reads[0].method, params: reads[0].params)
        XCTAssertEqual(attentionItem(liveAttention, botID: botID)?["state"]?.stringValue, "working")
        let liveConversations = try await f.router.dispatchPairedBotRemote(method: reads[1].method, params: reads[1].params)
        XCTAssertEqual(
            conversationRow(liveConversations, conversationID: conversationID)?["run_id"]?.stringValue,
            runID
        )

        // The run's settle stays queued behind this hold. Without it the
        // settle and a read race for the authority's lock, and the test would
        // pass or fail by thread scheduling.
        let projector = f.router.botRuntimeEvidenceProjectorForTesting
        let releaseSettles = DispatchSemaphore(value: 0)
        defer { releaseSettles.signal() }
        projector.holdTerminalsForTesting(until: releaseSettles)

        let probe = ReadProbe()
        let router = f.router
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { @Sendable event in
            guard event.kind == "bot.run.completed",
                  event.payload.objectValue?["run_id"]?.stringValue?.lowercased() == runID.lowercased() else { return }
            // The phone's reaction: read at once.
            for read in reads {
                probe.issued(read.method, Task<JSONValue, Error> { @MainActor in
                    probe.started(read.method)
                    let answer = try await router.dispatchPairedBotRemote(method: read.method, params: read.params)
                    probe.answered(read.method)
                    return answer
                })
            }
        }
        defer { EventBus.shared.unsubscribe(token) }

        XCTAssertTrue(f.runner.finish(runID: request.runId, status: .completed, reply: "ok"))
        let issued = await waitUntil { probe.startedMethods.count == reads.count }
        XCTAssertTrue(issued, "the run's end reached the subscriber as bot.run.completed and it read at once")
        XCTAssertEqual(
            probe.answeredMethods,
            [],
            "a read made on bot.run.completed is not answered while that run's settle is still queued"
        )

        // No suspension from here to the release: nothing else runs on the
        // MainActor while the writer is held.
        let writer = holdWriter(f.context.db)
        releaseSettles.signal()
        let settleLanded = DispatchSemaphore(value: 0)
        projector.afterQueuedTerminals { settleLanded.signal() }
        // The wait only gives the settle time to reach SQLite. It cannot land
        // while the writer is held, however long this waits.
        XCTAssertEqual(
            settleLanded.wait(timeout: .now() + .milliseconds(100)),
            .timedOut,
            "the settle the reads wait for is itself waiting for the SQLite writer"
        )
        writer.release.signal()

        let attention = try await XCTUnwrap(probe.task(reads[0].method)).value
        let conversations = try await XCTUnwrap(probe.task(reads[1].method)).value
        let receipt = try await XCTUnwrap(probe.task(reads[2].method)).value
        writer.done.wait()

        let item = try XCTUnwrap(attentionItem(attention, botID: botID))
        XCTAssertEqual(item["run_id"]?.stringValue, runID)
        XCTAssertEqual(item["state"]?.stringValue, "finished", "attention reports the run ended, not working")
        let row = try XCTUnwrap(conversationRow(conversations, conversationID: conversationID))
        XCTAssertNil(row["run_id"]?.stringValue, "the conversation no longer names the finished run as live")
        // `run_outcome` comes from the durable run row, written before
        // `agent.run.completed` is published, so it reads "completed" with or
        // without the wait. For this read only the wait itself is pinned, by
        // the `answeredMethods` assertion above.
        let receiptReadback = try XCTUnwrap(receipt.objectValue?["readback"]?.objectValue)
        XCTAssertEqual(receiptReadback["run_id"]?.stringValue, runID)
        XCTAssertEqual(receiptReadback["run_outcome"]?.stringValue, "completed")
    }

    /// WHY: the phone reads attention and conversations on every connect,
    /// long before any send. The projector subscribes to every host event
    /// when it is created, and until a paired `bot.send` binds a run it has
    /// no settle to wait for. A read must not be what creates it, or a host
    /// that is only being read pays one more handler call per event.
    func test_readsBeforeAnyPairedSendDoNotCreateTheProjector() async throws {
        let f = try makeFixture()
        let bot = try f.vm.create(name: "Piper", title: "Scout")
        let botID = bot.id.value.uuidString.lowercased()
        let reads: [(method: String, params: [String: JSONValue])] = [
            ("bot.attention.list", [:]),
            ("bot.conversation.list", ["bot_id": .string(botID)]),
            ("bot.receipt.status", ["client_request_id": .string("c09b-never-sent")]),
        ]
        XCTAssertEqual(Set(reads.map { $0.method }), AppCommandRouter.pairedBotRunStateReadMethods)
        for read in reads {
            _ = try await f.router.dispatchPairedBotRemote(method: read.method, params: read.params)
            XCTAssertFalse(
                f.router.botRuntimeEvidenceProjectorExists,
                "\(read.method) before any paired send must not create the projector"
            )
        }

        _ = try await f.router.dispatchPairedBotRemote(method: "bot.send", params: [
            "client_request_id": .string("c09b-first-send"),
            "host_id": .string("paired-host"),
            "bot_id": .string(botID),
            "text": .string("go"),
        ])
        XCTAssertTrue(
            f.router.botRuntimeEvidenceProjectorExists,
            "the first paired send creates the projector, so later reads wait for its settles"
        )
        // Ends the run this test started.
        let started = await waitUntil { !f.runner.requests.isEmpty }
        XCTAssertTrue(started)
        XCTAssertTrue(f.runner.finish(runID: try XCTUnwrap(f.runner.requests.first).runId, status: .completed, reply: "ok"))
    }

    /// WHY (review finding C01m RP-01): the projector does not replay retained
    /// events for a new receipt, because the run's provider start is queued
    /// behind the MainActor turn that registers the receipt. A suspension
    /// point between admitting the run (`authority.dispatch`) and
    /// `registerCompletedSend` would let that start run first. The run's
    /// events, its terminal one included, would then be published before the
    /// run is bound and never projected: no `bot.run.completed` for the
    /// phone and no settle, so the Bot would stay "working".
    func test_botSendRegistersItsReceiptWithNoSuspensionAfterTheRunIsAdmitted() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let entry = try XCTUnwrap(source.range(of: "public func dispatchPairedBotRemote("))
        let body = source[entry.upperBound...]
        let admit = try XCTUnwrap(
            body.range(of: "var result = try authority.dispatch(method: method, params: foundation)")
        )
        let register = try XCTUnwrap(
            body[admit.upperBound...].range(of: "botRuntimeEvidenceProjector.registerCompletedSend(")
        )
        let seam = body[admit.upperBound..<register.lowerBound]

        // The one suspension allowed is the stop settlement wait, inside the
        // branch only `bot.stop` and `bot.force_stop` take.
        XCTAssertEqual(
            seam.components(separatedBy: "await").count - 1,
            1,
            "bot.send must reach registerCompletedSend in the MainActor turn that admitted the run"
        )
        // A registration handed to a task or a queue also runs in a later
        // turn, with no `await` in this text.
        for token in ["Task", ".async"] {
            XCTAssertFalse(
                seam.contains(token),
                "registerCompletedSend must not be deferred past the admitting MainActor turn (\(token))"
            )
        }
        let stopBranch = try XCTUnwrap(seam.range(of: #"if method == "bot.stop" || method == "bot.force_stop","#))
        let stopWait = try XCTUnwrap(seam.range(of: "await waitForPairedBotSettlement(requestID: requestID)"))
        guard stopBranch.upperBound <= stopWait.lowerBound else {
            return XCTFail("the settlement wait must come after the stop branch opens")
        }
        XCTAssertFalse(
            seam[stopBranch.upperBound..<stopWait.lowerBound].contains("}"),
            "the settlement wait must stay inside the stop branch"
        )
    }
}

/// The reads a subscriber issued, shared between the EventBus delivery lane
/// (which starts them) and the MainActor (which runs and awaits them).
private final class ReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: Task<JSONValue, Error>] = [:]
    private var startedList: [String] = []
    private var answeredList: [String] = []

    var startedMethods: [String] { lock.lock(); defer { lock.unlock() }; return startedList }
    var answeredMethods: [String] { lock.lock(); defer { lock.unlock() }; return answeredList }

    func issued(_ method: String, _ task: Task<JSONValue, Error>) {
        lock.lock(); tasks[method] = task; lock.unlock()
    }

    func started(_ method: String) { lock.lock(); startedList.append(method); lock.unlock() }
    func answered(_ method: String) { lock.lock(); answeredList.append(method); lock.unlock() }
    func task(_ method: String) -> Task<JSONValue, Error>? {
        lock.lock(); defer { lock.unlock() }
        return tasks[method]
    }
}
