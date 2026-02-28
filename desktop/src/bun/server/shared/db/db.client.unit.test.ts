import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { DatabaseClientFactory } from "./db.client";

test("DatabaseClientFactory.create respects explicit path", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-db-client-"));
	const databasePath = join(root, "custom.sqlite");
	const client = await DatabaseClientFactory.create(databasePath);

	try {
		expect(client.dbPath).toBe(databasePath);
		expect(client.sqlite).toBeDefined();
		expect(() => client.sqlite.prepare("select 1").get()).not.toThrow();
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
