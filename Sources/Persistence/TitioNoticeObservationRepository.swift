import Foundation

/// Semantic terminal events outlive the bounded transport replay log. The
/// event writer inserts them in the same transaction, before replay pruning.
/// A processed row is a dedup checkpoint, not a reason to delete chat history.
public struct TitioNoticeObservationRepository {
    public static let eventKinds: Set<String> = [
        "agent.run.finished", "agent.request.opened", "agent.user_input.requested",
        "agent.request.resolved", "agent.user_input.resolved",
        "git.push", "git.deliver", "project.script.finished",
        "ssh.transfer.completed", "ssh.transfer.failed", "ssh.session.updated",
        "agent.provider.updated", "files.edit.conflict", "files.edit.saved",
        "files.edit.discarded", "files.edit.closed",
    ]
    private let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public struct Row: Sendable {
        public let seq: Int64
        public let kind: String
        public let payloadJSON: String
        public let occurredAt: Double
    }

    public func record(seq: Int64, kind: String, payloadJSON: String, occurredAt: Double) throws {
        guard Self.eventKinds.contains(kind) else { return }
        try db.performSync { database in
            let statement = try database.prepare("""
                INSERT OR IGNORE INTO titio_observations(seq, kind, payload_json, occurred_at)
                VALUES (?, ?, ?, ?);
                """)
            try statement.bind(1, seq)
            try statement.bind(2, kind)
            try statement.bind(3, payloadJSON)
            try statement.bind(4, occurredAt)
            _ = try statement.step()
        }
    }

    public func pending(limit: Int = 100) throws -> [Row] {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT seq, kind, payload_json, occurred_at FROM titio_observations
                WHERE processed_at IS NULL ORDER BY seq LIMIT ?;
                """)
            try statement.bind(1, max(1, limit))
            var rows: [Row] = []
            while try statement.step() {
                rows.append(Row(seq: statement.columnInt64(0), kind: statement.columnText(1) ?? "",
                    payloadJSON: statement.columnText(2) ?? "", occurredAt: statement.columnDouble(3)))
            }
            return rows
        }
    }

    public func acknowledge(seq: Int64, at date: Date) throws {
        try db.performSync { database in
            let statement = try database.prepare("UPDATE titio_observations SET processed_at = ?, payload_json = '{}' WHERE seq = ?;")
            try statement.bind(1, date.timeIntervalSince1970)
            try statement.bind(2, seq)
            _ = try statement.step()
        }
    }
    /// Keep checkpoints while their transport event can still replay. Pending
    /// observations are never pruned, even after a long offline interval.
    public func pruneProcessed(before cutoff: Date) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                DELETE FROM titio_observations WHERE processed_at < ?
                  AND seq < COALESCE((SELECT MIN(seq) FROM events), 0);
                """)
            try statement.bind(1, cutoff.timeIntervalSince1970)
            _ = try statement.step()
        }
    }

}
