import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { initializeDatabaseSchema } from "./db.bootstrap";
import { createDatabaseClient } from "./db.client";

test("DB initialization creates schema, indices and pragmas", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-db-init-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);

		const projectColumns = client.sqlite
			.prepare("PRAGMA table_info(projects)")
			.all()
			.map((row) => (row as { name: string }).name);

		expect(projectColumns.sort()).toEqual([
			"createdAt",
			"id",
			"isFavorite",
			"name",
			"path",
			"updatedAt",
		].sort());

		const chatColumns = client.sqlite
			.prepare("PRAGMA table_info(chats)")
			.all()
			.map((row) => (row as { name: string }).name);

		expect(chatColumns).toContain("status");
		expect(chatColumns).toContain("provider");
		expect(chatColumns).toContain("providerThreadId");

		const messageColumns = client.sqlite
			.prepare("PRAGMA table_info(messages)")
			.all()
			.map((row) => (row as { name: string }).name);

		expect(messageColumns).toContain("content");
		expect(messageColumns).toContain("role");

		const indexes = client.sqlite
			.prepare("PRAGMA index_list(projects)")
			.all()
			.map((row) => (row as { name: string }).name);

		expect(indexes).toContain("idx_projects_path");
		expect(indexes).toContain("sqlite_autoindex_projects_1");

		const chatIndexes = client.sqlite
			.prepare("PRAGMA index_list(chats)")
			.all()
			.map((row) => (row as { name: string }).name);

		expect(chatIndexes).toContain("idx_chats_project");

		const messageIndexes = client.sqlite
			.prepare("PRAGMA index_list(messages)")
			.all()
			.map((row) => (row as { name: string }).name);

		expect(messageIndexes).toContain("idx_messages_chat");

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
			.run(
				"c1",
				"p1",
				"chat",
				"codex",
				"thread-1",
				"pending",
				0,
				0,
				"2026-01-01T00:00:00.000Z",
			);

		const provider = client.sqlite
			.prepare("SELECT provider, providerThreadId FROM chats WHERE id = ?")
			.get("c1") as { provider: string; providerThreadId: string | null };
		expect(provider.provider).toBe("codex");
		expect(provider.providerThreadId).toBe("thread-1");
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
			.run(
				"chat-1",
				"project-1",
				"Legacy Chat",
				"fake",
				"completed",
				9,
				2,
				"2026-01-01T00:00:00.000Z",
			);
		client.sqlite
			.prepare("INSERT INTO messages (id, chatId, role, content, createdAt) VALUES (?, ?, ?, ?, ?)")
			.run("message-1", "chat-1", "assistant", "legacy message", "2026-01-01T00:00:00.000Z");

		initializeDatabaseSchema(client.sqlite);

		const chatColumns = client.sqlite
			.prepare("PRAGMA table_info(chats)")
			.all()
			.map((row) => (row as { name: string }).name);

		expect(chatColumns).toContain("providerThreadId");

		const migratedChat = client.sqlite
			.prepare("SELECT provider, providerThreadId, diffAdded, diffRemoved FROM chats WHERE id = ?")
			.get("chat-1") as {
				diffAdded: number;
				diffRemoved: number;
				provider: string;
				providerThreadId: string | null;
			};

		expect(migratedChat.provider).toBe("fake");
		expect(migratedChat.providerThreadId).toBeNull();
		expect(migratedChat.diffAdded).toBe(9);
		expect(migratedChat.diffRemoved).toBe(2);

		const messages = client.sqlite
			.prepare("SELECT chatId, content FROM messages WHERE id = ?")
			.get("message-1") as { chatId: string; content: string };
		expect(messages.chatId).toBe("chat-1");
		expect(messages.content).toBe("legacy message");

		client.sqlite
			.prepare(
				"INSERT INTO chats (id, projectId, title, provider, providerThreadId, status, diffAdded, diffRemoved, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
			)
			.run(
				"chat-2",
				"project-1",
				"Codex Chat",
				"codex",
				"thread-new",
				"pending",
				0,
				0,
				"2026-01-01T00:00:00.000Z",
			);

		const codexRow = client.sqlite
			.prepare("SELECT provider, providerThreadId FROM chats WHERE id = ?")
			.get("chat-2") as { provider: string; providerThreadId: string | null };
		expect(codexRow.provider).toBe("codex");
		expect(codexRow.providerThreadId).toBe("thread-new");
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
