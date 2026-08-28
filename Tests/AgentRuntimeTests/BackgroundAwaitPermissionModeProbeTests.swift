import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: auto-continue scheduling used to full-get 26 columns + routing JSON
/// just to learn whether durable `permissionMode` is `.fullAccess` when
/// `runMetadata.runtimeMode` is missing.
final class BackgroundAwaitPermissionModeProbeTests: XCTestCase {
    func test_maybeSchedule_sourceUsesPermissionModeProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "private func maybeScheduleBackgroundAwaitContinuation("))
        let end = try XCTUnwrap(source.range(of: "private func backgroundAwaitContinuationStillValid("))
        let body = String(source[range.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.permissionMode(of: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_permissionModeProbe_fasterThanDurableGet() throws {
        let tmp = NSTemporaryDirectory() + "rc2-bg-await-permission-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let thread = AgentThread(
            title: "bench",
            provider: .codex,
            model: "fake-model",
            permissionMode: .fullAccess
        )
        try threadRepo.upsert(thread)
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
            _ = try threadRepo.permissionMode(of: thread.id)
            _ = try threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.permissionMode(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.get(id: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] bg-await-permission permission_mode_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "permissionMode probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
