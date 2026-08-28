import XCTest
import CoreModel
@testable import Persistence

/// WHY: unselected session-grant persist compiled the 26-column row plus
/// routing JSON then upserted the full row just to set permission_mode.
final class PermissionModePreservingRoutingProbeTests: XCTestCase {
    func test_permissionWrites_sourceUsesSetPermissionModeNotUpsert() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repo = try String(
            contentsOf: root.appendingPathComponent("Sources/Persistence/Repositories.swift"),
            encoding: .utf8
        )
        let setPerm = try slice(repo, from: "public func setPermissionMode(", to: "public func setExecutionConfig(")
        XCTAssertTrue(setPerm.contains("SET permission_mode"))
        XCTAssertFalse(setPerm.contains("guard var t = try get(id: id)"))
        XCTAssertFalse(setPerm.contains("try upsert(t)"))

        let surface = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let ui = try slice(
            surface,
            from: "private func setPermissionMode(_ mode: AgentPermissionMode, for threadId: AgentThreadID)",
            to: "public func setReasoningEffort("
        )
        XCTAssertTrue(ui.contains("threadRepo.setPermissionMode("))
        XCTAssertFalse(ui.contains("threadRepo.upsert(thread)"))
        XCTAssertFalse(ui.contains("threadRepo.get(id: threadId)"))
    }

    func test_setPermissionMode_doesNotRewriteRouting() throws {
        let repo = try makeRepo("match")
        var thread = AgentThread(title: "perm", provider: .codex, model: "fake-model")
        thread.permissionMode = .supervised
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try repo.upsert(thread)
        let digest = thread.routingConfiguration?.policyDigest
        let getsBefore = repo.durableGetCountForTesting
        let writesBefore = repo.setPermissionModeCountForTesting
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            try repo.setPermissionMode(of: thread.id, permissionMode: .fullAccess, at: stamped),
            true
        )
        XCTAssertEqual(repo.setPermissionModeCountForTesting, writesBefore + 1)
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)

        let stored = try XCTUnwrap(try repo.get(id: thread.id))
        XCTAssertEqual(stored.permissionMode, .fullAccess)
        XCTAssertEqual(stored.updatedAt.timeIntervalSince1970, stamped.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)

        XCTAssertEqual(try repo.setPermissionMode(of: thread.id, permissionMode: .supervised), true)
        let again = try XCTUnwrap(try repo.get(id: thread.id))
        XCTAssertEqual(again.permissionMode, .supervised)
        XCTAssertEqual(again.routingConfiguration?.policyDigest, digest)
        XCTAssertFalse(try repo.setPermissionMode(of: AgentThreadID(), permissionMode: .fullAccess))
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore + 2)
    }

    func test_setPermissionMode_fasterThanGetAndUpsert() throws {
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
            _ = try repo.setPermissionMode(of: thread.id, permissionMode: .fullAccess)
            _ = try repo.setPermissionMode(of: thread.id, permissionMode: .supervised)
            if var copy = try repo.get(id: thread.id) {
                copy.permissionMode = .fullAccess
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
                    _ = try repo.setPermissionMode(
                        of: thread.id,
                        permissionMode: n % 2 == 0 ? .fullAccess : .supervised
                    )
                }
            })
            upsertSamples.append(try timeMs {
                for n in 0..<iterations {
                    if var copy = try repo.get(id: thread.id) {
                        copy.permissionMode = n % 2 == 0 ? .fullAccess : .supervised
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
            "[perf-proof] permission-mode-preserving-routing setPermissionMode_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ upsert=%@",
            String(probeMed), String(upsertMed), improvement,
            String(describing: probeSamples),
            String(describing: upsertSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "setPermissionMode must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms upsert=\(upsertMed)ms)"
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
