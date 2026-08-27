import XCTest
@testable import AppShell
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: queue-drain dispatch used to full-get 26 columns + routing JSON just
/// to refuse starting the next follow-up while status is running/pending.
@MainActor
final class QueueDrainDispatchStatusProbeTests: XCTestCase {
    private func makeRouter(_ label: String) throws -> (AppContext, AppCommandRouter) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    func test_drainWhileRunning_usesStatusProbeWithoutDurableGet() async throws {
        let (ctx, router) = try makeRouter("queue-drain-dispatch-running")
        var thread = AgentThread(
            title: "queue-drain-dispatch",
            provider: .codex,
            model: "fake-model",
            status: .running
        )
        try ctx.threadRepo.upsert(thread)
        _ = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "follow-up",
            attachments: [],
            interactionMode: .default
        )

        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.statusProbeCountForTesting
        try await router.drainNextQueuedAgentMessage(thread: thread.id)
        XCTAssertEqual(
            ctx.threadRepo.statusProbeCountForTesting,
            probesBefore + 1,
            "running drain must probe status once"
        )
        XCTAssertEqual(
            ctx.threadRepo.durableGetCountForTesting,
            getsBefore,
            "running drain must not compile a full 26-column get just to read status"
        )
        XCTAssertEqual(
            try ctx.queuedMessageRepo.list(threadId: thread.id).count,
            1,
            "a running thread must keep the queued follow-up"
        )

        thread.status = .pending
        try ctx.threadRepo.upsert(thread)
        let pendingGetsBefore = ctx.threadRepo.durableGetCountForTesting
        let pendingProbesBefore = ctx.threadRepo.statusProbeCountForTesting
        try await router.drainNextQueuedAgentMessage(thread: thread.id)
        XCTAssertEqual(ctx.threadRepo.statusProbeCountForTesting, pendingProbesBefore + 1)
        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, pendingGetsBefore)
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).count, 1)
    }

    func test_drainNextQueuedAgentMessage_sourceUsesStatusProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "public func drainNextQueuedAgentMessage("))
        let body = String(source[range.lowerBound...].prefix(1600))
        XCTAssertTrue(body.contains("threadRepo.status(of: thread)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: thread)"))
    }

    func test_statusProbe_fasterThanDurableGet() throws {
        let (ctx, _) = try makeRouter("queue-drain-dispatch-bench")
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
            "[perf-proof] queue-drain-dispatch status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
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
