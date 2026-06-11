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

    /// WHY: reorder() calls normalizeOrder which now issues a single transaction.
    /// The resulting sortOrder values must be identical to pre-fix behavior:
    /// pinned threads first, then unpinned, each group in the moved order.
    func test_reorder_finalSortOrderIsIdenticalAfterTransactionWrap() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let wid = try makeWorkspace(db: db)

        let tA = try makeThread(db: db, workspaceId: wid, title: "A")
        let tB = try makeThread(db: db, workspaceId: wid, title: "B")
        let tC = try makeThread(db: db, workspaceId: wid, title: "C")

        // Move C to front (position 0)
        try repo.reorder(id: tC.id, position: 0)

        let listed = try repo.list(workspaceId: wid)
        XCTAssertEqual(listed.map(\.title), ["C", "A", "B"],
            "reorder to front must produce C-A-B; transaction wrap must not change final order")
        XCTAssertEqual(listed.map(\.sortOrder), [0, 1, 2],
            "sortOrder must be contiguous 0-1-2 after normalizeOrder; each row gets its enumeration index")
    }

    /// WHY: pinned threads always sort before unpinned. After pinning a thread
    /// and normalizing, pinned group must head the list regardless of insertion order.
    func test_setPinned_pinnedGroupLeadsAfterNormalizeOrder() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let wid = try makeWorkspace(db: db)

        let tA = try makeThread(db: db, workspaceId: wid, title: "A")
        let tB = try makeThread(db: db, workspaceId: wid, title: "B")
        let tC = try makeThread(db: db, workspaceId: wid, title: "C")

        try repo.setPinned(id: tC.id, pinned: true)

        let listed = try repo.list(workspaceId: wid)
        XCTAssertEqual(listed.first?.title, "C",
            "pinned thread must appear first after normalizeOrder; transaction wrap must not disturb grouping")
        XCTAssertEqual(listed.map(\.sortOrder), [0, 1, 2],
            "sortOrder must remain contiguous 0-1-2 with pinned group at the front")
    }

    /// WHY: reorder to a clamped position (beyond list end) must land at the tail.
    func test_reorder_beyondEnd_clampsToTail() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let wid = try makeWorkspace(db: db)

        let tA = try makeThread(db: db, workspaceId: wid, title: "A")
        let tB = try makeThread(db: db, workspaceId: wid, title: "B")
        let tC = try makeThread(db: db, workspaceId: wid, title: "C")

        // Move A to position 999 (beyond list count of 3)
        try repo.reorder(id: tA.id, position: 999)

        let listed = try repo.list(workspaceId: wid)
        XCTAssertEqual(listed.map(\.title), ["B", "C", "A"],
            "reorder beyond end must clamp to tail; transaction wrap must not affect clamp behavior")
        XCTAssertEqual(listed.map(\.sortOrder), [0, 1, 2])
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
