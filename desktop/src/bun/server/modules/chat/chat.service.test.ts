import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { initializeDatabaseSchema } from "../../shared/db/db.bootstrap";
import { createDatabaseClient } from "../../shared/db/db.client";
import { createProjectRepository } from "../project/project.repository";
import { createChatRepository } from "./chat.repository";
import { createChatService } from "./chat.service";

test("chat service requires project and lists chats by updatedAt desc", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-chat-service-"));
	const path = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(path);

	try {
		initializeDatabaseSchema(client.sqlite);

		const projectRepository = createProjectRepository(client.orm);
		const chatRepository = createChatRepository(client.orm);
		const service = createChatService({ chat: chatRepository, project: projectRepository });
		const project = await projectRepository.createProject("/tmp", "tmp");

		await service.createChat(project.id, "A");
		await service.createChat(project.id, "B");

		const list = await service.listByProjectId(project.id);

		expect(list).toBeTruthy();
		expect(list?.length).toBe(2);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
