import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// WHY: provider usage ticks compiled the 10-column agent_runs row
/// (including error_message) on every token event just to copy provider/status.
@MainActor
final class ProviderUsageProbeTests: XCTestCase {
    func test_recordProviderTokenUsage_sourceUsesStatusAndProviderProbes() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppContext.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func recordProviderTokenUsage("))
        let end = try XCTUnwrap(source.range(of: "private func schedulePendingUsageFlush("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("runRepo.status(of: runId)"))
        XCTAssertTrue(body.contains("runRepo.provider(of: runId)"))
        XCTAssertFalse(body.contains("runRepo.get(id: runId)"))
    }

    func test_usageTicks_useProbesWithoutDurableGet() throws {
        let ctx = try makeContext("usage-ticks")
        let thread = AgentThread(title: "usage", provider: .codex, model: "fake-model")
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
        let statusBefore = ctx.runRepo.statusProbeCountForTesting
        let providerBefore = ctx.runRepo.providerProbeCountForTesting
        ctx.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(inputTokens: 10, outputTokens: 0, totalTokens: 10)),
            thread.id,
            run.id
        )
        XCTAssertEqual(ctx.runRepo.statusProbeCountForTesting, statusBefore + 1)
        XCTAssertEqual(ctx.runRepo.providerProbeCountForTesting, providerBefore + 1)
        XCTAssertEqual(
            ctx.runRepo.durableGetCountForTesting,
            getsBefore,
            "first usage tick must not compile a full 10-column get"
        )
        ctx.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(inputTokens: 20, outputTokens: 0, totalTokens: 20)),
            thread.id,
            run.id
        )
        XCTAssertEqual(
            ctx.runRepo.statusProbeCountForTesting,
            statusBefore + 1,
            "cached usage ticks must not re-probe status"
        )
        XCTAssertEqual(
            ctx.runRepo.providerProbeCountForTesting,
            providerBefore + 1,
            "cached usage ticks must not re-probe provider"
        )
        XCTAssertEqual(ctx.runRepo.durableGetCountForTesting, getsBefore)
    }

    func test_providerProbe_matchesStoredProviderWithoutDurableGet() throws {
        let ctx = try makeContext("provider-match")
        let thread = AgentThread(title: "usage", provider: .grok, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .grok,
            model: "fake-model",
            status: .running,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try ctx.runRepo.upsert(run)
        let getsBefore = ctx.runRepo.durableGetCountForTesting
        let probesBefore = ctx.runRepo.providerProbeCountForTesting
        XCTAssertEqual(try ctx.runRepo.provider(of: run.id), .grok)
        XCTAssertEqual(ctx.runRepo.providerProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(ctx.runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try ctx.runRepo.provider(of: AgentRunID()))
        XCTAssertEqual(ctx.runRepo.durableGetCountForTesting, getsBefore)
    }

    func test_providerProbe_fasterThanDurableGet() throws {
        let ctx = try makeContext("provider-bench")
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
            "[perf-proof] token-saver-usage provider_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
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
        let tmp = NSTemporaryDirectory() + "rc2-ts-usage-provider-\(label)-" + UUID().uuidString
        return try AppContext(channel: .debug, appSupportOverride: tmp)
    }
}
