import Foundation
import CoreModel

// Reuses the module-level `iso` ISO8601DateFormatter declared in Repositories.swift
// (hoisted; no per-append allocation).

enum EventRetentionPolicy {
    static let cap = 5_000

    /// Caller must own the surrounding transaction so its event write and both
    /// retention deletes commit or roll back together. Receipt rows are permanent.
    static func prune(db: SQLiteDB, cap: Int = cap) throws {
        let boundedCap = max(0, cap)
        // Under the cap both DELETEs are no-ops. The connection-local count
        // lets capped appends remove exactly the excess without two full counts.
        if let known = db.cachedEventRowCountIfKnown(), known <= Int64(boundedCap) {
            return
        }
        let rows: Int64
        if let known = db.cachedEventRowCountIfKnown() {
            rows = known
        } else {
#if DEBUG
            db.noteEventRowCountSelectForTesting()
#endif
            let count = try db.prepare("SELECT COUNT(*) FROM events;")
            _ = try count.step()
            rows = count.columnInt64(0)
            db.rememberEventRowCount(rows)
        }
        guard rows > Int64(boundedCap) else { return }
        let excess = rows - Int64(boundedCap)
        let deleteEvents: SQLiteStatement
        if excess == 1 {
            // The steady-state capped path appends one row at a time. MIN(id)
            // lets SQLite seek and delete that row directly without building a
            // temporary IN result, while remaining correct across id gaps.
            deleteEvents = try db.prepare("""
                DELETE FROM events WHERE id = (SELECT MIN(id) FROM events);
            """)
        } else {
            deleteEvents = try db.prepare("""
                DELETE FROM events
                WHERE id IN (
                    SELECT id FROM events ORDER BY id ASC LIMIT ?
                );
            """)
            try deleteEvents.bind(1, excess)
        }
        _ = try deleteEvents.step()
        let deleteOrphanedReceiptLinks = try db.prepare("""
            DELETE FROM command_receipt_events
            WHERE NOT EXISTS (
                SELECT 1 FROM events WHERE events.seq = command_receipt_events.seq
            );
        """)
        _ = try deleteOrphanedReceiptLinks.step()
        db.rememberEventRowCount(Int64(boundedCap))
    }
}

public final class EventLogRepository {
    let db: SQLiteDB
    // Enforced after every append so the documented cap is never exceeded.
    private static let cap = EventRetentionPolicy.cap

    public init(db: SQLiteDB) { self.db = db }

    public struct Row: Equatable {
        public let seq: Int64
        public let kind: String
        public let payloadJSON: String
        public let createdAt: String
    }

    public struct PendingRow: Sendable, Equatable {
        public let seq: Int64
        public let kind: String
        public let payloadJSON: String

        public init(seq: Int64, kind: String, payloadJSON: String) {
            self.seq = seq
            self.kind = kind
            self.payloadJSON = payloadJSON
        }
    }

    /// Persists one permanent cleanup proof and its replay event atomically.
    public func recordContextCleanupRepair(runID: AgentRunID, payloadJSON: String) throws -> (payloadJSON: String, created: Bool) {
        try db.performSync { db in
            try db.transaction {
                let key = "bot.context.cleanup.receipt." + runID.value.uuidString.lowercased()
                let settings = SettingsRepository(db: db)
                if let existing = try settings.get(key) { return (existing, false) }
                let sequence = try db.prepare("SELECT MAX(last_seq, COALESCE((SELECT MAX(seq) FROM events), 0)) FROM event_sequence WHERE singleton=1;")
                defer { sequence.reset() }
                guard try sequence.step(), sequence.columnInt64(0) < Int64.max else {
                    throw SQLiteError.execute("Durable cleanup receipt sequence is unavailable.")
                }
                let next = sequence.columnInt64(0) + 1
                sequence.reset()
                let event = try db.prepare("""
                    INSERT INTO events(seq, kind, request_id, origin_client_id, payload_json, created_at)
                    VALUES(?, 'bot.context.cleanup.repaired', ?, NULL, ?, ?);
                    """)
                defer { event.reset() }
                try event.bind(1, next)
                try event.bind(2, runID.value.uuidString.lowercased())
                try event.bind(3, payloadJSON)
                try event.bind(4, iso.string(from: Date()))
                _ = try event.step()
                let advance = try db.prepare("UPDATE event_sequence SET last_seq=? WHERE singleton=1;")
                defer { advance.reset() }
                try advance.bind(1, next)
                _ = try advance.step()
                try settings.set(key, payloadJSON)
                db.noteEventRowsInserted(1)
                try EventRetentionPolicy.prune(db: db)
                return (payloadJSON, true)
            }
        }
    }

    public func append(seq: Int64, kind: String, payloadJSON: String) throws {
        try appendBatch([PendingRow(seq: seq, kind: kind, payloadJSON: payloadJSON)])
    }

    /// EV-25(c): one BEGIN IMMEDIATE / n INSERTs / prune / COMMIT for a batch.
    /// Under a stream storm the writer queue used to commit one transaction per
    /// event (~1,100 per 10 min live) and, at the 5,000-row cap, re-ran the
    /// orphaned-receipt DELETE per row. Rows are inserted in the given order.
    public func appendBatch(_ rows: [PendingRow]) throws {
        guard !rows.isEmpty else { return }
        try db.performSync { db in
            try db.transaction {
                let st = try db.prepare("""
                    INSERT INTO events(seq, kind, request_id, origin_client_id, payload_json, created_at)
                    VALUES(?, ?, NULL, NULL, ?, ?);
                """)
                let createdAt = iso.string(from: Date())
                for row in rows {
                    st.reset()
                    try st.bind(1, row.seq)
                    try st.bind(2, row.kind)
                    try st.bind(3, row.payloadJSON)
                    try st.bind(4, createdAt)
                    _ = try st.step()
                }
                db.noteEventRowsInserted(Int64(rows.count))
                try EventRetentionPolicy.prune(db: db, cap: EventLogRepository.cap)
            }
        }
    }

    public func read(since: Int64, limit: Int = 500) throws -> [Row] {
        let st = try db.prepare("""
            SELECT seq, kind, payload_json, created_at FROM events
            WHERE seq > ? ORDER BY seq ASC LIMIT ?;
        """)
        try st.bind(1, since)
        try st.bind(2, Int64(limit))
        var rows: [Row] = []
        while try st.step() {
            rows.append(Row(
                seq: st.columnInt64(0),
                kind: st.columnText(1) ?? "",
                payloadJSON: st.columnText(2) ?? "",
                createdAt: st.columnText(3) ?? ""
            ))
        }
        return rows
    }

    public struct ReplayPage: Equatable {
        /// Rows with seq in `(after, through]`, oldest first.
        public let rows: [Row]
        /// True when a row with seq <= `after` is still stored, which proves
        /// retention has not pruned anything after `after`.
        public let anchored: Bool
    }

    /// C8 durable replay read: one statement (one read snapshot) returns the
    /// newest row at or below `after` as the anchor plus up to `limit` rows
    /// in `(after, through]`.
    public func readReplayPage(after: Int64, through: Int64, limit: Int) throws -> ReplayPage {
        let st = try db.prepare("""
            SELECT seq, kind, payload_json, created_at FROM events
            WHERE seq >= COALESCE((SELECT MAX(seq) FROM events WHERE seq <= ?), ? + 1)
              AND seq <= ?
            ORDER BY seq ASC LIMIT ?;
        """)
        try st.bind(1, after)
        try st.bind(2, after)
        try st.bind(3, through)
        try st.bind(4, Int64(max(0, limit)) + 1)
        var rows: [Row] = []
        var anchored = false
        while try st.step() {
            let row = Row(
                seq: st.columnInt64(0),
                kind: st.columnText(1) ?? "",
                payloadJSON: st.columnText(2) ?? "",
                createdAt: st.columnText(3) ?? ""
            )
            if row.seq <= after {
                anchored = true
            } else {
                rows.append(row)
            }
        }
        if rows.count > limit { rows.removeLast(rows.count - limit) }
        return ReplayPage(rows: rows, anchored: anchored)
    }

    /// The oldest rows in `(after, through]` (at most `rowLimit`) and their
    /// kind + payload bytes, for the durable-replay budget. `anchored` is
    /// false when no row at or below `after` is left (retention may have
    /// pruned past it); the sum is then skipped. Both reads are bounded: an
    /// index seek and at most `rowLimit` rows, whatever the range.
    public func estimateReplay(
        after: Int64,
        through: Int64,
        rowLimit: Int
    ) throws -> (rows: Int, bytes: Int, anchored: Bool) {
        let anchor = try db.prepare("SELECT 1 FROM events WHERE seq <= ? LIMIT 1;")
        try anchor.bind(1, after)
        guard try anchor.step() else { return (0, 0, false) }
        let st = try db.prepare("""
            SELECT COUNT(*),
                   COALESCE(SUM(LENGTH(CAST(payload_json AS BLOB)) + LENGTH(CAST(kind AS BLOB))), 0)
            FROM (
                SELECT payload_json, kind FROM events
                WHERE seq > ? AND seq <= ?
                ORDER BY seq ASC LIMIT ?
            );
        """)
        try st.bind(1, after)
        try st.bind(2, through)
        try st.bind(3, Int64(max(0, rowLimit)))
        guard try st.step() else { return (0, 0, true) }
        return (Int(st.columnInt64(0)), Int(st.columnInt64(1)), true)
    }

    /// Parses `created_at` (written by `appendBatch`) back to a Date.
    public static func createdAtDate(_ value: String) -> Date? {
        iso.date(from: value)
    }

    public func lastSeq() throws -> Int64 {
        let st = try db.prepare("SELECT COALESCE(MAX(seq), 0) FROM events;")
        if try st.step() { return st.columnInt64(0) }
        return 0
    }
}
