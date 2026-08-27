import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: requestAdmittingAutoRoute compiled the 26-column agent_threads row
/// plus routing JSON just to copy effectiveRoutingConfiguration when the
/// painted snapshot was nil (scheduled / snapshot-less starts).
final class AutoRouteRoutingProbeTests: XCTestCase {
    private func makeRepos(_ label: String) throws -> AgentThreadRepository {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return AgentThreadRepository(db: db)
    }

    private func fatThread(
        title: String,
        mode: AgentRoutingMode
    ) -> AgentThread {
        var thread = AgentThread(title: title, provider: .codex, model: "fake-model")
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: mode,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        return thread
    }

    func test_requestAdmittingAutoRoute_sourceUsesRoutingConfigurationProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func requestAdmittingAutoRoute("))
        let end = try XCTUnwrap(source.range(of: "private static func autoDeepFallbackRequest("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.routingConfiguration(of: request.threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: request.threadId)"))
    }

    func test_routingConfigurationProbe_matchesStoredRoutingWithoutDurableGet() throws {
        let threadRepo = try makeRepos("auto-route-chrome")
        let auto = fatThread(title: "auto", mode: .auto)
        try threadRepo.upsert(auto)
        let getsBefore = threadRepo.durableGetCountForTesting
        let probesBefore = threadRepo.routingConfigurationProbeCountForTesting
        XCTAssertEqual(try threadRepo.routingConfiguration(of: auto.id)?.mode, .auto)
        XCTAssertEqual(threadRepo.routingConfigurationProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try threadRepo.routingConfiguration(of: AgentThreadID()))
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        let manual = fatThread(title: "manual", mode: .manual)
        try threadRepo.upsert(manual)
        XCTAssertEqual(try threadRepo.routingConfiguration(of: manual.id)?.mode, .manual)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        let legacy = AgentThread(title: "legacy", provider: .codex, model: "fake-model")
        try threadRepo.upsert(legacy)
        XCTAssertNil(try threadRepo.routingConfiguration(of: legacy.id))
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertEqual(try threadRepo.get(id: auto.id)?.effectiveRoutingConfiguration.mode, .auto)
    }

    func test_routingConfigurationProbe_fasterThanDurableGet() throws {
        let threadRepo = try makeRepos("auto-route-bench")
        let thread = fatThread(title: "bench", mode: .manual)
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
            _ = try threadRepo.routingConfiguration(of: thread.id)
            _ = try threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.routingConfiguration(of: thread.id)
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
            "[perf-proof] auto-route routingConfiguration_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "routingConfiguration probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
