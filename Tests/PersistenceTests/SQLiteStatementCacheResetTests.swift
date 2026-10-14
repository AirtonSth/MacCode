import XCTest
@testable import Persistence

/// The end of every off-queue `performSync` used to reset and clear the
/// bindings of every statement the connection had ever cached. That cache is
/// never evicted, so each DB call (the main thread included) paid for all SQL
/// seen since launch.
final class SQLiteStatementCacheResetTests: XCTestCase {
    private func makeFileDB() throws -> (SQLiteDB, String) {
        let directory = NSTemporaryDirectory() + "rc-stmt-cache-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/cache.sqlite"
        return (try SQLiteDB(path: path), path)
    }

    func test_performSyncResetsOnlyTheStatementsItUsed_becauseTheCacheGrowsForTheAppsLifetime() throws {
        let (db, _) = try makeFileDB()
        for index in 0..<300 {
            try db.performSync { db in
                let statement = try db.prepare("SELECT \(index);")
                _ = try statement.step()
            }
        }
        let before = db.cachedStatementResetCountForTesting

        try db.performSync { db in
            let statement = try db.prepare("SELECT 1;")
            _ = try statement.step()
        }

        XCTAssertEqual(db.cachedStatementResetCountForTesting - before, 1,
                       "one statement used, one statement reset, however many are cached")
    }

    func test_earlyReturnedSelectStillReleasesItsReadSnapshot_becauseAHeldSnapshotBlocksCheckpoints() throws {
        // WHY: the end-of-operation reset exists so a SELECT left mid-iteration
        // does not pin the WAL; resetting fewer statements must keep that.
        let (db, path) = try makeFileDB()
        try db.execute("CREATE TABLE t(x INTEGER);")
        try db.execute("INSERT INTO t(x) VALUES (1), (2), (3);")
        let first: Int64 = try db.performSync { db in
            let statement = try db.prepare("SELECT x FROM t ORDER BY x;")
            _ = try statement.step()
            return statement.columnInt64(0) // returns with two rows unread
        }
        XCTAssertEqual(first, 1)

        let other = try SQLiteDB(path: path)
        try other.execute("INSERT INTO t(x) VALUES (4);")
        let checkpoint = try other.prepare("PRAGMA wal_checkpoint(TRUNCATE);")
        XCTAssertTrue(try checkpoint.step())
        XCTAssertEqual(checkpoint.columnInt64(0), 0, "a reader still holding a snapshot makes TRUNCATE busy")
    }
}
