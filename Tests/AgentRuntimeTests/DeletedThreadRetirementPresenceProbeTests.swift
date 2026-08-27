import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: deleted-thread retirement used to full-get 26 columns + routing JSON
/// (twice when the row is already gone) just to learn whether the thread exists.
final class DeletedThreadRetirementPresenceProbeTests: XCTestCase {
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

    func test_retireDeletedThreads_usesStatusProbeWithoutDurableGet() throws {
        let (threadRepo, messageRepo, runRepo) = try makeRepos("retire-status")
        let thread = AgentThread(title: "retire", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        let getsBeforePresent = threadRepo.durableGetCountForTesting
        let probesBeforePresent = threadRepo.statusProbeCountForTesting
        XCTAssertEqual(
            coordinator.retireDeletedThreads([thread.id], scheduleRetries: false)[thread.id],
            .confirmedPresent
        )
        XCTAssertEqual(
            threadRepo.statusProbeCountForTesting,
            probesBeforePresent + 1,
            "a still-present row must probe status once and return confirmedPresent"
        )
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBeforePresent,
            "presence must not compile a full 26-column get"
        )

        try threadRepo.delete(id: thread.id)
        let getsBeforeMissing = threadRepo.durableGetCountForTesting
        let probesBeforeMissing = threadRepo.statusProbeCountForTesting
        XCTAssertEqual(
            coordinator.retireDeletedThreads([thread.id], scheduleRetries: false)[thread.id],
            .retired
        )
        XCTAssertEqual(
            threadRepo.statusProbeCountForTesting,
            probesBeforeMissing + 2,
            "a deleted row is re-read immediately before adapter work"
        )
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBeforeMissing,
            "deleted-row retirement must not compile a full 26-column get"
        )
    }

    func test_isDeletedThreadPresentForRetirement_sourceUsesStatusProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "private func isDeletedThreadPresentForRetirement("))
        let end = try XCTUnwrap(source.range(of: "private func hasDurableActiveRun("))
        let body = String(source[range.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.status(of: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_deletedThreadRetirement_statusProbe_fasterThanDurableGet() throws {
        let (threadRepo, _, _) = try makeRepos("retire-status-bench")
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
            "[perf-proof] retire-deleted status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
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
