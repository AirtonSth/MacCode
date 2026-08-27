import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// WHY: bot-peer dispatch compiled the 10-column agent_runs row (including
/// error_message) just to copy host status / existence.
@MainActor
final class BotPeerHostStatusProbeTests: XCTestCase {
    func test_botPeerHostPaths_sourceUsesStatusProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        let raceStart = try XCTUnwrap(source.range(of: "Abort dispatch only on durable PROOF the host was"))
        let raceEnd = try XCTUnwrap(source.range(of: "let home = BotHome("))
        let race = String(source[raceStart.lowerBound..<raceEnd.lowerBound])
        XCTAssertTrue(race.contains("runRepo.status(of: hostRunID)"))
        XCTAssertFalse(race.contains("runRepo.get(id: hostRunID)"))
        let settleStart = try XCTUnwrap(source.range(of: "private func settleCancelledQueuedHost("))
        let settleEnd = try XCTUnwrap(source.range(of: "fileprivate func reconcilePeerHandoffsForTesting("))
        let settle = String(source[settleStart.lowerBound..<settleEnd.lowerBound])
        XCTAssertTrue(settle.contains("runRepo.status(of: runID)"))
        XCTAssertFalse(settle.contains("runRepo.get(id: runID)"))
    }

    func test_statusProbe_matchesCancelledWithoutDurableGet() throws {
        let ctx = try makeContext("match")
        let thread = AgentThread(title: "peer-host", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .cancelled,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try ctx.runRepo.upsert(run)
        let getsBefore = ctx.runRepo.durableGetCountForTesting
        let probesBefore = ctx.runRepo.statusProbeCountForTesting
        XCTAssertEqual(try ctx.runRepo.status(of: run.id), .cancelled)
        XCTAssertEqual(ctx.runRepo.statusProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(ctx.runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try ctx.runRepo.status(of: AgentRunID()))
        XCTAssertEqual(ctx.runRepo.durableGetCountForTesting, getsBefore)
    }

    func test_statusProbe_fasterThanDurableGet() throws {
        let ctx = try makeContext("bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .cancelled,
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
            _ = try ctx.runRepo.status(of: run.id)
            _ = try ctx.runRepo.get(id: run.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.runRepo.status(of: run.id)
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
            "[perf-proof] bot-peer-host status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "status probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeContext(_ label: String) throws -> AppContext {
        let tmp = NSTemporaryDirectory() + "rc2-bot-peer-host-status-\(label)-" + UUID().uuidString
        return try AppContext(channel: .debug, appSupportOverride: tmp)
    }
}
