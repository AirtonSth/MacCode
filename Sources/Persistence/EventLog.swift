import Foundation

public final class EventLogRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public struct Row: Equatable {
        public let seq: Int64
        public let kind: String
        public let payloadJSON: String
        public let createdAt: String
    }

    public func append(seq: Int64, kind: String, payloadJSON: String) throws {
        let st = try db.prepare("""
            INSERT INTO events(seq, kind, request_id, origin_client_id, payload_json, created_at)
            VALUES(?, ?, NULL, NULL, ?, ?);
        """)
        try st.bind(1, seq)
        try st.bind(2, kind)
        try st.bind(3, payloadJSON)
        try st.bind(4, ISO8601DateFormatter().string(from: Date()))
        _ = try st.step()
        // bounded log
        try db.execute("DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 5000);")
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
