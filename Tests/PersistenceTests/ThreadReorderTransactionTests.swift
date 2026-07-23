import XCTest
@testable import Persistence
import CoreModel

/// WHY (L83 perf fix): normalizeOrder, promoteToFront, and normalizePositions
/// previously issued one implicit transaction per upsert/UPDATE row. Wrapping
/// each loop in db.transaction{} reduces N WAL fsyncs to 1. These tests pin
/// the final row state so the transaction wrap cannot silently alter observable
/// behavior (order, positions, pinned grouping, rollback consistency).
final class ThreadReorderTransactionTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    private func makeWorkspace(db: SQLiteDB) throws -> WorkspaceID {
        let wid = WorkspaceID()
        // agent_threads references workspaces only by column; no FK to a workspaces table.
        return wid
    }

    private func makeThread(
        db: SQLiteDB,
        workspaceId: WorkspaceID,
        title: String,
        pinned: Bool = false
    ) throws -> AgentThread {
        var t = AgentThread(workspaceId: workspaceId, title: title, provider: .codex, model: "m")
        t.pinned = pinned
        try AgentThreadRepository(db: db).upsert(t)
        return t
    }

    // MARK: - normalizeOrder: final row state after reorder

    /// WHY: reorder() still renumbers sortOrder in one transaction. With
    /// activity-based list order the move uses that order, but the final
    /// sortOrder set must stay contiguous 0..n-1.
    func test_reorder_finalSortOrderIsIdenticalAfterTransactionWrap() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let wid = try makeWorkspace(db: db)

        _ = try makeThread(db: db, workspaceId: wid, title: "A")
        _ = try makeThread(db: db, workspaceId: wid, title: "B")
        let tC = try makeThread(db: db, workspaceId: wid, title: "C")

        try repo.reorder(id: tC.id, position: 0)

        let listed = try repo.list(workspaceId: wid)
        XCTAssertEqual(Set(listed.map(\.sortOrder)), Set([0, 1, 2]),
            "sortOrder must be contiguous 0-1-2 after normalizeOrder")
        XCTAssertEqual(listed.count, 3)
    }

    /// WHY: pin remains a retention/visual marker, but rail order is last
    /// activity only — pinning must not force a stale thread above newer work.
    func test_setPinned_doesNotOverrideLastActivityOrder() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let wid = try makeWorkspace(db: db)

        var oldPinned = AgentThread(workspaceId: wid, title: "old-pinned", provider: .codex, model: "m")
        oldPinned.updatedAt = Date(timeIntervalSince1970: 100)
        try repo.upsert(oldPinned)
        try repo.setPinned(id: oldPinned.id, pinned: true)

        // setPinned bumps updatedAt — reset it so the case is activity-driven.
        var pinned = try XCTUnwrap(repo.get(id: oldPinned.id))
        pinned.updatedAt = Date(timeIntervalSince1970: 100)
        try repo.upsert(pinned)

        var fresh = AgentThread(workspaceId: wid, title: "fresh", provider: .codex, model: "m")
        fresh.updatedAt = Date(timeIntervalSince1970: 500)
        try repo.upsert(fresh)

        let listed = try repo.list(workspaceId: wid)
        XCTAssertEqual(listed.map(\.title), ["fresh", "old-pinned"],
            "last activity wins over pin for rail order")
        XCTAssertTrue(listed.contains(where: { $0.title == "old-pinned" && $0.pinned }))
    }

    /// WHY: reorder to a clamped position (beyond list end) must renumber
    /// sortOrder without leaving gaps or crashing.
    func test_reorder_beyondEnd_clampsToTail() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let wid = try makeWorkspace(db: db)

        let tA = try makeThread(db: db, workspaceId: wid, title: "A")
        _ = try makeThread(db: db, workspaceId: wid, title: "B")
        _ = try makeThread(db: db, workspaceId: wid, title: "C")

        try repo.reorder(id: tA.id, position: 999)

        let listed = try repo.list(workspaceId: wid)
        XCTAssertEqual(Set(listed.map(\.sortOrder)), Set([0, 1, 2]),
            "reorder beyond end must leave contiguous sortOrder values")
        XCTAssertEqual(listed.first(where: { $0.id == tA.id })?.sortOrder, 2,
            "clamped tail index is the last sortOrder slot")
    }

    /// WHY: users expect the rail to surface the most recently finished/active
    /// thread at the top (last activity DESC), not a frozen manual sort_order.
    func test_list_ordersByLastActivityDescending_becauseFinishedRunsShouldFloatToTop() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let wid = try makeWorkspace(db: db)

        var older = AgentThread(workspaceId: wid, title: "older", provider: .codex, model: "m")
        older.updatedAt = Date(timeIntervalSince1970: 100)
        older.status = .completed
        try repo.upsert(older)

        var middle = AgentThread(workspaceId: wid, title: "middle", provider: .codex, model: "m")
        middle.updatedAt = Date(timeIntervalSince1970: 200)
        middle.status = .completed
        try repo.upsert(middle)

        var newest = AgentThread(workspaceId: wid, title: "newest", provider: .codex, model: "m")
        newest.updatedAt = Date(timeIntervalSince1970: 300)
        newest.status = .completed
        try repo.upsert(newest)

        let listed = try repo.list(workspaceId: wid)
        XCTAssertEqual(listed.map(\.title), ["newest", "middle", "older"],
            "list must order by updated_at DESC so the most recent activity is first")
    }

    /// WHY: each workspace keeps at most 100 threads so scheduled runs cannot
    /// grow SQLite without bound. Oldest non-active, unpinned threads go first.
    func test_enforceWorkspaceThreadLimit_prunesOldestBeyond100() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let wid = try makeWorkspace(db: db)
        let limit = 5

        for i in 0..<8 {
            var t = AgentThread(workspaceId: wid, title: "t\(i)", provider: .codex, model: "m")
            t.updatedAt = Date(timeIntervalSince1970: TimeInterval(i))
            t.status = .completed
            try repo.upsert(t)
        }
        // Keep one old running thread — must not be pruned.
        var running = AgentThread(workspaceId: wid, title: "running", provider: .codex, model: "m")
        running.updatedAt = Date(timeIntervalSince1970: 0)
        running.status = .running
        try repo.upsert(running)

        let deleted = try repo.enforceWorkspaceThreadLimit(workspaceId: wid, limit: limit)
        XCTAssertEqual(try repo.count(workspaceId: wid), limit)
        XCTAssertEqual(deleted.count, 4, "9 rows → keep 5, delete 4 oldest eligible")
        let remaining = try repo.list(workspaceId: wid)
        XCTAssertTrue(remaining.contains(where: { $0.title == "running" }),
                      "running threads must never be auto-pruned")
        XCTAssertFalse(remaining.contains(where: { $0.title == "t1" }),
                       "oldest idle history must be pruned first")
    }

    // MARK: - promoteToFront: final positions after transaction wrap

    /// WHY: promoteToFront now issues a single transaction for all position UPDATEs.
    /// Final positions must be identical: promoted=1, others shift up preserving relative order.
    func test_promoteToFront_finalPositionsIdenticalAfterTransactionWrap() throws {
        let db = try makeDB()
        let repo = AgentQueuedMessageRepository(db: db)
        let threadRepo = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "q", provider: .codex, model: "m")
        try threadRepo.upsert(thread)

        let m1 = try repo.enqueue(threadId: thread.id, text: "first", attachments: [], interactionMode: .default)
        let m2 = try repo.enqueue(threadId: thread.id, text: "second", attachments: [], interactionMode: .default)
        let m3 = try repo.enqueue(threadId: thread.id, text: "third", attachments: [], interactionMode: .default)

        let promoted = try repo.promoteToFront(id: m3.id)

        XCTAssertEqual(promoted?.position, 1,
            "promoted message must be at position 1; transaction wrap must not alter the assignment")
        let listed = try repo.list(threadId: thread.id)
        XCTAssertEqual(listed.map(\.text), ["third", "first", "second"],
            "list after promote must be third-first-second preserving relative order of non-promoted messages")
        XCTAssertEqual(listed.map(\.position), [1, 2, 3],
            "positions must be contiguous 1-2-3 after promoteToFront; transaction must not leave gaps")
    }

    // MARK: - normalizePositions: final positions after delete + transaction wrap

    /// WHY: delete() calls normalizePositions which now issues a single transaction.
    /// Remaining rows must get contiguous positions with no gaps.
    func test_delete_normalizePositions_contiguousAfterTransactionWrap() throws {
        let db = try makeDB()
        let repo = AgentQueuedMessageRepository(db: db)
        let threadRepo = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "q2", provider: .codex, model: "m")
        try threadRepo.upsert(thread)

        let m1 = try repo.enqueue(threadId: thread.id, text: "A", attachments: [], interactionMode: .default)
        let m2 = try repo.enqueue(threadId: thread.id, text: "B", attachments: [], interactionMode: .default)
        let m3 = try repo.enqueue(threadId: thread.id, text: "C", attachments: [], interactionMode: .default)
        let m4 = try repo.enqueue(threadId: thread.id, text: "D", attachments: [], interactionMode: .default)

        // Delete position-2 message (B)
        _ = try repo.delete(id: m2.id)

        let listed = try repo.list(threadId: thread.id)
        XCTAssertEqual(listed.map(\.text), ["A", "C", "D"],
            "B must be removed; A-C-D remain in original relative order")
        XCTAssertEqual(listed.map(\.position), [1, 2, 3],
            "positions must be renormalized to 1-2-3 with no gap at former position 2; transaction wrap must not change this")
    }
}
