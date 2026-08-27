import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: every durable terminal used to full-get the 10-column agent_runs row
/// (including error_message) just to log durationMs from started_at/finished_at.
final class RunFinishedDurationTimingProbeTests: XCTestCase {
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

    func test_durationMs_sourceUsesTimingProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "let durationMs ="))
        let body = String(source[range.lowerBound...].prefix(420))
        XCTAssertTrue(body.contains("runRepo.timing(of: runId)"))
        XCTAssertFalse(body.contains("runRepo.get(id: runId)"))
    }

    func test_timingProbe_matchesStoredDurationWithoutDurableGet() throws {
        let (threadRepo, runRepo) = try makeRepos("run-finished-duration")
        let thread = AgentThread(title: "done", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let finishedAt = Date(timeIntervalSince1970: 1_700_000_012)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .completed,
            startedAt: startedAt,
            finishedAt: finishedAt,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try runRepo.upsert(run)

        let getsBefore = runRepo.durableGetCountForTesting
        let probesBefore = runRepo.timingProbeCountForTesting
        let timing = try XCTUnwrap(runRepo.timing(of: run.id))
        let finished = try XCTUnwrap(timing.finishedAt)
        let durationMs = Int64(finished.timeIntervalSince(timing.startedAt) * 1000)
        XCTAssertEqual(durationMs, 12_000)
        XCTAssertEqual(runRepo.timingProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try runRepo.timing(of: AgentRunID()))
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
    }

    func test_timingProbe_fasterThanDurableGet() throws {
        let (threadRepo, runRepo) = try makeRepos("run-finished-duration-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .failed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_012),
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
            _ = try runRepo.timing(of: run.id)
            _ = try runRepo.get(id: run.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try runRepo.timing(of: run.id)
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
            "[perf-proof] run-finished-duration timing_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "timing probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
