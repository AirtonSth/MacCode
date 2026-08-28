import XCTest
import CoreModel
@testable import Persistence

/// WHY: Auto/manual routing configure compiled the 26-column row plus routing
/// JSON twice (before configure and after CAS) just to resolve revision.
final class ConfigureAgentThreadRoutingProbeTests: XCTestCase {
    func test_configureRouting_sourceSkipsDurableGet() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let router = try String(
            contentsOf: root.appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let body = try slice(
            router,
            from: "public func configureAgentThreadRouting(",
            to: "public func configureAgentThreadExecution("
        )
        XCTAssertTrue(body.contains("routingConfiguration(of: thread)"))
        XCTAssertTrue(body.contains("setRoutingConfiguration("))
        XCTAssertTrue(body.contains("threadWithoutRouting(of: thread)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: thread)"))
    }

    func test_routingConfiguration_doesNotCompileThreadRow() throws {
        let repo = try makeRepo("match")
        var thread = AgentThread(title: "keep-title", provider: .codex, model: "fake-model")
        thread.color = "purple"
        thread.pinned = true
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024),
            revision: 1
        )
        try repo.upsert(thread)
        let getsBefore = repo.durableGetCountForTesting
        let probesBefore = repo.routingConfigurationProbeCountForTesting

        let loaded = try XCTUnwrap(try repo.routingConfiguration(of: thread.id))
        XCTAssertEqual(loaded.revision, 1)
        XCTAssertEqual(loaded.policyDigest, thread.routingConfiguration?.policyDigest)
        XCTAssertEqual(repo.routingConfigurationProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try repo.routingConfiguration(of: AgentThreadID()))
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)
    }

    func test_routingConfiguration_fasterThanDurableGet() throws {
        let repo = try makeRepo("bench")
        var thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024),
            revision: 1
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
            _ = try repo.routingConfiguration(of: thread.id)
            _ = try repo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try repo.routingConfiguration(of: thread.id)
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
            "[perf-proof] configure-routing-skip-get routing_ms=%@ get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "routingConfiguration must beat get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
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
