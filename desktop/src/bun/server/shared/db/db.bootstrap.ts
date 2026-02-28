import type { Database } from "bun:sqlite";

const chatsCreateSql = `
	CREATE TABLE IF NOT EXISTS chats (
		id TEXT PRIMARY KEY,
		projectId TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
		title TEXT NOT NULL,
		provider TEXT NOT NULL CHECK(provider IN ('fake', 'codex')),
		providerThreadId TEXT,
		status TEXT NOT NULL CHECK(status IN ('pending', 'running', 'completed', 'failed')),
		diffAdded INTEGER NOT NULL DEFAULT 0,
		diffRemoved INTEGER NOT NULL DEFAULT 0,
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
		const createSql = this.getTableDefinition(database, "chats");
		const hasLegacyProviderConstraint = createSql.includes("CHECK(provider = 'fake')");
		return hasLegacyProviderConstraint || !hasThreadColumn;
	}

	private static rebuildChatsTable(database: Database): void {
		const hasThreadColumn = this.hasColumn(database, "chats", "providerThreadId");
		const threadSelection = hasThreadColumn ? "providerThreadId" : "NULL";

		database.exec("PRAGMA foreign_keys = OFF;");
		database.exec("BEGIN;");

		try {
			database.exec(`
				CREATE TABLE chats_next (
					id TEXT PRIMARY KEY,
					projectId TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
					title TEXT NOT NULL,
					provider TEXT NOT NULL CHECK(provider IN ('fake', 'codex')),
					providerThreadId TEXT,
					status TEXT NOT NULL CHECK(status IN ('pending', 'running', 'completed', 'failed')),
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
					diffAdded,
					diffRemoved,
					updatedAt
				)
				SELECT
					id,
					projectId,
					title,
					CASE
						WHEN provider IN ('fake', 'codex') THEN provider
						ELSE 'fake'
					END,
					${threadSelection},
					status,
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
				updatedAt TEXT NOT NULL
			)
		`);
	}

	private static createIndexes(database: Database): void {
		database.exec("CREATE INDEX IF NOT EXISTS idx_projects_path ON projects(path)");
		database.exec("CREATE INDEX IF NOT EXISTS idx_chats_project ON chats(projectId, updatedAt DESC)");
		database.exec("CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chatId, createdAt ASC)");
		database.exec(
			"CREATE INDEX IF NOT EXISTS idx_workspace_selection_project ON workspace_selection(selectedProjectId)",
		);
	}
}

export const initializeDatabaseSchema = (database: Database): void => {
	DatabaseBootstrap.initialize(database);
};
