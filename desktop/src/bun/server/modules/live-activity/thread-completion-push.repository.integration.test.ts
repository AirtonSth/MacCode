import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createDatabaseClient } from "../../shared/db/db.client";
import { initializeDatabaseSchema } from "../../shared/db/db.bootstrap";
import { createThreadCompletionPushRepository } from "./thread-completion-push.repository";

test("ThreadCompletionPushRepository upsert inserts a subscription", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-thread-push-insert-"));
	const databasePath = join(root, "remotecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);
		const repository = createThreadCompletionPushRepository(client.orm);

		const stored = repository.upsert({
			chatId: "chat-1",
			chatTitle: "Build Thread",
			pushToken: "device-token",
			pushTokenType: "fcm",
		});

		expect(stored.chatId).toBe("chat-1");
		expect(stored.pushToken).toBe("device-token");
		expect(stored.pushTokenType).toBe("fcm");
		expect(repository.listAll()).toHaveLength(1);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("ThreadCompletionPushRepository deleteExact removes the matching subscription", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-thread-push-delete-"));
	const databasePath = join(root, "remotecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);
		const repository = createThreadCompletionPushRepository(client.orm);

		repository.upsert({
			chatId: "chat-1",
			pushToken: "device-token",
			pushTokenType: "apns",
		});

		repository.deleteExact({
			chatId: "chat-1",
			pushToken: "device-token",
			pushTokenType: "apns",
		});

		expect(repository.listAll()).toHaveLength(0);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
