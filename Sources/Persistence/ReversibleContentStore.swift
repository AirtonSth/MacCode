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
    ///
    /// PERF: nibble-table hex instead of per-byte `String(format:)` so large
    /// store-before-loss payloads (tool outputs) avoid 32 formatter calls per digest.
    public static func handle(for data: Data) -> String {
        hexDigest(SHA256.hash(data: data))
    }

    /// Same handle as `handle(for: Data(text.utf8))` without an intermediate
    /// `Data` copy — hashes contiguous UTF-8 storage.
    public static func handle(for text: String) -> String {
        var hasher = SHA256()
        var copy = text
        copy.withUTF8 { buffer in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
        }
        return hexDigest(hasher.finalize())
    }

    private static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    // PERF: normalize trims wrapper punctuation on every store/retrieve handle
    // parse; share one set instead of allocating per call (same punctuation
    // set as the deterministic crushers' retrieve-handle normalizer).
    private static let handleStructureTrimSet = CharacterSet(charactersIn: "[]{}() \t\n")

    /// Extract a bare handle from a raw handle or a `[[rc:...]]` marker, normalized.
    static func normalize(_ handleOrMarker: String) -> String {
        var s = handleOrMarker.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "rc:") { s = String(s[r.upperBound...]) }
        s = s.trimmingCharacters(in: handleStructureTrimSet)
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

    /// Prune only unreferenced blocks last accessed before `cutoffMs`.
    ///
    /// **Unsafe by default (plan-final W3):** `ref_count` is never incremented in
    /// production (`retain` is test-only), so every row has ref_count=0 including
    /// originals still referenced by `[[rc:…]]` markers. Callers must pass
    /// `protectedHandles` from `durableReferencedHandles` (or equivalent). When
    /// `protectedHandles` is nil, this method is a no-op and returns 0.
    @discardableResult
    public func pruneUnreferenced(
        olderThanMs cutoffMs: Int64,
        protectedHandles: Set<String>? = nil
    ) throws -> Int {
        guard let protectedHandles else {
            // Fail closed: never delete by ref_count alone.
            return 0
        }
        return try db.performSync { database in
            // Load candidates then filter in process so we never DELETE a protected handle.
            let select = try database.prepare(
                "SELECT handle FROM rc_reversible_content WHERE last_access_ms < ?;"
            )
            defer { select.reset() }
            try select.bind(1, cutoffMs)
            var victims: [String] = []
            while try select.step() {
                guard let handle = select.columnText(0), !handle.isEmpty else { continue }
                if !protectedHandles.contains(handle) {
                    victims.append(handle)
                }
            }
            guard !victims.isEmpty else { return 0 }
            let del = try database.prepare("DELETE FROM rc_reversible_content WHERE handle = ?;")
            for handle in victims {
                del.reset()
                try del.bind(1, handle)
                _ = try del.step()
            }
            return victims.count
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

    /// Total bytes of all stored originals. Used by diagnostics to show store size.
    public func storeSizeBytes() throws -> Int64 {
        try db.performSync { database in
            let stmt = try database.prepare("SELECT COALESCE(SUM(byte_count), 0) FROM rc_reversible_content;")
            defer { stmt.reset() }
            guard try stmt.step() else { return 0 }
            return stmt.columnInt64(0)
        }
    }
}

// MARK: - Retention Job

/// Pure, schedulable retention job for the CCR store.
/// The caller (app launch, daily timer) calls `runRetention(now:cutoffMs:)`.
/// All state lives in SQLite; this struct is stateless.
public struct CCRRetentionJob {

    /// Derive the cutoff timestamp (ms since epoch) from a reference instant and a
    /// retention window. Rows last accessed before this value are eligible for pruning.
    ///
    /// - Parameters:
    ///   - now: The reference instant (pass explicitly so callers and tests control time).
    ///   - retentionDays: Number of days to keep. Default is 30.
    /// - Returns: `Int64` millisecond timestamp. Rows older than this may be pruned.
    public static func olderThanMs(now: Date, retentionDays: Int = 30) -> Int64 {
        let cutoffDate = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return Int64(cutoffDate.timeIntervalSince1970 * 1000)
    }

    /// Run a prune pass and return the number of rows removed.
    ///
    /// - Parameters:
    ///   - store: The CCR store to prune.
    ///   - now: Current instant; passed explicitly for testability.
    ///   - cutoffMs: Rows last accessed before this ms timestamp are candidates.
    ///               Derive it with `olderThanMs(now:retentionDays:)`.
    /// - Returns: Number of rows removed.
    /// Legacy entry — no-op fail-closed. Prefer `LocalStorageBudgetManager.cleanupExpired`.
    @discardableResult
    public static func runRetention(store: ReversibleContentStore, now: Date, cutoffMs: Int64) throws -> Int {
        // plan-final W3: never prune by ref_count; require protected handle set.
        try store.pruneUnreferenced(olderThanMs: cutoffMs, protectedHandles: nil)
    }

    /// Safe retention when the caller supplies marker-reachable handles.
    @discardableResult
    public static func runRetention(
        store: ReversibleContentStore,
        now: Date,
        cutoffMs: Int64,
        protectedHandles: Set<String>
    ) throws -> Int {
        try store.pruneUnreferenced(olderThanMs: cutoffMs, protectedHandles: protectedHandles)
    }
}
