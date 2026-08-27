import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: persistProviderNativeSubagentLifecycle compiled the 10-column
/// agent_runs row (including error_message) just to copy provider/model.
final class SubagentLifecycleProviderProbeTests: XCTestCase {
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

    func test_subagentLifecycle_sourceUsesProviderAndModelProbes() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func persistProviderNativeSubagentLifecycle("))
        let end = try XCTUnwrap(source.range(of: "private func scheduleTerminalDurabilityRetry("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("runRepo.provider(of: parentRunId)"))
        XCTAssertTrue(body.contains("runRepo.model(of: parentRunId)"))
        XCTAssertFalse(body.contains("runRepo.get(id: parentRunId)"))
    }

    func test_providerProbe_matchesStoredProviderWithoutDurableGet() throws {
        let (threadRepo, runRepo) = try makeRepos("subagent-provider")
        let thread = AgentThread(title: "subagent", provider: .grok, model: "fake-model")
        try threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .grok,
            model: "fake-model",
            status: .running,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try runRepo.upsert(run)
        let getsBefore = runRepo.durableGetCountForTesting
        let probesBefore = runRepo.providerProbeCountForTesting
        XCTAssertEqual(try runRepo.provider(of: run.id), .grok)
        XCTAssertEqual(runRepo.providerProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try runRepo.provider(of: AgentRunID()))
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertEqual(try runRepo.model(of: run.id), "fake-model")
        XCTAssertEqual(runRepo.durableGetCountForTesting, getsBefore)
    }

    func test_providerProbe_fasterThanDurableGet() throws {
        let (threadRepo, runRepo) = try makeRepos("subagent-provider-bench")
        let thread = AgentThread(title: "bench", provider: .grok, model: "fake-model")
        try threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .grok,
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
            _ = try runRepo.provider(of: run.id)
            _ = try runRepo.get(id: run.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try runRepo.provider(of: run.id)
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
            "[perf-proof] subagent-lifecycle provider_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "provider probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
