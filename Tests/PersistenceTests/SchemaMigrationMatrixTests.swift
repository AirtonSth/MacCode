import XCTest
@testable import Persistence
import CoreModel

/// P1 — Migration-path matrix: historical -> head.
///
/// WHY: `SchemaMigrationTransactionTests` covers transaction semantics (rollback,
/// re-run) but starts from an empty DB. The real migration risk is a partially-
/// deployed schema: a user on v13 who upgrades to head must get all intermediate
/// steps applied without data loss.  A missing ALTER or a step that fails mid-way
/// bricks the user's DB silently.
///
/// Strategy: `replay steps.prefix(n)` — apply the first n SchemaSteps to build
/// an "old version" DB in memory, seed representative data that those steps would
/// have created, then apply the remaining steps to head and assert:
///   1. `Schema.currentVersion` is reached (all steps applied).
///   2. Data seeded at the old version survives (no silent DROP/TRUNCATE).
///   3. New columns added after the old version are present and readable.
///
/// Key versions exercised (anchor points where new tables / non-trivial ALTERs land):
///   v1  — baseline (all core tables)
///   v2  — device_trust / audit_log / pairing_codes / notifications added
///   v13 — agent_turn_checkpoints added (checkpoint feature birth)
///   v25 — token_saver_savings added
///   v27 — rc_reversible_content added (CCR store)
///   v30 — token_saver_encoder_manifests added
///   v31 — shared_memory_blocks added
///   head — current  [identity: migrate from head is a no-op]
///
/// Each test follows the pattern:
///   1. Build old-version DB in memory via `Schema.migrateSteps(db, steps.prefix(n))`.
///   2. Seed a row in a table that existed at version n.
///   3. Migrate to head via `Schema.migrateSteps(db, steps)` (idempotent: already-applied steps skip).
///   4. Assert `maxVersion == currentVersion`.
///   5. Assert the seeded row survives and is readable.
final class SchemaMigrationMatrixTests: XCTestCase {

    // MARK: - Helpers

    private func maxVersion(_ db: SQLiteDB) throws -> Int {
        let st = try db.prepare("SELECT MAX(version) FROM schema_meta;")
        defer { st.reset() }
        guard try st.step(), !st.columnIsNull(0) else { return 0 }
        return Int(st.columnInt64(0))
    }

    private func rowCount(_ db: SQLiteDB, table: String) throws -> Int {
        let st = try db.prepare("SELECT COUNT(*) FROM \(table);")
        defer { st.reset() }
        guard try st.step() else { return 0 }
        return Int(st.columnInt64(0))
    }

    /// Build a DB that looks like "the app was at version n" by applying only the
    /// first n steps, then migrate to head and return the DB.
    private func migrateFromVersion(n: Int) throws -> SQLiteDB {
        let steps = Schema.steps
        let oldSteps = Array(steps.prefix(n))
        let db = try SQLiteDB(path: ":memory:")
        // Build the old-version schema.
        try Schema.migrateSteps(db, oldSteps)
        return db
    }

    // MARK: - v1 → head

    /// WHY: v1 is the absolute baseline — every schema above it builds on v1's
    /// core tables (agent_threads, agent_messages, agent_runs, events).  Any
    /// ALTER that collides with a v1 column name, or any step that drops a v1
    /// table, would corrupt a user who installed v1 at launch and upgraded later.
    func test_v1_to_head_dataAndVersionSurvive() throws {
        let steps = Schema.steps
        let db = try migrateFromVersion(n: 1)

        // Seed a project row (created in v1).
        try db.execute("""
            INSERT INTO projects (id, name, path, created_at, updated_at)
            VALUES ('proj-v1', 'My Project', '/home/user/proj', '2024-01-01T00:00:00Z', '2024-01-01T00:00:00Z');
        """)
        XCTAssertEqual(try rowCount(db, table: "projects"), 1,
                       "precondition: v1 project row must be seeded before migrating to head")

        // Migrate to head.
        try Schema.migrateSteps(db, steps)

        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "migrating from v1 to head must reach currentVersion — " +
                       "any missing step leaves a user on an older schema than they expect")
        XCTAssertEqual(try rowCount(db, table: "projects"), 1,
                       "the v1 project row must survive migration to head — " +
                       "a destructive migration step silently destroys user data")
    }

    // MARK: - v2 → head

    /// WHY: v2 adds device_trust and audit_log (pairing / security tables). A user
    /// who paired a device at v2 and upgrades must keep their paired device; a
    /// migration that drops device_trust would silently de-pair all iOS clients.
    func test_v2_to_head_pairedDeviceAndAuditRowSurvive() throws {
        let steps = Schema.steps
        let db = try migrateFromVersion(n: 2)

        // Seed a device_trust row and an audit_log row (both created in v2).
        try db.execute("""
            INSERT INTO device_trust (id, display_name, token_hash, created_at, capabilities)
            VALUES ('dev-v2', 'iPhone at v2', 'hash-abc', '2024-06-01T00:00:00Z', '*');
        """)
        try db.execute("""
            INSERT INTO audit_log (ts, actor, action, detail)
            VALUES ('2024-06-01T00:00:00Z', 'device', 'pairing.request', 'iPhone at v2');
        """)

        try Schema.migrateSteps(db, steps)

        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "migrating from v2 to head must reach currentVersion")
        XCTAssertEqual(try rowCount(db, table: "device_trust"), 1,
                       "a v2 paired device must survive migration to head — " +
                       "losing device_trust rows silently de-pairs all iOS clients")
        XCTAssertEqual(try rowCount(db, table: "audit_log"), 1,
                       "a v2 audit_log row must survive migration to head — " +
                       "losing audit history breaks compliance and post-incident review")
        let st = try db.prepare("SELECT client_device_id, always_allow_pairing FROM device_trust WHERE id = 'dev-v2';")
        defer { st.reset() }
        XCTAssertTrue(try st.step(),
                      "v29 must add permanent trust columns to surviving v2 device_trust rows")
        XCTAssertTrue(st.columnIsNull(0),
                      "old paired devices have no pre-token client_device_id and must migrate as nil, not a fabricated id")
        XCTAssertEqual(st.columnInt64(1), 0,
                       "old paired devices must not silently become Always Allow during migration")
    }

    // MARK: - v13 → head

    /// WHY: v13 introduces agent_turn_checkpoints (the checkpoint feature). Users who
    /// enabled checkpoints at v13 have checkpoint rows; any migration that alters the
    /// PRIMARY KEY or drops the table would corrupt their undo history.
    func test_v13_to_head_checkpointRowSurvives() throws {
        let steps = Schema.steps
        let db = try migrateFromVersion(n: 13)

        // Seed an agent_threads row (needed for FK in agent_turn_checkpoints).
        try db.execute("""
            INSERT INTO agent_threads
                (id, title, provider, model, status, created_at, updated_at)
            VALUES
                ('th-v13', 'Thread at v13', 'claude', 'claude-3', 'idle',
                 '2024-06-01T00:00:00Z', '2024-06-01T00:00:00Z');
        """)
        // Seed an agent_runs row (needed for FK in agent_turn_checkpoints).
        try db.execute("""
            INSERT INTO agent_runs (id, thread_id, provider, model, status, started_at)
            VALUES ('run-v13', 'th-v13', 'claude', 'claude-3', 'idle', '2024-06-01T00:00:00Z');
        """)
        // Seed a checkpoint row (created in v13).
        try db.execute("""
            INSERT INTO agent_turn_checkpoints
                (thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref,
                 status, files_json, completed_at, created_at)
            VALUES
                ('th-v13', 'run-v13', 'turn-v13', 1, 'ref-abc',
                 'done', '[]', '2024-06-01T00:00:00Z', '2024-06-01T00:00:00Z');
        """)

        try Schema.migrateSteps(db, steps)

        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "migrating from v13 to head must reach currentVersion")
        XCTAssertEqual(try rowCount(db, table: "agent_turn_checkpoints"), 1,
                       "a v13 checkpoint row must survive migration to head — " +
                       "destroying checkpoints removes the user's ability to undo agent actions")

        // Steps 14 and 15 ADD columns to agent_turn_checkpoints; verify those columns exist.
        let st = try db.prepare("SELECT file_snapshots_json, diff_patch, file_diffs_json FROM agent_turn_checkpoints LIMIT 1;")
        defer { st.reset() }
        XCTAssertTrue(try st.step(),
                      "columns added in v14/v15 (file_snapshots_json, diff_patch, file_diffs_json) " +
                      "must exist after migrating from v13 to head")
    }

    // MARK: - v25 → head

    /// WHY: v25 introduces token_saver_savings. Users who accumulated savings data at
    /// v25 expect to see their historical Token Saver statistics after upgrading. A
    /// migration that drops the table erases all historical compression metrics.
    func test_v25_to_head_tokenSaverSavingsRowSurvives() throws {
        let steps = Schema.steps
        let db = try migrateFromVersion(n: 25)

        try db.execute("""
            INSERT INTO token_saver_savings
                (provider, mode, input_tokens, output_tokens, saved_tokens, created_at, created_at_ms)
            VALUES
                ('claude', 'fill', 1000, 200, 300, '2024-06-01T00:00:00Z', 1717200000000);
        """)

        try Schema.migrateSteps(db, steps)

        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "migrating from v25 to head must reach currentVersion")
        XCTAssertEqual(try rowCount(db, table: "token_saver_savings"), 1,
                       "a v25 token_saver_savings row must survive migration to head — " +
                       "losing it erases the user's historical compression metrics")

        // v28 adds content_type, engine, cache_state columns; verify they exist and have defaults.
        let st = try db.prepare("SELECT content_type, engine, cache_state FROM token_saver_savings LIMIT 1;")
        defer { st.reset() }
        XCTAssertTrue(try st.step(),
                      "columns added in v28 (content_type, engine, cache_state) must exist " +
                      "after migrating from v25 and must be readable on the surviving v25 row")
    }

    // MARK: - v27 → head

    /// WHY: v27 introduces rc_reversible_content (CCR store). Users who stored
    /// compressed blocks at v27 expect those blocks to remain retrievable after
    /// upgrading; a migration that drops the table destroys the recovery path for
    /// every compressed message in the user's history.
    func test_v27_to_head_ccrRowSurvives() throws {
        let steps = Schema.steps
        let db = try migrateFromVersion(n: 27)

        try db.execute("""
            INSERT INTO rc_reversible_content
                (handle, original, sha256, byte_count, ref_count, created_at_ms, last_access_ms)
            VALUES
                ('deadbeef', X'48656C6C6F', 'deadbeef', 5, 0, 1717200000000, 1717200000000);
        """)

        try Schema.migrateSteps(db, steps)

        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "migrating from v27 to head must reach currentVersion")
        XCTAssertEqual(try rowCount(db, table: "rc_reversible_content"), 1,
                       "a v27 CCR block must survive migration to head — " +
                       "losing it destroys the recovery path for every compressed message referencing that handle")
    }

    // MARK: - v30 → head

    /// WHY: F8 pins encoder manifest storage to its own schema bump. A later
    /// migration must not collide with or recreate that table because the
    /// manifest is the hard license/runtime gate for optional encoder lanes.
    func test_v30_to_head_encoderManifestSurvives() throws {
        let steps = Schema.steps
        let db = try migrateFromVersion(n: 30)

        try db.execute("""
            INSERT INTO token_saver_encoder_manifests
                (role, model_id, source_url, revision, runtime, license, max_seq_len, chunk_policy, manifest_json, installed_at)
            VALUES
                ('reranker', 'example/model', 'https://example.invalid/model', 'abc123', 'coreml', 'Apache-2.0', 8192, 'sliding-window', '{}', '2026-01-01T00:00:00Z');
        """)

        try Schema.migrateSteps(db, steps)

        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "migrating from v30 to head must reach currentVersion")
        XCTAssertEqual(try rowCount(db, table: "token_saver_encoder_manifests"), 1,
                       "a v30 encoder manifest row must survive migration to head")
    }

    func test_tokenSaverSchemaStepsHaveExplicitStorageOrder() {
        let byVersion = Dictionary(uniqueKeysWithValues: Schema.steps.map { ($0.version, $0.sql) })

        XCTAssertTrue(byVersion[27]?.contains("rc_reversible_content") == true)
        XCTAssertTrue(byVersion[28]?.contains("ALTER TABLE token_saver_savings ADD COLUMN cache_state") == true)
        XCTAssertTrue(byVersion[29]?.contains("always_allow_pairing") == true,
                      "v29 is already consumed by pairing and must not be reused by Token Saver storage")
        XCTAssertTrue(byVersion[30]?.contains("token_saver_encoder_manifests") == true)
        XCTAssertTrue(byVersion[31]?.contains("shared_memory_blocks") == true)
    }

    // MARK: - head → head (idempotent re-run)

    func test_v38_to_head_preservesQueuedRowsAndInitializesDispatchState() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 38 })
        // Insert with the v38 column set — AgentThreadRepository.upsert always
        // targets HEAD columns (e.g. run_as_user_json) and cannot write a
        // mid-migration schema.
        let threadId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let threadInsert = try db.prepare("""
            INSERT INTO agent_threads(
                id, title, provider, model, status, created_at, updated_at,
                diff_additions, diff_deletions, has_unread, pinned, sort_order,
                permission_mode, reasoning_effort, execution_mode, service_tier,
                interaction_mode
            ) VALUES(?, 'queue migration', 'codex', 'gpt', 'pending', ?, ?, 0, 0, 0, 0, 0,
                     'supervised', 'medium', 'local', 'auto', 'default');
        """)
        try threadInsert.bind(1, threadId)
        try threadInsert.bind(2, now)
        try threadInsert.bind(3, now)
        _ = try threadInsert.step()
        let messageId = AgentQueuedMessageID()
        let insert = try db.prepare("""
            INSERT INTO agent_queued_messages(
                id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at
            ) VALUES(?, ?, 'survive', '[]', 'default', 1, ?, ?);
        """)
        try insert.bind(1, messageId.value.uuidString)
        try insert.bind(2, threadId)
        try insert.bind(3, now)
        try insert.bind(4, now)
        _ = try insert.step()

        try Schema.migrateSteps(db, Schema.steps)

        let repo = AgentQueuedMessageRepository(db: db)
        XCTAssertEqual(try repo.get(id: messageId)?.text, "survive")
        XCTAssertEqual(try repo.dispatch(id: messageId)?.state, .queued,
                       "v39 must default existing queue rows to claimable queued state without replay metadata")
        XCTAssertNil(try repo.dispatch(id: messageId)?.runId)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion)
    }

    /// WHY: the app may call `Schema.migrate` on every launch. If re-running a
    /// fully-migrated DB threw, every launch after the first would crash. This
    /// test pins the idempotent guarantee for the full step list at head.
    func test_headToHead_isNoop() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "first migration must reach head")

        // Re-run: must not throw and must not change recorded state.
        XCTAssertNoThrow(try Schema.migrate(db),
                         "re-running migrate on a fully-migrated DB must not throw — " +
                         "a crash here would break every launch after the first")
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "re-running must not alter the recorded version")
    }

    // MARK: - Monotonically-increasing version numbers

    /// WHY: `migrateSteps` uses `version > current` to find pending steps. If any
    /// two SchemaSteps share the same version number, one of them would be silently
    /// skipped forever. This test pins that every step has a unique, strictly
    /// monotonically-increasing version so no step is ever silently skipped.
    func test_schemaSteps_versionsAreUniqueAndMonotonic() {
        let versions = Schema.steps.map(\.version)
        // Unique: a Set drops duplicates; if counts differ there are duplicates.
        XCTAssertEqual(versions.count, Set(versions).count,
                       "all SchemaStep version numbers must be unique — " +
                       "a duplicate version causes one step to be silently skipped forever")
        // Monotonically increasing.
        let sorted = versions.sorted()
        XCTAssertEqual(versions, sorted,
                       "SchemaStep versions must be in strictly ascending order — " +
                       "an out-of-order step skips or double-applies SQL depending on the applied cursor")
        // Last step must equal currentVersion.
        XCTAssertEqual(versions.last, Schema.currentVersion,
                       "the last SchemaStep version must equal Schema.currentVersion — " +
                       "a mismatch means currentVersion does not reflect the actual schema")
    }
}
