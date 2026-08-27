import XCTest
@testable import AppShell
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: Desk work-log restore used to full-get 26 columns + routing JSON
/// just to copy `permissionMode` into follow-through rows.
@MainActor
final class DeskWorkLogPermissionModeProbeTests: XCTestCase {
    func test_restoreDeskWorkLog_sourceUsesPermissionModeProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "private func restoreDeskWorkLog("))
        let body = String(source[range.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("threadRepo.permissionMode(of: threadID)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadID)"))
    }

    func test_permissionModeProbe_matchesStoredModeAndMissingNil() throws {
        let tmp = NSTemporaryDirectory() + "rc2-desk-work-log-permission-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        var thread = AgentThread(
            title: "bench",
            provider: .codex,
            model: "fake-model",
            permissionMode: .fullAccess
        )
        try ctx.threadRepo.upsert(thread)
        XCTAssertEqual(try ctx.threadRepo.permissionMode(of: thread.id), .fullAccess)
        XCTAssertNil(try ctx.threadRepo.permissionMode(of: AgentThreadID()))
        thread.permissionMode = .supervised
        try ctx.threadRepo.upsert(thread)
        XCTAssertEqual(try ctx.threadRepo.permissionMode(of: thread.id), .supervised)
    }

    func test_permissionModeProbe_fasterThanDurableGet() throws {
        let tmp = NSTemporaryDirectory() + "rc2-desk-work-log-permission-bench-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let thread = AgentThread(
            title: "bench",
            provider: .codex,
            model: "fake-model",
            permissionMode: .fullAccess
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
            _ = try ctx.threadRepo.permissionMode(of: thread.id)
            _ = try ctx.threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.permissionMode(of: thread.id)
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
            "[perf-proof] desk-work-log-permission permission_mode_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
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
