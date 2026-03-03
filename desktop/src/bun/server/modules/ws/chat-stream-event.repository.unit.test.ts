import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { initializeDatabaseSchema } from "../../shared/db/db.bootstrap";
import { createDatabaseClient } from "../../shared/db/db.client";
import { createChatStreamEventRepository } from "./chat-stream-event.repository";

const createSeededChat = async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-stream-events-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);
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
		.run("chat-1", "project-1", "Chat", "codex", null, "running", 0, 0, "2026-01-01T00:00:00.000Z");

	return { client, root };
};

test("ChatStreamEventRepository appends events in id order", async () => {
	const { client, root } = await createSeededChat();

	try {
		const repository = createChatStreamEventRepository(client.orm);
		const first = repository.append("chat-1", {
			type: "turn_started",
			turnId: "turn-1",
		});
		const second = repository.append("chat-1", {
			type: "item_started",
			turnId: "turn-1",
			itemId: "tool-1",
			itemType: "tool",
			summary: "Running command",
		});

		expect(second.id).toBeGreaterThan(first.id);
		expect(first.event.type).toBe("turn_started");
		expect(second.event.type).toBe("item_started");
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("ChatStreamEventRepository paginates by afterId and limit", async () => {
	const { client, root } = await createSeededChat();

	try {
		const repository = createChatStreamEventRepository(client.orm);
		const e1 = repository.append("chat-1", {
			type: "turn_started",
			turnId: "turn-1",
		});
		const e2 = repository.append("chat-1", {
			type: "item_started",
			turnId: "turn-1",
			itemId: "reasoning-1",
			itemType: "reasoning",
		});
		const e3 = repository.append("chat-1", {
			type: "turn_completed",
			turnId: "turn-1",
		});

		const firstPage = repository.listByChatId("chat-1", { afterId: 0, limit: 2 });
		const secondPage = repository.listByChatId("chat-1", { afterId: e2.id, limit: 2 });

		expect(firstPage.map((event) => event.id)).toEqual([e1.id, e2.id]);
		expect(secondPage.map((event) => event.id)).toEqual([e3.id]);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
