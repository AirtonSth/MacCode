import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createDatabaseClient } from "../../shared/db/db.client";
import { initializeDatabaseSchema } from "../../shared/db/db.bootstrap";
import { createPushToStartTokenRepository } from "./push-to-start-token.repository";

test("PushToStartTokenRepository upsert inserts a new token", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-pts-insert-"));
	const databasePath = join(root, "remotecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);
		const repository = createPushToStartTokenRepository(client.orm);

		const stored = repository.upsert({
			pushToStartToken: "pts-token-1",
			pushToken: "device-push-1",
			pushTokenType: "apns",
		});

		expect(stored.pushToStartToken).toBe("pts-token-1");
		expect(stored.pushToken).toBe("device-push-1");
		expect(stored.pushTokenType).toBe("apns");
		expect(stored.updatedAt).toBeDefined();

		const allTokens = repository.listAll();
		expect(allTokens).toHaveLength(1);
		expect(allTokens[0]).toEqual(expect.objectContaining({
			pushToStartToken: "pts-token-1",
			pushToken: "device-push-1",
			pushTokenType: "apns",
		}));
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("PushToStartTokenRepository upsert replaces existing token for same device", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-pts-upsert-"));
	const databasePath = join(root, "remotecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);
		const repository = createPushToStartTokenRepository(client.orm);

		repository.upsert({
			pushToStartToken: "pts-old",
			pushToken: "device-push-1",
			pushTokenType: "apns",
		});

		repository.upsert({
			pushToStartToken: "pts-new",
			pushToken: "device-push-1",
			pushTokenType: "apns",
		});

		const allTokens = repository.listAll();
		expect(allTokens).toHaveLength(1);
		expect(allTokens[0]?.pushToStartToken).toBe("pts-new");
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("PushToStartTokenRepository stores separate tokens for different push token types", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-pts-types-"));
	const databasePath = join(root, "remotecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);
		const repository = createPushToStartTokenRepository(client.orm);

		repository.upsert({
			pushToStartToken: "pts-apns",
			pushToken: "device-push-1",
			pushTokenType: "apns",
		});

		repository.upsert({
			pushToStartToken: "pts-fcm",
			pushToken: "device-push-1",
			pushTokenType: "fcm",
		});

		const allTokens = repository.listAll();
		expect(allTokens).toHaveLength(2);

		const types = allTokens.map((t) => t.pushTokenType).sort();
		expect(types).toEqual(["apns", "fcm"]);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("PushToStartTokenRepository stores separate tokens for different push tokens", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-pts-devices-"));
	const databasePath = join(root, "remotecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);
		const repository = createPushToStartTokenRepository(client.orm);

		repository.upsert({
			pushToStartToken: "pts-device-a",
			pushToken: "device-a",
			pushTokenType: "apns",
		});

		repository.upsert({
			pushToStartToken: "pts-device-b",
			pushToken: "device-b",
			pushTokenType: "apns",
		});

		const allTokens = repository.listAll();
		expect(allTokens).toHaveLength(2);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("PushToStartTokenRepository deleteByPushToken removes the matching token", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-pts-delete-"));
	const databasePath = join(root, "remotecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);
		const repository = createPushToStartTokenRepository(client.orm);

		repository.upsert({
			pushToStartToken: "pts-to-delete",
			pushToken: "device-delete",
			pushTokenType: "apns",
		});

		expect(repository.listAll()).toHaveLength(1);

		repository.deleteByPushToken("device-delete", "apns");

		expect(repository.listAll()).toHaveLength(0);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("PushToStartTokenRepository deleteByPushToken only removes matching type", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-pts-delete-type-"));
	const databasePath = join(root, "remotecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);
		const repository = createPushToStartTokenRepository(client.orm);

		repository.upsert({
			pushToStartToken: "pts-apns",
			pushToken: "device-1",
			pushTokenType: "apns",
		});
		repository.upsert({
			pushToStartToken: "pts-fcm",
			pushToken: "device-1",
			pushTokenType: "fcm",
		});

		repository.deleteByPushToken("device-1", "apns");

		const remaining = repository.listAll();
		expect(remaining).toHaveLength(1);
		expect(remaining[0]?.pushTokenType).toBe("fcm");
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("PushToStartTokenRepository deleteByPushToken is no-op for non-existing token", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-pts-delete-noop-"));
	const databasePath = join(root, "remotecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);
		const repository = createPushToStartTokenRepository(client.orm);

		repository.upsert({
			pushToStartToken: "pts-existing",
			pushToken: "device-existing",
			pushTokenType: "apns",
		});

		repository.deleteByPushToken("device-nonexistent", "apns");

		expect(repository.listAll()).toHaveLength(1);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("PushToStartTokenRepository listAll returns empty array on empty table", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-pts-empty-"));
	const databasePath = join(root, "remotecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);
		const repository = createPushToStartTokenRepository(client.orm);

		expect(repository.listAll()).toEqual([]);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("PushToStartTokenRepository upsert updates the updatedAt timestamp", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-pts-timestamp-"));
	const databasePath = join(root, "remotecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);
		const repository = createPushToStartTokenRepository(client.orm);

		const first = repository.upsert({
			pushToStartToken: "pts-time-1",
			pushToken: "device-time",
			pushTokenType: "apns",
		});

		const firstTime = Date.parse(first.updatedAt);

		// Small delay to ensure different timestamp
		await new Promise<void>((resolve) => { setTimeout(resolve, 10); });

		const second = repository.upsert({
			pushToStartToken: "pts-time-2",
			pushToken: "device-time",
			pushTokenType: "apns",
		});

		const secondTime = Date.parse(second.updatedAt);
		expect(secondTime).toBeGreaterThanOrEqual(firstTime);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
