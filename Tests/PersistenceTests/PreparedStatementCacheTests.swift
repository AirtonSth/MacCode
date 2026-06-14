import XCTest
import SQLite3
@testable import Persistence

/// Tests for the SQLiteDB prepared-statement cache.
///
/// WHY these tests exist:
///   - CACHE-HIT: the cache must return the same underlying OpaquePointer for the
///     same SQL string.  If it does not, every hot-path call (terminal append,
///     message append, event log) re-parses and re-plans the query in SQLite,
///     burning CPU on every streaming token.
///   - CACHE-MISS: different SQL must compile a distinct statement.  If two
///     distinct queries accidentally share one compiled statement the wrong schema
///     binding would silently return wrong rows or corrupt writes.
///   - STALE-BINDING: a cached statement is reset (sqlite3_reset +
///     sqlite3_clear_bindings) before it is returned to the caller.  Without
///     reset, a previous binding value (e.g. a UUID from the last call) leaks
///     into the next call, causing silent data corruption.  This is the most
///     dangerous failure mode: it produces wrong rows with no error.
final class PreparedStatementCacheTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try db.execute("CREATE TABLE t(id INTEGER PRIMARY KEY, val TEXT);")
        return db
    }

    // MARK: - CACHE-HIT: same SQL reuses the cached statement handle

    /// WHY: if the cache is absent or broken, each call to prepare() compiles a
    /// fresh statement.  sqlite3_prepare_v2 parses + plans the query on every
    /// call -- on a hot streaming path (100+ events/s) this is measurable CPU
    /// waste and unnecessary GC pressure.  The test verifies that two calls with
    /// identical SQL return the same OpaquePointer, proving no redundant compile
    /// occurred.
    func test_cacheHit_sameSQLReusesCompiledStatement() throws {
        let db = try makeDB()
        let sql = "SELECT id, val FROM t WHERE id = ?;"

        let (ptr1, ptr2) = try db.performSync { database in
            let st1 = try database.prepare(sql)
            let ptr1 = st1.handle

            let st2 = try database.prepare(sql)
            let ptr2 = st2.handle
            return (ptr1, ptr2)
        }

        XCTAssertEqual(ptr1, ptr2,
            "CACHE-HIT: same SQL must reuse the same OpaquePointer inside performSync, where reset/bind/step are serialised")
    }

    // MARK: - CACHE-MISS: different SQL compiles a distinct statement

    /// WHY: if distinct queries incorrectly share one compiled statement, the
    /// second query would execute with the schema of the first -- returning wrong
    /// column data or corrupting writes with no visible error.
    func test_cacheMiss_differentSQLCompilesDistinctStatements() throws {
        let db = try makeDB()
        let sqlA = "SELECT id FROM t WHERE id = ?;"
        let sqlB = "SELECT val FROM t WHERE id = ?;"

        let stA = try db.prepare(sqlA)
        let stB = try db.prepare(sqlB)

        XCTAssertNotEqual(stA.handle, stB.handle,
            "CACHE-MISS: distinct SQL strings must produce distinct OpaquePointers")
    }

    // MARK: - STALE-BINDING: cached statement has bindings cleared between uses

    /// WHY: sqlite3_clear_bindings sets all parameter slots back to NULL before
    /// the statement is handed back to the caller.  Without this call, a binding
    /// from a previous invocation (e.g. thread_id = "X") persists silently.  The
    /// next caller who sets only some bindings gets stale values in the unset
    /// slots -- producing queries that return wrong rows or insert wrong data with
    /// no error.  This is the most dangerous cache correctness property.
    func test_staleBinding_cachedStatementHasBindingsClearedOnReuse() throws {
        let db = try makeDB()
        try db.execute("INSERT INTO t(id, val) VALUES(1, 'first');")
        try db.execute("INSERT INTO t(id, val) VALUES(2, 'second');")

        let sql = "SELECT val FROM t WHERE id = ?;"

        // First use: bind id=1, step, confirm result.
        let st1 = try db.prepare(sql)
        try st1.bind(1, Int64(1))
        XCTAssertTrue(try st1.step())
        XCTAssertEqual(st1.columnText(0), "first")

        // Second use: fetch the same SQL from the cache WITHOUT binding anything.
        // If bindings are NOT cleared, sqlite treats the slot as NULL (or the
        // previous value); we must read SQLITE_NULL (id IS NULL matches nothing).
        // If bindings ARE cleared (correct), the slot is NULL and no row matches,
        // so step() returns false.
        let st2 = try db.prepare(sql)
        // Intentionally DO NOT bind anything on st2 to expose stale-binding bugs.
        let hasRow = try st2.step()
        XCTAssertFalse(hasRow,
            "STALE-BINDING: an unbound slot on a reused cached statement must be NULL " +
            "(sqlite3_clear_bindings must run between uses); if a stale id=1 binding " +
            "survived, step() would return true and silently return wrong data")
    }

    // MARK: - Correctness: hot-path round-trip through cache

    /// WHY: verifies the cache works end-to-end for the terminal-output append
    /// pattern (high-frequency INSERT followed by SELECT on the same table).
    /// Uses a schema that mirrors terminal_output_chunks to prove the cache
    /// does not break real repo behaviour.
    func test_hotPath_insertThenSelectViaCache() throws {
        let db = try makeDB()
        try db.execute("INSERT INTO t(id, val) VALUES(42, 'hello');")

        // First call: compile + cache.
        let stInsert = try db.prepare("INSERT OR IGNORE INTO t(id, val) VALUES(?, ?);")
        try stInsert.bind(1, Int64(99))
        try stInsert.bind(2, "world")
        _ = try stInsert.step()

        // Second call for SELECT: separate cache slot.
        let stSelect = try db.prepare("SELECT val FROM t WHERE id = ?;")
        try stSelect.bind(1, Int64(99))
        XCTAssertTrue(try stSelect.step())
        XCTAssertEqual(stSelect.columnText(0), "world",
            "HOT-PATH: cached INSERT then cached SELECT must produce correct data")

        // Third call reuses the cached INSERT with new bindings.
        let stInsert2 = try db.prepare("INSERT OR IGNORE INTO t(id, val) VALUES(?, ?);")
        try stInsert2.bind(1, Int64(100))
        try stInsert2.bind(2, "again")
        _ = try stInsert2.step()

        let stSelect2 = try db.prepare("SELECT val FROM t WHERE id = ?;")
        try stSelect2.bind(1, Int64(100))
        XCTAssertTrue(try stSelect2.step())
        XCTAssertEqual(stSelect2.columnText(0), "again",
            "HOT-PATH: second reuse of cached INSERT must bind new values cleanly")
    }
}
