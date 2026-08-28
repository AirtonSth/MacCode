import XCTest
import CoreModel
@testable import Persistence

/// WHY: macOS renameThread compiled the 26-column row plus routing JSON
/// then upserted the full row, bumping updated_at, even after RPC rename
/// already used updateTitlePreservingActivity.
final class UIRenameTitlePreservingActivityProbeTests: XCTestCase {
    func test_uiRename_sourceUsesUpdateTitlePreservingActivity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let surface = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let ui = try slice(surface, from: "public func renameThread(_ id: AgentThreadID, to newTitle: String)", to: "public func setThreadColor(")
        XCTAssertTrue(ui.contains("updateTitlePreservingActivity("))
        XCTAssertFalse(ui.contains("threadRepo.upsert("))
        XCTAssertFalse(ui.contains("threadRepo.get(id: id)"))
    }

    func test_updateTitle_doesNotRewriteRoutingOrUpdatedAt() throws {
        let repo = try makeRepo("match")
        var thread = AgentThread(title: "old", provider: .codex, model: "fake-model")
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        thread.updatedAt = stamped
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try repo.upsert(thread)
        let digest = thread.routingConfiguration?.policyDigest
        let getsBefore = repo.durableGetCountForTesting
        try repo.updateTitlePreservingActivity(thread.id, title: "new title")
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)
        let stored = try XCTUnwrap(try repo.get(id: thread.id))
        XCTAssertEqual(stored.title, "new title")
        XCTAssertEqual(stored.updatedAt.timeIntervalSince1970, stamped.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)
    }

    func test_updateTitle_fasterThanGetAndUpsert() throws {
        let repo = try makeRepo("bench")
        var thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try repo.upsert(thread)
        let warmup = 3
        let samples = 5
        let iterations = 400
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
            try repo.updateTitlePreservingActivity(thread.id, title: "warm")
            if var copy = try repo.get(id: thread.id) {
                copy.title = "warm-upsert"
                copy.updatedAt = Date()
                try repo.upsert(copy)
            }
        }
        var probeSamples: [Double] = []
        var upsertSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        upsertSamples.reserveCapacity(samples)
        for i in 0..<samples {
            probeSamples.append(try timeMs {
                for n in 0..<iterations {
                    try repo.updateTitlePreservingActivity(thread.id, title: "p-\(i)-\(n)")
                }
            })
            upsertSamples.append(try timeMs {
                for n in 0..<iterations {
                    if var copy = try repo.get(id: thread.id) {
                        copy.title = "u-\(i)-\(n)"
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
            "[perf-proof] ui-rename-title-preserving updateTitle_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ upsert=%@",
            String(probeMed), String(upsertMed), improvement,
            String(describing: probeSamples),
            String(describing: upsertSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "updateTitle must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms upsert=\(upsertMed)ms)"
        )
    }

    private func makeRepo(_ label: String) throws -> AgentThreadRepository {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        _ = label
        return AgentThreadRepository(db: db)
    }

    private func slice(_ source: String, from: String, to: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: from))
        let end = try XCTUnwrap(source.range(of: to, range: start.lowerBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
