import Foundation

public enum SchemaError: Error { case versionMismatch(Int, Int) }

public struct SchemaStep {
    public let version: Int
    public let sql: String
    public init(_ version: Int, _ sql: String) { self.version = version; self.sql = sql }
}

public enum Schema {
    public static let currentVersion: Int = 29

    public static let steps: [SchemaStep] = [
        SchemaStep(1, """
        CREATE TABLE IF NOT EXISTS schema_meta (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            path TEXT NOT NULL,
            favorite INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS agent_threads (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            workspace_id TEXT,
            title TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            provider_thread_id TEXT,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            diff_additions INTEGER NOT NULL DEFAULT 0,
            diff_deletions INTEGER NOT NULL DEFAULT 0,
            has_unread INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_agent_threads_project ON agent_threads(project_id);
        CREATE INDEX IF NOT EXISTS idx_agent_threads_workspace ON agent_threads(workspace_id);
        CREATE TABLE IF NOT EXISTS agent_messages (
            id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_agent_messages_thread ON agent_messages(thread_id);
        CREATE INDEX IF NOT EXISTS idx_agent_messages_thread_created_id ON agent_messages(thread_id, created_at, id);
        CREATE TABLE IF NOT EXISTS agent_runs (
            id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            status TEXT NOT NULL,
            started_at TEXT NOT NULL,
            finished_at TEXT,
            error_message TEXT,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_agent_runs_thread ON agent_runs(thread_id);
        CREATE TABLE IF NOT EXISTS agent_stream_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            event_kind TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_stream_events_run ON agent_stream_events(run_id, seq);
        CREATE TABLE IF NOT EXISTS agent_turn_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            thread_id TEXT NOT NULL,
            run_id TEXT,
            turn_id TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_turn_snapshots_thread ON agent_turn_snapshots(thread_id);
        -- DEAD TABLE: workspace_selection
        -- No repository or call sites exist for this table beyond Bootstrap seeding.
        -- Candidate for removal in a future destructive migration once confirmed safe.
        -- Listed in Schema.knownDeadTableNames.
        CREATE TABLE IF NOT EXISTS workspace_selection (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            selected_workspace_id TEXT,
            selected_surface_id TEXT,
            selected_thread_id TEXT,
            selected_provider TEXT,
            selected_model TEXT,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS session_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            version INTEGER NOT NULL,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        -- DEAD TABLE: terminal_sessions
        -- No repository or call sites reference this table; terminal output is
        -- stored in terminal_output_chunks (step 7) instead.
        -- Candidate for removal in a future destructive migration once confirmed safe.
        -- Listed in Schema.knownDeadTableNames.
        CREATE TABLE IF NOT EXISTS terminal_sessions (
            id TEXT PRIMARY KEY,
            surface_id TEXT NOT NULL,
            workspace_id TEXT,
            cwd TEXT,
            scrollback TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        -- DEAD TABLE: browser_profiles
        -- No repository or call sites reference this table; browser-profile
        -- management was never implemented in the current codebase.
        -- Candidate for removal in a future destructive migration once confirmed safe.
        -- Listed in Schema.knownDeadTableNames.
        CREATE TABLE IF NOT EXISTS browser_profiles (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            is_default INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            seq INTEGER NOT NULL,
            kind TEXT NOT NULL,
            request_id TEXT,
            origin_client_id TEXT,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_events_seq ON events(seq);
        """),
        SchemaStep(2, """
        CREATE TABLE IF NOT EXISTS device_trust (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            token_hash TEXT NOT NULL,
            created_at TEXT NOT NULL,
            last_seen_at TEXT,
            revoked_at TEXT,
            capabilities TEXT NOT NULL DEFAULT '*'
        );
        CREATE INDEX IF NOT EXISTS idx_device_trust_token ON device_trust(token_hash);
        CREATE TABLE IF NOT EXISTS pairing_codes (
            code TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            redeemed_at TEXT,
            redeemed_device_id TEXT
        );
        CREATE TABLE IF NOT EXISTS audit_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            actor TEXT,
            action TEXT NOT NULL,
            detail TEXT
        );
        CREATE TABLE IF NOT EXISTS notifications (
            id TEXT PRIMARY KEY,
            workspace_id TEXT,
            surface_id TEXT,
            title TEXT NOT NULL,
            body TEXT,
            category TEXT,
            created_at TEXT NOT NULL,
            read_at TEXT,
            dismissed_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_notifications_workspace ON notifications(workspace_id);
        """),
        SchemaStep(3, """
        ALTER TABLE agent_threads ADD COLUMN color TEXT;
        """),
        SchemaStep(4, """
        CREATE TABLE IF NOT EXISTS pairing_requests (
            id TEXT PRIMARY KEY,
            code TEXT NOT NULL,
            device_name TEXT NOT NULL,
            created_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            device_id TEXT,
            decided_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_pairing_requests_status ON pairing_requests(status);
        """),
        SchemaStep(5, """
        ALTER TABLE agent_threads ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE agent_threads ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;
        """),
        SchemaStep(6, """
        ALTER TABLE agent_threads ADD COLUMN permission_mode TEXT NOT NULL DEFAULT 'supervised';
        ALTER TABLE agent_threads ADD COLUMN reasoning_effort TEXT NOT NULL DEFAULT 'medium';
        """),
        SchemaStep(7, """
        CREATE TABLE IF NOT EXISTS terminal_output_chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            surface_id TEXT NOT NULL,
            workspace_id TEXT,
            chunk_index INTEGER NOT NULL,
            data BLOB NOT NULL,
            byte_count INTEGER NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_terminal_output_surface_index ON terminal_output_chunks(surface_id, chunk_index);
        CREATE INDEX IF NOT EXISTS idx_terminal_output_surface_id ON terminal_output_chunks(surface_id, id);
        """),
        SchemaStep(8, """
        CREATE TABLE IF NOT EXISTS provider_session_runtime (
            thread_id TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            provider_instance_id TEXT,
            status TEXT NOT NULL,
            resume_cursor TEXT,
            runtime_payload_json TEXT,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_provider_session_runtime_provider ON provider_session_runtime(provider, status);
        """),
        SchemaStep(9, """
        CREATE TABLE IF NOT EXISTS command_receipts (
            method TEXT NOT NULL,
            client_request_id TEXT NOT NULL,
            result_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY(method, client_request_id)
        );
        """),
        SchemaStep(10, """
        ALTER TABLE provider_session_runtime ADD COLUMN cwd TEXT;
        ALTER TABLE provider_session_runtime ADD COLUMN model TEXT;
        ALTER TABLE provider_session_runtime ADD COLUMN last_event_kind TEXT;
        ALTER TABLE provider_session_runtime ADD COLUMN last_error_message TEXT;
        """),
        SchemaStep(11, """
        CREATE TABLE IF NOT EXISTS provider_pending_callbacks (
            thread_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            callback_kind TEXT NOT NULL,
            state TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            resolved_at TEXT,
            stale_reason TEXT,
            PRIMARY KEY(thread_id, request_id, callback_kind),
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_provider_pending_callbacks_open ON provider_pending_callbacks(state, thread_id);
        """),
        SchemaStep(12, """
        CREATE TABLE IF NOT EXISTS agent_proposed_plans (
            thread_id TEXT NOT NULL,
            plan_id TEXT NOT NULL,
            turn_id TEXT,
            markdown TEXT NOT NULL,
            implemented_at TEXT,
            implementation_thread_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY(thread_id, plan_id),
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_agent_proposed_plans_thread ON agent_proposed_plans(thread_id, created_at);
        """),
        SchemaStep(13, """
        CREATE TABLE IF NOT EXISTS agent_turn_checkpoints (
            thread_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            checkpoint_turn_count INTEGER NOT NULL,
            checkpoint_ref TEXT NOT NULL,
            status TEXT NOT NULL,
            files_json TEXT NOT NULL,
            assistant_message_id TEXT,
            error_message TEXT,
            completed_at TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY(thread_id, turn_id),
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE,
            FOREIGN KEY(run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_agent_turn_checkpoints_thread ON agent_turn_checkpoints(thread_id, checkpoint_turn_count);
        """),
        SchemaStep(14, """
        ALTER TABLE agent_turn_checkpoints ADD COLUMN file_snapshots_json TEXT NOT NULL DEFAULT '[]';
        """),
        SchemaStep(15, """
        ALTER TABLE agent_turn_checkpoints ADD COLUMN diff_patch TEXT;
        ALTER TABLE agent_turn_checkpoints ADD COLUMN file_diffs_json TEXT NOT NULL DEFAULT '[]';
        """),
        SchemaStep(16, """
        ALTER TABLE agent_threads ADD COLUMN execution_mode TEXT NOT NULL DEFAULT 'local';
        ALTER TABLE agent_threads ADD COLUMN base_branch TEXT;
        ALTER TABLE agent_threads ADD COLUMN worktree_path TEXT;
        """),
        SchemaStep(17, """
        ALTER TABLE agent_threads ADD COLUMN service_tier TEXT NOT NULL DEFAULT 'auto';
        """),
        SchemaStep(18, """
        ALTER TABLE provider_session_runtime ADD COLUMN service_tier TEXT NOT NULL DEFAULT 'auto';
        """),
        SchemaStep(19, """
        ALTER TABLE provider_session_runtime ADD COLUMN runtime_mode TEXT NOT NULL DEFAULT 'supervised';
        """),
        SchemaStep(20, """
        ALTER TABLE provider_session_runtime ADD COLUMN adapter_key TEXT;
        ALTER TABLE provider_session_runtime ADD COLUMN binary_identity TEXT;
        """),
        SchemaStep(21, """
        ALTER TABLE agent_threads ADD COLUMN model_selection_json TEXT;
        """),
        SchemaStep(22, """
        ALTER TABLE agent_threads ADD COLUMN provider_instance_id TEXT;
        ALTER TABLE agent_runs ADD COLUMN provider_instance_id TEXT;
        """),
        SchemaStep(23, """
        CREATE TABLE IF NOT EXISTS agent_provider_event_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            thread_id TEXT NOT NULL,
            run_id TEXT,
            event_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            source TEXT NOT NULL,
            method TEXT NOT NULL,
            provider_turn_id TEXT,
            provider_item_id TEXT,
            provider_request_id TEXT,
            payload_json TEXT NOT NULL,
            received_at_ms INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE,
            FOREIGN KEY(run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_provider_event_logs_thread ON agent_provider_event_logs(thread_id, id);
        CREATE INDEX IF NOT EXISTS idx_provider_event_logs_refs ON agent_provider_event_logs(provider_turn_id, provider_item_id, provider_request_id);
        """),
        SchemaStep(24, """
        CREATE TABLE IF NOT EXISTS agent_queued_messages (
            id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            text TEXT NOT NULL,
            attachments_json TEXT NOT NULL,
            interaction_mode TEXT NOT NULL,
            position INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_agent_queued_messages_thread ON agent_queued_messages(thread_id, position, created_at);
        """),
        SchemaStep(25, """
        CREATE TABLE IF NOT EXISTS token_saver_savings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            provider TEXT NOT NULL,
            mode TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            saved_tokens INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_savings_time ON token_saver_savings(created_at_ms);
        """),
        SchemaStep(26, """
        CREATE TABLE IF NOT EXISTS token_saver_savings_totals (
            provider TEXT NOT NULL,
            mode TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            saved_tokens INTEGER NOT NULL,
            runs INTEGER NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY(provider, mode)
        );
        INSERT INTO token_saver_savings_totals
            (provider, mode, input_tokens, output_tokens, saved_tokens, runs, updated_at)
        SELECT provider,
               mode,
               COALESCE(SUM(input_tokens), 0),
               COALESCE(SUM(output_tokens), 0),
               COALESCE(SUM(saved_tokens), 0),
               COUNT(*),
               COALESCE(MAX(created_at), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        FROM token_saver_savings
        GROUP BY provider, mode
        ON CONFLICT(provider, mode) DO UPDATE SET
            input_tokens = token_saver_savings_totals.input_tokens + excluded.input_tokens,
            output_tokens = token_saver_savings_totals.output_tokens + excluded.output_tokens,
            saved_tokens = token_saver_savings_totals.saved_tokens + excluded.saved_tokens,
            runs = token_saver_savings_totals.runs + excluded.runs,
            updated_at = excluded.updated_at;
        """),
        SchemaStep(27, """
        CREATE TABLE IF NOT EXISTS rc_reversible_content (
            handle TEXT PRIMARY KEY,
            original BLOB NOT NULL,
            sha256 TEXT NOT NULL,
            byte_count INTEGER NOT NULL,
            ref_count INTEGER NOT NULL DEFAULT 0,
            created_at_ms INTEGER NOT NULL,
            last_access_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_rc_reversible_content_access ON rc_reversible_content(last_access_ms);
        """),
        SchemaStep(28, """
        ALTER TABLE token_saver_savings ADD COLUMN content_type TEXT NOT NULL DEFAULT 'unknown';
        ALTER TABLE token_saver_savings ADD COLUMN engine TEXT NOT NULL DEFAULT 'unknown';
        ALTER TABLE token_saver_savings ADD COLUMN cache_state TEXT NOT NULL DEFAULT 'unknown';
        """),
        SchemaStep(29, """
        ALTER TABLE device_trust ADD COLUMN client_device_id TEXT;
        ALTER TABLE device_trust ADD COLUMN always_allow_pairing INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE pairing_requests ADD COLUMN client_device_id TEXT;
        CREATE INDEX IF NOT EXISTS idx_device_trust_client_allow ON device_trust(client_device_id, always_allow_pairing);
        """)
    ]

    /// Tables that exist in the schema for historical reasons but have no
    /// active repository or call sites in the current codebase.  They are
    /// retained to avoid a destructive migration step; they are candidates for
    /// removal once a future migration cycle confirms they are safe to drop.
    ///
    /// - workspace_selection: seeded by Bootstrap only; no queries elsewhere.
    /// - terminal_sessions: superseded by terminal_output_chunks (step 7).
    /// - browser_profiles: browser-profile feature was never implemented.
    public static func knownDeadTableNames() -> Set<String> {
        ["workspace_selection", "terminal_sessions", "browser_profiles"]
    }

    public static func migrate(_ db: SQLiteDB) throws {
        try migrateSteps(db, steps)
    }

    /// Applies the given steps transactionally and idempotently.
    /// Each pending step (SQL + its `schema_meta` row) is wrapped in a single
    /// `BEGIN IMMEDIATE ... COMMIT`, rolling back on any error so a step is
    /// all-or-nothing: a step that throws mid-way leaves both the schema and
    /// `schema_meta` unchanged. Already-applied steps (version <= current MAX)
    /// are skipped, so re-running is a no-op.
    static func migrateSteps(_ db: SQLiteDB, _ steps: [SchemaStep]) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS schema_meta (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL
            );
        """)
        let stmt = try db.prepare("SELECT MAX(version) FROM schema_meta;")
        defer { stmt.reset() }
        var current: Int = 0
        if try stmt.step() {
            if !stmt.columnIsNull(0) {
                current = Int(stmt.columnInt64(0))
            }
        }
        let pending = steps.filter { $0.version > current }
        for step in pending.sorted(by: { $0.version < $1.version }) {
            try db.transaction {
                try db.execute(step.sql)
                let ins = try db.prepare("INSERT OR IGNORE INTO schema_meta(version, applied_at) VALUES(?, ?);")
                try ins.bind(1, Int64(step.version))
                try ins.bind(2, ISO8601DateFormatter().string(from: Date()))
                _ = try ins.step()
            }
        }
    }
}
