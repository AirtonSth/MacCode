import XCTest
@testable import Persistence

/// P1 — Transactional, idempotent migrations.
///
/// WHY these tests matter: `Schema.migrateSteps` applies each SchemaStep's SQL
/// plus its `schema_meta` row. A multi-statement step (e.g. several ALTERs) that
/// fails on a later statement must NOT leave the DB half-migrated — otherwise a
/// partial ALTER bricks the store and the version counter lies. These tests
/// pin the all-or-nothing contract, the success-records-version contract, and
/// the re-run-is-a-no-op contract.
final class SchemaMigrationTransactionTests: XCTestCase {

    private func tableExists(_ db: SQLiteDB, _ name: String) throws -> Bool {
        let stmt = try db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;")
        defer { stmt.reset() }
        try stmt.bind(1, name)
        return try stmt.step()
    }

    private func maxVersion(_ db: SQLiteDB) throws -> Int {
        let stmt = try db.prepare("SELECT MAX(version) FROM schema_meta;")
        defer { stmt.reset() }
        guard try stmt.step(), !stmt.columnIsNull(0) else { return 0 }
        return Int(stmt.columnInt64(0))
    }

    // A failing step: a valid CREATE followed by syntactically-invalid SQL in the
    // SAME step. Pre-fix (no wrapping transaction) the CREATE lands but the
    // schema_meta row never does; post-fix BOTH are rolled back together.
    private let goodStep = SchemaStep(1, "CREATE TABLE good_one (id INTEGER PRIMARY KEY);")
    private let failingStep = SchemaStep(2, """
        CREATE TABLE partial_two (id INTEGER PRIMARY KEY);
        THIS IS NOT VALID SQL;
        """)

    func test_failingStep_rollsBackSchemaAndMeta() throws {
        let db = try SQLiteDB(path: ":memory:")

        XCTAssertThrowsError(try Schema.migrateSteps(db, [goodStep, failingStep])) { _ in }

        // Prior good step committed and recorded.
        XCTAssertTrue(try tableExists(db, "good_one"),
                      "the step that fully succeeded must remain applied")
        // The failing step is fully rolled back: neither its table...
        XCTAssertFalse(try tableExists(db, "partial_two"),
                       "a step that throws mid-way must leave NO partial table — its transaction rolled back")
        // ...nor its schema_meta version may survive.
        XCTAssertEqual(try maxVersion(db), 1,
                       "schema_meta must not record a step whose SQL did not fully apply")
    }

    func test_successfulRun_appliesAndRecordsEachStep() throws {
        let db = try SQLiteDB(path: ":memory:")
        let second = SchemaStep(2, "CREATE TABLE good_two (id INTEGER PRIMARY KEY);")

        try Schema.migrateSteps(db, [goodStep, second])

        XCTAssertTrue(try tableExists(db, "good_one"))
        XCTAssertTrue(try tableExists(db, "good_two"))
        XCTAssertEqual(try maxVersion(db), 2, "every applied step records its version")
    }

    func test_rerun_isNoOp() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, [goodStep])
        let firstApplied = try maxVersion(db)

        // Re-running the same steps must not re-execute SQL (a second CREATE
        // without IF NOT EXISTS would throw) nor change recorded state.
        XCTAssertNoThrow(try Schema.migrateSteps(db, [goodStep]),
                         "already-applied steps are skipped, so re-run does not re-run their SQL")
        XCTAssertEqual(try maxVersion(db), firstApplied,
                       "re-running records no new versions")
    }

    func test_realMigrate_appliesFullSchema() throws {
        // Guards the production delegation: Schema.migrate(db) must still apply
        // the real step list end-to-end and reach currentVersion.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "full migration reaches the declared current version")
    }
}
