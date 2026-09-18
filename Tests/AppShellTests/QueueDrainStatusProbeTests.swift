import XCTest
@testable import AppShell
@testable import AgentRuntime
import CoreModel
import Persistence
import SocketServer

/// WHY: queue-drain timeout used to full-get 26 columns + routing JSON just
/// to decide whether the provider is still stopping.
@MainActor
final class QueueDrainStatusProbeTests: XCTestCase {
    func test_queueDrainTimeout_usesStatusProbeWithoutDurableGet() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-queue-drain-status-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        var thread = AgentThread(
            title: "queue-drain",
            provider: .codex,
            model: "fake-model",
            status: .completed
        )
        try ctx.threadRepo.upsert(thread)
        ctx.coordinator.replaceProviderAdapter(
            .codex,
            adapter: LiveQueueSessionAdapter(threadId: thread.id)
        )
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "follow-up",
            attachments: [],
            interactionMode: .default
        )
        ctx.queueDrainSleepForTesting = { _, _ in Duration.zero }

        let failures = QueueDrainFailureCounter(threadId: thread.id)
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            failures.record($0)
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.statusProbeCountForTesting
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        let deadline = Date().addingTimeInterval(2)
        while failures.count == 0 && Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(
            ctx.threadRepo.statusProbeCountForTesting,
            probesBefore + 1,
            "queue-drain timeout must probe status once"
        )
        XCTAssertEqual(
            ctx.threadRepo.durableGetCountForTesting,
            getsBefore,
            "queue-drain timeout must not compile a full 26-column get just to read status"
        )

        ctx.cancelQueueDrainWaiter(threadId: thread.id)
        thread.status = .running
        try ctx.threadRepo.upsert(thread)
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        let quietDeadline = Date().addingTimeInterval(0.4)
        while Date() < quietDeadline { await Task.yield() }
        XCTAssertEqual(failures.count, 1, "a running thread must not emit a stop-timeout failure")
    }

    func test_unreadableQueueIsNotAnEmptyQueue_becauseAFailedReadMustNotDropTheDrainWaiter() throws {
        // WHY: the check read the queue with `try? … ?? []`, so a transient SQLite
        // failure looked exactly like an empty queue and threw away the drain
        // waiter plus the deferred promotion it owns. Both are live scheduling
        // state and the rows were still there to be read again — the same rule the
        // code already applies to deleted threads: "a transient readback failure
        // cannot safely decide ownership".
        let tmp = NSTemporaryDirectory() + "rc2-queue-drain-unreadable-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let thread = AgentThread(
            title: "unreadable-queue",
            provider: .codex,
            model: "fake-model",
            status: .running
        )
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "keep this queued intent",
            attachments: [],
            interactionMode: .default
        )
        // Park the waiter: it must not retire itself mid-spec.
        ctx.queueDrainSleepForTesting = { _, _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return .zero
        }
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        XCTAssertEqual(
            ctx.queueDrainWaiterCountForTesting,
            1,
            "fixture: a queued intent must arm exactly one drain waiter"
        )
        ctx.deferQueuePromotion(
            id: AgentQueuedMessageID(),
            after: queued.id,
            threadId: thread.id
        )

        // A real read failure, not a mock: the queue table stops resolving.
        try ctx.db.execute("ALTER TABLE agent_queued_messages RENAME TO agent_queued_messages_unreadable;")
        XCTAssertThrowsError(
            try ctx.queuedMessageRepo.list(threadId: thread.id),
            "fixture: the mutation must really make the queue unreadable"
        )

        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)

        XCTAssertEqual(
            ctx.queueDrainWaiterCountForTesting,
            1,
            "WHY: an unreadable queue must not cancel the waiter that would drain it"
        )
        XCTAssertNotNil(
            ctx.deferredQueuePromotion(threadId: thread.id, ownerId: queued.id),
            "WHY: the promotion is the user's chosen target; a failed read must not drop it"
        )
    }

    func test_drainedQueueStillRetiresTheWaiter_becauseOnlyAFailedReadIsNotEmptiness() throws {
        // Guards the fix above from the other side: when the read succeeds and the
        // queue really is empty, the waiter and its promotion must still go away —
        // otherwise the waiter would outlive the intent it exists for.
        let tmp = NSTemporaryDirectory() + "rc2-queue-drain-drained-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let thread = AgentThread(
            title: "drained-queue",
            provider: .codex,
            model: "fake-model",
            status: .running
        )
        try ctx.threadRepo.upsert(thread)
        let queued = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "drain me",
            attachments: [],
            interactionMode: .default
        )
        ctx.queueDrainSleepForTesting = { _, _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return .zero
        }
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)
        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 1,
                       "fixture: a queued intent must arm exactly one drain waiter")
        ctx.deferQueuePromotion(
            id: AgentQueuedMessageID(),
            after: queued.id,
            threadId: thread.id
        )

        _ = try ctx.queuedMessageRepo.delete(id: queued.id)
        XCTAssertTrue(
            try ctx.queuedMessageRepo.list(threadId: thread.id).isEmpty,
            "fixture: the queue must really be empty, and readable"
        )
        ctx.ensureQueueDrainWaiterIfNeeded(threadId: thread.id)

        XCTAssertEqual(ctx.queueDrainWaiterCountForTesting, 0,
                       "WHY: an empty queue must not keep a waiter alive for an intent that is gone")
        XCTAssertNil(
            ctx.deferredQueuePromotion(threadId: thread.id, ownerId: queued.id),
            "WHY: the promotion is scoped to the deleted intent"
        )
    }

    func test_queueDrainTimeout_sourceUsesStatusProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppContext.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "func ensureQueueDrainWaiterIfNeeded(threadId: AgentThreadID)"))
        let body = String(source[range.lowerBound...].prefix(2200))
        XCTAssertTrue(body.contains("threadRepo.status(of: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_queueDrainTimeout_statusProbe_fasterThanDurableGet() throws {
        let tmp = NSTemporaryDirectory() + "rc2-queue-drain-bench-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        let warmup = 3
        let samples = 5
        let iterations = 200
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }
        for _ in 0..<warmup {
            _ = try ctx.threadRepo.status(of: thread.id)
            _ = try ctx.threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.status(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.get(id: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] queue-drain status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "status probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}

private final class QueueDrainFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let threadId: String
    private var value = 0

    init(threadId: AgentThreadID) {
        self.threadId = threadId.value.uuidString
    }

    var count: Int { lock.withLock { value } }

    func record(_ event: EventBus.Event) {
        guard event.kind == "agent.message.queue.failed",
              event.payload.objectValue?["thread_id"]?.stringValue == threadId else { return }
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private final class LiveQueueSessionAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let threadId: AgentThreadID

    init(threadId: AgentThreadID) {
        self.threadId = threadId
    }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
    func cancelUserInput(threadId: AgentThreadID, requestId: String) throws {}
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] {
        [AgentProviderSessionSummary(
            threadId: threadId,
            provider: .codex,
            status: .running,
            providerThreadId: nil
        )]
    }
    func hasSession(threadId: AgentThreadID) -> Bool { threadId == self.threadId }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func forkThread(threadId: AgentThreadID) async throws -> String { "child" }
    func forkThread(_ request: AgentProviderForkRequest) async throws -> String { "child" }
    func compensateFork(_ request: AgentProviderForkRequest, providerChildThreadId: String) async throws {}
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func stopAllForAppTermination() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}
