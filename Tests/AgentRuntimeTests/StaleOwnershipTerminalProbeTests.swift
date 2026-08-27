import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: rail reload / Stop / finish used to full-get the 10-column agent_runs
/// row (including error_message) just to learn finishedAt and status before
/// releasing a ghost Working run.
final class StaleOwnershipTerminalProbeTests: XCTestCase {
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

    func test_staleOwnership_sourceUsesTerminalProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let reconcileRange = try XCTUnwrap(
            source.range(of: "public func reconcileStaleActiveOwnershipWithDurableState()")
        )
        let reconcileBody = String(source[reconcileRange.lowerBound...].prefix(900))
        XCTAssertTrue(reconcileBody.contains("runRepo.terminal(of: runId)"))
        XCTAssertFalse(reconcileBody.contains("runRepo.get(id: runId)"))

        let stopRange = try XCTUnwrap(source.range(of: "private func markStopRequested(threadId:"))
        let stopBody = String(source[stopRange.lowerBound...].prefix(2800))
        XCTAssertTrue(stopBody.contains("runRepo.terminal(of: runId)"))

        XCTAssertEqual(
            source.components(separatedBy: "runRepo.terminal(of: runId)").count - 1,
            3,
            "reconcile, Stop, and finish durable-terminal guards must share terminal(of:)"
        )
    }

    func test_terminalProbe_matchesStoredStatusAndFinishedAtWithoutDurableGet() throws {
        let (threadRepo, runRepo) = try makeRepos("stale-terminal")
        let thread = AgentThread(title: "ghost", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let finishedAt = Date(timeIntervalSince1970: 1_700_000_012)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .failed,
            startedAt: startedAt,
            finishedAt: finishedAt,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try runRepo.upsert(run)

        let getsBefore = runRepo.durableGetCountForTesting
        let probesBefore = runRepo.terminalProbeCountForTesting
        let chrome = try XCTUnwrap(runRepo.terminal(of: run.id))
        XCTAssertEqual(chrome.status, .failed)
        let probedFinished = try XCTUnwrap(chrome.finishedAt)
        XCTAssertEqual(probedFinished.timeIntervalSince1970, finishedAt.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(runRepo.terminalProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try runRepo.terminal(of: AgentRunID()))

        let live = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .running,
            startedAt: startedAt
        )
        try runRepo.upsert(live)
        let liveChrome = try XCTUnwrap(runRepo.terminal(of: live.id))
        XCTAssertEqual(liveChrome.status, .running)
        XCTAssertNil(liveChrome.finishedAt)
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
    }

    func test_terminalProbe_fasterThanDurableGet() throws {
        let (threadRepo, runRepo) = try makeRepos("stale-terminal-bench")
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
            _ = try runRepo.terminal(of: run.id)
            _ = try runRepo.get(id: run.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try runRepo.terminal(of: run.id)
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
            "[perf-proof] stale-ownership-terminal terminal_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "terminal probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
