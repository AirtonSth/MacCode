import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: fork launch recovery and prepared-fork admission compiled the
/// 26-column agent_threads row plus routing JSON just to learn whether
/// the source thread still exists.
final class ForkSourceExistenceProbeTests: XCTestCase {
    private func makeRepos(_ label: String) throws -> AgentThreadRepository {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return AgentThreadRepository(db: db)
    }

    private func fatThread(title: String) -> AgentThread {
        var thread = AgentThread(title: title, provider: .codex, model: "fake-model")
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        return thread
    }

    func test_forkSourceExistence_sourceUsesStatusProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let launchStart = try XCTUnwrap(source.range(of: "private func reconcileForkIntentOnLaunch("))
        let launchEnd = try XCTUnwrap(source.range(of: "private func recordForkLaunchRecoveryError("))
        let launch = String(source[launchStart.lowerBound..<launchEnd.lowerBound])
        XCTAssertTrue(launch.contains("threadRepo.status(of: intent.sourceThreadId)"))
        XCTAssertFalse(launch.contains("threadRepo.get(id: intent.sourceThreadId) != nil"))
        let forkStart = try XCTUnwrap(source.range(of: "private func reconcileForkIntent("))
        let forkEnd = try XCTUnwrap(source.range(of: "public func rollbackThread("))
        let fork = String(source[forkStart.lowerBound..<forkEnd.lowerBound])
        XCTAssertTrue(fork.contains("threadRepo.status(of: intent.sourceThreadId)"))
        XCTAssertFalse(fork.contains("threadRepo.get(id: intent.sourceThreadId) != nil"))
    }

    func test_statusProbe_matchesExistenceWithoutDurableGet() throws {
        let threadRepo = try makeRepos("fork-exist")
        let thread = fatThread(title: "fork-source")
        try threadRepo.upsert(thread)
        let getsBefore = threadRepo.durableGetCountForTesting
        let probesBefore = threadRepo.statusProbeCountForTesting
        XCTAssertNotNil(try threadRepo.status(of: thread.id))
        XCTAssertEqual(threadRepo.statusProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try threadRepo.status(of: AgentThreadID()))
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
    }

    func test_statusProbe_fasterThanDurableGet() throws {
        let threadRepo = try makeRepos("fork-bench")
        let thread = fatThread(title: "bench")
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
            "[perf-proof] fork-source status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "status probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
