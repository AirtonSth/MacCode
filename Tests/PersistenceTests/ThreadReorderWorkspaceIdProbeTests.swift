import XCTest
import CoreModel
@testable import Persistence

/// WHY: `reorder` used to full-get 26 columns + routing JSON just to learn
/// workspace membership before `list(workspaceId:)` already loaded the rail.
final class ThreadReorderWorkspaceIdProbeTests: XCTestCase {
    private func makeRepo(_ label: String) throws -> AgentThreadRepository {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc2-\(label)-\(UUID().uuidString)", isDirectory: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        return AgentThreadRepository(db: db)
    }

    func test_reorder_probesWorkspaceIdWithoutDurableGet() throws {
        let repo = try makeRepo("thread-reorder-workspace")
        let workspaceID = WorkspaceID()
        let first = AgentThread(
            workspaceId: workspaceID,
            title: "one",
            provider: .codex,
            model: "fake-model"
        )
        let second = AgentThread(
            workspaceId: workspaceID,
            title: "two",
            provider: .codex,
            model: "fake-model"
        )
        try repo.upsert(first)
        try repo.upsert(second)

        let getsBefore = repo.durableGetCountForTesting
        let probesBefore = repo.workspaceIdProbeCountForTesting
        try repo.reorder(id: first.id, position: 1)
        XCTAssertEqual(
            repo.workspaceIdProbeCountForTesting,
            probesBefore + 1,
            "reorder must probe workspace_id once"
        )
        XCTAssertEqual(
            repo.durableGetCountForTesting,
            getsBefore,
            "reorder must not compile a leftover 26-column get just to learn workspace_id"
        )
        let list = try repo.list(workspaceId: workspaceID)
        XCTAssertEqual(list.count, 2)
    }

    func test_reorder_sourceUsesWorkspaceIdProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Persistence/Repositories.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "public func reorder(id: AgentThreadID, position: Int)"))
        let body = String(source[range.lowerBound...].prefix(700))
        XCTAssertTrue(body.contains("workspaceId(of: id)"))
        XCTAssertFalse(body.contains("get(id: id)"))
    }

    func test_workspaceIdProbe_fasterThanDurableGet() throws {
        let repo = try makeRepo("thread-reorder-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try repo.upsert(thread)
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
            _ = try repo.workspaceId(of: thread.id)
            _ = try repo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try repo.workspaceId(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try repo.get(id: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] thread-reorder workspace_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
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
