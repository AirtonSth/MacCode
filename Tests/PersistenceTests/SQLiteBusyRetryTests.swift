import XCTest
@testable import Persistence
import SQLite3

/// Transient SQLITE_BUSY / SQLITE_LOCKED must not fail an agent-facing write.
///
/// WHY: a brief cross-connection or hot-row lock used to surface as
/// `sqlite execute: database is locked` and mark the whole agent run failed.
/// `PRAGMA busy_timeout` alone is not enough (BUSY_SNAPSHOT and some upgrade
/// paths return immediately). These tests pin the application-level bounded
/// retry at the write layer.
final class SQLiteBusyRetryTests: XCTestCase {

    /// SQLITE_BUSY_SNAPSHOT — extended busy that bypasses busy_timeout.
    private let busySnapshot: Int32 = SQLITE_BUSY | (2 << 8)
    /// SQLITE_IOERR — genuinely non-transient; must not be retried.
    private let ioError: Int32 = 10

    private func makeDB() throws -> SQLiteDB {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2BusyRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: dir.appendingPathComponent("busy.sqlite").path)
        try db.execute("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT NOT NULL);")
        // Keep injected-path tests fast; production still uses the 5s pragma.
        db.busyRetryMaxSleepNanosecondsForTesting = 50_000_000
        return db
    }

    // WHY: a single SQLITE_BUSY on a write must recover via retry instead of
    // throwing and failing the surrounding agent run.
    func test_writeThatHitsBusyOnce_succeedsAfterRetry() throws {
        let db = try makeDB()
        db.injectedResultCodesForTesting = [SQLITE_BUSY]
        db.busyRetryMaxAttemptsForTesting = 5

        try db.execute("INSERT INTO t(id, v) VALUES (1, 'ok');")

        XCTAssertEqual(
            db.transientLockAttemptCountForTesting, 2,
            "one injected BUSY plus one successful attempt — without retry the write would throw"
        )
        let stmt = try db.prepare("SELECT v FROM t WHERE id = 1;")
        XCTAssertTrue(try stmt.step())
        XCTAssertEqual(stmt.columnText(0), "ok")
    }

    // WHY: BUSY_SNAPSHOT (rc 517) is the busy form busy_timeout does not wait
    // for; the same write-layer retry must absorb it.
    func test_writeThatHitsBusySnapshotOnce_succeedsAfterRetry() throws {
        let db = try makeDB()
        db.injectedResultCodesForTesting = [busySnapshot]
        db.busyRetryMaxAttemptsForTesting = 5

        try db.execute("INSERT INTO t(id, v) VALUES (2, 'snapshot');")

        XCTAssertEqual(db.transientLockAttemptCountForTesting, 2)
        let stmt = try db.prepare("SELECT v FROM t WHERE id = 2;")
        XCTAssertTrue(try stmt.step())
        XCTAssertEqual(stmt.columnText(0), "snapshot")
    }

    // WHY: a multi-statement unit must restart from BEGIN after ROLLBACK, not
    // re-step a single mid-transaction statement (double-apply risk).
    func test_transactionThatHitsBusyOnBegin_retriesWholeUnit() throws {
        let db = try makeDB()
        // First BEGIN IMMEDIATE sees BUSY; retry restarts the whole unit.
        db.injectedResultCodesForTesting = [SQLITE_BUSY]
        db.busyRetryMaxAttemptsForTesting = 5

        try db.transaction {
            try db.execute("INSERT INTO t(id, v) VALUES (3, 'txn');")
            try db.execute("INSERT INTO t(id, v) VALUES (4, 'txn2');")
        }

        XCTAssertGreaterThanOrEqual(
            db.transientLockAttemptCountForTesting, 2,
            "transaction-level retry must re-enter the BEGIN…COMMIT body after BUSY"
        )
        let count = try db.prepare("SELECT COUNT(*) FROM t WHERE v LIKE 'txn%';")
        XCTAssertTrue(try count.step())
        XCTAssertEqual(count.columnInt64(0), 2, "both inserts commit exactly once after a clean retry")
    }

    // WHY: exhausted retry must still surface a clear error — never loop forever
    // and never pretend the write succeeded.
    func test_permanentlyBusyWrite_throwsClearErrorAfterBound() throws {
        let db = try makeDB()
        db.busyRetryMaxAttemptsForTesting = 3
        db.busyRetryMaxSleepNanosecondsForTesting = 20_000_000
        // Exactly maxAttempts BUSYs so the write exhausts the bound and no
        // leftover injects poison the post-assert verification read.
        db.injectedResultCodesForTesting = Array(repeating: SQLITE_BUSY, count: 3)

        let start = Date()
        XCTAssertThrowsError(try db.execute("INSERT INTO t(id, v) VALUES (5, 'nope');")) { error in
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("database is locked"),
                "exhausted retry must still report the lock error clearly, got: \(message)"
            )
            if let sqliteError = error as? SQLiteError {
                XCTAssertTrue(sqliteError.isTransientLockContention)
            } else {
                XCTFail("expected SQLiteError, got \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(
            db.transientLockAttemptCountForTesting, 3,
            "must stop at the configured attempt bound (no infinite loop)"
        )
        XCTAssertTrue(
            db.injectedResultCodesForTesting.isEmpty,
            "all injected BUSYs must have been consumed by the bounded retry"
        )
        XCTAssertLessThan(elapsed, 2.0, "bounded sleep budget must not block indefinitely")

        let stmt = try db.prepare("SELECT COUNT(*) FROM t WHERE id = 5;")
        XCTAssertTrue(try stmt.step())
        XCTAssertEqual(stmt.columnInt64(0), 0, "a permanently locked write must not silently succeed")
    }

    // WHY: constraint / I/O failures are not lock contention; retrying them
    // delays real errors and can mask bugs.
    func test_nonTransientSQLiteError_isNotRetried() throws {
        let db = try makeDB()
        try db.execute("INSERT INTO t(id, v) VALUES (6, 'first');")

        // Real UNIQUE constraint failure (not injection): must fail on first attempt.
        db.busyRetryMaxAttemptsForTesting = 8
        XCTAssertThrowsError(try db.execute("INSERT INTO t(id, v) VALUES (6, 'dup');")) { error in
            let message = String(describing: error).lowercased()
            XCTAssertTrue(
                message.contains("unique") || message.contains("constraint"),
                "non-transient error must propagate unchanged, got: \(error)"
            )
        }
        XCTAssertEqual(
            db.transientLockAttemptCountForTesting, 1,
            "a UNIQUE constraint failure must not enter the busy-retry loop more than once"
        )

        // Injected I/O error: same no-retry contract via the write path.
        db.injectedResultCodesForTesting = [ioError]
        XCTAssertThrowsError(try db.execute("INSERT INTO t(id, v) VALUES (7, 'io');")) { error in
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("injected sqlite error"),
                "non-transient injected error must surface as-is, got: \(message)"
            )
            if let sqliteError = error as? SQLiteError {
                XCTAssertFalse(
                    sqliteError.isTransientLockContention,
                    "I/O errors must not be classified as transient lock contention"
                )
            }
        }
        XCTAssertEqual(db.transientLockAttemptCountForTesting, 1)
    }

    // WHY: prepare/bind/step writers (common in repositories) share the same
    // step-level retry; one BUSY on step must not fail the write.
    func test_stepWriteThatHitsBusyOnce_succeedsAfterRetry() throws {
        let db = try makeDB()
        let stmt = try db.prepare("INSERT INTO t(id, v) VALUES (?, ?);")
        try stmt.bind(1, 8)
        try stmt.bind(2, "step-ok")
        db.injectedResultCodesForTesting = [SQLITE_BUSY]
        db.busyRetryMaxAttemptsForTesting = 5

        XCTAssertFalse(try stmt.step())
        XCTAssertEqual(db.transientLockAttemptCountForTesting, 2)

        let read = try db.prepare("SELECT v FROM t WHERE id = 8;")
        XCTAssertTrue(try read.step())
        XCTAssertEqual(read.columnText(0), "step-ok")
    }
}
