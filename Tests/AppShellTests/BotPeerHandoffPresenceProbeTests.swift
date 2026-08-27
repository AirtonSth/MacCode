import XCTest
@testable import AppShell
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: bot-peer continuation and restore used to full-get 26 columns + routing
/// JSON just to learn whether the origin/peer Agent thread still exists.
@MainActor
final class BotPeerHandoffPresenceProbeTests: XCTestCase {
    func test_handoffPresence_sourceUsesStatusProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        let continuation = try XCTUnwrap(source.range(of: "private func continuationHandoff("))
        let continuationBody = String(source[continuation.lowerBound...].prefix(1600))
        XCTAssertTrue(continuationBody.contains("threadRepo.status(of: peerThreadID)"))
        XCTAssertFalse(continuationBody.contains("threadRepo.get(id: peerThreadID)"))

        let reconcile = try XCTUnwrap(source.range(of: "private func reconcilePeerHandoffs()"))
        let reconcileBody = String(source[reconcile.lowerBound...].prefix(1400))
        XCTAssertTrue(reconcileBody.contains("threadRepo.status(of: threadID)"))
        XCTAssertFalse(reconcileBody.contains("threadRepo.get(id: threadID)"))
    }

    func test_statusProbe_fasterThanDurableGet() throws {
        let tmp = NSTemporaryDirectory() + "rc2-bot-peer-handoff-presence-" + UUID().uuidString
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
            _ = try ctx.threadRepo.status(of: thread.id)
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
            "[perf-proof] bot-peer-handoff-presence status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "status probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
