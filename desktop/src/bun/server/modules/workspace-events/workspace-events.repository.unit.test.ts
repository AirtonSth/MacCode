import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { initializeDatabaseSchema } from "../../shared/db/db.bootstrap";
import { createDatabaseClient } from "../../shared/db/db.client";
import { createWorkspaceEventsRepository } from "./workspace-events.repository";

const createRepository = async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-workspace-events-"));
	const databasePath = join(root, "remotecode.sqlite");
	const client = await createDatabaseClient(databasePath);
	initializeDatabaseSchema(client.sqlite);
	return {
		client,
		repository: createWorkspaceEventsRepository(client.orm),
		root,
	};
};

test("WorkspaceEventsRepository retains only the latest replay window", async () => {
	const { client, repository, root } = await createRepository();

	try {
		for (let index = 1; index <= 2_005; index += 1) {
			repository.append({
				originClientId: index % 2 === 0 ? "desktop-client" : null,
				payload: {
					index,
				},
				requestId: `req-${String(index)}`,
				type: "chat_updated",
			});
		}

		const retainedEvents = repository.listAfterSeq(0, 5_000);

		expect(retainedEvents).toHaveLength(2_000);
		expect(retainedEvents[0]?.seq).toBe(6);
		expect(retainedEvents.at(-1)?.seq).toBe(2_005);
		expect(retainedEvents[0]?.payload).toEqual({ index: 6 });
		expect(retainedEvents.at(-1)?.payload).toEqual({ index: 2_005 });
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
