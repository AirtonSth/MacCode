import XCTest
import CoreModel
import Persistence
import AgentRuntime
@testable import AppShell

/// WHY: every run completion used to resolve its notification inputs on the
/// MainActor, including the nested-worker check, which scans orchestration
/// receipts (`detail LIKE`, ~15 ms on a real 8.9k-row log) under the
/// process-wide receipt lock and file lock. The completion turn is when the
/// user looks at the result, so these reads must run off-main while the
/// notification decision (nested workers suppressed, root runs notified)
/// stays exactly the same.
@MainActor
final class RunFinishedNotificationOffMainTests: XCTestCase {
    func test_runFinishedNotificationInputs_readOffMainAndKeepNestedSuppression() async throws {
        let ctx = try makeContext("inputs")
        let thread = AgentThread(title: "finish", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        let rootRun = AgentRun(threadId: thread.id, provider: .codex, model: "fake-model",
                               status: .completed, finishedAt: Date())
        let nestedRun = AgentRun(threadId: thread.id, provider: .codex, model: "fake-model",
                                 status: .completed, finishedAt: Date())
        try ctx.runRepo.upsert(rootRun)
        try ctx.runRepo.upsert(nestedRun)
        let repository = AgentOrchestrationRepository(db: ctx.db)
        let rootReceipt = receipt(runId: rootRun.id, threadId: thread.id, parent: nil)
        try repository.save(rootReceipt)
        try repository.save(receipt(runId: nestedRun.id, threadId: thread.id, parent: rootReceipt.id))
        ctx.runFinishedNotificationReadProbeForTesting.reset()

        let root = await ctx.runFinishedNotificationInputs(runId: rootRun.id, threadId: thread.id)
        let nested = await ctx.runFinishedNotificationInputs(runId: nestedRun.id, threadId: thread.id)

        XCTAssertEqual(ctx.runFinishedNotificationReadProbeForTesting.mainThreadCallCount, 0,
                       "run-finished notification reads must not run on the MainActor")
        XCTAssertEqual(ctx.runFinishedNotificationReadProbeForTesting.backgroundCallCount, 2)
        XCTAssertFalse(root.isNestedWorker)
        XCTAssertTrue(nested.isNestedWorker)
        XCTAssertEqual(root.chrome?.title, "finish", "the gathered chrome must be this thread's")
        XCTAssertNotNil(
            RemoteCodeNotificationContent.threadOutcome(
                threadId: thread.id.value.uuidString,
                title: root.chrome?.title,
                phase: .completed,
                isNestedWorker: root.isNestedWorker
            ),
            "a root run must still produce its outcome notification"
        )
        XCTAssertNil(
            RemoteCodeNotificationContent.threadOutcome(
                threadId: thread.id.value.uuidString,
                title: nested.chrome?.title,
                phase: .completed,
                isNestedWorker: nested.isNestedWorker
            ),
            "a nested worker must still be suppressed (the parent owns the UX)"
        )
    }

    func test_onRunFinished_gathersNotificationInputsOffMain() async throws {
        let ctx = try makeContext("finish")
        let thread = AgentThread(title: "finish", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        // Cancelled: the inputs are still gathered, but a user stop posts no
        // banner, so this test adds nothing to the shared grouped-outcome window
        // other notification tests observe.
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "fake-model",
                           status: .cancelled, finishedAt: Date())
        try ctx.runRepo.upsert(run)
        ctx.runFinishedNotificationReadProbeForTesting.reset()

        ctx.coordinator.onRunFinished?(thread.id, run.id, .cancelled)
        let deadline = Date().addingTimeInterval(2)
        while ctx.runFinishedNotificationReadProbeForTesting.backgroundCallCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(ctx.runFinishedNotificationReadProbeForTesting.backgroundCallCount, 1,
                       "the finish handler must gather its notification inputs exactly once, off-main")
        XCTAssertEqual(ctx.runFinishedNotificationReadProbeForTesting.mainThreadCallCount, 0)
    }

    func test_runFinishedPosts_keepCallbackOrderWhenAnEarlierGatherIsSlower() async throws {
        // WHY: with the reads off-main, runs that finish close together gather
        // concurrently. On the MainActor both posts ran in callback order;
        // banners, grouped outcomes and the phone's copy still depend on that,
        // so a slow receipt scan for the first run must not let the second
        // run's banner post first. In a test host every post reaches
        // `onDeniedPost` (not authorized), on the main queue, in post order.
        let ctx = try makeContext("order")
        let first = AgentThread(title: "first", provider: .codex, model: "fake-model")
        let second = AgentThread(title: "second", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(first)
        try ctx.threadRepo.upsert(second)
        let firstRun = AgentRun(threadId: first.id, provider: .codex, model: "fake-model",
                                status: .failed, finishedAt: Date())
        let secondRun = AgentRun(threadId: second.id, provider: .codex, model: "fake-model",
                                 status: .failed, finishedAt: Date())
        try ctx.runRepo.upsert(firstRun)
        try ctx.runRepo.upsert(secondRun)
        let releaseFirst = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }
        let secondGathered = GatherFlag()
        let firstRunID = firstRun.id
        ctx.runFinishedNotificationWillGatherForTesting = { runId in
            if runId == firstRunID { releaseFirst.wait() } else { secondGathered.set() }
        }
        let watched = [first.id.value.uuidString, second.id.value.uuidString]
        let posted = PostLog()
        let notifier = SystemNotifier.shared
        let previousHandler = notifier.onDeniedPost
        notifier.onDeniedPost = { content in
            if let threadId = content.userInfo["threadId"], watched.contains(threadId) {
                posted.threadIds.append(threadId)
            }
        }
        defer { notifier.onDeniedPost = previousHandler }

        ctx.coordinator.onRunFinished?(first.id, firstRun.id, .failed)
        ctx.coordinator.onRunFinished?(second.id, secondRun.id, .failed)
        await wait(seconds: 2) { secondGathered.isSet }
        XCTAssertTrue(secondGathered.isSet, "the second run gathers while the first is still reading")
        // Room for the second banner to (wrongly) post ahead of the first.
        await wait(seconds: 0.5) { !posted.threadIds.isEmpty }
        XCTAssertEqual(posted.threadIds, [], "the second run's banner must wait for the first run's")

        releaseFirst.signal()
        await wait(seconds: 2) { posted.threadIds.count == 2 }
        XCTAssertEqual(posted.threadIds, watched, "banners post once each, in callback order")
    }

    private func wait(seconds: TimeInterval, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func receipt(
        runId: AgentRunID,
        threadId: AgentThreadID,
        parent: UUID?
    ) -> AgentOrchestrationAdmissionReceipt {
        AgentOrchestrationAdmissionReceipt(
            parentReceiptId: parent,
            runId: runId,
            threadId: threadId,
            nodeId: parent == nil ? "root" : "nested.codex.1",
            routingRevision: 0,
            policyDigest: "external",
            packageRevision: "external",
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "fake-model",
            capabilitySnapshotId: "external",
            decisionReason: parent == nil ? "manual-agent-app-controller" : "external-controlled-child",
            lifecycleStatus: .finalized
        )
    }

    private func makeContext(_ label: String) throws -> AppContext {
        let tmp = NSTemporaryDirectory() + "rc2-run-finished-offmain-\(label)-" + UUID().uuidString
        return try AppContext(channel: .debug, appSupportOverride: tmp)
    }
}

/// Set from the off-main gather once a run started its reads.
private final class GatherFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Thread ids of posted banners, appended on the main queue.
private final class PostLog {
    var threadIds: [String] = []
}
