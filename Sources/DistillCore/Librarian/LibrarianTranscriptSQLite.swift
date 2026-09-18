import Foundation
import SQLite3

/// Read-only SQLite access to the host's persisted transcript so
/// `session_transcript_search` and `history_recall_search` return real turns.
/// Opens the database with `SQLITE_OPEN_READONLY`: a librarian op can never
/// write to the host store.
public final class LibrarianTranscriptSQLite: @unchecked Sendable {
    private let dbPath: String
    private let lock = NSLock()
    private var db: OpaquePointer?

    public init(dbPath: String) {
        self.dbPath = dbPath
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public var store: LibrarianTranscriptStore {
        // Strong capture: the store struct owns the connection lifetime, so a
        // caller that keeps only `.store` still has a live read-only database.
        LibrarianTranscriptStore(
            search: { query, limit, threadID in
                self.rows(
                    sql: """
                    SELECT thread_id, role, created_at, substr(content, 1, 400)
                    FROM agent_messages
                    WHERE content LIKE ?1 ESCAPE '\\'
                      AND (?2 IS NULL OR thread_id = ?2)
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?3
                    """,
                    bindings: ["%\(Self.escapedLike(query))%", threadID, String(max(1, min(50, limit)))]
                )
            },
            recent: { limit, threadID in
                self.rows(
                    sql: """
                    SELECT thread_id, role, created_at, substr(content, 1, 400)
                    FROM agent_messages
                    WHERE (?2 IS NULL OR thread_id = ?2)
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?1
                    """,
                    bindings: [String(max(1, min(50, limit))), threadID]
                )
            }
        )
    }

    static func escapedLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func connection() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        if let db { return db }
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        db = handle
        return handle
    }

    private func rows(sql: String, bindings: [String?]) -> [LibrarianTranscriptHit]? {
        guard let handle = connection() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            if let value {
                sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, index)
            }
        }
        var hits: [LibrarianTranscriptHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let thread = column(statement, 0) ?? ""
            let role = column(statement, 1) ?? ""
            let created = column(statement, 2) ?? ""
            let snippet = (column(statement, 3) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            hits.append(LibrarianTranscriptHit(
                threadID: thread,
                role: role,
                createdAt: created,
                snippet: snippet
            ))
        }
        return hits
    }

    private func column(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
