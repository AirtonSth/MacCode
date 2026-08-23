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

    /// WHY: append() must enforce the documented hard cap after every write. If the
    /// prune is missing or delayed, the table can exceed the promised bound.
    func test_T009_append_enforcesCapAt5000Rows() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)

        for i in 0..<5001 {
            try repo.append(seq: Int64(i), kind: "test", payloadJSON: "{}")
        }

        let countSt = try db.prepare("SELECT COUNT(*) FROM events;")
        XCTAssertTrue(try countSt.step())
        let count = Int(countSt.columnInt64(0))

        XCTAssertEqual(count, 5000,
            "EventLogRepository must enforce its documented 5000-row hard cap")
    }

    /// WHY: the cap must retain the NEWEST rows, not the oldest. If the wrong rows
    /// survive, the WebSocket replay bus would re-send stale events from the past
    /// instead of the most recent ones.
    func test_T009_append_capRetainsNewestRows() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)

        for i in 0..<5001 {
            try repo.append(seq: Int64(i), kind: "test", payloadJSON: "{}")
        }

        let all = try repo.read(since: -1, limit: 6000)
        XCTAssertFalse(all.isEmpty, "must have retained rows after cap enforcement")
        XCTAssertEqual(all.count, 5000)
        XCTAssertEqual(all.first?.seq, 1, "cap must delete the oldest row")
        XCTAssertEqual(all.last?.seq, 5000, "cap must retain the newest row")
    }

    // MARK: - T009b: hard cap — no transient overflow

    /// WHY: no append may leave a transient state above the documented cap.
    func test_T009b_eachPostCapAppendRemainsStrictlyBounded() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)

        let total = 5003
        for i in 0..<total {
            try repo.append(seq: Int64(i), kind: "test", payloadJSON: "{}")
            if i >= 4999 {
                let countSt = try db.prepare("SELECT COUNT(*) FROM events;")
                XCTAssertTrue(try countSt.step())
                XCTAssertEqual(Int(countSt.columnInt64(0)), 5000)
            }
        }

        // The most recent row (seq = total - 1) must survive.
        let newest = try repo.read(since: Int64(total - 2), limit: 1)
        XCTAssertEqual(newest.first?.seq, Int64(total - 1),
            "strict pruning must retain the newest row")

        // The very first row (seq = 0) must be gone after the prune cycle.
        let oldest = try repo.read(since: -1, limit: 1)
        XCTAssertNotEqual(oldest.first?.seq, 0,
            "strict pruning must remove the oldest row")
    }

    /// WHY: append and retention are one atomic write. If pruning fails, callers
    /// must not receive an error after the new event has already been committed.
    /// WHY: every append used to run two retention DELETEs (events + orphan
    /// receipt links) even when COUNT(*) was far below the cap. A DELETE
    /// abort must not fail those under-cap writes.
    func test_append_underCapSkipsRetentionDeletes() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)
        try db.execute("""
            CREATE TRIGGER reject_event_retention_delete
            BEFORE DELETE ON events
            BEGIN
                SELECT RAISE(ABORT, 'injected retention failure');
            END;
        """)

        XCTAssertNoThrow(try repo.append(seq: 1, kind: "test", payloadJSON: "{}"))
        XCTAssertNoThrow(try repo.append(seq: 2, kind: "test", payloadJSON: "{}"))

        let countSt = try db.prepare("SELECT COUNT(*) FROM events;")
        XCTAssertTrue(try countSt.step())
        XCTAssertEqual(Int(countSt.columnInt64(0)), 2,
            "under-cap appends must not touch retention DELETEs")
    }

    func test_T009c_pruneFailureRollsBackAppendAndPreservesHardCap() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)
        for i in 0..<5000 {
            try repo.append(seq: Int64(i), kind: "test", payloadJSON: "{}")
        }
        try db.execute("""
            CREATE TRIGGER reject_event_retention_delete
            BEFORE DELETE ON events
            BEGIN
                SELECT RAISE(ABORT, 'injected retention failure');
            END;
        """)

        XCTAssertThrowsError(
            try repo.append(seq: 5000, kind: "test", payloadJSON: "{}")
        )

        let countSt = try db.prepare("SELECT COUNT(*) FROM events;")
        XCTAssertTrue(try countSt.step())
        XCTAssertEqual(Int(countSt.columnInt64(0)), 5000)
        let insertedSt = try db.prepare("SELECT COUNT(*) FROM events WHERE seq = 5000;")
        XCTAssertTrue(try insertedSt.step())
        XCTAssertEqual(Int(insertedSt.columnInt64(0)), 0,
            "failed retention must roll back the new event with the prune")

        try db.execute("DROP TRIGGER reject_event_retention_delete;")
        try repo.append(seq: 5001, kind: "test", payloadJSON: "{}")
        let recovered = try repo.read(since: -1, limit: 6000)
        XCTAssertEqual(recovered.count, 5000)
        XCTAssertEqual(recovered.first?.seq, 1,
            "a rolled-back prune must restore the cached occupancy before retry")
        XCTAssertEqual(recovered.last?.seq, 5001)
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

    func test_readLimitReturnsFirstEventsAfterCursorInAscendingSequenceOrder() throws {
        let db = try makeDB()
        let repo = EventLogRepository(db: db)
        for sequence in 1...8 {
            try repo.append(seq: Int64(sequence), kind: "event.\(sequence)", payloadJSON: "{}")
        }

        let rows = try repo.read(since: -1, limit: 3)

        XCTAssertEqual(rows.map(\.seq), [1, 2, 3],
                       "cursor pagination must return the first matching page in reducer order")
    }

    func test_append_skipsEventCountSelectWhileUnderCap() throws {
        // WHY: every EventLog.append used to SELECT COUNT(*) FROM events even
        // when the table was far under the 5000-row cap (lifecycle persist
        // after stream kinds were already live-only). The connection caches
        // occupancy after the first count so later under-cap appends skip it.
        let db = try makeDB()
        let repo = EventLogRepository(db: db)
        XCTAssertEqual(db.eventRowCountSelectCountForTesting, 0)
        try repo.append(seq: 1, kind: "agent.run.started", payloadJSON: "{}")
        XCTAssertEqual(
            db.eventRowCountSelectCountForTesting, 1,
            "first append must COUNT once to seed the connection cache"
        )
        for seq in 2...10 {
            try repo.append(seq: Int64(seq), kind: "agent.run.started", payloadJSON: "{}")
        }
        XCTAssertEqual(
            db.eventRowCountSelectCountForTesting, 1,
            "nine more under-cap appends must not COUNT again"
        )
        let countSt = try db.prepare("SELECT COUNT(*) FROM events;")
        XCTAssertTrue(try countSt.step())
        XCTAssertEqual(countSt.columnInt64(0), 10)
    }

    func test_append_skipsEventCountSelectAfterCap() throws {
        // WHY: lifecycle traffic continues after the 5,000-row replay cap. The
        // connection already knows occupancy, so recounting the full table twice
        // per event turns a fixed bound into permanent O(cap) append work.
        let db = try makeDB()
        let repo = EventLogRepository(db: db)
        for seq in 0..<5_010 {
            try repo.append(seq: Int64(seq), kind: "agent.run.started", payloadJSON: "{}")
        }

        XCTAssertEqual(
            db.eventRowCountSelectCountForTesting,
            1,
            "the initial occupancy seed is the only COUNT(*) required across capped appends"
        )
        let retained = try repo.read(since: -1, limit: 6_000)
        XCTAssertEqual(retained.count, 5_000)
        XCTAssertEqual(retained.first?.seq, 10)
        XCTAssertEqual(retained.last?.seq, 5_009)
    }

    /// Same-process A/B of the previous post-cap retention SQL and the cached
    /// exact-excess path. Primary metric: wall time for 1,000 durable appends after
    /// a 5,000-row seed (warmup=2, n=5).
    func test_microbench_postCapRetention_avoidsFullRecountsAndOrphanScan() throws {
        let warmup = 2
        let samples = 5
        let appendsPerSample = 1_000

        func median(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }

        func elapsedMilliseconds(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }

        var before: [Double] = []
        var after: [Double] = []
        for iteration in 0..<(warmup + samples) {
            let legacyDB = try makeDB()
            let optimizedDB = try makeDB()
            try seedEventLogAtCap(legacyDB)
            try seedEventLogAtCap(optimizedDB)

            let runLegacy = {
                try self.measureLegacyPostCapAppends(
                    db: legacyDB,
                    startSequence: 5_000,
                    count: appendsPerSample
                )
            }
            let runOptimized = {
                let repo = EventLogRepository(db: optimizedDB)
                for offset in 0..<appendsPerSample {
                    try repo.append(
                        seq: Int64(5_000 + offset),
                        kind: "agent.run.started",
                        payloadJSON: "{}"
                    )
                }
            }

            let legacyMS: Double
            let optimizedMS: Double
            if iteration.isMultiple(of: 2) {
                legacyMS = try elapsedMilliseconds(runLegacy)
                optimizedMS = try elapsedMilliseconds(runOptimized)
            } else {
                optimizedMS = try elapsedMilliseconds(runOptimized)
                legacyMS = try elapsedMilliseconds(runLegacy)
            }

            let legacyRows = try EventLogRepository(db: legacyDB).read(since: -1, limit: 6_000)
            let optimizedRows = try EventLogRepository(db: optimizedDB).read(since: -1, limit: 6_000)
            XCTAssertEqual(optimizedRows.map(\.seq), legacyRows.map(\.seq))
            XCTAssertEqual(optimizedRows.count, 5_000)

            if iteration >= warmup {
                before.append(legacyMS)
                after.append(optimizedMS)
            }
        }

        let beforeMedian = median(before)
        let afterMedian = median(after)
        let improvement = (beforeMedian - afterMedian) / beforeMedian * 100
        NSLog(
            "[perf-proof] eventLogPostCap legacy_ms=%@ optimized_ms=%@ improvement_pct=%.2f before=%@ after=%@ appends=%d cap=5000",
            String(beforeMedian), String(afterMedian), improvement,
            String(describing: before), String(describing: after), appendsPerSample
        )
        XCTAssertGreaterThan(
            improvement,
            5,
            "exact cached retention must outperform two full recounts and an orphan scan by at least 5%"
        )
    }

    private func seedEventLogAtCap(_ db: SQLiteDB) throws {
        try db.performSync { database in
            try database.transaction {
                for sequence in 0..<5_000 {
                    let statement = try database.prepare("""
                        INSERT INTO events(seq, kind, request_id, origin_client_id, payload_json, created_at)
                        VALUES(?, 'agent.run.started', NULL, NULL, '{}', '2026-08-23T00:00:00Z');
                    """)
                    try statement.bind(1, Int64(sequence))
                    _ = try statement.step()
                }
            }
        }
        db.rememberEventRowCount(5_000)
    }

    private func measureLegacyPostCapAppends(
        db: SQLiteDB,
        startSequence: Int,
        count: Int
    ) throws {
        for offset in 0..<count {
            try db.performSync { database in
                try database.transaction {
                    let statement = try database.prepare("""
                        INSERT INTO events(seq, kind, request_id, origin_client_id, payload_json, created_at)
                        VALUES(?, 'agent.run.started', NULL, NULL, '{}', ?);
                    """)
                    try statement.bind(1, Int64(startSequence + offset))
                    try statement.bind(2, iso.string(from: Date()))
                    _ = try statement.step()
                    database.noteEventRowsInserted(1)

                    database.noteEventRowCountSelectForTesting()
                    let countStatement = try database.prepare("SELECT COUNT(*) FROM events;")
                    _ = try countStatement.step()
                    let rows = countStatement.columnInt64(0)
                    database.rememberEventRowCount(rows)
                    if rows > 5_000 {
                        try database.execute("""
                            DELETE FROM events
                            WHERE id <= (SELECT MAX(id) FROM events) - 5000;
                        """)
                        try database.execute("""
                            DELETE FROM command_receipt_events
                            WHERE NOT EXISTS (
                                SELECT 1 FROM events WHERE events.seq = command_receipt_events.seq
                            );
                        """)
                        database.noteEventRowCountSelectForTesting()
                        let after = try database.prepare("SELECT COUNT(*) FROM events;")
                        _ = try after.step()
                        database.rememberEventRowCount(after.columnInt64(0))
                    }
                }
            }
        }
    }
}
