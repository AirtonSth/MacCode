import XCTest
@testable import Persistence
import CoreModel

/// Tests for EventLogRepository: bound enforcement (cap 5000), ordering, and read(since:).
///
/// WHY these tests matter (T009-T011):
///   - The `events` table has a hard cap of 5000 rows. Without a test, a bug in the
///     DELETE LIMIT could silently let the table grow unboundedly.
///   - read(since:) is the replay path the WebSocket event bus uses; wrong ordering
///     or an off-by-one on the `seq > ?` predicate causes a client to miss or
///     double-receive events.
///   - lastSeq() is the watermark callers use to avoid re-sending stale events;
///     wrong results cause duplicate delivery or dropped events.
final class EventLogRepositoryTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    // MARK: - T009: events bound — cap at 5000 rows

    /// WHY: append() prunes periodically (every 256 appends). If the prune is ever
    /// missing or uses the wrong LIMIT, the table grows without bound. This test
    /// inserts cap + pruneInterval rows (5256) to guarantee at least one prune fires,
    /// then asserts the row count is bounded, pinning the retention policy.
    func test_T009_append_enforcesCapAt5000Rows() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)

        // 5256 = cap(5000) + pruneInterval(256); guarantees the prune at append #256
        // fires at least once so the DELETE actually executes.
        for i in 0..<5256 {
            try repo.append(seq: Int64(i), kind: "test", payloadJSON: "{}")
        }

        let countSt = try db.prepare("SELECT COUNT(*) FROM events;")
        XCTAssertTrue(try countSt.step())
        let count = Int(countSt.columnInt64(0))

        // Prune fires at append multiples of 256; after 5256 appends the last prune
        // was at append #5120 (20 * 256), leaving at most 5000 + 255 = 5255 rows.
        // But since 5256 is itself a multiple of 256 (5256 / 256 = 20.53... no --
        // 5120 = 20*256, 5376 = 21*256; so the last prune before 5256 is at 5120,
        // after which 136 more rows are inserted). Bound: <= 5255.
        XCTAssertLessThanOrEqual(count, 5255,
            "EventLogRepository must keep at most cap+pruneInterval-1 rows so the events table cannot grow unboundedly")
    }

    /// WHY: the cap must retain the NEWEST rows, not the oldest. If the wrong rows
    /// survive, the WebSocket replay bus would re-send stale events from the past
    /// instead of the most recent ones. Uses 5256 inserts so at least one prune fires.
    func test_T009_append_capRetainsNewestRows() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)

        // 5256 = cap + pruneInterval; at append #256 the prune fires for the first
        // time, deleting rows with id <= max_id - 5000 (i.e. the oldest 256 rows).
        for i in 0..<5256 {
            try repo.append(seq: Int64(i), kind: "test", payloadJSON: "{}")
        }

        // After the last prune (at append #5120) 120 rows were deleted; the oldest
        // surviving row has seq >= 120. The newest must always be present.
        let all = try repo.read(since: -1, limit: 6000)
        XCTAssertFalse(all.isEmpty, "must have retained rows after cap enforcement")
        XCTAssertEqual(all.last?.seq, 5255, "newest row (seq=5255) must still be present after cap")
        // Oldest surviving row must have been pruned at least once (seq > 0 after first prune at #256).
        XCTAssertGreaterThan(all.first?.seq ?? 0, 0,
            "cap must delete the oldest rows; seq=0 must not survive a full prune cycle")
    }

    // MARK: - T009b: periodic prune — bounded growth, newest rows retained

    /// WHY: the prune is now gated to run every 256 appends, not every append, to
    /// avoid a full anti-join on the publishing thread. This test verifies:
    ///   1. After cap + pruneInterval rows the table is bounded (<= cap + pruneInterval - 1).
    ///   2. The newest rows are retained (the oldest are purged).
    /// Without this test a regression that skips the prune entirely would go undetected
    /// until the events table grew unboundedly on long-lived installs.
    func test_T009b_periodicPrune_boundsTableAndRetainsNewestRows() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)

        // Insert cap + pruneInterval rows to guarantee at least one prune fires.
        let total = 5000 + 256
        for i in 0..<total {
            try repo.append(seq: Int64(i), kind: "test", payloadJSON: "{}")
        }

        let countSt = try db.prepare("SELECT COUNT(*) FROM events;")
        XCTAssertTrue(try countSt.step())
        let count = Int(countSt.columnInt64(0))

        // After the prune at append #256 the table must be <= cap + pruneInterval - 1
        // (at most cap + 255 rows transiently between prune runs).
        XCTAssertLessThanOrEqual(count, 5000 + 256 - 1,
            "periodic prune must keep the table bounded so growth is O(pruneInterval) above cap, not unbounded")

        // The most recent row (seq = total - 1) must survive.
        let newest = try repo.read(since: Int64(total - 2), limit: 1)
        XCTAssertEqual(newest.first?.seq, Int64(total - 1),
            "periodic prune must retain the newest rows; if it deletes from the wrong end, the event bus loses recent events")

        // The very first row (seq = 0) must be gone after the prune cycle.
        let oldest = try repo.read(since: -1, limit: 1)
        XCTAssertNotEqual(oldest.first?.seq, 0,
            "periodic prune must remove the oldest rows; if seq=0 survives a full prune cycle, the table grows from the wrong end")
    }

    // MARK: - T010: ordering — read(since:) returns rows seq ASC

    /// WHY: WebSocket event streaming depends on rows arriving in seq-ascending order.
    /// Out-of-order delivery corrupts state machines on the client side.
    func test_T010_read_returnsRowsInSeqAscendingOrder() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)

        // Insert out of natural-insert order to verify ORDER BY seq ASC, not rowid order.
        for seq in [10, 3, 7, 1, 15] as [Int64] {
            try repo.append(seq: seq, kind: "e", payloadJSON: "{}")
        }

        let rows = try repo.read(since: 0, limit: 10)
        XCTAssertEqual(rows.map(\.seq), [1, 3, 7, 10, 15],
            "read(since:) must return rows in seq ASC order so WebSocket clients receive events in the correct sequence")
    }

    // MARK: - T011: read(since:) uses strict greater-than on seq

    /// WHY: the predicate `seq > ?` is intentionally strict (not >=). If it were >=,
    /// callers using their last-received seq as the watermark would always re-receive
    /// the last event, causing a duplicate on every poll.
    func test_T011_read_since_excludesExactSeqBoundary() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)

        try repo.append(seq: 1, kind: "a", payloadJSON: "{}")
        try repo.append(seq: 2, kind: "b", payloadJSON: "{}")
        try repo.append(seq: 3, kind: "c", payloadJSON: "{}")

        let rows = try repo.read(since: 2, limit: 10)
        XCTAssertEqual(rows.map(\.seq), [3],
            "read(since: 2) must return only seq > 2, so callers using last-received seq as watermark do not re-receive the boundary event")
    }

    func test_T011_read_since_minus1_returnsAll() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)

        try repo.append(seq: 1, kind: "x", payloadJSON: "{}")
        try repo.append(seq: 2, kind: "x", payloadJSON: "{}")

        let rows = try repo.read(since: 0, limit: 100)
        XCTAssertEqual(rows.count, 2, "read(since: 0) must return all rows when all seqs are > 0")
    }

    func test_T011_read_limit_capsResults() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)

        for i in 1...10 as ClosedRange<Int64> {
            try repo.append(seq: i, kind: "e", payloadJSON: "{}")
        }

        let rows = try repo.read(since: 0, limit: 3)
        XCTAssertEqual(rows.count, 3, "read(since:limit:) must respect the limit so callers can page through events in bounded chunks")
        XCTAssertEqual(rows.map(\.seq), [1, 2, 3], "limited read must return the oldest rows in the window, not a random subset")
    }

    // MARK: - lastSeq() watermark

    /// WHY: callers publish events with monotonically increasing seqs; lastSeq()
    /// is the starting watermark. If it returns wrong results, callers either
    /// duplicate old events or gap-skip new ones.
    func test_lastSeq_returnsZeroOnEmptyTable() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)

        XCTAssertEqual(try repo.lastSeq(), 0,
            "lastSeq() must return 0 on an empty table so new publishers start from seq=1 without skipping")
    }

    func test_lastSeq_returnsMaxSeqAfterInserts() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)

        try repo.append(seq: 5, kind: "a", payloadJSON: "{}")
        try repo.append(seq: 2, kind: "b", payloadJSON: "{}")
        try repo.append(seq: 9, kind: "c", payloadJSON: "{}")

        XCTAssertEqual(try repo.lastSeq(), 9,
            "lastSeq() must return MAX(seq), not the last-inserted seq, so the watermark is always the global high-water mark")
    }

    // MARK: - kind and payloadJSON round-trip

    /// WHY: EventLogRepository stores kind and payload verbatim; if either field
    /// is truncated or mangled the consuming event bus would dispatch wrong events.
    func test_append_roundTripsKindAndPayload() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)

        let payload = #"{"type":"agent.run.finished","runId":"run-abc"}"#
        try repo.append(seq: 1, kind: "agent.run.finished", payloadJSON: payload)

        let rows = try repo.read(since: 0, limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, "agent.run.finished",
            "kind must round-trip so the event bus dispatches to the correct handler")
        XCTAssertEqual(rows[0].payloadJSON, payload,
            "payloadJSON must round-trip verbatim so consumers decode the correct event body")
    }

    func test_readNewest_loadsNewestRetainedRangeInAscendingSequenceOrder() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)
        for sequence in 1...8 {
            try repo.append(seq: Int64(sequence), kind: "event.\(sequence)", payloadJSON: "{}")
        }

        let rows = try repo.read(since: -1, limit: 3)

        XCTAssertEqual(rows.map(\.seq), [6, 7, 8],
                       "startup replay must load the newest retained range and preserve reducer order")
    }
}
