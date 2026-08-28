import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// WHY: every run start compiled the 10-column agent_runs row (including
/// error_message) just to copy provider/model before Token Saver admission.
@MainActor
final class TokenSaverAttemptModelProbeTests: XCTestCase {
    func test_beginTokenSaverAttempt_sourceUsesProviderAndModelProbes() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppContext.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func beginTokenSaverAttempt("))
        let end = try XCTUnwrap(source.range(of: "private func appendTokenSaverProviderUsage("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("tokenSaverProjectObservation(runId: runId, lane: \"measurement\")"))
        XCTAssertTrue(body.contains("runRepo.provider(of: runId)"))
        XCTAssertTrue(body.contains("runRepo.model(of: runId)"))
        XCTAssertFalse(body.contains("runRepo.get(id: runId)"))
        let admission = body.range(of: "tokenSaverProjectObservation(runId: runId, lane: \"measurement\")")
        let getProvider = body.range(of: "runRepo.provider(of: runId)")
        XCTAssertLessThan(
            try XCTUnwrap(admission).lowerBound,
            try XCTUnwrap(getProvider).lowerBound,
            "admission must run before provider/model probes so denied starts skip SQLite chrome"
        )
    }

    func test_runStarted_deniedMeasurement_skipsDurableGet() throws {
        let ctx = try makeContext("denied")
        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = true }
        let thread = AgentThread(title: "attempt", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .running,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try ctx.runRepo.upsert(run)
        let getsBefore = ctx.runRepo.durableGetCountForTesting
        let providerBefore = ctx.runRepo.providerProbeCountForTesting
        let modelBefore = ctx.runRepo.modelProbeCountForTesting
        ctx.coordinator.onRunStarted?(thread.id, run.id)
        XCTAssertEqual(
            ctx.runRepo.durableGetCountForTesting,
            getsBefore,
            "denied Token Saver attempt begin must not compile a full 10-column get"
        )
        XCTAssertEqual(
            ctx.runRepo.providerProbeCountForTesting,
            providerBefore,
            "denied admission must not probe provider"
        )
        XCTAssertEqual(
            ctx.runRepo.modelProbeCountForTesting,
            modelBefore,
            "denied admission must not probe model"
        )
    }

    func test_modelProbe_matchesStoredModelWithoutDurableGet() throws {
        let ctx = try makeContext("model-match")
        let thread = AgentThread(title: "attempt", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .running,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try ctx.runRepo.upsert(run)
        let getsBefore = ctx.runRepo.durableGetCountForTesting
        let probesBefore = ctx.runRepo.modelProbeCountForTesting
        XCTAssertEqual(try ctx.runRepo.model(of: run.id), "fake-model")
        XCTAssertEqual(ctx.runRepo.modelProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(ctx.runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try ctx.runRepo.model(of: AgentRunID()))
        XCTAssertEqual(ctx.runRepo.durableGetCountForTesting, getsBefore)
    }

    func test_modelProbe_fasterThanDurableGet() throws {
        let ctx = try makeContext("bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .running,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try ctx.runRepo.upsert(run)
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
            _ = try ctx.runRepo.model(of: run.id)
            _ = try ctx.runRepo.get(id: run.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.runRepo.model(of: run.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.runRepo.get(id: run.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] token-saver-attempt model_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "model probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeContext(_ label: String) throws -> AppContext {
        let tmp = NSTemporaryDirectory() + "rc2-ts-attempt-model-\(label)-" + UUID().uuidString
        return try AppContext(channel: .debug, appSupportOverride: tmp)
    }
}
