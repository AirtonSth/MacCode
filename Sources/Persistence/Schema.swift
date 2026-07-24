import Foundation

public enum SchemaError: Error { case versionMismatch(Int, Int) }

public struct SchemaStep {
    public let version: Int
    public let sql: String
    public init(_ version: Int, _ sql: String) { self.version = version; self.sql = sql }
}

public enum Schema {
    public static let currentVersion: Int = 52

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
        """),
        SchemaStep(30, """
        CREATE TABLE IF NOT EXISTS token_saver_encoder_manifests (
            role TEXT NOT NULL,
            model_id TEXT NOT NULL,
            source_url TEXT NOT NULL,
            revision TEXT NOT NULL,
            runtime TEXT NOT NULL,
            license TEXT NOT NULL,
            max_seq_len INTEGER NOT NULL,
            chunk_policy TEXT NOT NULL,
            manifest_json TEXT NOT NULL,
            installed_at TEXT NOT NULL,
            PRIMARY KEY(role, model_id)
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_encoder_manifests_role ON token_saver_encoder_manifests(role);
        """),
        SchemaStep(31, """
        CREATE TABLE IF NOT EXISTS shared_memory_blocks (
            id TEXT PRIMARY KEY,
            content_hash TEXT NOT NULL,
            reversible_handle TEXT NOT NULL,
            preview TEXT NOT NULL DEFAULT '',
            byte_count INTEGER NOT NULL,
            token_count_estimate INTEGER NOT NULL DEFAULT 0,
            ref_count INTEGER NOT NULL DEFAULT 0,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            created_at_ms INTEGER NOT NULL,
            last_access_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_shared_memory_blocks_hash ON shared_memory_blocks(content_hash);
        CREATE INDEX IF NOT EXISTS idx_shared_memory_blocks_handle ON shared_memory_blocks(reversible_handle);
        CREATE INDEX IF NOT EXISTS idx_shared_memory_blocks_access ON shared_memory_blocks(last_access_ms);
        """),
        SchemaStep(32, """
        ALTER TABLE command_receipts ADD COLUMN owner_fingerprint TEXT;
        ALTER TABLE command_receipts ADD COLUMN params_hash TEXT;
        ALTER TABLE command_receipts ADD COLUMN state TEXT;
        ALTER TABLE command_receipts ADD COLUMN updated_at TEXT;
        """),
        SchemaStep(33, """
        ALTER TABLE command_receipts ADD COLUMN event_start_seq INTEGER;
        ALTER TABLE command_receipts ADD COLUMN event_end_seq INTEGER;
        DELETE FROM events WHERE rowid NOT IN (SELECT MIN(rowid) FROM events GROUP BY seq);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_events_unique_seq ON events(seq);
        CREATE TABLE IF NOT EXISTS event_sequence (
            singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
            last_seq INTEGER NOT NULL
        );
        INSERT OR IGNORE INTO event_sequence(singleton, last_seq)
        VALUES(1, (SELECT COALESCE(MAX(seq), 0) FROM events));
        UPDATE event_sequence
        SET last_seq = MAX(last_seq, (SELECT COALESCE(MAX(seq), 0) FROM events))
        WHERE singleton = 1;
        CREATE TABLE IF NOT EXISTS command_receipt_events (
            method TEXT NOT NULL,
            client_request_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            seq INTEGER NOT NULL UNIQUE,
            PRIMARY KEY(method, client_request_id, ordinal),
            FOREIGN KEY(method, client_request_id)
                REFERENCES command_receipts(method, client_request_id)
                ON DELETE CASCADE
        );
        """),
        SchemaStep(34, """
        ALTER TABLE agent_threads
        ADD COLUMN interaction_mode TEXT NOT NULL DEFAULT 'default';
        """),
        SchemaStep(35, """
        ALTER TABLE agent_messages
        ADD COLUMN attachments_json TEXT NOT NULL DEFAULT '[]';
        """),
        SchemaStep(36, """
        CREATE TABLE IF NOT EXISTS agent_thread_drafts (
            thread_id TEXT PRIMARY KEY,
            provider_instance_id TEXT NOT NULL,
            text TEXT NOT NULL DEFAULT '',
            attachments_json TEXT NOT NULL DEFAULT '[]',
            interaction_mode TEXT NOT NULL DEFAULT 'default',
            updated_at TEXT NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        """),
        SchemaStep(37, """
        ALTER TABLE agent_queued_messages ADD COLUMN lease_id TEXT;
        ALTER TABLE agent_queued_messages ADD COLUMN lease_started_at TEXT;
        CREATE INDEX IF NOT EXISTS idx_agent_queued_messages_lease
        ON agent_queued_messages(thread_id, lease_id, lease_started_at, position, created_at);
        """),
        SchemaStep(38, """
        CREATE TABLE agent_thread_drafts_v38 (
            thread_id TEXT NOT NULL,
            provider_instance_id TEXT NOT NULL,
            text TEXT NOT NULL DEFAULT '',
            attachments_json TEXT NOT NULL DEFAULT '[]',
            interaction_mode TEXT NOT NULL DEFAULT 'default',
            updated_at TEXT NOT NULL,
            PRIMARY KEY(thread_id, provider_instance_id),
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        INSERT INTO agent_thread_drafts_v38(
            thread_id, provider_instance_id, text, attachments_json, interaction_mode, updated_at
        )
        SELECT thread_id, provider_instance_id, text, attachments_json, interaction_mode, updated_at
        FROM agent_thread_drafts;
        DROP TABLE agent_thread_drafts;
        ALTER TABLE agent_thread_drafts_v38 RENAME TO agent_thread_drafts;
        """),
        SchemaStep(39, """
        ALTER TABLE agent_queued_messages
        ADD COLUMN dispatch_state TEXT NOT NULL DEFAULT 'queued';
        ALTER TABLE agent_queued_messages
        ADD COLUMN dispatch_run_id TEXT;
        ALTER TABLE agent_queued_messages
        ADD COLUMN dispatch_updated_at TEXT;
        CREATE INDEX IF NOT EXISTS idx_agent_queued_messages_dispatch
        ON agent_queued_messages(thread_id, dispatch_state, position, created_at);
        """),
        SchemaStep(40, """
        CREATE TABLE IF NOT EXISTS agent_thread_fork_intents (
            child_thread_id TEXT PRIMARY KEY,
            source_thread_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            idempotency_key TEXT NOT NULL UNIQUE,
            state TEXT NOT NULL,
            child_thread_json TEXT NOT NULL,
            source_messages_json TEXT NOT NULL,
            provider_child_thread_id TEXT,
            last_error TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_agent_thread_fork_intents_state
        ON agent_thread_fork_intents(state, updated_at);
        """),
        SchemaStep(41, """
        ALTER TABLE provider_session_runtime ADD COLUMN last_run_id TEXT;
        """),
        SchemaStep(42, """
        CREATE TABLE IF NOT EXISTS agent_thread_undo_gc_pins (
            owner_id TEXT PRIMARY KEY,
            attachments_json TEXT NOT NULL DEFAULT '[]',
            opaque_payload TEXT NOT NULL DEFAULT '',
            expires_at TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_agent_thread_undo_gc_pins_expiry
        ON agent_thread_undo_gc_pins(expires_at);
        """),
        SchemaStep(43, """
        ALTER TABLE agent_threads
        ADD COLUMN run_as_user_json TEXT;
        """),
        SchemaStep(44, """
        CREATE TABLE IF NOT EXISTS scheduled_tasks (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            prompt TEXT NOT NULL,
            workspace_id TEXT NOT NULL,
            workspace_path_snapshot TEXT NOT NULL,
            run_as_user TEXT NOT NULL,
            run_as_uid INTEGER NOT NULL,
            provider TEXT NOT NULL,
            provider_instance_id TEXT NOT NULL,
            model TEXT NOT NULL,
            reasoning_effort TEXT NOT NULL,
            recurrence_json TEXT NOT NULL,
            timezone_id TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            next_run_at TEXT,
            last_run_at TEXT,
            lease_owner TEXT,
            lease_expires_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_scheduled_tasks_due
        ON scheduled_tasks(enabled, next_run_at, lease_expires_at);

        CREATE TABLE IF NOT EXISTS scheduled_task_runs (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            occurrence_key TEXT NOT NULL UNIQUE,
            trigger TEXT NOT NULL,
            scheduled_at TEXT NOT NULL,
            queued_at TEXT NOT NULL,
            started_at TEXT,
            finished_at TEXT,
            status TEXT NOT NULL,
            thread_id TEXT,
            agent_run_id TEXT,
            error_code TEXT,
            error_summary TEXT,
            lease_owner TEXT,
            heartbeat_at TEXT,
            created_at TEXT NOT NULL,
            FOREIGN KEY(task_id) REFERENCES scheduled_tasks(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_scheduled_task_runs_task
        ON scheduled_task_runs(task_id, queued_at DESC);
        CREATE INDEX IF NOT EXISTS idx_scheduled_task_runs_status
        ON scheduled_task_runs(status, queued_at);
        """),
        SchemaStep(45, """
        CREATE TABLE IF NOT EXISTS token_saver_attempts (
            id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            adapter_version TEXT NOT NULL,
            provider_version TEXT NOT NULL,
            model TEXT NOT NULL,
            cache_state TEXT NOT NULL,
            language TEXT NOT NULL,
            hardware_class TEXT NOT NULL,
            workload TEXT NOT NULL,
            task_class TEXT NOT NULL,
            evidence_level TEXT NOT NULL,
            unavailable_fields_json TEXT NOT NULL DEFAULT '[]',
            created_at_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_attempts_run ON token_saver_attempts(run_id, created_at_ms);

        CREATE TABLE IF NOT EXISTS token_saver_attempt_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            attempt_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            FOREIGN KEY(attempt_id) REFERENCES token_saver_attempts(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_attempt_events_attempt ON token_saver_attempt_events(attempt_id, id);

        CREATE TABLE IF NOT EXISTS token_saver_input_components (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            attempt_id TEXT NOT NULL,
            category TEXT NOT NULL,
            tokens INTEGER NOT NULL,
            cost_micros INTEGER NOT NULL,
            created_at_ms INTEGER NOT NULL,
            FOREIGN KEY(attempt_id) REFERENCES token_saver_attempts(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_input_components_attempt ON token_saver_input_components(attempt_id, category);

        CREATE TABLE IF NOT EXISTS token_saver_recovery_objects (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            attempt_id TEXT NOT NULL,
            integrity_sha256 TEXT NOT NULL,
            original BLOB NOT NULL,
            byte_count INTEGER NOT NULL,
            state TEXT NOT NULL,
            expires_at_ms INTEGER,
            tombstoned_at_ms INTEGER,
            created_at_ms INTEGER NOT NULL,
            last_access_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_recovery_scope
        ON token_saver_recovery_objects(workspace_id, project_id, thread_id, provider, attempt_id);
        CREATE INDEX IF NOT EXISTS idx_token_saver_recovery_expiry
        ON token_saver_recovery_objects(expires_at_ms, tombstoned_at_ms);

        CREATE TABLE IF NOT EXISTS token_saver_recovery_capabilities (
            capability_hash TEXT PRIMARY KEY,
            object_id TEXT NOT NULL,
            revoked_at_ms INTEGER,
            created_at_ms INTEGER NOT NULL,
            FOREIGN KEY(object_id) REFERENCES token_saver_recovery_objects(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_recovery_capability_object
        ON token_saver_recovery_capabilities(object_id);

        CREATE TABLE IF NOT EXISTS token_saver_recovery_outbox (
            object_id TEXT PRIMARY KEY,
            state TEXT NOT NULL,
            transport_outcome TEXT NOT NULL,
            idempotency_key TEXT NOT NULL UNIQUE,
            updated_at_ms INTEGER NOT NULL,
            FOREIGN KEY(object_id) REFERENCES token_saver_recovery_objects(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS token_saver_recovery_references (
            id TEXT PRIMARY KEY,
            object_id TEXT NOT NULL,
            owner_kind TEXT NOT NULL,
            owner_id TEXT NOT NULL,
            expires_at_ms INTEGER,
            created_at_ms INTEGER NOT NULL,
            FOREIGN KEY(object_id) REFERENCES token_saver_recovery_objects(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_recovery_references_owner
        ON token_saver_recovery_references(owner_kind, owner_id);

        CREATE TABLE IF NOT EXISTS token_saver_lane_state (
            project_id TEXT NOT NULL,
            lane TEXT NOT NULL,
            state TEXT NOT NULL,
            reason TEXT NOT NULL,
            evidence_level TEXT NOT NULL,
            owner_role TEXT NOT NULL,
            permission_boundary TEXT NOT NULL,
            retention_days INTEGER NOT NULL,
            opted_out INTEGER NOT NULL,
            kill_switch_active INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY(project_id, lane)
        );

        CREATE TABLE IF NOT EXISTS token_saver_owner_signoffs (
            role TEXT PRIMARY KEY,
            owner_name TEXT NOT NULL,
            signed_at_ms INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS token_saver_session_learn_records (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            project_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            attempt_id TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            expires_at_ms INTEGER,
            tombstoned_at_ms INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_session_learn_scope
        ON token_saver_session_learn_records(workspace_id, project_id, thread_id, provider, attempt_id);

        CREATE TABLE IF NOT EXISTS token_saver_rollover_capsules (
            id TEXT PRIMARY KEY,
            parent_thread_id TEXT NOT NULL,
            child_thread_id TEXT NOT NULL,
            scope_transition_json TEXT,
            capsule_sha256 TEXT NOT NULL,
            capsule_text TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS token_saver_audit_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_kind TEXT NOT NULL,
            project_id TEXT,
            thread_id TEXT,
            attempt_id TEXT,
            object_id TEXT,
            count_value INTEGER,
            reason TEXT,
            created_at_ms INTEGER NOT NULL
        );
        """),
        SchemaStep(46, """
        ALTER TABLE token_saver_recovery_objects
        ADD COLUMN operation_id TEXT;
        ALTER TABLE token_saver_recovery_objects
        ADD COLUMN lane TEXT NOT NULL DEFAULT 'semantic_prose';
        ALTER TABLE token_saver_session_learn_records
        ADD COLUMN lane TEXT NOT NULL DEFAULT 'session_learn';
        CREATE UNIQUE INDEX IF NOT EXISTS idx_token_saver_recovery_operation
        ON token_saver_recovery_objects(
            workspace_id, project_id, thread_id, provider, attempt_id, operation_id
        ) WHERE operation_id IS NOT NULL;
        """),
        SchemaStep(47, """
        ALTER TABLE token_saver_recovery_objects
        ADD COLUMN invocation_id TEXT;
        DROP INDEX IF EXISTS idx_token_saver_recovery_operation;
        CREATE UNIQUE INDEX IF NOT EXISTS idx_token_saver_recovery_invocation
        ON token_saver_recovery_objects(
            workspace_id, project_id, thread_id, provider, attempt_id, invocation_id
        ) WHERE invocation_id IS NOT NULL;

        ALTER TABLE token_saver_lane_state
        ADD COLUMN attribution_joined INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE token_saver_lane_state
        ADD COLUMN reconciliation_passed INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE token_saver_lane_state
        ADD COLUMN usage_semantics_available INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE token_saver_lane_state
        ADD COLUMN scorecard_id TEXT NOT NULL DEFAULT '';
        """),
        SchemaStep(48, """
        CREATE TABLE IF NOT EXISTS agent_thread_routing (
            thread_id TEXT PRIMARY KEY,
            mode TEXT NOT NULL CHECK(mode IN ('manual', 'auto')),
            configuration_json TEXT NOT NULL,
            revision INTEGER NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS agent_queued_message_routing (
            queued_message_id TEXT PRIMARY KEY,
            configuration_json TEXT NOT NULL,
            revision INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(queued_message_id) REFERENCES agent_queued_messages(id) ON DELETE CASCADE
        );
        """),
        SchemaStep(49, """
        ALTER TABLE agent_queued_message_routing ADD COLUMN deadline_at TEXT;
        ALTER TABLE agent_queued_message_routing ADD COLUMN budget_tokens INTEGER;
        ALTER TABLE agent_queued_message_routing ADD COLUMN budget_cost_micros INTEGER;
        ALTER TABLE agent_queued_message_routing ADD COLUMN reservation_id TEXT;
        ALTER TABLE agent_queued_message_routing ADD COLUMN reserved_tokens INTEGER;
        ALTER TABLE agent_queued_message_routing ADD COLUMN reserved_cost_micros INTEGER;
        ALTER TABLE agent_queued_message_routing ADD COLUMN admission_receipt_id TEXT;
        """),
        SchemaStep(50, """
        CREATE TABLE IF NOT EXISTS storage_usage_counters (
            storage_class TEXT PRIMARY KEY,
            payload_bytes INTEGER NOT NULL DEFAULT 0
        );
        INSERT OR REPLACE INTO storage_usage_counters(storage_class, payload_bytes)
        SELECT 'stream_events', COALESCE(SUM(
            LENGTH(CAST(event_kind AS BLOB)) + LENGTH(CAST(payload_json AS BLOB))
        ), 0) FROM agent_stream_events;
        INSERT OR REPLACE INTO storage_usage_counters(storage_class, payload_bytes)
        SELECT 'provider_logs', COALESCE(SUM(
            LENGTH(CAST(source AS BLOB)) + LENGTH(CAST(method AS BLOB)) + LENGTH(CAST(payload_json AS BLOB))
        ), 0) FROM agent_provider_event_logs;

        CREATE TRIGGER IF NOT EXISTS trg_stream_usage_insert
        AFTER INSERT ON agent_stream_events BEGIN
            UPDATE storage_usage_counters
            SET payload_bytes = payload_bytes + LENGTH(CAST(NEW.event_kind AS BLOB)) + LENGTH(CAST(NEW.payload_json AS BLOB))
            WHERE storage_class = 'stream_events';
        END;
        CREATE TRIGGER IF NOT EXISTS trg_stream_usage_delete
        AFTER DELETE ON agent_stream_events BEGIN
            UPDATE storage_usage_counters
            SET payload_bytes = MAX(0, payload_bytes - LENGTH(CAST(OLD.event_kind AS BLOB)) - LENGTH(CAST(OLD.payload_json AS BLOB)))
            WHERE storage_class = 'stream_events';
        END;
        CREATE TRIGGER IF NOT EXISTS trg_provider_usage_insert
        AFTER INSERT ON agent_provider_event_logs BEGIN
            UPDATE storage_usage_counters
            SET payload_bytes = payload_bytes + LENGTH(CAST(NEW.source AS BLOB)) + LENGTH(CAST(NEW.method AS BLOB)) + LENGTH(CAST(NEW.payload_json AS BLOB))
            WHERE storage_class = 'provider_logs';
        END;
        CREATE TRIGGER IF NOT EXISTS trg_provider_usage_delete
        AFTER DELETE ON agent_provider_event_logs BEGIN
            UPDATE storage_usage_counters
            SET payload_bytes = MAX(0, payload_bytes - LENGTH(CAST(OLD.source AS BLOB)) - LENGTH(CAST(OLD.method AS BLOB)) - LENGTH(CAST(OLD.payload_json AS BLOB)))
            WHERE storage_class = 'provider_logs';
        END;
        """),
        SchemaStep(51, """
        ALTER TABLE scheduled_tasks
        ADD COLUMN routing_mode TEXT NOT NULL DEFAULT 'manual'
            CHECK(routing_mode IN ('manual', 'auto'));
        """),
        // Repair factory deterministic_wrapper rows seeded with retention_days=0
        // (and kill_switch=1) before Token Saver store-before-loss could durable-
        // readback. INSERT OR IGNORE never upgrades those rows; without this
        // migration every ensureDefaults install stays permanently verbatim.
        SchemaStep(52, """
        UPDATE token_saver_lane_state
        SET retention_days = 7,
            kill_switch_active = 0
        WHERE lane = 'deterministic_wrapper'
          AND reason = 'owner_and_scorecard_required'
          AND opted_out = 0
          AND retention_days = 0
          AND kill_switch_active = 1;
        """),
        // Daily credible economy vs bare agent. Week UI = SUM(total_credible).
        // Past days without a row stay measured-only (no retroactive rewrite).
        SchemaStep(53, """
        CREATE TABLE IF NOT EXISTS token_saver_daily_economy (
            day_start_ms INTEGER PRIMARY KEY,
            measured_tokens INTEGER NOT NULL,
            dialect_tokens INTEGER NOT NULL,
            graphify_tokens INTEGER NOT NULL,
            orchestration_tokens INTEGER NOT NULL DEFAULT 0,
            total_credible INTEGER NOT NULL,
            window_usage_tokens INTEGER NOT NULL,
            formula_version TEXT NOT NULL,
            applied_output_share REAL NOT NULL,
            graphify_signal_count INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_token_saver_daily_economy_updated
            ON token_saver_daily_economy(updated_at);
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
        // Finalize the schema-version read before a pending migration rebuilds
        // or drops a table. An active sqlite statement holds a schema read lock.
        stmt.reset()
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
