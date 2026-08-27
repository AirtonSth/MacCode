import XCTest
import CoreModel
@testable import Persistence

/// WHY: setPinned compiled the 26-column row plus routing JSON, upserted it,
/// then normalizeOrder listed and upserted every rail row just to flip pin /
/// sort_order.
final class PinSortOrderPreservingRoutingProbeTests: XCTestCase {
    func test_setPinned_sourceSkipsGetUpsertAndNormalizeOrder() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Persistence/Repositories.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func setPinned(id: AgentThreadID, pinned: Bool)"))
        let end = try XCTUnwrap(source.range(of: "public func reorder(id: AgentThreadID, position: Int)"))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("SET pinned"))
        XCTAssertFalse(body.contains("guard var t = try get(id: id)"))
        XCTAssertFalse(body.contains("try upsert(t)"))
        XCTAssertFalse(body.contains("try normalizeOrder"))

        let nStart = try XCTUnwrap(source.range(of: "private func normalizeOrder("))
        let nEnd = try XCTUnwrap(source.range(of: "public enum AgentThreadForkPersistenceError"))
        let nBody = String(source[nStart.lowerBound..<nEnd.lowerBound])
        XCTAssertTrue(nBody.contains("SET sort_order"))
        XCTAssertFalse(nBody.contains("try upsert(t)"))
    }

    func test_setPinned_doesNotRewriteRouting() throws {
        let repo = try makeRepo("match")
        let workspace = WorkspaceID()
        var thread = AgentThread(
            workspaceId: workspace,
            title: "pin",
            provider: .codex,
            model: "fake-model"
        )
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try repo.upsert(thread)
        let digest = thread.routingConfiguration?.policyDigest
        let getsBefore = repo.durableGetCountForTesting
        let listsBefore = repo.durableListCountForTesting
        try repo.setPinned(id: thread.id, pinned: true)
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)
        XCTAssertEqual(repo.durableListCountForTesting, listsBefore)
        let stored = try XCTUnwrap(try repo.get(id: thread.id))
        XCTAssertTrue(stored.pinned)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)
        try repo.setPinned(id: AgentThreadID(), pinned: true)
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore + 1)
    }

    func test_setPinned_fasterThanGetAndUpsert() throws {
        let repo = try makeRepo("bench")
        let workspace = WorkspaceID()
        var thread = AgentThread(
            workspaceId: workspace,
            title: "bench",
            provider: .codex,
            model: "fake-model"
        )
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
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
            try repo.setPinned(id: thread.id, pinned: true)
            if var copy = try repo.get(id: thread.id) {
                copy.pinned = false
                copy.updatedAt = Date()
                try repo.upsert(copy)
            }
        }
        var probeSamples: [Double] = []
        var upsertSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        upsertSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for n in 0..<iterations {
                    try repo.setPinned(id: thread.id, pinned: n % 2 == 0)
                }
            })
            upsertSamples.append(try timeMs {
                for n in 0..<iterations {
                    if var copy = try repo.get(id: thread.id) {
                        copy.pinned = n % 2 == 0
                        copy.updatedAt = Date()
                        try repo.upsert(copy)
                    }
                }
            })
        }
        let probeMed = median(probeSamples)
        let upsertMed = median(upsertSamples)
        let improvement = (upsertMed - probeMed) / upsertMed * 100.0
        NSLog(
            "[perf-proof] pin-sort-order-preserving pin_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ upsert=%@",
            String(probeMed), String(upsertMed), improvement,
            String(describing: probeSamples),
            String(describing: upsertSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "setPinned must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms upsert=\(upsertMed)ms)"
        )
    }

    private func makeRepo(_ label: String) throws -> AgentThreadRepository {
        let tmp = NSTemporaryDirectory() + "rc2-pin-" + label + "-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return AgentThreadRepository(db: db)
    }
}
