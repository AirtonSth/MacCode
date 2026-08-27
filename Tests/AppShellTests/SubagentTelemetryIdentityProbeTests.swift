import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// WHY: subagent telemetry env (every run/recovery, including Token Saver off)
/// used to full-get 26 columns + routing JSON just for model and instance.
@MainActor
final class SubagentTelemetryIdentityProbeTests: XCTestCase {
    func test_subagentTelemetryEnvironment_usesIdentityProbeWithoutDurableGet() throws {
        let tmp = NSTemporaryDirectory() + "rc2-subagent-identity-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let thread = AgentThread(
            title: "telemetry",
            provider: .codex,
            model: "fake-model",
            status: .completed
        )
        try ctx.threadRepo.upsert(thread)
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.identityProbeCountForTesting
        let env = ctx.subagentTelemetryEnvironment(provider: .codex, threadId: thread.id)
        XCTAssertEqual(env["REMOTE_CODE_AGENT_MODEL"], "fake-model")
        XCTAssertEqual(env["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"], thread.id.value.uuidString)
        XCTAssertEqual(env["REMOTE_CODE_AGENT_PROVIDER"], "codex")
        XCTAssertEqual(
            ctx.threadRepo.identityProbeCountForTesting,
            probesBefore + 1,
            "subagent telemetry must probe identity once"
        )
        XCTAssertEqual(
            ctx.threadRepo.durableGetCountForTesting,
            getsBefore,
            "subagent telemetry must not compile a full 26-column get"
        )
    }

    func test_subagentTelemetryEnvironment_sourceUsesIdentityProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppContext.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "func subagentTelemetryEnvironment("))
        let end = try XCTUnwrap(source.range(of: "private static func subagentTelemetryExecutableURL("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.identity(of: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_subagentTelemetryIdentity_fasterThanDurableGet() throws {
        let tmp = NSTemporaryDirectory() + "rc2-subagent-identity-bench-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
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
            _ = try ctx.threadRepo.identity(of: thread.id)
            _ = try ctx.threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.identity(of: thread.id)
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
            "[perf-proof] subagent-telemetry identity_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "identity probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
