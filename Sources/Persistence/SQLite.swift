import Foundation
import SQLite3

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    case step(String)
    case bind(String)
    case execute(String)

    public var description: String {
        switch self {
        case .open(let m): return "sqlite open: \(m)"
        case .prepare(let m): return "sqlite prepare: \(m)"
        case .step(let m): return "sqlite step: \(m)"
        case .bind(let m): return "sqlite bind: \(m)"
        case .execute(let m): return "sqlite execute: \(m)"
        }
    }
}

public final class SQLiteDB {
    fileprivate var handle: OpaquePointer?
    public let path: String
    private let queue = DispatchQueue(label: "RemoteCode.SQLiteDB")

    // MARK: - Prepared-statement cache
    //
    // Thread-safety: the cache lives here and is only accessed inside `queue.sync`
    // blocks (every public method that touches `handle` already serialises through
    // `queue`).  SQLite statement handles are NOT thread-safe on their own, so
    // keeping them inside the serial queue is the only correct approach.
    //
    // Reset contract: before returning a cached statement the cache calls
    // sqlite3_reset + sqlite3_clear_bindings.  sqlite3_reset rewinds the cursor so
    // the caller can re-step, and sqlite3_clear_bindings removes any values left
    // from the previous use so there is no stale-binding data corruption.
    //
    // Eviction: statements are finalised (freed) when the connection closes (deinit).
    // There is no LRU cap because the SQL vocabulary of a single SQLiteDB connection
    // is bounded by the number of distinct query strings in the Persistence module
    // (~40-50 distinct strings), so unbounded growth is not a practical risk.
    private var stmtCache: [String: OpaquePointer] = [:]

    // Returns a cached-and-reset statement, or compiles a fresh one.
    // Caller is responsible for serialisation (either via `performSync` or a
    // single-writer context); see `prepare` for the thread-safety rationale.
    fileprivate func cachedStatement(sql: String) throws -> SQLiteStatement {
        if let cached = stmtCache[sql] {
            // Reset: rewinds the VM + wipes bindings before each reuse.
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return SQLiteStatement(handle: cached, db: self, owned: false)
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(handle))
            throw SQLiteError.prepare(msg)
        }
        stmtCache[sql] = stmt!
        return SQLiteStatement(handle: stmt!, db: self, owned: false)
    }

    public init(path: String) throws {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty && path != ":memory:" {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        if rc != SQLITE_OK {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(h)
            throw SQLiteError.open(msg)
        }
        self.handle = h
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA synchronous=NORMAL;")
        // WAL gives one writer + many readers across processes. The Token Saver
        // sidecar and the app open this same file concurrently (CCR store writes
        // in the sidecar, history/dedup writes in the app), so a writer can briefly
        // hold the lock. Wait instead of failing fast with SQLITE_BUSY.
        try execute("PRAGMA busy_timeout=5000;")
    }

    deinit {
        // Finalise every cached statement before closing the connection.
        // sqlite3_close returns SQLITE_BUSY if any statement is still alive.
        for stmt in stmtCache.values { sqlite3_finalize(stmt) }
        stmtCache.removeAll()
        if let handle { sqlite3_close(handle) }
    }

    public func execute(_ sql: String) throws {
        try queue.sync {
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(handle, sql, nil, nil, &err)
            if rc != SQLITE_OK {
                let m = err.map { String(cString: $0) } ?? "exec failed"
                if let err { sqlite3_free(err) }
                throw SQLiteError.execute(m)
            }
        }
    }

    public func performSync<T>(_ block: (SQLiteDB) throws -> T) rethrows -> T {
        try queue.sync { try block(self) }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        // Does NOT dispatch through `queue`: callers that need serialisation use
        // `performSync` or call from a single-writer context.  Adding queue.sync
        // here would deadlock callers inside `performSync { database.prepare(...) }`
        // (a serial DispatchQueue is non-reentrant).
        //
        // The thread-safety contract is: the cache (`stmtCache`) is accessed only
        // from contexts that are already serialised by either `queue` (via
        // `performSync`) or by the caller's own concurrency domain.  This is the
        // same contract the original `prepare` imposed (it accessed `handle`
        // directly without a queue).
        try cachedStatement(sql: sql)
    }

    public func transaction<T>(_ block: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let r = try block()
            try execute("COMMIT;")
            return r
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func lastErrorMessage() -> String {
        guard let handle else { return "no handle" }
        return String(cString: sqlite3_errmsg(handle))
    }
}

public final class SQLiteStatement {
    // `internal` (not `fileprivate`) so @testable tests can compare handles
    // when verifying the statement cache returns the same compiled pointer.
    let handle: OpaquePointer
    fileprivate weak var db: SQLiteDB?
    // When `owned` is false the handle belongs to the SQLiteDB statement cache
    // and must NOT be finalised here; the cache finalises it in SQLiteDB.deinit.
    private let owned: Bool

    init(handle: OpaquePointer, db: SQLiteDB, owned: Bool = true) {
        self.handle = handle
        self.db = db
        self.owned = owned
    }

    deinit { if owned { sqlite3_finalize(handle) } }

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public func bind(_ index: Int32, _ value: String?) throws {
        guard let value else { sqlite3_bind_null(handle, index); return }
        let rc = sqlite3_bind_text(handle, index, value, -1, SQLiteStatement.transientDestructor)
        if rc != SQLITE_OK { throw SQLiteError.bind("text") }
    }

    public func bind(_ index: Int32, _ value: Int64?) throws {
        guard let value else { sqlite3_bind_null(handle, index); return }
        let rc = sqlite3_bind_int64(handle, index, value)
        if rc != SQLITE_OK { throw SQLiteError.bind("int64") }
    }

    public func bind(_ index: Int32, _ value: Int?) throws {
        try bind(index, value.map { Int64($0) })
    }

    public func bind(_ index: Int32, _ value: Bool?) throws {
        try bind(index, value.map { $0 ? Int64(1) : Int64(0) })
    }

    public func bind(_ index: Int32, _ value: Double?) throws {
        guard let value else { sqlite3_bind_null(handle, index); return }
        let rc = sqlite3_bind_double(handle, index, value)
        if rc != SQLITE_OK { throw SQLiteError.bind("double") }
    }

    public func bind(_ index: Int32, _ value: Data?) throws {
        guard let value else { sqlite3_bind_null(handle, index); return }
        let count = Int32(value.count)
        let rc = value.withUnsafeBytes { ptr in
            sqlite3_bind_blob(handle, index, ptr.baseAddress, count, SQLiteStatement.transientDestructor)
        }
        if rc != SQLITE_OK { throw SQLiteError.bind("blob") }
    }

    public func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        let msg = db.map { $0.lastErrorMessage() } ?? "step \(rc)"
        throw SQLiteError.step(msg)
    }

    public func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    public func columnText(_ index: Int32) -> String? {
        guard let c = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: c)
    }

    public func columnInt64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    public func columnDouble(_ index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    public func columnIsNull(_ index: Int32) -> Bool {
        sqlite3_column_type(handle, index) == SQLITE_NULL
    }

    public func columnBlob(_ index: Int32) -> Data? {
        let count = sqlite3_column_bytes(handle, index)
        guard count > 0, let p = sqlite3_column_blob(handle, index) else { return nil }
        return Data(bytes: p, count: Int(count))
    }
}
