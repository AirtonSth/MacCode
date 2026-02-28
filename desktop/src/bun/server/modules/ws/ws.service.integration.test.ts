import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { initializeDatabaseSchema } from "../../shared/db/db.bootstrap";
import { createDatabaseClient } from "../../shared/db/db.client";
import { createChatRepository } from "../chat/chat.repository";
import { createMessageRepository } from "../message/message.repository";
import { createProjectRepository } from "../project/project.repository";
import { WsService } from "./ws.service";

type ServerEvent =
	| {
			data: {
				chatId?: string;
				delta?: string;
				diffAdded?: number;
				diffRemoved?: number;
				status?: "pending" | "running" | "completed" | "failed";
				updatedAt?: string;
			};
			event: "assistant_delta" | "assistant_done" | "chat_updated" | "error";
	  };

test("WsService runs streaming flow with provider and persists assistant message", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-ws-service-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);

		const projectRepository = createProjectRepository(client.orm);
		const chatRepository = createChatRepository(client.orm);
		const messageRepository = createMessageRepository(client.orm);
		const service = new WsService(chatRepository, messageRepository);

		const project = projectRepository.createProject("/tmp", "tmp");
		const chat = chatRepository.createChat(project.id, "stream");
		const events: ServerEvent[] = [];

		await service.startUserMessage({
			chatId: chat.id,

			emit: (event) => {
				if (typeof event === "object" && typeof event.event === "string") {
					events.push(event);
				}
			},

			text: "hello",
		});

		const hasRunning = events.some(
			(event) => event.event === "chat_updated" && event.data.status === "running",
		);
		const hasDone = events.some((event) => event.event === "assistant_done");
		const hasCompleted = events.some(
			(event) => event.event === "chat_updated" && event.data.status === "completed",
		);

		expect(hasRunning).toBe(true);
		expect(hasDone).toBe(true);
		expect(hasCompleted).toBe(true);

		const updated = await chatRepository.findChatById(chat.id);

		expect(updated?.status).toBe("completed");
		expect(updated?.diffAdded).toBeGreaterThan(0);

		const messages = messageRepository.listMessagesByChatId(chat.id);

		expect(messages).toHaveLength(2);
		expect(messages[0].role).toBe("user");
		expect(messages[1].role).toBe("assistant");
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
