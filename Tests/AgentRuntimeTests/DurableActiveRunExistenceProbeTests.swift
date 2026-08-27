import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: Stop-wait polled durableActiveRun every 20ms, compiling the 10-column
/// agent_runs row including error_message just to learn pending/running
/// existence. Stop chrome and desk live-thread discovery did the same.
final class DurableActiveRunExistenceProbeTests: XCTestCase {
    func test_existenceCallers_sourceUsesHasDurableActiveRunNotGet() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coord = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let stopStart = try XCTUnwrap(coord.range(of: "public func stopAndAwaitTermination(threadId:"))
        let stopEnd = try XCTUnwrap(coord.range(of: "private func terminationTimeoutError("))
        let stopBody = String(coord[stopStart.lowerBound..<stopEnd.lowerBound])
        XCTAssertTrue(stopBody.contains("hasDurableActiveRun(threadId: threadId)"))
        XCTAssertFalse(stopBody.contains("durableActiveRun(threadId: threadId) != nil"))

        let surface = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let hasStart = try XCTUnwrap(surface.range(of: "private func hasStoppableRun(threadId:"))
        let hasEnd = try XCTUnwrap(surface.range(of: "private func clearStaleRunProjection("))
        let hasBody = String(surface[hasStart.lowerBound..<hasEnd.lowerBound])
        XCTAssertTrue(hasBody.contains("hasDurableActiveRun(threadId: threadId)"))
        XCTAssertFalse(hasBody.contains("durableActiveRun(threadId: threadId) != nil"))

        let bots = try String(
            contentsOf: root.appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        let liveStart = try XCTUnwrap(bots.range(of: "private func liveThreadIDs("))
        let liveEnd = try XCTUnwrap(bots.range(of: "public func reloadQueuedFollowUpsFromStore("))
        let liveBody = String(bots[liveStart.lowerBound..<liveEnd.lowerBound])
        XCTAssertTrue(liveBody.contains("hasDurableActiveRun(threadId: threadID)"))
        XCTAssertFalse(liveBody.contains("durableActiveRun(threadId: threadID) != nil"))
    }

    func test_hasActiveProbe_matchesPresenceWithoutDurableGet() throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo) = try makeRepos("durable-active-existence")
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [:]
        )
        let thread = AgentThread(title: "live", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .running,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try runRepo.upsert(run)
        let getsBefore = runRepo.durableGetCountForTesting
        let probesBefore = runRepo.hasActiveProbeCountForTesting

        XCTAssertTrue(try runRepo.hasActive(for: thread.id))
        XCTAssertTrue(try coordinator.hasDurableActiveRun(threadId: thread.id))
        XCTAssertEqual(runRepo.hasActiveProbeCountForTesting, probesBefore + 2)
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)

        var done = run
        done.status = .completed
        try runRepo.upsert(done)
        XCTAssertFalse(try runRepo.hasActive(for: thread.id))
        XCTAssertFalse(try coordinator.hasDurableActiveRun(threadId: thread.id))
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertFalse(try runRepo.hasActive(for: AgentThreadID()))
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
    }

    func test_hasActiveProbe_fasterThanLatestActive() throws {
        let (threadRepo, _, runRepo, _) = try makeRepos("durable-active-existence-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .running,
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
            _ = try runRepo.hasActive(for: thread.id)
            _ = try runRepo.latestActive(for: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try runRepo.hasActive(for: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try runRepo.latestActive(for: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] durable-active-existence hasActive_ms=%@ latestActive_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "hasActive probe must beat latestActive by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

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
}
