import Foundation
import CryptoKit

/// headroom's CCR (reversible compression) ported native. A content-addressed,
/// on-device store of ORIGINAL payloads keyed by their SHA-256. Any lossy or
/// element-dropping compression embeds a `[[rc:<handle>]]` marker; the agent (or
/// the app) recovers the byte-exact original via `retrieve`. This is what makes
/// aggressive compression safe (N5): nothing is ever dropped without a recovery path.
///
/// Concurrency: stores are written by the sidecar (store-before-loss at the HTTP
/// boundary) and, later, by the app (history compaction / dedup). Both open the
/// same SQLite file; WAL + `busy_timeout` (see SQLiteDB) make cross-process writes
/// wait rather than fail. All access goes through `db.performSync`.
public final class ReversibleContentStore: @unchecked Sendable {
    private let db: SQLiteDB

    public init(db: SQLiteDB) {
        self.db = db
    }

    /// Marker embedded in compressed text to reference a stored original.
    public static func marker(for handle: String) -> String { "[[rc:\(handle)]]" }

    /// Lowercased hex SHA-256 of `data` — the content-addressed handle. Identical
    /// bytes always produce the same handle, so storing twice is a no-op upsert and
    /// repeated blocks (dedup, P4) collapse to one row.
    public static func handle(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func handle(for text: String) -> String {
        handle(for: Data(text.utf8))
    }

    /// Extract a bare handle from a raw handle or a `[[rc:...]]` marker, normalized.
    static func normalize(_ handleOrMarker: String) -> String {
        var s = handleOrMarker.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "rc:") { s = String(s[r.upperBound...]) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]{}() \t\n"))
        return s.lowercased()
    }

    /// Store `data` and return its handle. Idempotent: re-storing identical bytes
    /// just refreshes `last_access_ms` (content-addressed dedup).
    @discardableResult
    public func store(_ data: Data, at date: Date = Date()) throws -> String {
        let hex = Self.handle(for: data)
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        try db.performSync { database in
            let upsert = try database.prepare("""
                INSERT INTO rc_reversible_content
                    (handle, original, sha256, byte_count, ref_count, created_at_ms, last_access_ms)
                VALUES (?, ?, ?, ?, 0, ?, ?)
                ON CONFLICT(handle) DO UPDATE SET last_access_ms = excluded.last_access_ms;
            """)
            defer { upsert.reset() }
            try upsert.bind(1, hex)
            try upsert.bind(2, data)
            try upsert.bind(3, hex)
            try upsert.bind(4, Int64(data.count))
            try upsert.bind(5, ms)
            try upsert.bind(6, ms)
            _ = try upsert.step()
        }
        return hex
    }

    @discardableResult
    public func store(_ text: String, at date: Date = Date()) throws -> String {
        try store(Data(text.utf8), at: date)
    }

    /// Recover the byte-exact original for a handle or `[[rc:...]]` marker, or nil
    /// when it is not stored (a typed "original unavailable" — never empty/hang).
    /// Refreshes `last_access_ms` so a recovered block is not pruned out from under
    /// a live transcript.
    public func retrieve(_ handleOrMarker: String, at date: Date = Date()) throws -> Data? {
        let handle = Self.normalize(handleOrMarker)
        guard !handle.isEmpty else { return nil }
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        return try db.performSync { database in
            let sel = try database.prepare("SELECT original FROM rc_reversible_content WHERE handle = ? LIMIT 1;")
            defer { sel.reset() }
            try sel.bind(1, handle)
            guard try sel.step() else { return nil }
            let data = sel.columnBlob(0) ?? Data()
            let touch = try database.prepare("UPDATE rc_reversible_content SET last_access_ms = ? WHERE handle = ?;")
            defer { touch.reset() }
            try touch.bind(1, ms)
            try touch.bind(2, handle)
            _ = try touch.step()
            return data
        }
    }

    public func retrieveText(_ handleOrMarker: String, at date: Date = Date()) throws -> String? {
        guard let data = try retrieve(handleOrMarker, at: date) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Increment the reference count for a handle (P4 cross-thread retention). A
    /// block reachable from any live transcript is retained; see `pruneUnreferenced`.
    public func retain(_ handleOrMarker: String) throws {
        try adjustRef(handleOrMarker, by: 1)
    }

    public func release(_ handleOrMarker: String) throws {
        try adjustRef(handleOrMarker, by: -1)
    }

    private func adjustRef(_ handleOrMarker: String, by delta: Int) throws {
        let handle = Self.normalize(handleOrMarker)
        guard !handle.isEmpty else { return }
        try db.performSync { database in
            let stmt = try database.prepare(
                "UPDATE rc_reversible_content SET ref_count = MAX(0, ref_count + ?) WHERE handle = ?;"
            )
            defer { stmt.reset() }
            try stmt.bind(1, Int64(delta))
            try stmt.bind(2, handle)
            _ = try stmt.step()
        }
    }

    /// Prune only unreferenced blocks last accessed before `cutoffMs`. Referenced
    /// blocks (ref_count > 0) are never evicted — they outlive the union of the
    /// threads holding them (P4). Returns the number of rows removed.
    @discardableResult
    public func pruneUnreferenced(olderThanMs cutoffMs: Int64) throws -> Int {
        try db.performSync { database in
            let count = try database.prepare(
                "SELECT COUNT(*) FROM rc_reversible_content WHERE ref_count <= 0 AND last_access_ms < ?;"
            )
            defer { count.reset() }
            try count.bind(1, cutoffMs)
            let removed = (try count.step()) ? Int(count.columnInt64(0)) : 0

            let del = try database.prepare(
                "DELETE FROM rc_reversible_content WHERE ref_count <= 0 AND last_access_ms < ?;"
            )
            defer { del.reset() }
            try del.bind(1, cutoffMs)
            _ = try del.step()
            return removed
        }
    }

    /// Number of stored originals (test/inspection helper).
    public func count() throws -> Int {
        try db.performSync { database in
            let stmt = try database.prepare("SELECT COUNT(*) FROM rc_reversible_content;")
            defer { stmt.reset() }
            guard try stmt.step() else { return 0 }
            return Int(stmt.columnInt64(0))
        }
    }
}
