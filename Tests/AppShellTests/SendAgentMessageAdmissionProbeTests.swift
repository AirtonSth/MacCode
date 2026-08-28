import XCTest
@testable import AppShell
import CoreModel
import Persistence

/// WHY: sendAgentMessage compiled the 26-column agent_threads row plus routing
/// JSON just to copy status/permission/provider/instance before
/// configureAgentThread loaded the row again for mutate.
@MainActor
final class SendAgentMessageAdmissionProbeTests: XCTestCase {
    func test_sendAgentMessage_sourceUsesSendAdmissionNotGet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func sendAgentMessage(thread: AgentThreadID, text: String, provider: AgentProvider?"))
        let end = try XCTUnwrap(source.range(of: "var t = try configureAgentThread("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.sendAdmission(of: thread)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: thread)"))
    }

    func test_sendAdmissionProbe_matchesAdmissionWithoutDurableGet() throws {
        let ctx = try makeContext("match")
        var thread = AgentThread(
            title: "send",
            provider: .claude,
            providerInstanceId: "claude-cli",
            model: "keep-model",
            status: .running,
            permissionMode: .fullAccess,
            reasoningEffort: .high,
            serviceTier: .fast
        )
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .claude, modelId: "keep-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try ctx.threadRepo.upsert(thread)
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.sendAdmissionProbeCountForTesting
        let admission = try XCTUnwrap(try ctx.threadRepo.sendAdmission(of: thread.id))
        XCTAssertEqual(admission.status, .running)
        XCTAssertEqual(admission.permissionMode, .fullAccess)
        XCTAssertEqual(admission.provider, .claude)
        XCTAssertEqual(admission.providerInstanceId, "claude-cli")
        XCTAssertEqual(admission.model, "keep-model")
        XCTAssertEqual(admission.reasoningEffort, .high)
        XCTAssertEqual(admission.serviceTier, .fast)
        XCTAssertEqual(ctx.threadRepo.sendAdmissionProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try ctx.threadRepo.sendAdmission(of: AgentThreadID()))
        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBefore)
    }

    func test_sendAdmissionProbe_fasterThanDurableGet() throws {
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
            _ = try ctx.threadRepo.sendAdmission(of: thread.id)
            _ = try ctx.threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.sendAdmission(of: thread.id)
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
            "[perf-proof] send-agent-message-admission sendAdmission_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "sendAdmission probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeContext(_ label: String) throws -> AppContext {
        let tmp = NSTemporaryDirectory() + "rc2-send-admission-\(label)-" + UUID().uuidString
        return try AppContext(channel: .debug, appSupportOverride: tmp)
    }
}
