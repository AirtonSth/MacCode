import XCTest
@testable import AppShell
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: bot-peer wait keepalives used to full-get 26 columns + routing JSON
/// every 20–250ms just to copy `updatedAt` into latestPeerProgress.
@MainActor
final class BotPeerProgressUpdatedAtProbeTests: XCTestCase {
    func test_latestPeerProgress_sourceUsesUpdatedAtProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "func latestPeerProgress("))
        let body = String(source[range.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("threadRepo.updatedAt(of: threadID)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadID)"))
    }

    func test_updatedAtProbe_matchesStoredDateAndMissingNil() throws {
        let tmp = NSTemporaryDirectory() + "rc2-bot-peer-progress-updated-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        var thread = AgentThread(
            title: "bench",
            provider: .codex,
            model: "fake-model",
            updatedAt: stamped
        )
        try ctx.threadRepo.upsert(thread)
        let probed = try XCTUnwrap(ctx.threadRepo.updatedAt(of: thread.id))
        XCTAssertEqual(probed.timeIntervalSince1970, stamped.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertNil(try ctx.threadRepo.updatedAt(of: AgentThreadID()))
        thread.updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        try ctx.threadRepo.upsert(thread)
        let later = try XCTUnwrap(ctx.threadRepo.updatedAt(of: thread.id))
        XCTAssertGreaterThan(later.timeIntervalSince1970, probed.timeIntervalSince1970)
    }

    func test_updatedAtProbe_fasterThanDurableGet() throws {
        let tmp = NSTemporaryDirectory() + "rc2-bot-peer-progress-updated-bench-" + UUID().uuidString
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
            _ = try ctx.threadRepo.updatedAt(of: thread.id)
            _ = try ctx.threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.updatedAt(of: thread.id)
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
            "[perf-proof] bot-peer-progress-updatedAt updated_at_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "updatedAt probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
