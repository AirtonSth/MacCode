import type { Database } from "bun:sqlite";

export const initializeDatabaseSchema = (database: Database): void => {
	database.exec("PRAGMA foreign_keys = ON;");
	database.exec("PRAGMA journal_mode = WAL;");
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
	database.exec(`
	CREATE TABLE IF NOT EXISTS chats (
		id TEXT PRIMARY KEY,
		projectId TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
		title TEXT NOT NULL,
		provider TEXT NOT NULL CHECK(provider = 'fake'),
		status TEXT NOT NULL CHECK(status IN ('pending', 'running', 'completed', 'failed')),
		diffAdded INTEGER NOT NULL DEFAULT 0,
		diffRemoved INTEGER NOT NULL DEFAULT 0,
		updatedAt TEXT NOT NULL
	)
	`);
	database.exec(`
	CREATE TABLE IF NOT EXISTS messages (
		id TEXT PRIMARY KEY,
		chatId TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
		role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
		content TEXT NOT NULL,
		createdAt TEXT NOT NULL
	)
	`);
	database.exec("CREATE INDEX IF NOT EXISTS idx_projects_path ON projects(path)");
	database.exec("CREATE INDEX IF NOT EXISTS idx_chats_project ON chats(projectId, updatedAt DESC)");
	database.exec("CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chatId, createdAt ASC)");
}
