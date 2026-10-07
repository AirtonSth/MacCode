import XCTest
@testable import AppShell
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: rail reorder used to full-get 26 columns + routing JSON after
/// `reorder()` just to learn workspace membership for the list reload.
@MainActor
final class ReorderThreadWorkspaceIdProbeTests: XCTestCase {
    private func makeRouter(_ label: String) throws -> (AppContext, AppCommandRouter) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    func test_reorderAgentThread_probesWorkspaceIdWithoutExtraDurableGet() throws {
        let (ctx, router) = try makeRouter("reorder-workspace")
        let workspace = try router.createWorkspace(name: "REORDER", cwd: NSTemporaryDirectory())
        let first = try router.createAgentThread(
            workspace: workspace.id,
            title: "one",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let second = try router.createAgentThread(
            workspace: workspace.id,
            title: "two",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )

        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.workspaceIdProbeCountForTesting
        let list = try router.reorderAgentThread(thread: first.id, position: 1)
        XCTAssertEqual(
            ctx.threadRepo.workspaceIdProbeCountForTesting,
            probesBefore + 2,
            "rail reorder must probe workspace_id in reorder() and again for list reload"
        )
        XCTAssertEqual(
            ctx.threadRepo.durableGetCountForTesting,
            getsBefore,
            "rail reorder must not compile a leftover 26-column get"
        )
        // Rail order is pure last activity (`list` sorts by updated_at, not
        // sort_order), so two threads created in the same second tie on
        // updated_at and order by id. Check membership, not position.
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(Set(list.map(\.id)), [first.id, second.id])
    }

    func test_reorderAgentThread_sourceUsesWorkspaceIdProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "public func reorderAgentThread(thread: AgentThreadID, position: Int)"))
        let body = String(source[range.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("threadRepo.workspaceId(of: thread)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: thread)"))
    }

    func test_workspaceIdProbe_fasterThanDurableGet() throws {
        let (ctx, _) = try makeRouter("reorder-workspace-bench")
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
            _ = try ctx.threadRepo.workspaceId(of: thread.id)
            _ = try ctx.threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.workspaceId(of: thread.id)
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
            "[perf-proof] reorder-thread workspace_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "workspace_id probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
