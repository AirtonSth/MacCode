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

        // Later steps add detail and bounded-list columns. Verify the v13 row
        // remains visible without fabricating metadata from its raw fields.
        let st = try db.prepare("""
            SELECT file_snapshots_json, diff_patch, file_diffs_json,
                   list_turn_id, list_completed_at, list_metadata_unavailable,
                   list_turn_id_encoded_bytes, list_turn_id_sha256
            FROM agent_turn_checkpoints
            LIMIT 1;
            """)
        defer { st.reset() }
        XCTAssertTrue(try st.step(),
                      "columns added after v13 " +
                      "must exist after migrating from v13 to head")
        XCTAssertTrue(st.columnText(3)?.hasPrefix("rc2-legacy-row:") == true)
        XCTAssertEqual(st.columnText(4), "2024-06-01T00:00:00.000Z")
        XCTAssertEqual(st.columnInt64(5), 1)
        XCTAssertEqual(st.columnInt64(6), 0)
        XCTAssertTrue(st.columnIsNull(7))
    }

    func test_v56_to_head_installsPerThreadCatalogRevisionAndListProjections() throws {
        // WHY: shared integration base is 56. Message identity (57) followed by
        // the single checkpoint step (58) must migrate as one ordered sequence.
        XCTAssertEqual(Schema.sharedIntegrationBaseVersion, 56)
        let db = try migrateFromVersion(n: Schema.sharedIntegrationBaseVersion)
        let threadID = UUID().uuidString
        let runID = UUID().uuidString
        try db.execute("""
            INSERT INTO agent_threads
                (id, title, provider, model, status, created_at, updated_at)
            VALUES
                ('\(threadID)', 'rev', 'claude', 'claude-3', 'idle',
                 '2024-06-01T00:00:00Z', '2024-06-01T00:00:00Z');
            INSERT INTO agent_runs
                (id, thread_id, provider, model, status, started_at)
            VALUES
                ('\(runID)', '\(threadID)', 'claude', 'claude-3', 'idle',
                 '2024-06-01T00:00:00Z');
            INSERT INTO agent_turn_checkpoints
                (thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref,
                 status, files_json, completed_at, created_at)
            VALUES
                ('\(threadID)', '\(runID)', 'legacy-t1', 1, 'r1', 'ready', '[]',
                 '2024-06-01T00:00:00Z', '2024-06-01T00:00:00Z');
            """)
        try Schema.migrateSteps(db, Schema.steps)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion)
        XCTAssertGreaterThanOrEqual(try maxVersion(db), Schema.checkpointListSchemaVersion)

        let legacy = try db.prepare("""
            SELECT list_turn_id, list_metadata_unavailable, files_summary_timestamp
            FROM agent_turn_checkpoints WHERE thread_id = ?;
            """)
        try legacy.bind(1, threadID)
        XCTAssertTrue(try legacy.step())
        XCTAssertTrue(legacy.columnText(0)?.hasPrefix("rc2-legacy-row:") == true)
        XCTAssertEqual(legacy.columnInt64(1), 1)
        XCTAssertEqual(legacy.columnInt64(2), 1)

        // Per-thread fence: insert for this thread bumps only its row.
        try db.execute("""
            INSERT INTO agent_turn_checkpoints
                (thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref,
                 status, files_json, completed_at, created_at,
                 files_summary_json, files_summary_truncated,
                 list_turn_id, list_completed_at, list_metadata_unavailable)
            VALUES
                ('\(threadID)', '\(runID)', 't2', 2, 'r2', 'ready', '[]',
                 '2024-06-01T00:00:01.000Z', '2024-06-01T00:00:01Z',
                 '[]', 0, 't2', '2024-06-01T00:00:01.000Z', 0);
            """)
        let rev = try db.prepare("""
            SELECT revision FROM agent_turn_checkpoint_catalog_meta
            WHERE thread_id = ?;
            """)
        try rev.bind(1, threadID)
        XCTAssertTrue(try rev.step())
        XCTAssertGreaterThanOrEqual(rev.columnInt64(0), 2)
    }

    func test_precedingVersion_to_head_checkpointListStepIsSelfContained() throws {
        // WHY: the named relocatable step is self-contained from its immediate
        // predecessor. Composition renumbers `checkpointListSchemaVersion`
        // past Message slots; tests never hardcode SchemaStep57 / base+1.
        let preceding = Schema.checkpointListSchemaVersion - 1
        XCTAssertGreaterThanOrEqual(preceding, Schema.sharedIntegrationBaseVersion)
        let db = try migrateFromVersion(n: preceding)
        XCTAssertEqual(try maxVersion(db), preceding)
        try Schema.migrateSteps(db, Schema.steps)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion)
        XCTAssertGreaterThanOrEqual(try maxVersion(db), Schema.checkpointListSchemaVersion)

        // Table exists and is per-thread (no global id=1 singleton).
        let cols = try db.prepare(
            "PRAGMA table_info(agent_turn_checkpoint_catalog_meta);"
        )
        var names: [String] = []
        while try cols.step() {
            if let name = cols.columnText(1) { names.append(name) }
        }
        XCTAssertTrue(names.contains("thread_id"))
        XCTAssertTrue(names.contains("revision"))
        XCTAssertFalse(names.contains("id"), "must not ship the never-released global singleton schema")
    }

    func test_sharedBase_to_head_invalidLegacyCompletedAtUsesFixedBoundedSentinel() throws {
        // WHY: SQLite strftime returns NULL for malformed legacy dates. Falling
        // back to the raw completed_at value would copy attacker-sized text into
        // list_completed_at and violate the capture-time bounded source contract.
        let db = try migrateFromVersion(n: Schema.sharedIntegrationBaseVersion)
        let threadID = UUID().uuidString
        let runID = UUID().uuidString
        try db.execute("""
            INSERT INTO agent_threads
                (id, title, provider, model, status, created_at, updated_at)
            VALUES
                ('\(threadID)', 'legacy hostile date', 'claude', 'claude-3', 'idle',
                 '2024-06-01T00:00:00Z', '2024-06-01T00:00:00Z');
            INSERT INTO agent_runs
                (id, thread_id, provider, model, status, started_at)
            VALUES
                ('\(runID)', '\(threadID)', 'claude', 'claude-3', 'idle',
                 '2024-06-01T00:00:00Z');
            """)
        let hostile = "not-an-iso-date-" + String(repeating: "x", count: 128 * 1_024)
        let insert = try db.prepare("""
            INSERT INTO agent_turn_checkpoints
                (thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref,
                 status, files_json, completed_at, created_at)
            VALUES (?, ?, 'legacy-turn', 1, 'legacy-ref', 'ready', '[]', ?,
                    '2024-06-01T00:00:00Z');
            """)
        try insert.bind(1, threadID)
        try insert.bind(2, runID)
        try insert.bind(3, hostile)
        _ = try insert.step()

        try Schema.migrateSteps(db, Schema.steps)

        let row = try db.prepare("""
            SELECT list_completed_at, length(list_completed_at),
                   list_metadata_unavailable
            FROM agent_turn_checkpoints
            WHERE thread_id = ?;
            """)
        try row.bind(1, threadID)
        XCTAssertTrue(try row.step())
        XCTAssertEqual(row.columnText(0), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(row.columnInt64(1), 24)
        XCTAssertEqual(row.columnInt64(2), 1)
    }

    func test_checkpointListSchemaVersion_isSingleNamedRelocatableStep() throws {
        // WHY: composition assigns one named constant atomically. Tests bind to
        // `checkpointListSchemaVersion` / `checkpointListMigrationSQL` identity,
        // never a fixed SchemaStep57 or base+1 equality that collides with Message.
        let namedSteps = Schema.steps.filter {
            $0.version == Schema.checkpointListSchemaVersion
        }
        XCTAssertEqual(namedSteps.count, 1, "exactly one step uses the named version")
        XCTAssertEqual(namedSteps[0].sql, Schema.checkpointListMigrationSQL)
        XCTAssertGreaterThanOrEqual(Schema.currentVersion, Schema.checkpointListSchemaVersion)
        XCTAssertGreaterThan(
            Schema.checkpointListSchemaVersion,
            Schema.sharedIntegrationBaseVersion,
            "named step must sit after the shared integration base"
        )
        // The composed head has Message identity, named checkpoint list,
        // Token Saver per-thread totals (59), terminal fork transcript
        // scrubbing (60), then causal fork cleanup support (61). This catches
        // duplicate/reordered slots.
        let postBase = Schema.steps.filter {
            $0.version > Schema.sharedIntegrationBaseVersion
        }
        XCTAssertEqual(postBase.map(\.version), [
            Schema.sharedIntegrationBaseVersion + 1,
            Schema.checkpointListSchemaVersion,
            59,
            60,
            Schema.currentVersion,
        ])
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

    func test_v59ToV60ForkIntentTranscriptScrubIsAtomicSelectiveAndIdempotent() throws {
        XCTAssertGreaterThanOrEqual(Schema.currentVersion, 61)
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 59 })
        let largePayload = "[\"\(String(repeating: "x", count: 128 * 1024))\"]"
        let states = [
            "prepared", "provider_created", "compensating",
            "local_committed", "compensated", "abandoned"
        ]
        for state in states {
            let statement = try db.prepare("""
                INSERT INTO agent_thread_fork_intents(
                    child_thread_id, source_thread_id, provider, idempotency_key,
                    state, child_thread_json, source_messages_json,
                    provider_child_thread_id, last_error, created_at, updated_at
                ) VALUES(?, ?, 'codex', ?, ?, ?, ?, ?, ?, 'created', 'updated');
            """)
            try statement.bind(1, "child-\(state)")
            try statement.bind(2, "source-\(state)")
            try statement.bind(3, "key-\(state)")
            try statement.bind(4, state)
            try statement.bind(5, "{\"identity\":\"child-\(state)\"}")
            try statement.bind(6, largePayload)
            try statement.bind(7, "provider-child-\(state)")
            try statement.bind(8, "error-\(state)")
            _ = try statement.step()
        }

        try db.execute("""
            CREATE TRIGGER fail_terminal_fork_scrub
            BEFORE UPDATE OF source_messages_json ON agent_thread_fork_intents
            WHEN NEW.child_thread_id = 'child-compensated'
                 AND NEW.source_messages_json = '[]'
            BEGIN SELECT RAISE(ABORT, 'injected terminal scrub failure'); END;
        """)
        let v60Steps = Schema.steps.filter { $0.version <= 60 }
        XCTAssertThrowsError(try Schema.migrateSteps(db, v60Steps))
        XCTAssertEqual(try maxVersion(db), 59,
                       "the scrub and schema version must roll back as one migration step")
        let afterRollback = try db.prepare("""
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE source_messages_json = ?;
        """)
        try afterRollback.bind(1, largePayload)
        XCTAssertTrue(try afterRollback.step())
        XCTAssertEqual(afterRollback.columnInt64(0), 6,
                       "one failed terminal update must roll every earlier scrub back")

        try db.execute("DROP TRIGGER fail_terminal_fork_scrub;")
        try Schema.migrateSteps(db, v60Steps)
        XCTAssertEqual(try maxVersion(db), 60)

        let rows = try db.prepare("""
            SELECT child_thread_id, source_thread_id, provider, idempotency_key,
                   state, child_thread_json, source_messages_json,
                   provider_child_thread_id, last_error
            FROM agent_thread_fork_intents ORDER BY state ASC;
        """)
        var observed: [String: [String]] = [:]
        while try rows.step() {
            let state = rows.columnText(4) ?? ""
            observed[state] = (0..<9).map { rows.columnText(Int32($0)) ?? "" }
        }
        XCTAssertEqual(Set(observed.keys), Set(states), "terminal intents remain as tombstones")
        for state in states {
            let row = try XCTUnwrap(observed[state])
            XCTAssertEqual(row[0], "child-\(state)")
            XCTAssertEqual(row[1], "source-\(state)")
            XCTAssertEqual(row[2], "codex")
            XCTAssertEqual(row[3], "key-\(state)")
            XCTAssertEqual(row[4], state)
            XCTAssertEqual(row[5], "{\"identity\":\"child-\(state)\"}")
            XCTAssertEqual(row[7], "provider-child-\(state)")
            XCTAssertEqual(row[8], "error-\(state)")
            let terminal = ["local_committed", "compensated", "abandoned"].contains(state)
            XCTAssertEqual(row[6], terminal ? "[]" : largePayload,
                           "only terminal transcript payloads may be scrubbed")
        }

        XCTAssertNoThrow(try Schema.migrateSteps(db, v60Steps))
        let afterRerun = try db.prepare("""
            SELECT state, length(CAST(source_messages_json AS BLOB))
            FROM agent_thread_fork_intents ORDER BY state ASC;
        """)
        while try afterRerun.step() {
            let state = afterRerun.columnText(0) ?? ""
            let terminal = ["local_committed", "compensated", "abandoned"].contains(state)
            XCTAssertEqual(Int(afterRerun.columnInt64(1)), terminal ? 2 : largePayload.utf8.count,
                           "re-running head migration must be an idempotent no-op")
        }
        try Schema.migrateSteps(db, Schema.steps)
        XCTAssertEqual(try maxVersion(db), Schema.currentVersion,
                       "the forward-only v61 lifecycle support must follow an already-applied v60 scrub")
    }

    func test_v59ForkIntentMigrationBenchmark() throws {
        XCTAssertGreaterThanOrEqual(Schema.currentVersion, 61)
        let root = NSTemporaryDirectory() + "rc2-fork-intent-v60-benchmark-" + UUID().uuidString
        let dbPath = root + "/remotecode.sqlite"
        defer { try? FileManager.default.removeItem(atPath: root) }

        let db = try SQLiteDB(path: dbPath)
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 59 })
        let terminalPayload = "[\"" + String(repeating: "x", count: 256 * 1024) + "\"]"
        let terminalStates = ["local_committed", "compensated", "abandoned"]
        let terminalRows = 1_000
        let recoverableStates = ["prepared", "provider_created", "compensating"]

        try db.performSync { database in
            try database.transaction {
                let insert = try database.prepare("""
                    INSERT INTO agent_thread_fork_intents(
                        child_thread_id, source_thread_id, provider, idempotency_key,
                        state, child_thread_json, source_messages_json,
                        provider_child_thread_id, last_error, created_at, updated_at
                    ) VALUES(?, ?, 'codex', ?, ?, '{}', ?, NULL, NULL, 'created', 'updated');
                """)
                for index in 0..<(terminalRows + recoverableStates.count) {
                    insert.reset()
                    let state = index < terminalRows
                        ? terminalStates[index % terminalStates.count]
                        : recoverableStates[index - terminalRows]
                    try insert.bind(1, "child-\(index)")
                    try insert.bind(2, "source-\(index)")
                    try insert.bind(3, "key-\(index)")
                    try insert.bind(4, state)
                    try insert.bind(5, terminalPayload)
                    _ = try insert.step()
                }
            }
        }
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE);")

        func fileBytes(_ path: String) -> Int64 {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else { return 0 }
            return size.int64Value
        }
        func totalBytes() -> Int64 {
            fileBytes(dbPath) + fileBytes(dbPath + "-wal")
        }
        func countRows(_ sql: String) throws -> Int {
            let statement = try db.prepare(sql)
            defer { statement.reset() }
            guard try statement.step() else { return 0 }
            return Int(statement.columnInt64(0))
        }

        let beforeBytes = totalBytes()
        let sampleLock = NSLock()
        var peakBytes = beforeBytes
        let sampleQueue = DispatchQueue(label: "rc2-fork-intent-v60-benchmark-sampler")
        let sampler = DispatchSource.makeTimerSource(queue: sampleQueue)
        sampler.schedule(deadline: .now(), repeating: .milliseconds(1))
        sampler.setEventHandler {
            let bytes = totalBytes()
            sampleLock.lock()
            peakBytes = max(peakBytes, bytes)
            sampleLock.unlock()
        }
        sampler.resume()
        let startedAt = Date()
        let v60Steps = Schema.steps.filter { $0.version <= 60 }
        try Schema.migrateSteps(db, v60Steps)
        let wallSeconds = Date().timeIntervalSince(startedAt)
        sampler.cancel()
        sampleQueue.sync {}
        sampleLock.lock()
        peakBytes = max(peakBytes, totalBytes())
        sampleLock.unlock()
        let afterBytes = totalBytes()

        XCTAssertLessThanOrEqual(wallSeconds, 10,
                                 "the v60 startup migration must finish the 1,000-row 256 KiB corpus within its declared 10-second budget")
        XCTAssertLessThanOrEqual(peakBytes - beforeBytes, 8 * 1_024 * 1_024,
                                 "the v60 migration must not duplicate the 256 MiB terminal corpus into the database or WAL")

        XCTAssertEqual(try countRows("""
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE state IN ('local_committed', 'compensated', 'abandoned')
              AND source_messages_json = '[]';
        """), terminalRows)
        XCTAssertEqual(try countRows("""
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE state IN ('prepared', 'provider_created', 'compensating')
              AND length(CAST(source_messages_json AS BLOB)) = \(terminalPayload.utf8.count);
        """), recoverableStates.count)
        XCTAssertNoThrow(try Schema.migrateSteps(db, v60Steps),
                         "re-running the completed migration must be an idempotent no-op")
        try Schema.migrateSteps(db, Schema.steps)
        XCTAssertEqual(try countRows("SELECT COUNT(*) FROM schema_meta WHERE version = 61;"), 1,
                       "head migration must record the forward-only causal cleanup support")

        print("FORK_INTENT_V60_BENCH wall_seconds=\(String(format: "%.3f", wallSeconds)) before_bytes=\(beforeBytes) peak_bytes=\(peakBytes) after_bytes=\(afterBytes) peak_delta_bytes=\(peakBytes - beforeBytes) after_delta_bytes=\(afterBytes - beforeBytes) terminal_rows=\(terminalRows) recoverable_rows=\(recoverableStates.count)")
    }

    func test_v61CausalForkIntentCleanupIsBoundedCrashSafeAndResumableOnStartup() throws {
        XCTAssertEqual(Schema.currentVersion, 61)
        let root = NSTemporaryDirectory() + "rc2-fork-intent-v61-cleanup-" + UUID().uuidString
        let dbPath = root + "/remotecode.sqlite"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let batchSize = AgentThreadRepository.terminalForkIntentCleanupBatchSize
        let candidateCount = batchSize + 2

        func scalar(_ db: SQLiteDB, _ sql: String) throws -> Int {
            let statement = try db.prepare(sql)
            defer { statement.reset() }
            guard try statement.step() else { return 0 }
            return Int(statement.columnInt64(0))
        }

        do {
            let legacy = try SQLiteDB(path: dbPath)
            try Schema.migrateSteps(legacy, Schema.steps.filter { $0.version <= 60 })
            let insert = try legacy.prepare("""
                INSERT INTO agent_thread_fork_intents(
                    child_thread_id, source_thread_id, provider, idempotency_key,
                    state, child_thread_json, source_messages_json,
                    provider_child_thread_id, last_error, created_at, updated_at
                ) VALUES(?, ?, 'codex', ?, ?, '{}', ?, 'provider-child', NULL, 'created', 'updated');
            """)
            for index in 0..<candidateCount {
                insert.reset()
                try insert.bind(1, String(format: "candidate-%04d", index))
                try insert.bind(2, "source-\(index)")
                try insert.bind(3, "key-\(index)")
                try insert.bind(4, index.isMultiple(of: 2) ? "compensated" : "local_committed")
                try insert.bind(5, "[\"historical terminal payload\"]")
                _ = try insert.step()
            }
            insert.reset()
            try insert.bind(1, "recoverable-prepared")
            try insert.bind(2, "source-recoverable")
            try insert.bind(3, "key-recoverable")
            try insert.bind(4, "prepared")
            try insert.bind(5, "[\"recoverable transcript\"]")
            _ = try insert.step()
            insert.reset()
            try insert.bind(1, "legacy-abandoned")
            try insert.bind(2, "source-abandoned")
            try insert.bind(3, "key-abandoned")
            try insert.bind(4, "abandoned")
            try insert.bind(5, "[]")
            _ = try insert.step()
            try legacy.execute("""
                INSERT INTO agent_threads(id, title, provider, model, status, created_at, updated_at)
                VALUES('candidate-\(String(format: "%04d", 1))', 'live child', 'codex', 'm', 'completed', 'created', 'updated');
            """)
            try legacy.execute("""
                CREATE TRIGGER fail_causal_fork_cleanup
                BEFORE DELETE ON agent_thread_fork_intents
                WHEN OLD.child_thread_id = 'candidate-\(String(format: "%04d", 2))'
                BEGIN SELECT RAISE(ABORT, 'injected causal cleanup failure'); END;
            """)
        }

        let bootstrap = Bootstrap(
            channel: .debug,
            dbPathOverride: dbPath,
            appSupportOverride: root
        )
        XCTAssertThrowsError(try bootstrap.run()) { error in
            XCTAssertTrue(String(describing: error).contains("injected causal cleanup failure"))
        }

        let afterFailure = try SQLiteDB(path: dbPath)
        XCTAssertEqual(try scalar(afterFailure, "SELECT MAX(version) FROM schema_meta;"), Schema.currentVersion,
                       "schema progress commits before a bounded maintenance batch can fail")
        XCTAssertEqual(try scalar(afterFailure, """
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE state = 'compensated'
               OR (state = 'local_committed' AND child_thread_id != 'candidate-0001');
        """), candidateCount - 1,
                       "a failed batch must roll back every tentative terminal deletion")
        XCTAssertEqual(try scalar(afterFailure, """
            SELECT provider_creation_attempted FROM agent_thread_fork_intents
            WHERE child_thread_id = 'recoverable-prepared';
        """), 1,
                       "legacy recoverable rows default to ambiguous rather than becoming deletable")
        try afterFailure.execute("DROP TRIGGER fail_causal_fork_cleanup;")

        let (_, firstDB) = try bootstrap.run()
        XCTAssertEqual(try scalar(firstDB, """
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE state = 'compensated'
               OR (state = 'local_committed' AND child_thread_id != 'candidate-0001');
        """), candidateCount - 1 - batchSize,
                       "one startup must delete no more than its configured causal batch")
        XCTAssertEqual(try scalar(firstDB, """
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE child_thread_id = 'recoverable-prepared'
              AND source_messages_json = '["recoverable transcript"]';
        """), 1,
                       "recoverable transcript payloads must survive every maintenance retry exactly")
        XCTAssertEqual(try scalar(firstDB, """
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE child_thread_id IN ('candidate-0001', 'legacy-abandoned');
        """), 2,
                       "a live local child and an unproven legacy abandonment are not cleanup candidates")

        let (_, secondDB) = try bootstrap.run()
        XCTAssertEqual(try scalar(secondDB, """
            SELECT COUNT(*) FROM agent_thread_fork_intents
            WHERE state = 'compensated'
               OR (state = 'local_committed' AND child_thread_id != 'candidate-0001');
        """), 0,
                       "the next startup resumes from the remaining causal candidates without a cursor replay")
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
