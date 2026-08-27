import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// WHY: run-finish Token Saver still compiled the 10-column agent_runs row
/// (including error_message) just to copy provider for Grok refresh and
/// usage tombstones.
@MainActor
final class TokenSaverFinishProviderProbeTests: XCTestCase {
    func test_runFinishPaths_sourceUsesProviderProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppContext.swift"),
            encoding: .utf8
        )
        let finishStart = try XCTUnwrap(source.range(of: "coordinator.onRunFinished = {"))
        let finishEnd = try XCTUnwrap(source.range(of: "self.cancelQueueDrainWaiter(threadId: tid)"))
        let finish = String(source[finishStart.lowerBound..<finishEnd.lowerBound])
        XCTAssertTrue(finish.contains("runRepo.provider(of: rid)"))
        XCTAssertFalse(finish.contains("runRepo.get(id: rid)"))
        let pendingStart = try XCTUnwrap(source.range(of: "private func finishPendingTokenSaverUsage("))
        let pendingEnd = try XCTUnwrap(source.range(of: "private func completeTokenSaverUsageWrite("))
        let pending = String(source[pendingStart.lowerBound..<pendingEnd.lowerBound])
        XCTAssertTrue(pending.contains("runRepo.provider(of: runId)"))
        XCTAssertFalse(pending.contains("runRepo.get(id: runId)"))
    }

    func test_runFinished_usesProviderProbeWithoutDurableGet() async throws {
        let ctx = try makeContext("finish")
        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = true }
        let thread = AgentThread(title: "finish", provider: .grok, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .grok,
            model: "fake-model",
            status: .completed,
            finishedAt: Date(),
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try ctx.runRepo.upsert(run)
        let getsBefore = ctx.runRepo.durableGetCountForTesting
        let probesBefore = ctx.runRepo.providerProbeCountForTesting
        ctx.coordinator.onRunFinished?(thread.id, run.id, .completed)
        let deadline = Date().addingTimeInterval(1)
        while ctx.runRepo.providerProbeCountForTesting < probesBefore + 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(
            ctx.runRepo.providerProbeCountForTesting,
            probesBefore + 2,
            "finish usage tombstone and Grok refresh must each probe provider"
        )
        XCTAssertEqual(
            ctx.runRepo.durableGetCountForTesting,
            getsBefore,
            "run finish must not compile a full 10-column get just for provider"
        )
    }

    func test_providerProbe_fasterThanDurableGet() throws {
        let ctx = try makeContext("bench")
        let thread = AgentThread(title: "bench", provider: .grok, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .grok,
            model: "fake-model",
            status: .completed,
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
            _ = try ctx.runRepo.provider(of: run.id)
            _ = try ctx.runRepo.get(id: run.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.runRepo.provider(of: run.id)
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
            "[perf-proof] token-saver-finish provider_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
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

    private func makeContext(_ label: String) throws -> AppContext {
        let tmp = NSTemporaryDirectory() + "rc2-ts-finish-provider-\(label)-" + UUID().uuidString
        return try AppContext(channel: .debug, appSupportOverride: tmp)
    }
}
