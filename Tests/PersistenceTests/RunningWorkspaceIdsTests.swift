import XCTest
@testable import Persistence
import CoreModel

/// Correctness pin for AgentThreadRepository.runningWorkspaceIds(in:) (PERF-008).
///
/// WHY: listWorkspaces() previously called threadRepo.list(workspaceId:) once
/// per workspace to detect running threads (N queries for N workspaces). The
/// batch path issues a single SELECT DISTINCT workspace_id ... WHERE workspace_id
/// IN (...) AND status='running'. This test asserts the batch result equals the
/// per-workspace result for a seeded set, so collapsing N queries to 1 cannot
/// silently change which workspaces are reported as busy.
final class RunningWorkspaceIdsTests: XCTestCase {

    private struct Harness {
        let repo: AgentThreadRepository
        let workspaceIds: [WorkspaceID]
    }

    /// Seeds `workspaceCount` workspaces, each with one thread. Threads at
    /// `runningIndices` are set to .running; the rest remain .pending.
    private func makeHarness(workspaceCount: Int, runningIndices: Set<Int>) throws -> Harness {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let repo = AgentThreadRepository(db: db)
        var wsIds: [WorkspaceID] = []
        for i in 0..<workspaceCount {
            let wid = WorkspaceID()
            wsIds.append(wid)
            let status: AgentRunStatus = runningIndices.contains(i) ? .running : .pending
            let t = AgentThread(
                workspaceId: wid,
                title: "t\(i)",
                provider: .codex,
                model: "m",
                status: status
            )
            try repo.upsert(t)
        }
        return Harness(repo: repo, workspaceIds: wsIds)
    }

    // batch busy-set must equal per-workspace result for mixed running/pending.
    func test_batchMatchesPerWorkspace_mixedStatus() throws {
        let h = try makeHarness(workspaceCount: 5, runningIndices: [1, 3])

        // per-workspace path (original N queries)
        let perWorkspace: [WorkspaceID: Bool] = Dictionary(uniqueKeysWithValues: h.workspaceIds.map { wid in
            let threads = (try? h.repo.list(workspaceId: wid)) ?? []
            return (wid, threads.contains { $0.status == .running })
        })

        // batch path (PERF-008 single query)
        let runningSet = try h.repo.runningWorkspaceIds(in: h.workspaceIds)
        let batchResult: [WorkspaceID: Bool] = Dictionary(uniqueKeysWithValues: h.workspaceIds.map { wid in
            (wid, runningSet.contains(wid))
        })

        XCTAssertEqual(batchResult, perWorkspace,
            "runningWorkspaceIds must produce the same busy flag as per-workspace " +
            "list(workspaceId:) for each workspace; collapsing N queries to 1 must " +
            "not change which workspaces are reported as having running threads")
    }

    // when no threads are running, batch returns empty set.
    func test_noRunningThreads_emptySet() throws {
        let h = try makeHarness(workspaceCount: 3, runningIndices: [])
        let runningSet = try h.repo.runningWorkspaceIds(in: h.workspaceIds)
        XCTAssertTrue(runningSet.isEmpty,
            "runningWorkspaceIds must return empty set when no threads have status=running")
    }

    // when all threads are running, batch returns all workspace ids.
    func test_allRunning_fullSet() throws {
        let h = try makeHarness(workspaceCount: 4, runningIndices: [0, 1, 2, 3])
        let runningSet = try h.repo.runningWorkspaceIds(in: h.workspaceIds)
        for wid in h.workspaceIds {
            XCTAssertTrue(runningSet.contains(wid),
                "workspace with a running thread must appear in runningWorkspaceIds result")
        }
    }

    // empty input returns empty set without hitting the database.
    func test_emptyInput_emptySet() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let repo = AgentThreadRepository(db: db)
        let result = try repo.runningWorkspaceIds(in: [])
        XCTAssertTrue(result.isEmpty,
            "runningWorkspaceIds([]) must return empty set without issuing a query")
    }
}
