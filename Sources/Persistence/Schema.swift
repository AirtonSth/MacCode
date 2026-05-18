import Foundation

public enum SchemaError: Error { case versionMismatch(Int, Int) }

public struct SchemaStep {
    public let version: Int
    public let sql: String
    public init(_ version: Int, _ sql: String) { self.version = version; self.sql = sql }
}

public enum Schema {
    public static let currentVersion: Int = 5

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
        CREATE TABLE IF NOT EXISTS terminal_sessions (
            id TEXT PRIMARY KEY,
            surface_id TEXT NOT NULL,
            workspace_id TEXT,
            cwd TEXT,
            scrollback TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
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
        """)
    ]

    public static func migrate(_ db: SQLiteDB) throws {
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
            try db.execute(step.sql)
            let ins = try db.prepare("INSERT OR IGNORE INTO schema_meta(version, applied_at) VALUES(?, ?);")
            try ins.bind(1, Int64(step.version))
            try ins.bind(2, ISO8601DateFormatter().string(from: Date()))
            _ = try ins.step()
        }
    }
}
