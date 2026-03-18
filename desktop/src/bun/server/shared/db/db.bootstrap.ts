import type { Database } from "bun:sqlite";

const chatsCreateSql = `
	CREATE TABLE IF NOT EXISTS chats (
		id TEXT PRIMARY KEY,
		projectId TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
		title TEXT NOT NULL,
		provider TEXT NOT NULL CHECK(provider IN ('fake', 'codex', 'claude')),
		providerThreadId TEXT,
		status TEXT NOT NULL CHECK(status IN ('pending', 'running', 'completed', 'failed')),
		isActive INTEGER NOT NULL DEFAULT 0,
		diffAdded INTEGER NOT NULL DEFAULT 0,
		diffRemoved INTEGER NOT NULL DEFAULT 0,
		updatedAt TEXT NOT NULL
	)
`;

const terminalCommandsCreateSql = `
	CREATE TABLE IF NOT EXISTS terminal_commands (
		id TEXT PRIMARY KEY,
		chatId TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
		command TEXT NOT NULL,
		shell TEXT NOT NULL,
		cwd TEXT NOT NULL,
		status TEXT NOT NULL CHECK(status IN ('running', 'completed', 'failed', 'timeout')),
		exitCode INTEGER,
		durationMs INTEGER,
		startedAt TEXT NOT NULL,
		finishedAt TEXT
	)
`;

const terminalEntriesCreateSql = `
	CREATE TABLE IF NOT EXISTS terminal_entries (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		commandId TEXT NOT NULL REFERENCES terminal_commands(id) ON DELETE CASCADE,
		chatId TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
		stream TEXT NOT NULL CHECK(stream IN ('stdout', 'stderr')),
		data TEXT NOT NULL,
		createdAt TEXT NOT NULL
	)
`;

const workspaceEventsCreateSql = `
	CREATE TABLE IF NOT EXISTS workspace_events (
		seq INTEGER PRIMARY KEY AUTOINCREMENT,
		type TEXT NOT NULL,
		payload TEXT NOT NULL,
		originClientId TEXT,
		requestId TEXT,
		createdAt TEXT NOT NULL
	)
`;

const chatStreamSnapshotsCreateSql = `
	CREATE TABLE IF NOT EXISTS chat_stream_snapshots (
		chatId TEXT PRIMARY KEY REFERENCES chats(id) ON DELETE CASCADE,
		partialText TEXT NOT NULL DEFAULT '',
		updatedAt TEXT NOT NULL
	)
`;

const chatStreamEventsCreateSql = `
	CREATE TABLE IF NOT EXISTS chat_stream_events (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		chatId TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
		eventJson TEXT NOT NULL,
		turnId TEXT NOT NULL,
		createdAt TEXT NOT NULL
	)
`;

const chatTurnSnapshotsCreateSql = `
	CREATE TABLE IF NOT EXISTS chat_turn_snapshots (
		turnId TEXT PRIMARY KEY,
		chatId TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
		anchorMessageId TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
		payloadJson TEXT NOT NULL,
		createdAt TEXT NOT NULL,
		updatedAt TEXT NOT NULL
	)
`;

const serverMetadataCreateSql = `
	CREATE TABLE IF NOT EXISTS server_metadata (
		key TEXT PRIMARY KEY,
		value TEXT NOT NULL,
		updatedAt TEXT NOT NULL
	)
`;

const liveActivitySubscriptionsCreateSql = `
	CREATE TABLE IF NOT EXISTS live_activity_subscriptions (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		chatId TEXT NOT NULL,
		chatTitle TEXT,
		pushToken TEXT NOT NULL,
		pushTokenType TEXT NOT NULL CHECK(pushTokenType IN ('apns', 'fcm')),
		liveActivityToken TEXT NOT NULL,
		updatedAt TEXT NOT NULL
	)
`;

export class DatabaseBootstrap {
	static initialize(database: Database): void {
		this.enableForeignKeys(database);
		this.setJournalMode(database);
		this.createProjectsTable(database);
		this.createOrMigrateChatsTable(database);
		this.createMessagesTable(database);
		this.createWorkspaceSelectionTable(database);
		this.createTerminalCommandsTable(database);
		this.createOrMigrateTerminalEntriesTable(database);
		this.createWorkspaceEventsTable(database);
		this.createChatStreamSnapshotsTable(database);
		this.createChatStreamEventsTable(database);
		this.createChatTurnSnapshotsTable(database);
		this.createServerMetadataTable(database);
		this.createOrMigrateLiveActivitySubscriptionsTable(database);
		this.createPushToStartTokensTable(database);
		this.dropLegacyTerminalSessionsTable(database);
		this.createIndexes(database);
	}

	private static enableForeignKeys(database: Database): void {
		database.exec("PRAGMA foreign_keys = ON;");
	}

	private static setJournalMode(database: Database): void {
		database.exec("PRAGMA journal_mode = WAL;");
	}

	private static createProjectsTable(database: Database): void {
		database.exec(`
			CREATE TABLE IF NOT EXISTS projects (
				id TEXT PRIMARY KEY,
				name TEXT NOT NULL,
				path TEXT NOT NULL UNIQUE,
				isFavorite INTEGER NOT NULL DEFAULT 0,
				createdAt TEXT NOT NULL,
				updatedAt TEXT NOT NULL
			)
		`);
	}

	private static createOrMigrateChatsTable(database: Database): void {
		if (!this.hasTable(database, "chats")) {
			database.exec(chatsCreateSql);
			return;
		}

		if (!this.needsChatsMigration(database)) {
			return;
		}

		this.rebuildChatsTable(database);
	}

	private static hasTable(database: Database, tableName: string): boolean {
		const result = database
			.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?")
			.get(tableName) as { name?: string } | null;

		return result?.name === tableName;
	}

	private static getTableDefinition(database: Database, tableName: string): string {
		const result = database
			.prepare("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?")
			.get(tableName) as { sql?: string } | null;

		return result?.sql ?? "";
	}

	private static hasColumn(database: Database, tableName: string, columnName: string): boolean {
		const rows = database.prepare(`PRAGMA table_info(${tableName})`).all() as Array<{ name?: string }>;
		return rows.some((row) => row.name === columnName);
	}

	private static needsChatsMigration(database: Database): boolean {
		const hasThreadColumn = this.hasColumn(database, "chats", "providerThreadId");
		const hasIsActiveColumn = this.hasColumn(database, "chats", "isActive");
		const createSql = this.getTableDefinition(database, "chats");
		const hasLegacyProviderConstraint = createSql.includes("CHECK(provider = 'fake')");
		const missingClaudeProvider = !createSql.includes("'claude'");
		return hasLegacyProviderConstraint || missingClaudeProvider || !hasThreadColumn || !hasIsActiveColumn;
	}

	private static rebuildChatsTable(database: Database): void {
		const hasThreadColumn = this.hasColumn(database, "chats", "providerThreadId");
		const hasIsActiveColumn = this.hasColumn(database, "chats", "isActive");
		const threadSelection = hasThreadColumn ? "providerThreadId" : "NULL";
		const isActiveSelection = hasIsActiveColumn
			? "COALESCE(isActive, CASE WHEN status = 'running' THEN 1 ELSE 0 END)"
			: "CASE WHEN status = 'running' THEN 1 ELSE 0 END";

		database.exec("PRAGMA foreign_keys = OFF;");
		database.exec("BEGIN;");

		try {
			database.exec(`
				CREATE TABLE chats_next (
					id TEXT PRIMARY KEY,
					projectId TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
					title TEXT NOT NULL,
					provider TEXT NOT NULL CHECK(provider IN ('fake', 'codex', 'claude')),
					providerThreadId TEXT,
					status TEXT NOT NULL CHECK(status IN ('pending', 'running', 'completed', 'failed')),
					isActive INTEGER NOT NULL DEFAULT 0,
					diffAdded INTEGER NOT NULL DEFAULT 0,
					diffRemoved INTEGER NOT NULL DEFAULT 0,
					updatedAt TEXT NOT NULL
				)
			`);

			database.exec(`
				INSERT INTO chats_next (
					id,
					projectId,
					title,
					provider,
					providerThreadId,
					status,
					isActive,
					diffAdded,
					diffRemoved,
					updatedAt
				)
				SELECT
					id,
					projectId,
					title,
					CASE
						WHEN provider IN ('fake', 'codex', 'claude') THEN provider
						ELSE 'fake'
					END,
					${threadSelection},
					status,
					${isActiveSelection},
					COALESCE(diffAdded, 0),
					COALESCE(diffRemoved, 0),
					updatedAt
				FROM chats
			`);

			database.exec("DROP TABLE chats;");
			database.exec("ALTER TABLE chats_next RENAME TO chats;");
			database.exec("COMMIT;");
		} catch (error) {
			database.exec("ROLLBACK;");
			throw error;
		} finally {
			database.exec("PRAGMA foreign_keys = ON;");
		}

		const foreignKeyViolations = database.prepare("PRAGMA foreign_key_check").all() as unknown[];
		if (foreignKeyViolations.length > 0) {
			throw new Error("foreign key integrity check failed after chats schema migration");
		}
	}

	private static createMessagesTable(database: Database): void {
		database.exec(`
			CREATE TABLE IF NOT EXISTS messages (
				id TEXT PRIMARY KEY,
				chatId TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
				role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
				content TEXT NOT NULL,
				createdAt TEXT NOT NULL
			)
		`);
	}

	private static createWorkspaceSelectionTable(database: Database): void {
		database.exec(`
			CREATE TABLE IF NOT EXISTS workspace_selection (
				id TEXT PRIMARY KEY,
				selectedProjectId TEXT REFERENCES projects(id) ON DELETE SET NULL,
				selectedChatId TEXT REFERENCES chats(id) ON DELETE SET NULL,
				permissionMode TEXT,
				selectedModel TEXT,
				selectedReasoningEffort TEXT,
				updatedAt TEXT NOT NULL
			)
		`);
		this.ensureWorkspaceSelectionColumns(database);
	}

	private static ensureWorkspaceSelectionColumns(database: Database): void {
		if (!this.hasColumn(database, "workspace_selection", "permissionMode")) {
			database.exec("ALTER TABLE workspace_selection ADD COLUMN permissionMode TEXT");
		}

		if (!this.hasColumn(database, "workspace_selection", "selectedModel")) {
			database.exec("ALTER TABLE workspace_selection ADD COLUMN selectedModel TEXT");
		}

		if (!this.hasColumn(database, "workspace_selection", "selectedReasoningEffort")) {
			database.exec("ALTER TABLE workspace_selection ADD COLUMN selectedReasoningEffort TEXT");
		}

		if (!this.hasColumn(database, "workspace_selection", "selectedProvider")) {
			database.exec("ALTER TABLE workspace_selection ADD COLUMN selectedProvider TEXT");
		}
	}

	private static createTerminalCommandsTable(database: Database): void {
		database.exec(terminalCommandsCreateSql);
	}

	private static createOrMigrateTerminalEntriesTable(database: Database): void {
		if (!this.hasTable(database, "terminal_entries")) {
			database.exec(terminalEntriesCreateSql);
			return;
		}

		const hasCommandId = this.hasColumn(database, "terminal_entries", "commandId");
		const hasStream = this.hasColumn(database, "terminal_entries", "stream");

		if (hasCommandId && hasStream) {
			return;
		}

		database.exec("PRAGMA foreign_keys = OFF;");
		database.exec("BEGIN;");

		try {
			database.exec(`
				CREATE TABLE terminal_entries_next (
					id INTEGER PRIMARY KEY AUTOINCREMENT,
					commandId TEXT NOT NULL REFERENCES terminal_commands(id) ON DELETE CASCADE,
					chatId TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
					stream TEXT NOT NULL CHECK(stream IN ('stdout', 'stderr')),
					data TEXT NOT NULL,
					createdAt TEXT NOT NULL
				)
			`);

			database.exec("DROP TABLE terminal_entries;");
			database.exec("ALTER TABLE terminal_entries_next RENAME TO terminal_entries;");
			database.exec("COMMIT;");
		} catch (error) {
			database.exec("ROLLBACK;");
			throw error;
		} finally {
			database.exec("PRAGMA foreign_keys = ON;");
		}
	}

	private static createWorkspaceEventsTable(database: Database): void {
		database.exec(workspaceEventsCreateSql);
	}

	private static createChatStreamSnapshotsTable(database: Database): void {
		database.exec(chatStreamSnapshotsCreateSql);
	}

	private static createChatStreamEventsTable(database: Database): void {
		database.exec(chatStreamEventsCreateSql);
	}

	private static createChatTurnSnapshotsTable(database: Database): void {
		database.exec(chatTurnSnapshotsCreateSql);
	}

	private static createServerMetadataTable(database: Database): void {
		database.exec(serverMetadataCreateSql);
	}

	private static needsLiveActivitySubscriptionsMigration(database: Database): boolean {
		if (!this.hasTable(database, "live_activity_subscriptions")) {
			return false;
		}

		const createSql = this.getTableDefinition(database, "live_activity_subscriptions");
		return createSql.includes("REFERENCES chats(id) ON DELETE CASCADE")
			|| createSql.includes("idx_live_activity_subscriptions_token_pair(chatId, pushTokenType, pushToken, liveActivityToken)");
	}

	private static rebuildLiveActivitySubscriptionsTable(database: Database): void {
		type LegacySubscriptionRow = {
			chatId: string;
			chatTitle: string | null;
			id: number;
			liveActivityToken: string;
			pushToken: string;
			pushTokenType: string;
			updatedAt: string;
		};

		const rows = database
			.prepare(`
				SELECT id, chatId, chatTitle, pushToken, pushTokenType, liveActivityToken, updatedAt
				FROM live_activity_subscriptions
				ORDER BY updatedAt DESC, id DESC
			`)
			.all() as LegacySubscriptionRow[];
		const uniqueRows: LegacySubscriptionRow[] = [];
		const seenTokenPairs = new Set<string>();
		for (const row of rows) {
			const tokenPairKey = `${row.pushTokenType}::${row.pushToken}::${row.liveActivityToken}`;
			if (seenTokenPairs.has(tokenPairKey)) {
				continue;
			}

			seenTokenPairs.add(tokenPairKey);
			uniqueRows.push(row);
		}

		database.exec("PRAGMA foreign_keys = OFF;");
		database.exec("BEGIN;");

		try {
			database.exec(`
				CREATE TABLE live_activity_subscriptions_next (
					id INTEGER PRIMARY KEY AUTOINCREMENT,
					chatId TEXT NOT NULL,
					chatTitle TEXT,
					pushToken TEXT NOT NULL,
					pushTokenType TEXT NOT NULL CHECK(pushTokenType IN ('apns', 'fcm')),
					liveActivityToken TEXT NOT NULL,
					updatedAt TEXT NOT NULL
				)
			`);

			const insertStatement = database.prepare(`
				INSERT INTO live_activity_subscriptions_next (
					chatId,
					chatTitle,
					pushToken,
					pushTokenType,
					liveActivityToken,
					updatedAt
				) VALUES (?, ?, ?, ?, ?, ?)
			`);
			for (const row of uniqueRows) {
				insertStatement.run(
					row.chatId,
					row.chatTitle,
					row.pushToken,
					row.pushTokenType,
					row.liveActivityToken,
					row.updatedAt,
				);
			}

			database.exec("DROP TABLE live_activity_subscriptions;");
			database.exec("ALTER TABLE live_activity_subscriptions_next RENAME TO live_activity_subscriptions;");
			database.exec("COMMIT;");
		} catch (error) {
			database.exec("ROLLBACK;");
			throw error;
		} finally {
			database.exec("PRAGMA foreign_keys = ON;");
		}
	}

	private static createOrMigrateLiveActivitySubscriptionsTable(database: Database): void {
		if (!this.hasTable(database, "live_activity_subscriptions")) {
			database.exec(liveActivitySubscriptionsCreateSql);
			return;
		}

		if (this.needsLiveActivitySubscriptionsMigration(database)) {
			this.rebuildLiveActivitySubscriptionsTable(database);
		}

		database.exec(liveActivitySubscriptionsCreateSql);
	}

	private static createPushToStartTokensTable(database: Database): void {
		database.exec(`
			CREATE TABLE IF NOT EXISTS push_to_start_tokens (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				pushToStartToken TEXT NOT NULL,
				pushToken TEXT NOT NULL,
				pushTokenType TEXT NOT NULL CHECK(pushTokenType IN ('apns', 'fcm')),
				updatedAt TEXT NOT NULL
			)
		`);
	}

	private static dropLegacyTerminalSessionsTable(database: Database): void {
		if (!this.hasTable(database, "terminal_sessions")) {
			return;
		}

		database.exec("PRAGMA foreign_keys = OFF;");
		database.exec("DROP TABLE terminal_sessions;");
		database.exec("PRAGMA foreign_keys = ON;");
	}

	private static createIndexes(database: Database): void {
		database.exec("CREATE INDEX IF NOT EXISTS idx_projects_path ON projects(path)");
		database.exec("CREATE INDEX IF NOT EXISTS idx_chats_project ON chats(projectId, updatedAt DESC)");
		database.exec("CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chatId, createdAt ASC)");
		database.exec(
			"CREATE INDEX IF NOT EXISTS idx_workspace_selection_project ON workspace_selection(selectedProjectId)",
		);
		database.exec(
			"CREATE INDEX IF NOT EXISTS idx_terminal_commands_chat_id_desc ON terminal_commands(chatId, id DESC)",
		);
		database.exec(
			"CREATE INDEX IF NOT EXISTS idx_terminal_entries_chat_id ON terminal_entries(chatId, id ASC)",
		);
		database.exec(
			"CREATE INDEX IF NOT EXISTS idx_terminal_entries_command_id ON terminal_entries(commandId, id ASC)",
		);
		database.exec("CREATE INDEX IF NOT EXISTS idx_workspace_events_seq ON workspace_events(seq ASC)");
		database.exec("CREATE INDEX IF NOT EXISTS idx_workspace_events_created_at ON workspace_events(createdAt ASC)");
		database.exec(
			"CREATE INDEX IF NOT EXISTS idx_chat_stream_snapshots_updated_at ON chat_stream_snapshots(updatedAt ASC)",
		);
		database.exec(
			"CREATE INDEX IF NOT EXISTS idx_chat_stream_events_chat_id_id ON chat_stream_events(chatId, id ASC)",
		);
		database.exec(
			"CREATE INDEX IF NOT EXISTS idx_chat_stream_events_chat_id_turn_id_id ON chat_stream_events(chatId, turnId, id ASC)",
		);
		database.exec(
			"CREATE INDEX IF NOT EXISTS idx_chat_turn_snapshots_chat_anchor ON chat_turn_snapshots(chatId, anchorMessageId, createdAt ASC)",
		);
		database.exec("CREATE INDEX IF NOT EXISTS idx_server_metadata_updated_at ON server_metadata(updatedAt DESC)");
		database.exec(
			"CREATE INDEX IF NOT EXISTS idx_live_activity_subscriptions_chat_id ON live_activity_subscriptions(chatId)",
		);
		database.exec(
			"CREATE INDEX IF NOT EXISTS idx_live_activity_subscriptions_updated_at ON live_activity_subscriptions(updatedAt DESC)",
		);
		database.exec(
			"CREATE UNIQUE INDEX IF NOT EXISTS idx_live_activity_subscriptions_token_pair ON live_activity_subscriptions(pushTokenType, pushToken, liveActivityToken)",
		);
		database.exec(
			"CREATE UNIQUE INDEX IF NOT EXISTS idx_push_to_start_tokens_device ON push_to_start_tokens(pushTokenType, pushToken)",
		);
	}
}

export const initializeDatabaseSchema = (database: Database): void => {
	DatabaseBootstrap.initialize(database);
};
