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

    /// WHY: append() runs "DELETE FROM events WHERE id NOT IN (...LIMIT 5000)"
    /// after every insert. If that DELETE is ever missing or uses the wrong LIMIT,
    /// the table grows without bound. This test inserts 5005 rows and asserts only
    /// 5000 survive, pinning the retention policy.
    func test_T009_append_enforcesCapAt5000Rows() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)

        for i in 0..<5005 {
            try repo.append(seq: Int64(i), kind: "test", payloadJSON: "{}")
        }

        let countSt = try db.prepare("SELECT COUNT(*) FROM events;")
        XCTAssertTrue(try countSt.step())
        let count = Int(countSt.columnInt64(0))

        XCTAssertEqual(count, 5000,
            "EventLogRepository must keep at most 5000 rows so the events table cannot grow unboundedly on long-lived installs")
    }

    /// WHY: the cap must retain the NEWEST rows, not the oldest. If the wrong rows
    /// survive, the WebSocket replay bus would re-send stale events from the past
    /// instead of the most recent ones.
    func test_T009_append_capRetainsNewestRows() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)

        for i in 0..<5005 {
            try repo.append(seq: Int64(i), kind: "test", payloadJSON: "{}")
        }

        // read(since:) returns rows with seq > since, ordered ASC.
        // After the cap the 5 oldest rows (seq 0-4) are deleted.
        let all = try repo.read(since: -1, limit: 5000)
        XCTAssertFalse(all.isEmpty, "must have retained rows after cap enforcement")
        XCTAssertEqual(all.first?.seq, 5, "cap must delete the 5 oldest rows (seq 0-4)")
        XCTAssertEqual(all.last?.seq, 5004, "newest row must still be present after cap")
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
}
