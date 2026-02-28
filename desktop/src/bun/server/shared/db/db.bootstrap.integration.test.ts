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
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
