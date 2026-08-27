import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: fork admission compiled the 26-column agent_threads row plus
/// routing JSON just to learn whether the source exists and matches the
/// child provider.
final class ForkSourceProviderProbeTests: XCTestCase {
    func test_forkAdmission_sourceUsesProviderProbeNotGet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func forkThreadReturningPrunedThreadIDs("))
        let end = try XCTUnwrap(source.range(of: "public func reconcileForkIntentsOnLaunch("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("provider(of: sourceThreadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: sourceThreadId)"))
    }

    func test_providerProbe_matchesProviderWithoutDurableGet() throws {
        let repo = try makeRepo("fork-source-provider")
        var thread = AgentThread(title: "live", provider: .claude, model: "keep-model")
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .claude, modelId: "keep-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try repo.upsert(thread)
        let getsBefore = repo.durableGetCountForTesting
        let probesBefore = repo.providerProbeCountForTesting

        XCTAssertEqual(try repo.provider(of: thread.id), .claude)
        XCTAssertEqual(repo.providerProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try repo.provider(of: AgentThreadID()))
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)
    }

    func test_providerProbe_fasterThanDurableGet() throws {
        let repo = try makeRepo("fork-source-provider-bench")
        var thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try repo.upsert(thread)
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
            _ = try repo.provider(of: thread.id)
            _ = try repo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try repo.provider(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try repo.get(id: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] fork-source-provider provider_ms=%@ get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "provider probe must beat get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepo(_ label: String) throws -> AgentThreadRepository {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return AgentThreadRepository(db: db)
    }
}
