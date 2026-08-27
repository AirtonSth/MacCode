import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: delayed auto-continue validity used to full-get 26 columns + routing
/// JSON just to learn whether durable status is still `.completed`.
final class BackgroundAwaitStatusProbeTests: XCTestCase {
    private func makeRepos(_ label: String) throws -> (
        AgentThreadRepository,
        AgentMessageRepository,
        AgentRunRepository
    ) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (
            AgentThreadRepository(db: db),
            AgentMessageRepository(db: db),
            AgentRunRepository(db: db)
        )
    }

    func test_stillValid_completedIdle_usesStatusProbeWithoutDurableGet() throws {
        let (threadRepo, messageRepo, runRepo) = try makeRepos("bg-await-status")
        var thread = AgentThread(title: "await", provider: .codex, model: "fake-model")
        thread.status = .completed
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        coordinator.seedAutoContinuationStateForTesting(thread.id)

        let getsBefore = threadRepo.durableGetCountForTesting
        let probesBefore = threadRepo.statusProbeCountForTesting
        XCTAssertTrue(
            coordinator.backgroundAwaitContinuationStillValidForTesting(thread.id, token: 1),
            "a completed idle thread with a matching token must stay eligible"
        )
        XCTAssertEqual(
            threadRepo.statusProbeCountForTesting,
            probesBefore + 1,
            "stillValid must probe status once for durable completed"
        )
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBefore,
            "stillValid must not compile a full 26-column get just to read status"
        )

        thread.status = .running
        try threadRepo.upsert(thread)
        XCTAssertFalse(
            coordinator.backgroundAwaitContinuationStillValidForTesting(thread.id, token: 1),
            "a running thread must abort the scheduled continuation"
        )
        XCTAssertEqual(threadRepo.statusProbeCountForTesting, probesBefore + 2)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)

        XCTAssertFalse(
            coordinator.backgroundAwaitContinuationStillValidForTesting(thread.id, token: 99),
            "a stale token must abort without touching SQLite"
        )
        XCTAssertEqual(threadRepo.statusProbeCountForTesting, probesBefore + 2)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
    }

    func test_stillValid_sourceUsesStatusProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "private func backgroundAwaitContinuationStillValid("))
        let end = try XCTUnwrap(source.range(of: "private func incompleteTurnContinuationRequest("))
        let body = String(source[range.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.status(of: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_backgroundAwait_statusProbe_fasterThanDurableGet() throws {
        let (threadRepo, _, _) = try makeRepos("bg-await-status-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
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
            _ = try threadRepo.status(of: thread.id)
            _ = try threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.status(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.get(id: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] bg-await status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
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
