import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: LaunchAgent live poll (every 2s on MainActor), Working-for clocks,
/// iOS active-run snapshots, and Stop targeting compiled the 10-column
/// agent_runs row including error_message just for id + started_at.
final class DurableActiveRunChromeProbeTests: XCTestCase {
    func test_chromeCallers_sourceUsesDurableActiveRunChromeNotGet() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let surface = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        for needle in ["private func bindScheduledOwnedRun(", "private func tickScheduledLivePoll("] {
            let start = try XCTUnwrap(surface.range(of: needle))
            let body = String(surface[start.lowerBound...].prefix(1600))
            XCTAssertTrue(body.contains("durableActiveRunChrome(threadId:"))
            XCTAssertFalse(body.contains("durableActiveRun(threadId:"))
        }

        let coord = try String(
            contentsOf: root.appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        // Token Saver removal deleted the respondToUserInput caller; Stop
        // targeting is the remaining coordinator chrome caller.
        XCTAssertGreaterThanOrEqual(
            coord.components(separatedBy: "durableActiveRunChrome(threadId: threadId)").count - 1,
            1
        )
        let stop = try XCTUnwrap(coord.range(of: "public func stopAndAwaitTermination(threadId:"))
        let stopBody = String(coord[stop.lowerBound...].prefix(2400))
        XCTAssertTrue(stopBody.contains("durableActiveRunChrome(threadId: threadId)"))
        XCTAssertFalse(stopBody.contains("durableActiveRun(threadId: threadId)"))

        let router = try String(
            contentsOf: root.appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let active = try XCTUnwrap(router.range(of: "public func activeAgentRun(thread:"))
        let activeBody = String(router[active.lowerBound...].prefix(1200))
        XCTAssertTrue(activeBody.contains("durableActiveRunChrome(threadId: thread)"))
        XCTAssertFalse(activeBody.contains("durableActiveRun(threadId: thread)"))
    }

    func test_latestActiveChromeProbe_matchesIdAndStartedAtWithoutDurableGet() throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo) = try makeRepos("durable-active-chrome")
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [:]
        )
        let thread = AgentThread(title: "live", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .running,
            startedAt: started,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try runRepo.upsert(run)
        let getsBefore = runRepo.durableGetCountForTesting
        let probesBefore = runRepo.activeChromeProbeCountForTesting

        let chrome = try XCTUnwrap(runRepo.latestActiveChrome(for: thread.id))
        XCTAssertEqual(chrome.id, run.id)
        XCTAssertEqual(chrome.startedAt.timeIntervalSince1970, started.timeIntervalSince1970, accuracy: 1)
        let coordinated = try XCTUnwrap(coordinator.durableActiveRunChrome(threadId: thread.id))
        XCTAssertEqual(coordinated.id, run.id)
        XCTAssertEqual(runRepo.activeChromeProbeCountForTesting, probesBefore + 2)
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try runRepo.latestActiveChrome(for: AgentThreadID()))
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)

        var done = run
        done.status = .completed
        try runRepo.upsert(done)
        XCTAssertNil(try runRepo.latestActiveChrome(for: thread.id))
        XCTAssertNil(try runRepo.activeRunChrome(of: run.id))
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
    }

    func test_latestActiveChromeProbe_fasterThanLatestActive() throws {
        let (threadRepo, _, runRepo, _) = try makeRepos("durable-active-chrome-bench")
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
            _ = try runRepo.latestActiveChrome(for: thread.id)
            _ = try runRepo.latestActive(for: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try runRepo.latestActiveChrome(for: thread.id)
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
            "[perf-proof] durable-active-chrome latestActiveChrome_ms=%@ latestActive_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "latestActiveChrome probe must beat latestActive by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
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
