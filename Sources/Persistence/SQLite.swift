import Foundation
import CoreModel
import SQLite3

protocol SQLiteDBOwnedMaintenance: AnyObject {
    func cancel()
}

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

    /// True when the failure is SQLite lock contention that may clear if retried
    /// (SQLITE_BUSY / SQLITE_LOCKED and extended forms such as BUSY_SNAPSHOT).
    public var isTransientLockContention: Bool {
        switch self {
        case .open(let m), .prepare(let m), .step(let m), .execute(let m):
            return Self.messageIndicatesTransientLock(m)
        case .bind:
            return false
        }
    }

    fileprivate static func messageIndicatesTransientLock(_ message: String) -> Bool {
        let lower = message.lowercased()
        // sqlite3_errmsg for BUSY/LOCKED is typically "database is locked" or
        // "database table is locked". Match those and the common "database is locked"
        // surface form already stored on failed agent runs.
        return lower.contains("database is locked")
            || lower.contains("database table is locked")
    }

    fileprivate static func isTransientLockCode(_ rc: Int32) -> Bool {
        // Primary result codes: SQLITE_BUSY (5), SQLITE_LOCKED (6). Extended
        // codes (BUSY_SNAPSHOT, BUSY_TIMEOUT, LOCKED_SHAREDCACHE, …) keep the
        // same primary byte in the low 8 bits.
        let primary = rc & 0xFF
        return primary == SQLITE_BUSY || primary == SQLITE_LOCKED
    }
}

public final class SQLiteDB {
    fileprivate var handle: OpaquePointer?
    public let path: String
    private let queue: DispatchQueue
    // Repository methods historically prepare and step statements off `queue`.
    // This recursive gate therefore spans every transaction and every statement
    // step, preventing a bare repository writer from entering a maintenance
    // transaction between its durable-reference scan and reversible-row delete.
    private let operationLock = NSRecursiveLock()
    // Process-only Agent App selections belong to this database connection so
    // distinct repository instances share one retention authority. The same
    // operation lock makes selection changes atomic with capped transactions.
    private var liveAgentThreadBySurface: [SurfaceID: AgentThreadID] = [:]
    private var ownedMaintenance: SQLiteDBOwnedMaintenance?
    private(set) var maintenanceInstallCountForTesting = 0
#if DEBUG
    /// `SELECT COUNT(*) FROM events` probes from `EventRetentionPolicy.prune`.
    private(set) var eventRowCountSelectCountForTesting = 0
#endif
    var onDeinitForTesting: (() -> Void)?
    /// Connection-local events-table occupancy. EventLog + command receipts
    /// share this so under-cap appends skip COUNT(*).
    private var cachedEventRowCount: Int64?
    /// Connection-scoped terminal occupancy estimate shared by every repository
    /// using this SQLite authority. Nil fails closed to a real global scan.
    private var cachedTerminalOutputBytes: Int?

    func cachedEventRowCountIfKnown() -> Int64? { cachedEventRowCount }

    func rememberEventRowCount(_ count: Int64) {
        cachedEventRowCount = count
    }

    func noteEventRowsInserted(_ n: Int64) {
        guard n > 0, let current = cachedEventRowCount else { return }
        cachedEventRowCount = current + n
    }

    func terminalOutputRetentionRequired(maxBytes: Int) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let cachedTerminalOutputBytes else { return true }
        return cachedTerminalOutputBytes > maxBytes
    }

    func rememberTerminalOutputBytes(_ byteCount: Int) {
        operationLock.lock()
        cachedTerminalOutputBytes = max(0, byteCount)
        operationLock.unlock()
    }

    func noteTerminalOutputBytesInserted(_ byteCount: Int) {
        operationLock.lock()
        if let current = cachedTerminalOutputBytes {
            let (updated, overflow) = current.addingReportingOverflow(max(0, byteCount))
            cachedTerminalOutputBytes = overflow ? Int.max : updated
        }
        operationLock.unlock()
    }

    func invalidateTerminalOutputBytes() {
        operationLock.lock()
        cachedTerminalOutputBytes = nil
        operationLock.unlock()
    }

#if DEBUG
    func noteEventRowCountSelectForTesting() {
        eventRowCountSelectCountForTesting += 1
    }
#endif
    // Marks `queue` so cachedStatement() can detect when it is running inside a
    // `performSync` block (and may therefore safely reuse a shared cached stmt).
    private static let queueKey = DispatchSpecificKey<UInt8>()

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
    var beforeStatementStepForTesting: ((String) -> Void)?
    /// Invoked for every `execute` SQL string (including BEGIN/COMMIT/ROLLBACK).
    /// Tests use this to prove read paths never issue BEGIN IMMEDIATE or DDL.
    var beforeExecuteForTesting: ((String) -> Void)?

    // Nesting depth for `transaction` / `readTransaction`. While > 0, individual
    // execute/step calls must NOT retry: a mid-transaction retry would re-run only
    // one statement and could double-apply earlier work. Retry is owned by the
    // transaction helpers so the whole BEGIN…COMMIT unit restarts after ROLLBACK.
    fileprivate var transactionDepth = 0

    // MARK: - Transient lock retry (test hooks + policy)
    //
    // `PRAGMA busy_timeout` already waits for ordinary SQLITE_BUSY, but it does
    // not cover every contention case (notably SQLITE_BUSY_SNAPSHOT and some
    // upgrade/deadlock paths return immediately). Application-level retry is a
    // second, bounded backstop so a brief lock does not fail an agent run.
    private enum BusyRetryDefaults {
        static let maxAttempts = 8
        /// Extra sleep budget after each failed attempt (busy_timeout waits are
        /// inside SQLite and do not count against this).
        static let maxSleepNanoseconds: UInt64 = 2_000_000_000
        static let initialSleepNanoseconds: UInt64 = 1_000_000
        static let maxSingleSleepNanoseconds: UInt64 = 100_000_000
    }

    /// When non-empty, the next executeDirect/step pops a code and treats it as
    /// the SQLite result without calling into the C API. Deterministic tests use
    /// this to inject SQLITE_BUSY once (retry succeeds) or repeatedly (exhaust).
    var injectedResultCodesForTesting: [Int32] = []
    /// Counts entry into the transient-lock retry loop body (including the first
    /// attempt). Tests assert non-transient errors do not inflate this.
    private(set) var transientLockAttemptCountForTesting = 0
    var busyRetryMaxAttemptsForTesting: Int?
    var busyRetryMaxSleepNanosecondsForTesting: UInt64?

    func withSerializedOperation<T>(_ block: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try block()
    }

    func setLiveAgentThreadBinding(surfaceID: SurfaceID, threadID: AgentThreadID?) {
        withSerializedOperation {
            if let threadID {
                liveAgentThreadBySurface[surfaceID] = threadID
            } else {
                liveAgentThreadBySurface.removeValue(forKey: surfaceID)
            }
        }
    }

    func withLiveAgentThreadBindings<T>(
        _ body: (Set<AgentThreadID>) throws -> T
    ) rethrows -> T {
        try withSerializedOperation {
            try body(Set(liveAgentThreadBySurface.values))
        }
    }

    fileprivate func takeInjectedResultCodeForTesting() -> Int32? {
        guard !injectedResultCodesForTesting.isEmpty else { return nil }
        return injectedResultCodesForTesting.removeFirst()
    }

    fileprivate func withTransientLockRetry<T>(
        onRetry: (() -> Void)? = nil,
        _ operation: () throws -> T
    ) throws -> T {
        let maxAttempts = max(1, busyRetryMaxAttemptsForTesting ?? BusyRetryDefaults.maxAttempts)
        let maxSleep = busyRetryMaxSleepNanosecondsForTesting ?? BusyRetryDefaults.maxSleepNanoseconds
        var attempt = 0
        var slept: UInt64 = 0
        var sleepStep = BusyRetryDefaults.initialSleepNanoseconds
        transientLockAttemptCountForTesting = 0

        while true {
            transientLockAttemptCountForTesting += 1
            do {
                return try operation()
            } catch {
                let transient: Bool
                if let sqliteError = error as? SQLiteError {
                    transient = sqliteError.isTransientLockContention
                } else {
                    transient = false
                }
                attempt += 1
                let budgetLeft = slept < maxSleep
                guard transient, attempt < maxAttempts, budgetLeft else { throw error }

                onRetry?()

                let remaining = maxSleep - slept
                let delay = min(sleepStep, remaining, BusyRetryDefaults.maxSingleSleepNanoseconds)
                if delay > 0 {
                    // Short park only — total sleep is hard-capped by maxSleep.
                    Thread.sleep(forTimeInterval: TimeInterval(delay) / 1_000_000_000)
                    slept += delay
                }
                sleepStep = min(
                    sleepStep * 2,
                    BusyRetryDefaults.maxSingleSleepNanoseconds
                )
            }
        }
    }

    fileprivate func releaseReadSnapshotForRetry() {
        // Ending cached statement VMs drops any implicit WAL read snapshot so a
        // subsequent BEGIN IMMEDIATE is less likely to hit BUSY_SNAPSHOT again.
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            resetCachedStatements()
        } else {
            queue.sync { resetCachedStatements() }
        }
    }

    private func resetCachedStatements() {
        for statement in stmtCache.values {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }

    // Returns a cached-and-reset statement, or compiles a fresh one.
    // Caller is responsible for serialisation (either via `performSync` or a
    // single-writer context); see `prepare` for the thread-safety rationale.
    fileprivate func cachedStatement(sql: String) throws -> SQLiteStatement {
        // The cache hands out a SHARED sqlite3_stmt (owned: false). Sharing one
        // statement is only safe when the whole reset->bind->step sequence is
        // serialised -- i.e. when we are running ON `queue` (a `performSync`
        // caller). Off the queue (the bare `prepare()` repo call sites, reached
        // from the main/socket/coordinator threads -- QA-mac:72 T007) two threads
        // would share one handle and one thread's sqlite3_reset/clear_bindings
        // would wipe another's in-flight state, losing writes. So:
        //   - on the serial queue  -> use/grow the cache (fast, serialised, safe)
        //   - off the serial queue -> compile a FRESH OWNED statement per call.
        // SQLITE_OPEN_FULLMUTEX serialises every use of the shared connection, so
        // independent per-call statements prepare/bind/step/finalize safely from
        // many threads. This is the pre-cache concurrency contract the original
        // `prepare` actually provided (it compiled a fresh statement each call).
        let onSerialQueue = DispatchQueue.getSpecific(key: Self.queueKey) != nil
        if onSerialQueue {
            if let cached = stmtCache[sql] {
                // Reset: rewinds the VM + wipes bindings before each reuse.
                sqlite3_reset(cached)
                sqlite3_clear_bindings(cached)
                return SQLiteStatement(handle: cached, db: self, sql: sql, owned: false)
            }
            let stmt = try compileStatement(sql)
            stmtCache[sql] = stmt
            return SQLiteStatement(handle: stmt, db: self, sql: sql, owned: false)
        }
        return SQLiteStatement(handle: try compileStatement(sql), db: self, sql: sql, owned: true)
    }

    private func compileStatement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        return stmt!
    }

    public init(path: String, readonly: Bool = false) throws {
        self.path = path
        self.queue = DispatchQueue(
            label: readonly ? "RemoteCode.SQLiteDB.read" : "RemoteCode.SQLiteDB"
        )
        let dir = (path as NSString).deletingLastPathComponent
        if !readonly, !dir.isEmpty && path != ":memory:" {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        var h: OpaquePointer?
        // Readonly opens are used by Distill MCP / admission helpers so N codex
        // children do not each hold a writer against the 1GB+ app database.
        let flags = readonly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        if rc != SQLITE_OK {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(h)
            throw SQLiteError.open(msg)
        }
        self.handle = h
        queue.setSpecific(key: Self.queueKey, value: 1)
        if readonly {
            // Shared read path only — no WAL mutation, short busy wait.
            try execute("PRAGMA query_only=ON;")
            try execute("PRAGMA busy_timeout=1000;")
            return
        }
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA synchronous=NORMAL;")
        // Keep week-long processes from accumulating an ever-growing WAL. The
        // passive auto-checkpoint is reader-friendly; the size limit is applied
        // only after a successful reset/checkpoint and never truncates live data.
        try execute("PRAGMA wal_autocheckpoint=512;")
        try execute("PRAGMA journal_size_limit=16777216;")
        // WAL gives one writer + many readers across processes. Helper processes
        // and the app can open this same file concurrently, so a writer can briefly
        // hold the lock. Wait instead of failing fast with SQLITE_BUSY.
        try execute("PRAGMA busy_timeout=5000;")
    }

    deinit {
        ownedMaintenance?.cancel()
        // Finalise every cached statement before closing the connection.
        // sqlite3_close returns SQLITE_BUSY if any statement is still alive.
        for stmt in stmtCache.values { sqlite3_finalize(stmt) }
        stmtCache.removeAll()
        if let handle { sqlite3_close(handle) }
        onDeinitForTesting?()
    }

    public func execute(_ sql: String) throws {
        try measureCallerWaitIfOnMain {
            try withSerializedOperation {
                // Inside an open transaction, surface lock errors immediately so the
                // transaction owner can ROLLBACK and retry the whole unit.
                let run: () throws -> Void = { [self] in
                    if transactionDepth > 0 {
                        try executeDirect(sql)
                    } else {
                        try withTransientLockRetry(onRetry: { [self] in
                            releaseReadSnapshotForRetry()
                        }) {
                            try executeDirect(sql)
                        }
                    }
                }
                if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
                    try run()
                    return
                }
                try queue.sync { try run() }
            }
        }
    }

    private func executeDirect(_ sql: String) throws {
        beforeExecuteForTesting?(sql)
        if let injected = takeInjectedResultCodeForTesting(),
           injected != SQLITE_OK {
            if SQLiteError.isTransientLockCode(injected) {
                throw SQLiteError.execute("database is locked")
            }
            throw SQLiteError.execute("injected sqlite error (\(injected))")
        }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            if let err { sqlite3_free(err) }
            throw SQLiteError.execute(message)
        }
    }

    /// Receipt and event commits require power-loss durability. This database
    /// also stores the surrounding domain state, so SQLite durability is a
    /// connection-wide setting rather than a per-table setting.
    public func enableFullDurability() throws {
        try execute("PRAGMA synchronous=FULL;")
        try execute("PRAGMA fullfsync=ON;")
    }

    /// Retains one database-scoped background worker for exactly this
    /// connection's lifetime. Repeated installation attempts are harmless.
    @discardableResult
    func installOwnedMaintenance(_ maintenance: SQLiteDBOwnedMaintenance) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard ownedMaintenance == nil else { return false }
        ownedMaintenance = maintenance
        maintenanceInstallCountForTesting += 1
        return true
    }

    func releaseOwnedMaintenance(_ maintenance: SQLiteDBOwnedMaintenance) {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard ownedMaintenance === maintenance else { return }
        ownedMaintenance = nil
    }

    public func performSync<T>(_ block: (SQLiteDB) throws -> T) rethrows -> T {
        try measureCallerWaitIfOnMain {
            try withSerializedOperation {
                if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
                    return try block(self)
                }
                return try queue.sync {
                    // Early-returned SELECTs must not retain a WAL read snapshot after
                    // the serialized operation ends, including when the block throws.
                    defer { resetCachedStatements() }
                    return try block(self)
                }
            }
        }
    }

    /// PF-00 (c): the idle capture blocked on `NSRecursiveLock` (operationLock)
    /// before `queue.sync`. Measure the caller-thread wait, not just the inner hop.
    private func measureCallerWaitIfOnMain<T>(_ body: () throws -> T) rethrows -> T {
        let onMain = Thread.isMainThread && DispatchQueue.getSpecific(key: Self.queueKey) == nil
        guard onMain else { return try body() }
        return try PerfSwitchMetrics.measureQueueSync(onMainThread: true, body: body)
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
        try withSerializedOperation { try cachedStatement(sql: sql) }
    }

    public func transaction<T>(_ block: () throws -> T) throws -> T {
        try withSerializedOperation {
            // Retry the whole BEGIN…COMMIT unit only. Never re-enter a partially
            // applied multi-statement transaction: every failure ROLLBACKs first.
            try withTransientLockRetry(onRetry: { [self] in
                releaseReadSnapshotForRetry()
            }) {
                let eventRowCountBeforeTransaction = cachedEventRowCount
                transactionDepth += 1
                defer { transactionDepth -= 1 }
                try execute("BEGIN IMMEDIATE;")
                do {
                    let r = try block()
                    try execute("COMMIT;")
                    return r
                } catch {
                    try? execute("ROLLBACK;")
                    cachedEventRowCount = eventRowCountBeforeTransaction
                    throw error
                }
            }
        }
    }

    /// Consistent read snapshot that does **not** reserve the writer.
    ///
    /// Uses `BEGIN DEFERRED` so the first SELECT takes a shared read lock only.
    /// Writers (agent upserts, other repositories) can still acquire the reserved
    /// lock concurrently. Use `transaction` for any multi-statement write unit.
    public func readTransaction<T>(_ block: () throws -> T) throws -> T {
        try withSerializedOperation {
            try withTransientLockRetry(onRetry: { [self] in
                releaseReadSnapshotForRetry()
            }) {
                transactionDepth += 1
                defer { transactionDepth -= 1 }
                try execute("BEGIN DEFERRED;")
                do {
                    let r = try block()
                    try execute("COMMIT;")
                    return r
                } catch {
                    try? execute("ROLLBACK;")
                    throw error
                }
            }
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
    private let sql: String
    // When `owned` is false the handle belongs to the SQLiteDB statement cache
    // and must NOT be finalised here; the cache finalises it in SQLiteDB.deinit.
    private let owned: Bool

    init(handle: OpaquePointer, db: SQLiteDB, sql: String, owned: Bool = true) {
        self.handle = handle
        self.db = db
        self.sql = sql
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
        guard let db else { throw SQLiteError.step("database closed") }
        return try db.withSerializedOperation {
            let once: () throws -> Bool = { [self] in
                db.beforeStatementStepForTesting?(self.sql)
                if let injected = db.takeInjectedResultCodeForTesting() {
                    if injected == SQLITE_ROW { return true }
                    if injected == SQLITE_DONE { return false }
                    if SQLiteError.isTransientLockCode(injected) {
                        // Preserve bindings so a retry can re-step the same write.
                        sqlite3_reset(self.handle)
                        throw SQLiteError.step("database is locked")
                    }
                    throw SQLiteError.step("injected sqlite error (\(injected))")
                }
                let rc = sqlite3_step(self.handle)
                if rc == SQLITE_ROW { return true }
                if rc == SQLITE_DONE { return false }
                if SQLiteError.isTransientLockCode(rc) {
                    // Statement did not complete; reset for a safe re-step. Do not
                    // clear bindings — the caller's bind values must remain.
                    sqlite3_reset(self.handle)
                }
                throw SQLiteError.step(db.lastErrorMessage())
            }
            // Mid-transaction steps must not self-retry (partial apply risk).
            if db.transactionDepth > 0 {
                return try once()
            }
            return try db.withTransientLockRetry(onRetry: {
                db.releaseReadSnapshotForRetry()
            }, once)
        }
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
