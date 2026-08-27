import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// WHY: scheduled failed/cancelled finish compiled the 10-column agent_runs
/// row after terminal(of:) already supplied status and finished_at, just to
/// copy error_message.
final class ScheduledErrorMessageProbeTests: XCTestCase {
    private func makeRepos(_ label: String) throws -> (
        AgentThreadRepository,
        AgentRunRepository
    ) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (
            AgentThreadRepository(db: db),
            AgentRunRepository(db: db)
        )
    }

    func test_observeAndReclaim_sourceUsesErrorMessageProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"),
            encoding: .utf8
        )
        let observeStart = try XCTUnwrap(source.range(of: "private func observeRunning(now:"))
        let observeEnd = try XCTUnwrap(source.range(of: "private func notifyFailure(for"))
        let observe = String(source[observeStart.lowerBound..<observeEnd.lowerBound])
        XCTAssertTrue(observe.contains("context.runRepo.errorMessage(of: agentRunID)"))
        XCTAssertFalse(observe.contains("context.runRepo.get(id: agentRunID)"))
        let reclaimStart = try XCTUnwrap(source.range(of: "private func reclaimOrphanedActiveRuns(now:"))
        let reclaimEnd = try XCTUnwrap(source.range(of: "private func skipMissedOccurrencesOnLaunch(now:"))
        let reclaim = String(source[reclaimStart.lowerBound..<reclaimEnd.lowerBound])
        XCTAssertTrue(reclaim.contains("context.runRepo.errorMessage(of: agentRunID)"))
        XCTAssertFalse(reclaim.contains("context.runRepo.get(id: agentRunID)"))
    }

    func test_errorMessageProbe_matchesStoredTextWithoutDurableGet() throws {
        let (threadRepo, runRepo) = try makeRepos("sched-error")
        let thread = AgentThread(title: "sched", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let message = "provider exploded"
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .failed,
            errorMessage: message
        )
        try runRepo.upsert(run)
        let getsBefore = runRepo.durableGetCountForTesting
        let probesBefore = runRepo.errorMessageProbeCountForTesting
        XCTAssertEqual(try runRepo.errorMessage(of: run.id), message)
        XCTAssertEqual(runRepo.errorMessageProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try runRepo.errorMessage(of: AgentRunID()))
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
        let cancelled = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .cancelled
        )
        try runRepo.upsert(cancelled)
        XCTAssertNil(try runRepo.errorMessage(of: cancelled.id))
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
    }

    func test_errorMessageProbe_fasterThanDurableGet() throws {
        let (threadRepo, runRepo) = try makeRepos("sched-error-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .failed,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try runRepo.upsert(run)
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
            _ = try runRepo.errorMessage(of: run.id)
            _ = try runRepo.get(id: run.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try runRepo.errorMessage(of: run.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try runRepo.get(id: run.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] scheduled-error errorMessage_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "errorMessage probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
