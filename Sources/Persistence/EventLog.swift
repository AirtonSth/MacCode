import Foundation

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

    public func append(seq: Int64, kind: String, payloadJSON: String) throws {
        try db.performSync { db in
            try db.transaction {
                let st = try db.prepare("""
                    INSERT INTO events(seq, kind, request_id, origin_client_id, payload_json, created_at)
                    VALUES(?, ?, NULL, NULL, ?, ?);
                """)
                try st.bind(1, seq)
                try st.bind(2, kind)
                try st.bind(3, payloadJSON)
                try st.bind(4, iso.string(from: Date()))
                _ = try st.step()
                db.noteEventRowsInserted(1)
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

    public func lastSeq() throws -> Int64 {
        let st = try db.prepare("SELECT COALESCE(MAX(seq), 0) FROM events;")
        if try st.step() { return st.columnInt64(0) }
        return 0
    }
}
