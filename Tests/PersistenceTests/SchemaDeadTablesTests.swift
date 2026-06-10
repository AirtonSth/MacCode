import XCTest
@testable import Persistence

/// Documents the set of schema tables that are currently unused / dead.
/// These tests exist to:
///   1. Assert the documented dead-table set is exact (no silent additions or removals).
///   2. Guard that running all migrations still reaches Schema.currentVersion,
///      proving the dead tables' DDL does not break the migration chain.
final class SchemaDeadTablesTests: XCTestCase {

    // MARK: - Dead-table set

    /// The documented dead set must be exactly these three tables.
    /// Fails if a table is silently added to or removed from the set,
    /// which would indicate an undocumented schema change.
    func testKnownDeadTableNamesIsExact() {
        let expected: Set<String> = [
            "workspace_selection",
            "terminal_sessions",
            "browser_profiles"
        ]
        XCTAssertEqual(
            Schema.knownDeadTableNames(),
            expected,
            "Dead-table set changed. Update docs and this test together."
        )
    }

    // MARK: - Migration guard

    /// Migrations applied to an in-memory DB must reach currentVersion.
    /// Verifies that the dead-table DDL (step 1) does not block the chain.
    func testMigrateReachesCurrentVersion() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)

        let stmt = try db.prepare("SELECT MAX(version) FROM schema_meta;")
        defer { stmt.reset() }
        var applied: Int = 0
        if try stmt.step(), !stmt.columnIsNull(0) {
            applied = Int(stmt.columnInt64(0))
        }
        XCTAssertEqual(
            applied,
            Schema.currentVersion,
            "migrate() did not reach currentVersion \(Schema.currentVersion); got \(applied)."
        )
    }

    // MARK: - Dead tables are physically present

    /// Each dead table must exist in the DB after migration (they are retained,
    /// not dropped). This test would catch an accidental destructive migration.
    func testDeadTablesExistAfterMigration() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)

        for tableName in Schema.knownDeadTableNames().sorted() {
            let stmt = try db.prepare(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?;"
            )
            defer { stmt.reset() }
            try stmt.bind(1, tableName)
            var count: Int = 0
            if try stmt.step() { count = Int(stmt.columnInt64(0)) }
            XCTAssertEqual(
                count, 1,
                "Dead table '\(tableName)' is missing from DB — it may have been accidentally dropped."
            )
        }
    }
}
