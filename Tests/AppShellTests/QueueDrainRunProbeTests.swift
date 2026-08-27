import XCTest
@testable import AppShell
@testable import AgentRuntime
@testable import SocketServer
import CoreModel
import Persistence

/// WHY: queue-drain prepared dispatch compiled the 10-column agent_runs row
/// (including error_message) twice just for existence/status.
@MainActor
final class QueueDrainRunProbeTests: XCTestCase {
    func test_queueDrainPreparedPath_sourceUsesRunProbes() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let drainStart = try XCTUnwrap(source.range(of: "public func drainNextQueuedAgentMessage("))
        let drainEnd = try XCTUnwrap(source.range(of: "private func routingSnapshotForQueuedMessage("))
        let drain = String(source[drainStart.lowerBound..<drainEnd.lowerBound])
        XCTAssertTrue(drain.contains("runRepo.status(of: runId)"))
        XCTAssertFalse(drain.contains("runRepo.get(id: runId)"))
        let evidenceStart = try XCTUnwrap(source.range(of: "private func preparedQueueRunHasProviderEvidence("))
        let evidenceEnd = try XCTUnwrap(source.range(of: "private func unconfirmedQueuedMessageStartError("))
        let evidence = String(source[evidenceStart.lowerBound..<evidenceEnd.lowerBound])
        XCTAssertTrue(evidence.contains("runRepo.threadId(of: runId)"))
        XCTAssertFalse(evidence.contains("runRepo.get(id: runId)"))
    }

    func test_drainPreparedHead_usesRunProbesWithoutDurableGet() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-queue-drain-run-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let thread = AgentThread(
            title: "queue-drain-run",
            provider: .codex,
            model: "fake-model",
            status: .completed
        )
        try ctx.threadRepo.upsert(thread)
        let head = try ctx.queuedMessageRepo.enqueue(
            threadId: thread.id,
            text: "follow-up",
            attachments: [],
            interactionMode: .default
        )
        let lease = try XCTUnwrap(ctx.queuedMessageRepo.claim(id: head.id, leaseId: "probe"))
        let runId = AgentRunID(head.id.value)
        XCTAssertTrue(try ctx.queuedMessageRepo.prepareDispatch(lease, runId: runId))
        try ctx.runRepo.upsert(AgentRun(
            id: runId,
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .completed,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        ))

        let getsBefore = ctx.runRepo.durableGetCountForTesting
        let statusBefore = ctx.runRepo.statusProbeCountForTesting
        let threadIdBefore = ctx.runRepo.threadIdProbeCountForTesting
        do {
            try await router.drainNextQueuedAgentMessage(thread: thread.id)
            XCTFail("unconfirmed prepared dispatch must throw")
        } catch let error as JSONRPCError {
            XCTAssertTrue(error.message.contains("remains queued"))
        }
        XCTAssertEqual(ctx.runRepo.statusProbeCountForTesting, statusBefore + 1)
        XCTAssertEqual(ctx.runRepo.threadIdProbeCountForTesting, threadIdBefore + 1)
        XCTAssertEqual(
            ctx.runRepo.durableGetCountForTesting,
            getsBefore,
            "prepared drain must not compile a full 10-column get just for existence/status"
        )
        XCTAssertEqual(try ctx.queuedMessageRepo.list(threadId: thread.id).count, 1)
    }

    func test_statusProbe_fasterThanDurableGet() throws {
        let tmp = NSTemporaryDirectory() + "rc2-queue-drain-run-bench-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .completed,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try ctx.runRepo.upsert(run)
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
            _ = try ctx.runRepo.status(of: run.id)
            _ = try ctx.runRepo.get(id: run.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.runRepo.status(of: run.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.runRepo.get(id: run.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] queue-drain status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "status probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
