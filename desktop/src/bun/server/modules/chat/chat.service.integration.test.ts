import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { initializeDatabaseSchema } from "../../shared/db/db.bootstrap";
import { createDatabaseClient } from "../../shared/db/db.client";
import { createProjectRepository } from "../project/project.repository";
import { createChatRepository } from "./chat.repository";
import { createChatService } from "./chat.service";

test("chat service requires project and lista chats por updatedAt desc", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-chat-service-"));
	const path = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(path);

	try {
		initializeDatabaseSchema(client.sqlite);

		const projectRepository = createProjectRepository(client.orm);
		const chatRepository = createChatRepository(client.orm);
		const service = createChatService({ chat: chatRepository, project: projectRepository });
		const project = await projectRepository.createProject("/tmp", "tmp");

		const first = await service.createChat(project.id, "A");

		await new Promise((resolve) => setTimeout(resolve, 5));

		const second = await service.createChat(project.id, "B");

		if (!first || !second) {
			throw new Error("chat creation failed");
		}

		await service.updateChat(second.id, { status: "running" });
		await new Promise((resolve) => setTimeout(resolve, 5));
		await service.updateChat(first.id, { diffAdded: 10, status: "completed" });

		const list = await service.listByProjectId(project.id);

		expect(list).toBeTruthy();
		expect(list?.length).toBe(2);
		expect(list?.[0].id).toBe(first.id);
		expect(list?.[1].id).toBe(second.id);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
