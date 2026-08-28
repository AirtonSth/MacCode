import XCTest
import CoreModel
@testable import Persistence

/// WHY: persist/configure execution compiled the 26-column row plus routing
/// JSON then upserted the full row just to set mode/branch/path.
final class ExecutionConfigPreservingRoutingProbeTests: XCTestCase {
    func test_executionWrites_sourceUsesSetExecutionConfigNotUpsert() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repo = try String(
            contentsOf: root.appendingPathComponent("Sources/Persistence/Repositories.swift"),
            encoding: .utf8
        )
        let setExec = try slice(repo, from: "public func setExecutionConfig(", to: "public func setWorktreePath(")
        XCTAssertTrue(setExec.contains("SET execution_mode"))
        XCTAssertFalse(setExec.contains("guard var t = try get(id: id)"))
        XCTAssertFalse(setExec.contains("try upsert(t)"))

        let router = try String(
            contentsOf: root.appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let rpc = try slice(router, from: "public func configureAgentThreadExecution(", to: "public func prepareAgentThreadForPullRequest(")
        XCTAssertTrue(rpc.contains("threadWithoutRouting(of: thread)"))
        XCTAssertTrue(rpc.contains("setExecutionConfig("))
        XCTAssertTrue(rpc.contains("messageRepo.hasAny(threadId: thread)"))
        XCTAssertFalse(rpc.contains("threadRepo.get(id: thread)"))
        XCTAssertFalse(rpc.contains("threadRepo.upsert(t)"))

        let surface = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let ui = try slice(surface, from: "public func persistThreadExecutionConfig() -> Bool {", to: "public func setModel(")
        XCTAssertTrue(ui.contains("threadRepo.setExecutionConfig("))
        XCTAssertFalse(ui.contains("threadRepo.upsert(thread)"))
        XCTAssertFalse(ui.contains("guard var thread = try threadRepo.get(id: id)"))
    }

    func test_setExecutionConfig_doesNotRewriteRouting() throws {
        let repo = try makeRepo("match")
        var thread = AgentThread(title: "exec", provider: .codex, model: "fake-model")
        thread.executionMode = .local
        thread.worktreePath = "/tmp/wt"
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try repo.upsert(thread)
        let digest = thread.routingConfiguration?.policyDigest
        let getsBefore = repo.durableGetCountForTesting
        let writesBefore = repo.setExecutionConfigCountForTesting
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            try repo.setExecutionConfig(
                of: thread.id,
                executionMode: .worktree,
                baseBranch: "main",
                at: stamped
            ),
            true
        )
        XCTAssertEqual(repo.setExecutionConfigCountForTesting, writesBefore + 1)
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)

        let stored = try XCTUnwrap(try repo.get(id: thread.id))
        XCTAssertEqual(stored.executionMode, .worktree)
        XCTAssertEqual(stored.baseBranch, "main")
        XCTAssertEqual(stored.worktreePath, "/tmp/wt")
        XCTAssertEqual(stored.updatedAt.timeIntervalSince1970, stamped.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)

        XCTAssertEqual(
            try repo.setExecutionConfig(
                of: thread.id,
                executionMode: .local,
                baseBranch: nil
            ),
            true
        )
        let local = try XCTUnwrap(try repo.get(id: thread.id))
        XCTAssertEqual(local.executionMode, .local)
        XCTAssertNil(local.baseBranch)
        XCTAssertNil(local.worktreePath)
        XCTAssertEqual(local.routingConfiguration?.policyDigest, digest)
        XCTAssertFalse(try repo.setExecutionConfig(
            of: AgentThreadID(),
            executionMode: .worktree,
            baseBranch: "main"
        ))
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore + 2)
    }

    func test_setExecutionConfig_fasterThanGetAndUpsert() throws {
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
            _ = try repo.setExecutionConfig(
                of: thread.id,
                executionMode: .worktree,
                baseBranch: "main"
            )
            _ = try repo.setExecutionConfig(
                of: thread.id,
                executionMode: .local,
                baseBranch: nil
            )
            if var copy = try repo.get(id: thread.id) {
                copy.executionMode = .worktree
                copy.baseBranch = "main"
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
                    _ = try repo.setExecutionConfig(
                        of: thread.id,
                        executionMode: n % 2 == 0 ? .worktree : .local,
                        baseBranch: n % 2 == 0 ? "main" : nil
                    )
                }
            })
            upsertSamples.append(try timeMs {
                for n in 0..<iterations {
                    if var copy = try repo.get(id: thread.id) {
                        copy.executionMode = n % 2 == 0 ? .worktree : .local
                        copy.baseBranch = n % 2 == 0 ? "main" : nil
                        copy.worktreePath = n % 2 == 0 ? "/tmp/wt" : nil
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
            "[perf-proof] execution-config-preserving-routing setExecutionConfig_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ upsert=%@",
            String(probeMed), String(upsertMed), improvement,
            String(describing: probeSamples),
            String(describing: upsertSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "setExecutionConfig must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms upsert=\(upsertMed)ms)"
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
