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
