import XCTest
import CoreModel
@testable import Persistence

/// WHY: setAgentThreadColor / setThreadColor compiled the 26-column row plus
/// routing JSON then upserted the full row just to change a swatch.
final class ColorPreservingRoutingProbeTests: XCTestCase {
    func test_colorWrites_sourceUsesSetColorNotUpsert() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repo = try String(
            contentsOf: root.appendingPathComponent("Sources/Persistence/Repositories.swift"),
            encoding: .utf8
        )
        let setColor = try slice(repo, from: "public func setColor(id: AgentThreadID", to: "public func setPinned(id: AgentThreadID")
        XCTAssertTrue(setColor.contains("SET color"))
        XCTAssertFalse(setColor.contains("guard var t = try get(id: id)"))
        XCTAssertFalse(setColor.contains("try upsert(t)"))

        let router = try String(
            contentsOf: root.appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let rpc = try slice(router, from: "public func setAgentThreadColor(", to: "public func reorderAgentThread(")
        XCTAssertTrue(rpc.contains("threadRepo.setColor("))
        XCTAssertFalse(rpc.contains("threadRepo.upsert(t)"))

        let surface = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let ui = try slice(surface, from: "public func setThreadColor(", to: "public func setThreadPinned(")
        XCTAssertTrue(ui.contains("threadRepo.setColor("))
        XCTAssertFalse(ui.contains("threadRepo.upsert(stored)"))
        XCTAssertFalse(ui.contains("threadRepo.get("))
    }

    func test_setColor_doesNotRewriteRouting() throws {
        let repo = try makeRepo("match")
        var thread = AgentThread(title: "swatch", provider: .codex, model: "fake-model")
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try repo.upsert(thread)
        let digest = thread.routingConfiguration?.policyDigest
        let getsBefore = repo.durableGetCountForTesting
        try repo.setColor(id: thread.id, color: "purple")
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)
        let stored = try XCTUnwrap(try repo.get(id: thread.id))
        XCTAssertEqual(stored.color, "purple")
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)
        try repo.setColor(id: thread.id, color: nil)
        XCTAssertNil(try repo.get(id: thread.id)?.color)
        try repo.setColor(id: AgentThreadID(), color: "purple")
    }

    func test_setColor_fasterThanGetAndUpsert() throws {
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
            try repo.setColor(id: thread.id, color: "purple")
            if var copy = try repo.get(id: thread.id) {
                copy.color = "blue"
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
                    try repo.setColor(id: thread.id, color: n % 2 == 0 ? "purple" : "blue")
                }
            })
            upsertSamples.append(try timeMs {
                for n in 0..<iterations {
                    if var copy = try repo.get(id: thread.id) {
                        copy.color = n % 2 == 0 ? "purple" : "blue"
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
            "[perf-proof] color-preserving-routing color_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ upsert=%@",
            String(probeMed), String(upsertMed), improvement,
            String(describing: probeSamples),
            String(describing: upsertSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "setColor must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms upsert=\(upsertMed)ms)"
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
