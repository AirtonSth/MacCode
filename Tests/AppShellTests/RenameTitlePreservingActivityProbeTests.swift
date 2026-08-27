import XCTest
@testable import AppShell
import CoreModel
import Persistence

/// WHY: renameAgentThread compiled the 26-column agent_threads row plus
/// routing JSON then upserted the full row, bumping updated_at and clobbering
/// concurrent persistThreadConfig / run-start writes.
@MainActor
final class RenameTitlePreservingActivityProbeTests: XCTestCase {
    func test_renameAgentThread_sourceUsesUpdateTitlePreservingActivity() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func renameAgentThread("))
        let end = try XCTUnwrap(source.range(of: "public func setAgentThreadPinned("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("updateTitlePreservingActivity"))
        XCTAssertFalse(body.contains("threadRepo.upsert(t)"))
    }

    func test_rename_doesNotRewriteUpdatedAtOrRouting() throws {
        let (ctx, router) = try makeRouter()
        var thread = AgentThread(
            title: "old",
            provider: .codex,
            model: "fake-model"
        )
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        thread.updatedAt = stamped
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try ctx.threadRepo.upsert(thread)
        let digest = thread.routingConfiguration?.policyDigest
        let renamed = try router.renameAgentThread(thread: thread.id, title: "new title")
        XCTAssertEqual(renamed.title, "new title")
        XCTAssertEqual(renamed.routingConfiguration?.policyDigest, digest)
        let stored = try XCTUnwrap(try ctx.threadRepo.get(id: thread.id))
        XCTAssertEqual(stored.title, "new title")
        XCTAssertEqual(stored.updatedAt.timeIntervalSince1970, stamped.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)
        XCTAssertThrowsError(try router.renameAgentThread(thread: AgentThreadID(), title: "gone"))
        XCTAssertThrowsError(try router.renameAgentThread(thread: thread.id, title: "   "))
    }

    func test_rename_fasterThanGetAndUpsert() throws {
        let (ctx, router) = try makeRouter()
        var thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
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
            _ = try router.renameAgentThread(thread: thread.id, title: "warm")
            if var copy = try ctx.threadRepo.get(id: thread.id) {
                copy.title = "warm-upsert"
                copy.updatedAt = Date()
                try ctx.threadRepo.upsert(copy)
            }
        }
        var probeSamples: [Double] = []
        var upsertSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        upsertSamples.reserveCapacity(samples)
        for i in 0..<samples {
            probeSamples.append(try timeMs {
                for n in 0..<iterations {
                    _ = try router.renameAgentThread(thread: thread.id, title: "p-\(i)-\(n)")
                }
            })
            upsertSamples.append(try timeMs {
                for n in 0..<iterations {
                    if var copy = try ctx.threadRepo.get(id: thread.id) {
                        copy.title = "u-\(i)-\(n)"
                        copy.updatedAt = Date()
                        try ctx.threadRepo.upsert(copy)
                    }
                }
            })
        }
        let probeMed = median(probeSamples)
        let upsertMed = median(upsertSamples)
        let improvement = (upsertMed - probeMed) / upsertMed * 100.0
        NSLog(
            "[perf-proof] rename-title-preserving rename_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ upsert=%@",
            String(probeMed), String(upsertMed), improvement,
            String(describing: probeSamples),
            String(describing: upsertSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "rename must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms upsert=\(upsertMed)ms)"
        )
    }

    private func makeRouter() throws -> (AppContext, AppCommandRouter) {
        let tmp = NSTemporaryDirectory() + "rc2-rename-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }
}
