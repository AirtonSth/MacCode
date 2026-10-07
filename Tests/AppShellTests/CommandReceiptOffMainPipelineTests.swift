import XCTest
@testable import AppShell
import CoreModel
import Persistence
@testable import SocketServer

/// WHY (C6 / H2c): every remote mutation ran its durable receipt claim and its
/// finalize (receipt + event outbox transaction, retention prune) on MainActor,
/// and finalize first drained the whole utility writer queue. The Mac UI and
/// every other RPC stopped for as long as SQLite or that queue was busy. The
/// SQLite now runs off MainActor, but the contract must not move: one receipt,
/// one durable event and one delivery per request; receipt events sorted after
/// earlier events and before anything the Mac publishes after the effect; and
/// the same error codes when the claim or the finalize fails.
@MainActor
final class CommandReceiptOffMainPipelineTests: XCTestCase {
    private var temporaryDirectories: [String] = []
    private let mutationContext = MutationRequestContext(
        ownerFingerprint: "owner-c6",
        hostId: "host-c6",
        bootEpoch: 1
    )

    override func tearDown() {
        AppContext.beforeEventLogBatchWriteForTesting = nil
        EventBus.shared.persister = nil
        EventBus.shared.persistenceCommitFence = nil
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Immediate path

    func test_claimWaitingOnSQLiteDoesNotBlockMainActor() async throws {
        let fixture = try make()
        let held = holdDatabase(fixture.context, forSeconds: 0.5)
        XCTAssertEqual(held.wait(timeout: .now() + 2), .success)

        let finished = Flag()
        let request = Task { @MainActor in
            let response = await self.rename(fixture, requestId: "held-claim", to: "Held")
            finished.set()
            return response
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(
            finished.isSet,
            "MainActor ran again while the claim was still waiting on SQLite; before C6 it was blocked until the writer let go"
        )
        let response = await request.value
        XCTAssertNil(response.error, "\(String(describing: response.error))")
        XCTAssertEqual(try fixture.router.listWorkspaces().first { $0.id == fixture.workspace }?.name, "Held")
        XCTAssertEqual(try receiptStatus(fixture, "held-claim"), .committed)
    }

    // MARK: - Eventual exact completion

    func test_mutationPersistsOneReceiptOneEventAndDeliversItOnce() async throws {
        let fixture = try make()
        let recorder = EventRecorder(kind: "workspace.renamed")
        defer { recorder.stop() }

        let first = await rename(fixture, requestId: "exact-once", to: "Renamed")
        XCTAssertNil(first.error)
        XCTAssertEqual(first.result, .bool(true))
        XCTAssertEqual(try receiptStatus(fixture, "exact-once"), .committed)

        let durable = try receiptEventRows(fixture, "exact-once")
        XCTAssertEqual(durable.map(\.kind), ["workspace.renamed"], "one durable event, linked to this request")
        XCTAssertEqual(recorder.events.map(\.seq), durable.map(\.seq), "delivered once, with its durable sequence")
        XCTAssertEqual(recorder.events.first?.payload.objectValue?["name"], .string("Renamed"))
        let sequenceAfterFirst = EventBus.shared.currentSeq

        let replay = await rename(fixture, requestId: "exact-once", to: "Renamed")
        XCTAssertNil(replay.error)
        XCTAssertEqual(replay.result, first.result, "a retry answers from the committed receipt")
        XCTAssertEqual(try receiptEventRows(fixture, "exact-once").map(\.seq), durable.map(\.seq))
        XCTAssertEqual(recorder.events.count, 1, "a retry never publishes again")
        XCTAssertEqual(EventBus.shared.currentSeq, sequenceAfterFirst, "a retry allocates no sequence")
    }

    // MARK: - Ordering and A -> B

    func test_receiptEventsSortBetweenEarlierEventsAndPublishesAfterTheEffect() async throws {
        let fixture = try make()
        let batchEntered = DispatchSemaphore(value: 0)
        let releaseBatch = DispatchSemaphore(value: 0)
        let blockOnce = Flag()
        AppContext.beforeEventLogBatchWriteForTesting = {
            guard !blockOnce.isSet else { return }
            blockOnce.set()
            batchEntered.signal()
            releaseBatch.wait()
        }
        defer { releaseBatch.signal() }

        // An earlier normal event whose batch the writer is still writing.
        EventBus.shared.publish(kind: .agentRunStarted, payload: .object(["marker": .string("before")]))
        let before = EventBus.shared.currentSeq
        XCTAssertEqual(batchEntered.wait(timeout: .now() + 2), .success)
        // Safety net: if a regression blocks MainActor on this batch, fail
        // after 3 s instead of deadlocking the suite.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { releaseBatch.signal() }

        let request = Task { @MainActor in
            await self.rename(fixture, requestId: "ordered", to: "Ordered")
        }
        // The effect has run and the commit is queued behind the in-flight batch.
        for _ in 0..<200 where EventBus.shared.pendingPersistedCommitCountForTesting == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(EventBus.shared.pendingPersistedCommitCountForTesting, 1)
        XCTAssertEqual(try fixture.router.listWorkspaces().first { $0.id == fixture.workspace }?.name, "Ordered")

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { releaseBatch.signal() }
        // A Mac-side publish after the effect: it must sort after the receipt.
        EventBus.shared.publish(kind: .workspaceUpdated, payload: .object(["marker": .string("after")]))
        let after = EventBus.shared.currentSeq

        let response = await request.value
        XCTAssertNil(response.error)
        let receiptSeqs = try receiptEventRows(fixture, "ordered").map(\.seq)
        XCTAssertEqual(receiptSeqs.count, 1)
        XCTAssertLessThan(before, receiptSeqs[0], "receipt events come after the earlier event")
        XCTAssertLessThan(receiptSeqs[0], after, "a publish made after the effect comes after the receipt events")

        fixture.context.flushEventPersistence()
        let physical = try physicalOrder(fixture, seqs: [before, receiptSeqs[0], after])
        XCTAssertEqual(physical, [before, receiptSeqs[0], after],
            "durable rows are written in sequence order")
    }

    func test_rapidRenamesAToB_lastDeliveredEventMatchesHostState() async throws {
        let fixture = try make()
        let recorder = EventRecorder(kind: "workspace.renamed")
        defer { recorder.stop() }

        let a = Task { @MainActor in await self.rename(fixture, requestId: "rapid-a", to: "Name A") }
        let b = Task { @MainActor in await self.rename(fixture, requestId: "rapid-b", to: "Name B") }
        let responses = await [a.value, b.value]
        XCTAssertTrue(responses.allSatisfy { $0.error == nil })

        let hostName = try fixture.router.listWorkspaces().first { $0.id == fixture.workspace }?.name
        let delivered = recorder.events.sorted { $0.seq < $1.seq }
        XCTAssertEqual(delivered.count, 2, "each request publishes exactly once")
        XCTAssertEqual(
            delivered.last?.payload.objectValue?["name"]?.stringValue,
            hostName,
            "a client applying events in sequence order must converge on the host's name, never the stale one"
        )
    }

    // MARK: - Failure surfaces

    func test_claimFailure_returnsRetryableReceiptUnavailableWithoutEffectOrEvent() async throws {
        let fixture = try make()
        let recorder = EventRecorder(kind: "workspace.renamed")
        defer { recorder.stop() }
        try fixture.context.db.performSync { db in
            try db.execute("ALTER TABLE command_receipts RENAME TO command_receipts_unavailable;")
        }

        let response = await rename(fixture, requestId: "claim-fails", to: "Never")

        XCTAssertEqual(response.error?.code, -32091)
        XCTAssertEqual(response.error?.data?.objectValue?["retryable"], .bool(true))
        XCTAssertNotEqual(try fixture.router.listWorkspaces().first { $0.id == fixture.workspace }?.name, "Never",
            "no effect runs without a durable claim")
        XCTAssertEqual(recorder.events.count, 0)
    }

    func test_finalizeFailure_returnsOutcomeUnknownAndNeverPublishes() async throws {
        let fixture = try make()
        let recorder = EventRecorder(kind: "workspace.renamed")
        defer { recorder.stop() }
        try fixture.context.db.performSync { db in
            try db.execute("""
                CREATE TRIGGER c6_fail_receipt_events BEFORE INSERT ON events
                WHEN NEW.request_id IS NOT NULL
                BEGIN SELECT RAISE(ABORT, 'injected receipt event failure'); END;
            """)
        }
        let sequenceBefore = EventBus.shared.currentSeq

        let response = await rename(fixture, requestId: "finalize-fails", to: "Unknown")

        XCTAssertEqual(response.error?.code, -32095, "the effect ran but its outcome is not durable")
        XCTAssertEqual(response.error?.data?.objectValue?["requiresSnapshot"], .bool(true))
        XCTAssertEqual(recorder.events.count, 0, "an event whose receipt failed is never delivered")
        XCTAssertEqual(try receiptEventRows(fixture, "finalize-fails").count, 0)
        XCTAssertEqual(EventBus.shared.currentSeq, sequenceBefore, "a failed finalize allocates no sequence")
        XCTAssertEqual(try receiptStatus(fixture, "finalize-fails"), .unknown)

        let retry = await rename(fixture, requestId: "finalize-fails", to: "Unknown")
        XCTAssertEqual(retry.error?.code, -32095, "the request id stays fenced as unknown")
        XCTAssertEqual(recorder.events.count, 0)
    }

    // MARK: - Helpers

    private struct Fixture {
        let context: AppContext
        let router: AppCommandRouter
        let dispatcher: JSONRPCDispatcher
        let workspace: WorkspaceID
    }

    private func make() throws -> Fixture {
        let directory = NSTemporaryDirectory() + "RC2ReceiptC6-" + UUID().uuidString
        temporaryDirectories.append(directory)
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        AppDelegate.wireEventPersistence(context: context)
        let workspace = try router.listWorkspaces().first?.id
            ?? router.createWorkspace(name: "C6", cwd: directory).id
        return Fixture(context: context, router: router, dispatcher: JSONRPCDispatcher(router: router), workspace: workspace)
    }

    private func rename(_ fixture: Fixture, requestId: String, to name: String) async -> JSONRPCResponse {
        await fixture.dispatcher.dispatch(
            JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "workspace.rename", params: [
                "client_request_id": .string(Self.wireRequestId(requestId)),
                "connection_id": .string("c6-connection"),
                "expected_host_id": .string(mutationContext.hostId),
                "expected_boot_epoch": .number(1),
                "id": .string(fixture.workspace.value.uuidString),
                "name": .string(name),
            ]),
            mutationContext: mutationContext
        )
    }

    private func receiptStatus(_ fixture: Fixture, _ requestId: String) throws -> CommandReceiptStatusResult {
        try fixture.context.commandReceiptRepo.status(
            method: "workspace.rename",
            clientRequestId: Self.wireRequestId(requestId),
            ownerFingerprint: mutationContext.ownerFingerprint
        )
    }

    private func receiptEventRows(_ fixture: Fixture, _ requestId: String) throws -> [(seq: Int64, kind: String)] {
        try fixture.context.db.performSync { db in
            let statement = try db.prepare("SELECT seq, kind FROM events WHERE request_id = ? ORDER BY seq;")
            try statement.bind(1, Self.wireRequestId(requestId))
            var rows: [(seq: Int64, kind: String)] = []
            while try statement.step() {
                rows.append((statement.columnInt64(0), statement.columnText(1) ?? ""))
            }
            return rows
        }
    }

    private func physicalOrder(_ fixture: Fixture, seqs: [Int64]) throws -> [Int64] {
        try fixture.context.db.performSync { db in
            let statement = try db.prepare("SELECT seq FROM events ORDER BY id ASC;")
            var order: [Int64] = []
            while try statement.step() {
                let seq = statement.columnInt64(0)
                if seqs.contains(seq) { order.append(seq) }
            }
            return order
        }
    }

    /// Holds the SQLite connection from another thread for `seconds`.
    private func holdDatabase(_ context: AppContext, forSeconds seconds: TimeInterval) -> DispatchSemaphore {
        let started = DispatchSemaphore(value: 0)
        let db = context.db
        DispatchQueue.global(qos: .userInitiated).async {
            db.performSync { _ in
                started.signal()
                Thread.sleep(forTimeInterval: seconds)
            }
        }
        return started
    }

    /// client_request_id must be 8-128 chars.
    private static func wireRequestId(_ name: String) -> String { "c6-req-\(name)" }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var matched: [EventBus.Event] = []
    private var subscription: UUID?

    init(kind: String) {
        subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { [weak self] event in
            guard event.kind == kind else { return }
            self?.lock.lock(); self?.matched.append(event); self?.lock.unlock()
        }
    }

    var events: [EventBus.Event] {
        EventBus.shared.flushPersistenceSubmissions()
        lock.lock(); defer { lock.unlock() }
        return matched
    }

    func stop() {
        if let subscription { EventBus.shared.unsubscribe(subscription) }
    }
}
