import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: start-gate pendingTerminalRunIds used to full-get the 10-column
/// agent_runs row (including error_message) just to compare thread_id.
final class PendingTerminalThreadIdProbeTests: XCTestCase {
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

    func test_pendingTerminalRunIds_sourceUsesThreadIdProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "private func pendingTerminalRunIds(for threadId: AgentThreadID)"))
        let body = String(source[range.lowerBound...].prefix(420))
        XCTAssertTrue(body.contains("runRepo.threadId(of: runId)"))
        XCTAssertFalse(body.contains("runRepo.get(id: runId)"))
    }

    func test_threadIdProbe_matchesStoredThreadWithoutDurableGet() throws {
        let (threadRepo, runRepo) = try makeRepos("pending-terminal-thread-id")
        let thread = AgentThread(title: "live", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .failed,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try runRepo.upsert(run)

        let getsBefore = runRepo.durableGetCountForTesting
        let probesBefore = runRepo.threadIdProbeCountForTesting
        XCTAssertEqual(try runRepo.threadId(of: run.id), thread.id)
        XCTAssertEqual(runRepo.threadIdProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try runRepo.threadId(of: AgentRunID()))
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertFalse((try? runRepo.threadId(of: run.id) == AgentThreadID()) ?? false)
    }

    func test_threadIdProbe_fasterThanDurableGet() throws {
        let (threadRepo, runRepo) = try makeRepos("pending-terminal-thread-id-bench")
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
            _ = try runRepo.threadId(of: run.id)
            _ = try runRepo.get(id: run.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try runRepo.threadId(of: run.id)
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
            "[perf-proof] pending-terminal threadId_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "threadId probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
