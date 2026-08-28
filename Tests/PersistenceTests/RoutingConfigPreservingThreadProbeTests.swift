import XCTest
import CoreModel
@testable import Persistence

/// WHY: Auto toggle compiled the 26-column agent_threads row plus routing
/// JSON then upserted the full row just to CAS-write agent_thread_routing.
final class RoutingConfigPreservingThreadProbeTests: XCTestCase {
    func test_setRoutingConfiguration_sourceSkipsGetAndUpsert() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repo = try String(
            contentsOf: root.appendingPathComponent("Sources/Persistence/Repositories.swift"),
            encoding: .utf8
        )
        let body = try slice(
            repo,
            from: "public func setRoutingConfiguration(",
            to: "private func loadRoutingConfiguration("
        )
        XCTAssertTrue(body.contains("INSERT INTO agent_thread_routing"))
        XCTAssertTrue(body.contains("SET updated_at"))
        XCTAssertFalse(body.contains("guard var thread = try get(id: threadId)"))
        XCTAssertFalse(body.contains("try upsert(thread)"))
    }

    func test_setRoutingConfiguration_doesNotRewriteThreadChrome() throws {
        let repo = try makeRepo("match")
        var thread = AgentThread(title: "auto", provider: .codex, model: "fake-model")
        thread.color = "purple"
        thread.pinned = true
        thread.permissionMode = .fullAccess
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        thread.updatedAt = stamped
        let original = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024),
            revision: 1,
            updatedAt: stamped
        )
        thread.routingConfiguration = original
        try repo.upsert(thread)
        let getsBefore = repo.durableGetCountForTesting
        let writesBefore = repo.setRoutingConfigurationCountForTesting
        let next = Date(timeIntervalSince1970: 1_700_000_100)
        let changed = AgentRoutingConfiguration(
            mode: .auto,
            manualSelection: original.manualSelection,
            policyDigest: original.policyDigest,
            revision: 2,
            updatedAt: next
        )

        try repo.setRoutingConfiguration(changed, threadId: thread.id, expectedRevision: 1)
        XCTAssertEqual(repo.setRoutingConfigurationCountForTesting, writesBefore + 1)
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)

        let stored = try XCTUnwrap(try repo.get(id: thread.id))
        XCTAssertEqual(stored.routingConfiguration?.mode, .auto)
        XCTAssertEqual(stored.routingConfiguration?.revision, 2)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, original.policyDigest)
        XCTAssertEqual(stored.updatedAt.timeIntervalSince1970, next.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(stored.color, "purple")
        XCTAssertTrue(stored.pinned)
        XCTAssertEqual(stored.permissionMode, .fullAccess)

        XCTAssertThrowsError(
            try repo.setRoutingConfiguration(changed, threadId: thread.id, expectedRevision: 1)
        ) { error in
            XCTAssertEqual(
                error as? AgentRoutingRevisionError,
                .conflict(expected: 1, actual: 2)
            )
        }
        try repo.setRoutingConfiguration(changed, threadId: AgentThreadID(), expectedRevision: 0)
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore + 1)
    }

    func test_setRoutingConfiguration_fasterThanGetAndUpsert() throws {
        let repo = try makeRepo("bench")
        var thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        let routing = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024),
            revision: 1
        )
        thread.routingConfiguration = routing
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
            try repo.setRoutingConfiguration(routing, threadId: thread.id, expectedRevision: 1)
            if var copy = try repo.get(id: thread.id) {
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
                for _ in 0..<iterations {
                    try repo.setRoutingConfiguration(
                        routing,
                        threadId: thread.id,
                        expectedRevision: 1
                    )
                }
            })
            upsertSamples.append(try timeMs {
                for _ in 0..<iterations {
                    if var copy = try repo.get(id: thread.id) {
                        copy.routingConfiguration = routing
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
            "[perf-proof] routing-config-preserving-thread setRouting_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ upsert=%@",
            String(probeMed), String(upsertMed), improvement,
            String(describing: probeSamples),
            String(describing: upsertSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "setRoutingConfiguration must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms upsert=\(upsertMed)ms)"
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
