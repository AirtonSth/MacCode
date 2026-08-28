import XCTest
@testable import AppShell
import CoreModel
import Persistence

/// WHY: agent.message.send compiled the 26-column agent_threads row plus
/// routing JSON just to check existence and routing revision/mode before
/// sendAgentMessage loaded the row again for mutate.
@MainActor
final class SendAgentMessageRoutingProbeTests: XCTestCase {
    func test_sendAgentMessageRouting_sourceUsesStatusAndRoutingProbesNotGet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func sendAgentMessageRouting("))
        let end = try XCTUnwrap(source.range(of: "private func preflightAgentRun("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.status(of: thread)"))
        XCTAssertTrue(body.contains("threadRepo.routingConfiguration(of: thread)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: thread)"))
    }

    func test_statusAndRoutingProbes_matchAdmissionWithoutDurableGet() throws {
        let ctx = try makeContext("match")
        var auto = AgentThread(title: "auto", provider: .codex, model: "fake-model")
        auto.routingConfiguration = AgentRoutingConfiguration(
            mode: .auto,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024),
            revision: 4
        )
        try ctx.threadRepo.upsert(auto)
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let statusBefore = ctx.threadRepo.statusProbeCountForTesting
        let routingBefore = ctx.threadRepo.routingConfigurationProbeCountForTesting

        XCTAssertNotNil(try ctx.threadRepo.status(of: auto.id))
        XCTAssertEqual(try ctx.threadRepo.routingConfiguration(of: auto.id)?.mode, .auto)
        XCTAssertEqual(try ctx.threadRepo.routingConfiguration(of: auto.id)?.revision, 4)
        XCTAssertEqual(ctx.threadRepo.statusProbeCountForTesting, statusBefore + 1)
        XCTAssertEqual(ctx.threadRepo.routingConfigurationProbeCountForTesting, routingBefore + 2)
        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBefore)

        XCTAssertNil(try ctx.threadRepo.status(of: AgentThreadID()))
        XCTAssertNil(try ctx.threadRepo.routingConfiguration(of: AgentThreadID()))
        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBefore)

        let legacy = AgentThread(title: "legacy", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(legacy)
        XCTAssertNotNil(try ctx.threadRepo.status(of: legacy.id))
        XCTAssertNil(try ctx.threadRepo.routingConfiguration(of: legacy.id))
        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBefore)
    }

    func test_statusAndRoutingProbes_fasterThanDurableGet() throws {
        let ctx = try makeContext("bench")
        var thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try ctx.threadRepo.upsert(thread)
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
            _ = try ctx.threadRepo.status(of: thread.id)
            _ = try ctx.threadRepo.routingConfiguration(of: thread.id)
            _ = try ctx.threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.status(of: thread.id)
                    _ = try ctx.threadRepo.routingConfiguration(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.get(id: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] send-agent-message-routing status+routing_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "status+routing probes must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeContext(_ label: String) throws -> AppContext {
        let tmp = NSTemporaryDirectory() + "rc2-send-routing-\(label)-" + UUID().uuidString
        return try AppContext(channel: .debug, appSupportOverride: tmp)
    }
}
