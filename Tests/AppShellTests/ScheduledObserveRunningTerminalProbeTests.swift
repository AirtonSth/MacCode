import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// WHY: scheduled-task observe ticks compiled the 10-column agent_runs row
/// (including error_message) just to copy status and finished_at.
final class ScheduledObserveRunningTerminalProbeTests: XCTestCase {
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

    func test_observeRunning_sourceUsesTerminalProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func observeRunning(now:"))
        let end = try XCTUnwrap(source.range(of: "private func notifyFailure(for"))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("context.runRepo.terminal(of: agentRunID)"))
        XCTAssertTrue(body.contains("context.runRepo.errorMessage(of: agentRunID)"))
        XCTAssertFalse(body.contains("context.runRepo.get(id: agentRunID)"))
        XCTAssertLessThan(
            try XCTUnwrap(body.range(of: "context.runRepo.terminal(of: agentRunID)")).lowerBound,
            try XCTUnwrap(body.range(of: "context.runRepo.errorMessage(of: agentRunID)")).lowerBound
        )
    }

    func test_terminalProbe_matchesStatusWithoutDurableGet() throws {
        let (threadRepo, runRepo) = try makeRepos("sched-observe")
        let thread = AgentThread(title: "sched", provider: .codex, model: "fake-model")
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
        let probesBefore = runRepo.terminalProbeCountForTesting
        let chrome = try XCTUnwrap(runRepo.terminal(of: run.id))
        XCTAssertEqual(chrome.status, .completed)
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
        let (threadRepo, runRepo) = try makeRepos("sched-observe-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
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
            "[perf-proof] sched-observe terminal_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
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
