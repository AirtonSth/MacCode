import XCTest
import CoreModel
@testable import Persistence

/// WHY: first worktree-mode send compiled the 26-column row plus routing JSON
/// then upserted title/status/unread/color/pin/picker just to stamp worktree_path.
final class WorktreePathPreservingRoutingProbeTests: XCTestCase {
    func test_prepareWorktree_sourceUsesSetWorktreePathNotUpsert() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repo = try String(
            contentsOf: root.appendingPathComponent("Sources/Persistence/Repositories.swift"),
            encoding: .utf8
        )
        let setPath = try slice(repo, from: "public func setWorktreePath(", to: "public func setColor(id: AgentThreadID")
        XCTAssertTrue(setPath.contains("SET worktree_path"))
        XCTAssertFalse(setPath.contains("guard var t = try get(id: id)"))
        XCTAssertFalse(setPath.contains("try upsert(t)"))

        let router = try String(
            contentsOf: root.appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let prepare = try slice(
            router,
            from: "private func prepareAgentExecutionCwd(",
            to: "public func implementAgentPlan("
        )
        XCTAssertTrue(prepare.contains("setWorktreePath("))
        XCTAssertFalse(prepare.contains("threadRepo.upsert(thread)"))
        XCTAssertFalse(prepare.contains("routingConfiguration(of: thread.id)"))
    }

    func test_setWorktreePath_doesNotRewriteThreadChrome() throws {
        let repo = try makeRepo("match")
        var thread = AgentThread(title: "keep-title", provider: .codex, model: "fake-model")
        thread.color = "purple"
        thread.pinned = true
        thread.hasUnread = true
        thread.executionMode = .worktree
        thread.baseBranch = "main"
        thread.status = .running
        thread.permissionMode = .fullAccess
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
        let writesBefore = repo.setWorktreePathCountForTesting
        let next = Date(timeIntervalSince1970: 1_700_000_100)

        XCTAssertEqual(
            try repo.setWorktreePath(of: thread.id, path: "/tmp/rc-wt", at: next),
            true
        )
        XCTAssertEqual(repo.setWorktreePathCountForTesting, writesBefore + 1)
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)

        let stored = try XCTUnwrap(try repo.get(id: thread.id))
        XCTAssertEqual(stored.worktreePath, "/tmp/rc-wt")
        XCTAssertEqual(stored.title, "keep-title")
        XCTAssertEqual(stored.color, "purple")
        XCTAssertTrue(stored.pinned)
        XCTAssertTrue(stored.hasUnread)
        XCTAssertEqual(stored.executionMode, .worktree)
        XCTAssertEqual(stored.baseBranch, "main")
        XCTAssertEqual(stored.status, .running)
        XCTAssertEqual(stored.permissionMode, .fullAccess)
        XCTAssertEqual(stored.updatedAt.timeIntervalSince1970, next.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)
        XCTAssertFalse(try repo.setWorktreePath(of: AgentThreadID(), path: "/tmp/missing"))
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore + 1)
    }

    func test_setWorktreePath_fasterThanGetAndUpsert() throws {
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
            _ = try repo.setWorktreePath(of: thread.id, path: "/tmp/rc-wt")
            if var copy = try repo.get(id: thread.id) {
                copy.worktreePath = "/tmp/rc-wt"
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
                    _ = try repo.setWorktreePath(of: thread.id, path: "/tmp/rc-wt")
                }
            })
            upsertSamples.append(try timeMs {
                for _ in 0..<iterations {
                    if var copy = try repo.get(id: thread.id) {
                        copy.worktreePath = "/tmp/rc-wt"
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
            "[perf-proof] worktree-path-preserving-routing setWorktreePath_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ upsert=%@",
            String(probeMed), String(upsertMed), improvement,
            String(describing: probeSamples),
            String(describing: upsertSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "setWorktreePath must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms upsert=\(upsertMed)ms)"
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
