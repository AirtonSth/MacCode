import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: Agent App selectThread / run-start chrome used to full-get the
/// 10-column agent_runs row (including error_message) just to copy started_at
/// into "Working for Xs".
final class RunStartedAtTimingProbeTests: XCTestCase {
    private func makeRepos(_ label: String) throws -> (
        AgentThreadRepository,
        AgentMessageRepository,
        AgentRunRepository,
        ProviderSessionRuntimeRepository
    ) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (
            AgentThreadRepository(db: db),
            AgentMessageRepository(db: db),
            AgentRunRepository(db: db),
            ProviderSessionRuntimeRepository(db: db)
        )
    }

    private func makeCoordinator(
        threadRepo: AgentThreadRepository,
        messageRepo: AgentMessageRepository,
        runRepo: AgentRunRepository,
        sessionRepo: ProviderSessionRuntimeRepository
    ) -> AgentRunCoordinator {
        AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [:]
        )
    }

    func test_runStartedAt_sourceUsesTimingProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let runIdRange = try XCTUnwrap(source.range(of: "public func runStartedAt(runId: AgentRunID)"))
        let runIdBody = String(source[runIdRange.lowerBound...].prefix(280))
        XCTAssertTrue(runIdBody.contains("runRepo.timing(of: runId)"))
        XCTAssertFalse(runIdBody.contains("runRepo.get(id: runId)"))

        let threadRange = try XCTUnwrap(source.range(of: "public func runStartedAt(threadId: AgentThreadID)"))
        let threadBody = String(source[threadRange.lowerBound...].prefix(700))
        XCTAssertTrue(threadBody.contains("runRepo.timing(of: runId)"))
        XCTAssertTrue(threadBody.contains("latestActive(for: threadId)"))
        XCTAssertFalse(threadBody.contains("runRepo.get("))
    }

    func test_runStartedAt_matchesStoredClockWithoutDurableGet() throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo) = try makeRepos("run-started-at")
        let coordinator = makeCoordinator(
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            runRepo: runRepo,
            sessionRepo: sessionRepo
        )
        let thread = AgentThread(title: "clock", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .running,
            startedAt: startedAt,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try runRepo.upsert(run)

        let getsBefore = runRepo.durableGetCountForTesting
        let timingBefore = runRepo.timingProbeCountForTesting
        let probedRun = try XCTUnwrap(coordinator.runStartedAt(runId: run.id))
        XCTAssertEqual(probedRun.timeIntervalSince1970, startedAt.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(runRepo.timingProbeCountForTesting, timingBefore + 1)
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
        let probedThread = try XCTUnwrap(coordinator.runStartedAt(threadId: thread.id))
        XCTAssertEqual(probedThread.timeIntervalSince1970, startedAt.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try coordinator.runStartedAt(runId: AgentRunID()))
        XCTAssertNil(try coordinator.runStartedAt(threadId: AgentThreadID()))
    }

    func test_runStartedAt_timingProbe_fasterThanDurableGet() throws {
        let (threadRepo, _, runRepo, _) = try makeRepos("run-started-at-bench")
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
            _ = try runRepo.timing(of: run.id)
            _ = try runRepo.get(id: run.id)
        }
        var timingSamples: [Double] = []
        var getSamples: [Double] = []
        timingSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            timingSamples.append(try timeMs {
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
        let timingMed = median(timingSamples)
        let getMed = median(getSamples)
        let timingImprovement = (getMed - timingMed) / getMed * 100.0
        NSLog(
            "[perf-proof] run-started-at timing_probe_ms=%@ durable_get_ms=%@ timing_improvement_pct=%.2f timing=%@ get=%@",
            String(timingMed), String(getMed), timingImprovement,
            String(describing: timingSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            timingImprovement,
            5.0,
            "timing probe must beat durable get by ≥5% (got \(timingImprovement)%; probe=\(timingMed)ms get=\(getMed)ms)"
        )
    }
}
