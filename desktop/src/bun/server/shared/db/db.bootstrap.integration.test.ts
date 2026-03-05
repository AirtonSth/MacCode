import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { initializeDatabaseSchema } from "./db.bootstrap";
import { createDatabaseClient } from "./db.client";

test("DB initialization creates schema, indices and pragmas for REST terminal model", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-db-init-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);

		const terminalCommandColumns = client.sqlite
			.prepare("PRAGMA table_info(terminal_commands)")
			.all()
			.map((row) => (row as { name: string }).name);

		expect(terminalCommandColumns).toEqual(
			expect.arrayContaining([
				"id",
				"chatId",
				"command",
				"shell",
				"cwd",
				"status",
				"exitCode",
				"durationMs",
				"startedAt",
				"finishedAt",
			]),
		);

			const terminalEntryColumns = client.sqlite
				.prepare("PRAGMA table_info(terminal_entries)")
				.all()
				.map((row) => (row as { name: string }).name);

			expect(terminalEntryColumns).toEqual(
				expect.arrayContaining(["id", "commandId", "chatId", "stream", "data", "createdAt"]),
			);

			const workspaceSelectionColumns = client.sqlite
				.prepare("PRAGMA table_info(workspace_selection)")
				.all()
				.map((row) => (row as { name: string }).name);

			expect(workspaceSelectionColumns).toEqual(
				expect.arrayContaining([
					"id",
					"selectedProjectId",
					"selectedChatId",
					"permissionMode",
					"selectedModel",
					"selectedReasoningEffort",
					"updatedAt",
				]),
			);

		const chatStreamSnapshotColumns = client.sqlite
			.prepare("PRAGMA table_info(chat_stream_snapshots)")
			.all()
			.map((row) => (row as { name: string }).name);

		expect(chatStreamSnapshotColumns).toEqual(
			expect.arrayContaining(["chatId", "partialText", "updatedAt"]),
		);

		const chatStreamEventColumns = client.sqlite
			.prepare("PRAGMA table_info(chat_stream_events)")
			.all()
			.map((row) => (row as { name: string }).name);

		expect(chatStreamEventColumns).toEqual(
			expect.arrayContaining(["id", "chatId", "eventJson", "turnId", "createdAt"]),
		);

		const commandIndexes = client.sqlite
			.prepare("PRAGMA index_list(terminal_commands)")
			.all()
			.map((row) => (row as { name: string }).name);
		expect(commandIndexes).toContain("idx_terminal_commands_chat_id_desc");

		const entryIndexes = client.sqlite
			.prepare("PRAGMA index_list(terminal_entries)")
			.all()
			.map((row) => (row as { name: string }).name);
		expect(entryIndexes).toContain("idx_terminal_entries_chat_id");
		expect(entryIndexes).toContain("idx_terminal_entries_command_id");

		const chatSnapshotIndexes = client.sqlite
			.prepare("PRAGMA index_list(chat_stream_snapshots)")
			.all()
			.map((row) => (row as { name: string }).name);
		expect(chatSnapshotIndexes).toContain("idx_chat_stream_snapshots_updated_at");

		const chatStreamEventIndexes = client.sqlite
			.prepare("PRAGMA index_list(chat_stream_events)")
			.all()
			.map((row) => (row as { name: string }).name);
		expect(chatStreamEventIndexes).toContain("idx_chat_stream_events_chat_id_id");
		expect(chatStreamEventIndexes).toContain("idx_chat_stream_events_chat_id_turn_id_id");

		const chatColumns = client.sqlite
			.prepare("PRAGMA table_info(chats)")
			.all()
			.map((row) => (row as { name: string }).name);
		expect(chatColumns).toContain("isActive");

		expect(
			(client.sqlite.prepare("PRAGMA foreign_keys").get() as { foreign_keys: number }).foreign_keys,
		).toBe(1);
		expect((client.sqlite.prepare("PRAGMA journal_mode").get() as { journal_mode: string }).journal_mode).toBe(
			"wal",
		);

		client.sqlite
			.prepare(
				"INSERT INTO projects (id, name, path, isFavorite, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)",
			)
			.run("p1", "Project", "/tmp/db-bootstrap", 0, "2026-01-01T00:00:00.000Z", "2026-01-01T00:00:00.000Z");
		client.sqlite
			.prepare(
				"INSERT INTO chats (id, projectId, title, provider, providerThreadId, status, diffAdded, diffRemoved, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
			)
			.run("c1", "p1", "chat", "codex", "thread-1", "pending", 0, 0, "2026-01-01T00:00:00.000Z");
		client.sqlite
			.prepare(
				"INSERT INTO terminal_commands (id, chatId, command, shell, cwd, status, exitCode, durationMs, startedAt, finishedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
			)
			.run(
				"cmd-1",
				"c1",
				"echo test",
				"/bin/zsh",
				"/tmp/db-bootstrap",
				"completed",
				0,
				12,
				"2026-01-01T00:00:00.100Z",
				"2026-01-01T00:00:00.112Z",
			);
		client.sqlite
			.prepare(
				"INSERT INTO terminal_entries (commandId, chatId, stream, data, createdAt) VALUES (?, ?, ?, ?, ?)",
			)
			.run("cmd-1", "c1", "stdout", "test\n", "2026-01-01T00:00:00.110Z");

		const persistedTerminalEntry = client.sqlite
			.prepare("SELECT chatId, stream, data FROM terminal_entries WHERE commandId = ?")
			.get("cmd-1") as { chatId: string; stream: string; data: string };
		expect(persistedTerminalEntry.chatId).toBe("c1");
		expect(persistedTerminalEntry.stream).toBe("stdout");
		expect(persistedTerminalEntry.data).toBe("test\n");
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("DB initialization migrates legacy chats schema and preserves data", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-db-migration-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		client.sqlite.exec(`
			CREATE TABLE projects (
				id TEXT PRIMARY KEY,
				name TEXT NOT NULL,
				path TEXT NOT NULL UNIQUE,
				isFavorite INTEGER NOT NULL DEFAULT 0,
				createdAt TEXT NOT NULL,
				updatedAt TEXT NOT NULL
			)
		`);
		client.sqlite.exec(`
			CREATE TABLE chats (
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
		client.sqlite.exec(`
			CREATE TABLE messages (
				id TEXT PRIMARY KEY,
				chatId TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
				role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
				content TEXT NOT NULL,
				createdAt TEXT NOT NULL
			)
		`);
		client.sqlite.exec(`
			CREATE TABLE workspace_selection (
				id TEXT PRIMARY KEY,
				selectedProjectId TEXT REFERENCES projects(id) ON DELETE SET NULL,
				selectedChatId TEXT REFERENCES chats(id) ON DELETE SET NULL,
				updatedAt TEXT NOT NULL
			)
		`);

		client.sqlite
			.prepare(
				"INSERT INTO projects (id, name, path, isFavorite, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)",
			)
			.run("project-1", "Legacy", "/tmp/legacy-db-bootstrap", 0, "2026-01-01T00:00:00.000Z", "2026-01-01T00:00:00.000Z");
		client.sqlite
			.prepare(
				"INSERT INTO chats (id, projectId, title, provider, status, diffAdded, diffRemoved, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
			)
			.run("chat-1", "project-1", "Legacy Chat", "fake", "completed", 9, 2, "2026-01-01T00:00:00.000Z");
		client.sqlite
			.prepare("INSERT INTO messages (id, chatId, role, content, createdAt) VALUES (?, ?, ?, ?, ?)")
			.run("message-1", "chat-1", "assistant", "legacy message", "2026-01-01T00:00:00.000Z");

			initializeDatabaseSchema(client.sqlite);

			const chatColumns = client.sqlite
				.prepare("PRAGMA table_info(chats)")
				.all()
				.map((row) => (row as { name: string }).name);
			expect(chatColumns).toContain("providerThreadId");
			expect(chatColumns).toContain("isActive");

			const workspaceSelectionColumns = client.sqlite
				.prepare("PRAGMA table_info(workspace_selection)")
				.all()
				.map((row) => (row as { name: string }).name);
			expect(workspaceSelectionColumns).toEqual(
				expect.arrayContaining(["permissionMode", "selectedModel", "selectedReasoningEffort"]),
			);

		const migratedChat = client.sqlite
			.prepare("SELECT provider, providerThreadId, isActive, diffAdded, diffRemoved FROM chats WHERE id = ?")
			.get("chat-1") as {
				diffAdded: number;
				diffRemoved: number;
				isActive: number;
				provider: string;
				providerThreadId: string | null;
			};

		expect(migratedChat.provider).toBe("fake");
		expect(migratedChat.providerThreadId).toBeNull();
		expect(migratedChat.isActive).toBe(0);
		expect(migratedChat.diffAdded).toBe(9);
		expect(migratedChat.diffRemoved).toBe(2);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("DB initialization rebuilds legacy terminal tables to REST terminal schema", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-db-terminal-migrate-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		client.sqlite.exec(`
			CREATE TABLE projects (
				id TEXT PRIMARY KEY,
				name TEXT NOT NULL,
				path TEXT NOT NULL UNIQUE,
				isFavorite INTEGER NOT NULL DEFAULT 0,
				createdAt TEXT NOT NULL,
				updatedAt TEXT NOT NULL
			)
		`);
		client.sqlite.exec(`
			CREATE TABLE chats (
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
		client.sqlite.exec(`
			CREATE TABLE messages (
				id TEXT PRIMARY KEY,
				chatId TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
				role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
				content TEXT NOT NULL,
				createdAt TEXT NOT NULL
			)
		`);
		client.sqlite.exec(`
			CREATE TABLE workspace_selection (
				id TEXT PRIMARY KEY,
				selectedProjectId TEXT REFERENCES projects(id) ON DELETE SET NULL,
				selectedChatId TEXT REFERENCES chats(id) ON DELETE SET NULL,
				updatedAt TEXT NOT NULL
			)
		`);
		client.sqlite.exec(`
			CREATE TABLE terminal_sessions (
				id TEXT PRIMARY KEY,
				chatId TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
				status TEXT NOT NULL CHECK(status IN ('running', 'exited')),
				shell TEXT NOT NULL,
				cwd TEXT NOT NULL,
				startedAt TEXT NOT NULL,
				lastActivityAt TEXT NOT NULL,
				exitedAt TEXT,
				exitCode INTEGER
			)
		`);
		client.sqlite.exec(`
			CREATE TABLE terminal_entries (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				sessionId TEXT NOT NULL REFERENCES terminal_sessions(id) ON DELETE CASCADE,
				chatId TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
				direction TEXT NOT NULL CHECK(direction IN ('input', 'output')),
				data TEXT NOT NULL,
				createdAt TEXT NOT NULL
			)
		`);

		initializeDatabaseSchema(client.sqlite);

		const hasLegacySessionsTable = client.sqlite
			.prepare("SELECT COUNT(1) AS count FROM sqlite_master WHERE type = 'table' AND name = 'terminal_sessions'")
			.get() as { count: number };
		expect(hasLegacySessionsTable.count).toBe(0);

		const terminalEntryColumns = client.sqlite
			.prepare("PRAGMA table_info(terminal_entries)")
			.all()
			.map((row) => (row as { name: string }).name);

		expect(terminalEntryColumns).toEqual(
			expect.arrayContaining(["id", "commandId", "chatId", "stream", "data", "createdAt"]),
		);
		expect(terminalEntryColumns).not.toContain("sessionId");
		expect(terminalEntryColumns).not.toContain("direction");
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("terminal command and entries cascade on chat delete", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-db-terminal-cascade-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);

		client.sqlite
			.prepare(
				"INSERT INTO projects (id, name, path, isFavorite, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)",
			)
			.run("project-1", "Project", "/tmp/project-1", 0, "2026-01-01T00:00:00.000Z", "2026-01-01T00:00:00.000Z");
		client.sqlite
			.prepare(
				"INSERT INTO chats (id, projectId, title, provider, providerThreadId, status, diffAdded, diffRemoved, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
			)
			.run("chat-1", "project-1", "Chat", "codex", null, "pending", 0, 0, "2026-01-01T00:00:00.000Z");
		client.sqlite
			.prepare(
				"INSERT INTO terminal_commands (id, chatId, command, shell, cwd, status, exitCode, durationMs, startedAt, finishedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
			)
			.run(
				"cmd-1",
				"chat-1",
				"echo ok",
				"/bin/zsh",
				"/tmp/project-1",
				"completed",
				0,
				1,
				"2026-01-01T00:00:00.100Z",
				"2026-01-01T00:00:00.101Z",
			);
		client.sqlite
			.prepare("INSERT INTO terminal_entries (commandId, chatId, stream, data, createdAt) VALUES (?, ?, ?, ?, ?)")
			.run("cmd-1", "chat-1", "stdout", "ok\n", "2026-01-01T00:00:00.101Z");
		client.sqlite
			.prepare("INSERT INTO chat_stream_snapshots (chatId, partialText, updatedAt) VALUES (?, ?, ?)")
			.run("chat-1", "in-progress", "2026-01-01T00:00:00.100Z");
		client.sqlite
			.prepare("INSERT INTO chat_stream_events (chatId, eventJson, turnId, createdAt) VALUES (?, ?, ?, ?)")
			.run(
				"chat-1",
				"{\"type\":\"turn_started\",\"turnId\":\"turn-1\"}",
				"turn-1",
				"2026-01-01T00:00:00.100Z",
			);

		client.sqlite.prepare("DELETE FROM chats WHERE id = ?").run("chat-1");

		const commandCount = client.sqlite
			.prepare("SELECT COUNT(1) AS count FROM terminal_commands WHERE chatId = ?")
			.get("chat-1") as { count: number };
		const entryCount = client.sqlite
			.prepare("SELECT COUNT(1) AS count FROM terminal_entries WHERE chatId = ?")
			.get("chat-1") as { count: number };
		const snapshotCount = client.sqlite
			.prepare("SELECT COUNT(1) AS count FROM chat_stream_snapshots WHERE chatId = ?")
			.get("chat-1") as { count: number };
		const streamEventCount = client.sqlite
			.prepare("SELECT COUNT(1) AS count FROM chat_stream_events WHERE chatId = ?")
			.get("chat-1") as { count: number };

		expect(commandCount.count).toBe(0);
		expect(entryCount.count).toBe(0);
		expect(snapshotCount.count).toBe(0);
		expect(streamEventCount.count).toBe(0);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
