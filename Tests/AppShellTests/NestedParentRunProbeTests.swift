import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// WHY: nested Agent App admission compiled the 10-column agent_runs row
/// (including error_message) just to copy parent thread_id and status.
@MainActor
final class NestedParentRunProbeTests: XCTestCase {
    func test_validatedNestedParent_sourceUsesThreadIdAndStatusProbes() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func validatedNestedParent("))
        let end = try XCTUnwrap(source.range(of: "private static func permissionRank("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("runRepo.threadId(of: nestedRunContext.parentRunID)"))
        XCTAssertTrue(body.contains("runRepo.status(of: nestedRunContext.parentRunID)"))
        XCTAssertFalse(body.contains("runRepo.get(id: nestedRunContext.parentRunID)"))
    }

    func test_threadIdAndStatusProbes_matchMembershipWithoutDurableGet() throws {
        let ctx = try makeContext("match")
        let thread = AgentThread(title: "nested-parent", provider: .codex, model: "fake-model")
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
        let threadIdBefore = ctx.runRepo.threadIdProbeCountForTesting
        let statusBefore = ctx.runRepo.statusProbeCountForTesting
        XCTAssertEqual(try ctx.runRepo.threadId(of: run.id), thread.id)
        XCTAssertEqual(try ctx.runRepo.status(of: run.id), .running)
        XCTAssertEqual(ctx.runRepo.threadIdProbeCountForTesting, threadIdBefore + 1)
        XCTAssertEqual(ctx.runRepo.statusProbeCountForTesting, statusBefore + 1)
        XCTAssertEqual(ctx.runRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try ctx.runRepo.threadId(of: AgentRunID()))
        XCTAssertEqual(ctx.runRepo.durableGetCountForTesting, getsBefore)
    }

    func test_threadIdAndStatusProbes_fasterThanDurableGet() throws {
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
            _ = try ctx.runRepo.threadId(of: run.id)
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
                    _ = try ctx.runRepo.threadId(of: run.id)
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
            "[perf-proof] nested-parent threadId+status_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "threadId+status probes must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeContext(_ label: String) throws -> AppContext {
        let tmp = NSTemporaryDirectory() + "rc2-nested-parent-run-\(label)-" + UUID().uuidString
        return try AppContext(channel: .debug, appSupportOverride: tmp)
    }
}
