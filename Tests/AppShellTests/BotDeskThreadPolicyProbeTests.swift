import XCTest
@testable import AppShell
import CoreModel
import Persistence

/// WHY: host bot send compiled the 26-column agent_threads row plus routing
/// JSON just to copy permission/effort/tier/run-as-user after the caller
/// run route already froze provider/model.
@MainActor
final class BotDeskThreadPolicyProbeTests: XCTestCase {
    func test_sendHostBot_usesDeskPolicyProbeNotGet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func sendHostBot("))
        let end = try XCTUnwrap(source.range(of: "public func createHostBotThread("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.deskPolicy(of: callerThread)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: callerThread)"))
    }

    func test_deskPolicyProbe_matchesPolicyWithoutDurableGet() throws {
        let ctx = try makeContext("match")
        var thread = AgentThread(
            title: "desk",
            provider: .claude,
            model: "keep-model",
            permissionMode: .fullAccess,
            reasoningEffort: .high,
            serviceTier: .fast
        )
        thread.runAsUser = AgentRunAsUser.current()
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .claude, modelId: "keep-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try ctx.threadRepo.upsert(thread)
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.deskPolicyProbeCountForTesting
        let policy = try XCTUnwrap(try ctx.threadRepo.deskPolicy(of: thread.id))
        XCTAssertEqual(policy.permissionMode, .fullAccess)
        XCTAssertEqual(policy.reasoningEffort, .high)
        XCTAssertEqual(policy.serviceTier, .fast)
        XCTAssertEqual(policy.runAsUser?.uid, thread.runAsUser?.uid)
        XCTAssertEqual(ctx.threadRepo.deskPolicyProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try ctx.threadRepo.deskPolicy(of: AgentThreadID()))
        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBefore)
    }

    func test_deskPolicyProbe_fasterThanDurableGet() throws {
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
            _ = try ctx.threadRepo.deskPolicy(of: thread.id)
            _ = try ctx.threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.deskPolicy(of: thread.id)
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
            "[perf-proof] bot-desk-thread-policy deskPolicy_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "deskPolicy probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeContext(_ label: String) throws -> AppContext {
        let tmp = NSTemporaryDirectory() + "rc2-bot-desk-policy-\(label)-" + UUID().uuidString
        return try AppContext(channel: .debug, appSupportOverride: tmp)
    }
}
