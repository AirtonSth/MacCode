import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createDatabaseClient } from "../../shared/db/db.client";
import { initializeDatabaseSchema } from "../../shared/db/db.bootstrap";
import { createLiveActivitySubscriptionRepository } from "./live-activity-subscription.repository";

const seedChat = (sqlite: Awaited<ReturnType<typeof createDatabaseClient>>["sqlite"]): void => {
	sqlite
		.prepare(
			"INSERT INTO projects (id, name, path, isFavorite, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)",
		)
		.run("project-1", "Project", "/tmp/live-activity-repo", 0, "2026-01-01T00:00:00.000Z", "2026-01-01T00:00:00.000Z");
	sqlite
		.prepare(
			"INSERT INTO chats (id, projectId, title, provider, providerThreadId, status, isActive, diffAdded, diffRemoved, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
		)
		.run("chat-1", "project-1", "Live Activity", "codex", "thread-1", "running", 1, 0, 0, "2026-01-01T00:00:00.000Z");
};

test("LiveActivitySubscriptionRepository upsert replaces stale token pairs", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-live-activity-repo-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);
		seedChat(client.sqlite);
		const repository = createLiveActivitySubscriptionRepository(client.orm);

		repository.upsert({
			chatId: "chat-1",
			chatTitle: "Live Activity",
			liveActivityToken: "activity-token-1",
			pushToken: "push-token-1",
			pushTokenType: "apns",
		});
		repository.upsert({
			chatId: "chat-1",
			chatTitle: "Live Activity",
			liveActivityToken: "activity-token-2",
			pushToken: "push-token-1",
			pushTokenType: "apns",
		});
		repository.upsert({
			chatId: "chat-1",
			chatTitle: "Live Activity",
			liveActivityToken: "activity-token-2",
			pushToken: "push-token-2",
			pushTokenType: "apns",
		});

		const rows = repository.listAll();

		expect(rows).toHaveLength(1);
		expect(rows[0]).toEqual(
			expect.objectContaining({
				chatId: "chat-1",
				chatTitle: "Live Activity",
				liveActivityToken: "activity-token-2",
				pushToken: "push-token-2",
				pushTokenType: "apns",
			}),
		);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("LiveActivitySubscriptionRepository deleteByChatId removes persisted rows", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-live-activity-delete-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);
		seedChat(client.sqlite);
		const repository = createLiveActivitySubscriptionRepository(client.orm);

		repository.upsert({
			chatId: "chat-1",
			chatTitle: "Live Activity",
			liveActivityToken: "activity-token-1",
			pushToken: "push-token-1",
			pushTokenType: "apns",
		});

		expect(repository.listAll()).toHaveLength(1);

		repository.deleteByChatId("chat-1");

		expect(repository.listAll()).toEqual([]);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
