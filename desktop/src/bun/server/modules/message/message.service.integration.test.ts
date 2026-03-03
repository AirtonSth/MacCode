import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { initializeDatabaseSchema } from "../../shared/db/db.bootstrap";
import { createDatabaseClient } from "../../shared/db/db.client";
import { createChatRepository } from "../chat/chat.repository";
import { createProjectRepository } from "../project/project.repository";
import { createMessageRepository } from "./message.repository";
import { createMessageService } from "./message.service";

test("message service preserves ascending order by createdAt", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-message-service-"));
	const path = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(path);

	try {
		initializeDatabaseSchema(client.sqlite);

		const projectRepository = createProjectRepository(client.orm);
		const chatRepository = createChatRepository(client.orm);
		const messageRepository = createMessageRepository(client.orm);
		const service = createMessageService({
			chat: chatRepository,
			message: messageRepository,
		});

		const project = await projectRepository.createProject("/tmp", "tmp");
		const chat = await chatRepository.createChat(project.id, "chat");

		await messageRepository.createMessage(chat.id, "user", "a");
		await new Promise((resolve) => setTimeout(resolve, 2));
		await messageRepository.createMessage(chat.id, "assistant", "b");

		const result = await service.listByChatId(chat.id);

		expect(result.chatExists).toBe(true);
		expect(result.hasMore).toBe(false);
		expect(result.nextBeforeMessageId).toBeNull();
		expect(result.messages).toHaveLength(2);
		expect(result.messages[0].content).toBe("a");
		expect(result.messages[1].content).toBe("b");
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
