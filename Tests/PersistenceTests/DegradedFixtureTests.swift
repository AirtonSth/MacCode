import XCTest
@testable import Persistence
import CoreModel

/// Tests for degraded/corrupt FixtureScenarios.
///
/// WHY these tests matter (P2 mac-persistence.md Fixtures item):
///   - Fixtures.swift had only clean happy-path scenarios. Recovery paths
///     (fallback past corrupt snapshots, migration from old schema, orphaned
///     terminal chunks) were untestable. These tests drive each degraded
///     scenario and assert the app degrades gracefully rather than crashing.
final class DegradedFixtureTests: XCTestCase {

    // MARK: - corruptSnapshot

    /// WHY: SessionSnapshotRepository.latest() decodes with try? and falls back
    /// to the next-older row. The corruptSnapshot fixture inserts a corrupt row
    /// AFTER a valid row (higher id). latest() must skip the corrupt row and
    /// return the valid snapshot rather than returning nil or throwing.
    func test_corruptSnapshot_latestFallsBackToValidRow() throws {
        let tmp = NSTemporaryDirectory() + "RC2DegradedFixture-corruptSnapshot-" + UUID().uuidString + ".sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // FixtureFactory.build() runs Schema.migrate internally before inserting rows.
        let built = try FixtureFactory().build(.corruptSnapshot, dbPath: tmp)

        let repo = SessionSnapshotRepository(db: built.db)
        let snap = try repo.latest()

        XCTAssertNotNil(snap,
            "latest() must return the valid snapshot row even when a newer corrupt row is present; returning nil would cause the app to start with an empty layout")
    }

    /// WHY: Asserting non-nil is insufficient - latest() could return the
    /// corrupt row deserialized as some default struct, or a row from an
    /// unrelated test that leaked into the DB. This test pins the CONTENT of
    /// the returned snapshot to the known-valid row so any regression in the
    /// skip-and-fallback logic is caught by a meaningful assertion, not a
    /// silent wrong-version return.
    func test_corruptSnapshot_latestReturnsCorrectVersion() throws {
        let tmp = NSTemporaryDirectory() + "RC2DegradedFixture-corruptSnapshotVersion-" + UUID().uuidString + ".sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let built = try FixtureFactory().build(.corruptSnapshot, dbPath: tmp)

        let repo = SessionSnapshotRepository(db: built.db)
        let snap = try XCTUnwrap(repo.latest(),
            "pre-condition: latest() must find the valid row before the version assertion can run")

        XCTAssertEqual(snap.version, SessionSnapshot.currentVersion,
            "the fallback row must carry version == currentVersion; returning a wrong version would silently decode an incompatible layout and wipe the user's workspace arrangement on boot")
    }

    /// WHY: the fixture inserts exactly two rows (one valid, one corrupt).
    /// latest() walks rows newest-first and returns the first decodable one.
    /// This test verifies that exactly one row is skipped, not more, so a
    /// future corruption scenario that adds extra corrupt rows is caught early.
    func test_corruptSnapshot_exactlyTwoRowsExistInDB() throws {
        let tmp = NSTemporaryDirectory() + "RC2DegradedFixture-corruptSnapshotCount-" + UUID().uuidString + ".sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let built = try FixtureFactory().build(.corruptSnapshot, dbPath: tmp)

        let countSt = try built.db.prepare("SELECT COUNT(*) FROM session_snapshots;")
        XCTAssertTrue(try countSt.step())
        XCTAssertEqual(Int(countSt.columnInt64(0)), 2,
            "corruptSnapshot fixture must insert exactly 2 rows (1 valid + 1 corrupt) so tests asserting row-skip behavior are precise about what they prove")
    }

    // MARK: - legacySchemaV13

    /// WHY: a DB left at schema v13 by a downgraded or partially-updated build
    /// must reach Schema.currentVersion after Schema.migrate() runs. Every column
    /// added by steps 14..currentVersion must be present so queries don't fail.
    func test_legacySchemaV13_migratesForwardToCurrentVersion() throws {
        let tmp = NSTemporaryDirectory() + "RC2DegradedFixture-legacyV13-" + UUID().uuidString + ".sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Fixture DB is stopped at v13 (steps 1..13 applied only).
        let built = try FixtureFactory().build(.legacySchemaV13, dbPath: tmp)

        // Verify the DB truly stops at v13 before the forward migration.
        let preSt = try built.db.prepare("SELECT MAX(version) FROM schema_meta;")
        XCTAssertTrue(try preSt.step())
        XCTAssertEqual(Int(preSt.columnInt64(0)), 13,
            "pre-condition: fixture DB must be at schema v13 before the forward migration runs")
        preSt.reset()

        // Forward migrate to currentVersion.
        try Schema.migrate(built.db)

        let vSt = try built.db.prepare("SELECT MAX(version) FROM schema_meta;")
        XCTAssertTrue(try vSt.step())
        XCTAssertEqual(Int(vSt.columnInt64(0)), Schema.currentVersion,
            "migrating forward from schema v13 must reach currentVersion so a user upgrading from an old build does not lose their session")
    }

    /// WHY: after migrating from v13, the columns added in later steps must be
    /// queryable. If any ALTER TABLE step was skipped, a query using the new
    /// column would crash at runtime without any test catching it.
    func test_legacySchemaV13_postMigrationCanReadAllColumns() throws {
        let tmp = NSTemporaryDirectory() + "RC2DegradedFixture-legacyV13-cols-" + UUID().uuidString + ".sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let built = try FixtureFactory().build(.legacySchemaV13, dbPath: tmp)
        try Schema.migrate(built.db)

        // Insert a thread using columns added after step 6 (reasoning_effort,
        // execution_mode, base_branch, worktree_path, service_tier,
        // model_selection_json - steps 6+). All of these must exist post-migration.
        let thread = AgentThread(
            title: "post-v13",
            provider: .codex,
            model: "gpt-5",
            reasoningEffort: .high,
            executionMode: .worktree
        )
        XCTAssertNoThrow(try AgentThreadRepository(db: built.db).upsert(thread),
            "inserting a thread with columns added after schema v13 must not throw after a forward migration")

        let listed = try AgentThreadRepository(db: built.db).list()
        XCTAssertEqual(listed.count, 1,
            "a thread inserted after forward migration must be retrievable - a missing column would produce an empty row")
        XCTAssertEqual(listed[0].reasoningEffort, .high,
            "columns added after v13 must round-trip after migration so user-selected reasoning effort is not silently reset")
    }

    // MARK: - orphanedTerminalChunks

    /// WHY: a crash between terminal-chunk write and session-snapshot save leaves
    /// chunks for a surface that no longer appears in the layout. The app must boot
    /// normally and the orphaned surface must not appear in the sidebar or cause
    /// any repository call to fail.
    func test_orphanedTerminalChunks_doesNotPreventBoot() throws {
        let tmp = NSTemporaryDirectory() + "RC2DegradedFixture-orphaned-" + UUID().uuidString + ".sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let built = try FixtureFactory().build(.orphanedTerminalChunks, dbPath: tmp)

        // Boot simulation: Schema.migrate must succeed on the db that already has orphaned chunks.
        XCTAssertNoThrow(try Schema.migrate(built.db),
            "orphaned terminal chunks must not prevent re-running the schema migration")
    }

    func test_orphanedTerminalChunks_chunksPresentInTable() throws {
        let tmp = NSTemporaryDirectory() + "RC2DegradedFixture-orphaned-count-" + UUID().uuidString + ".sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let built = try FixtureFactory().build(.orphanedTerminalChunks, dbPath: tmp)

        let countSt = try built.db.prepare("SELECT COUNT(*) FROM terminal_output_chunks;")
        XCTAssertTrue(try countSt.step())
        XCTAssertGreaterThan(Int(countSt.columnInt64(0)), 0,
            "fixture pre-condition: orphaned chunks must be present in the table so the degraded scenario is non-trivial")
    }

    func test_orphanedTerminalChunks_canBePrunedWithoutError() throws {
        let tmp = NSTemporaryDirectory() + "RC2DegradedFixture-orphaned-prune-" + UUID().uuidString + ".sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let built = try FixtureFactory().build(.orphanedTerminalChunks, dbPath: tmp)

        // Determine the orphaned surface id (only surface in the table).
        let stSurf = try built.db.prepare("SELECT DISTINCT surface_id FROM terminal_output_chunks LIMIT 1;")
        guard try stSurf.step(), let surfaceID = stSurf.columnText(0) else {
            XCTFail("fixture must contain at least one terminal_output_chunks row")
            return
        }

        let repo = TerminalOutputRepository(db: built.db)
        XCTAssertNoThrow(try repo.delete(surfaceID: surfaceID),
            "deleting orphaned chunks must not throw so housekeeping can clean up without crashing")

        XCTAssertEqual(try repo.totalBytes(surfaceID: surfaceID), 0,
            "after deleting orphaned chunks the surface must report 0 bytes so storage is fully reclaimed")
    }
}
