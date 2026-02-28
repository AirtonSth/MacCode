import { expect, test } from "bun:test";

import type { MessageDTO } from "../../types";
import type { ChatRepository } from "../chat/chat.repository";
import type { MessageRepository } from "./message.repository";
import { MessageService } from "./message.service";

const createMessage = (overrides: Partial<MessageDTO> = {}): MessageDTO => ({
	chatId: "chat-id",
	content: "texto",
	createdAt: new Date().toISOString(),
	id: "message-id",
	role: "assistant",
	...overrides,
});

test("MessageService.listByChatId retorna vazio para chat inexistente", async () => {
	const service = new MessageService(
		{ findChatById: () => null } as unknown as ChatRepository,
		{ listMessagesByChatId: () => [] } as unknown as MessageRepository,
	);
	const result = await service.listByChatId("missing");

	expect(result.chatExists).toBe(false);
	expect(result.messages).toEqual([]);
});

test("MessageService.listByChatId retorna mensagens de chat existente", async () => {
	const messages = [
		createMessage({ content: "ola", id: "1", role: "user" }),
		createMessage({ content: "ola também", id: "2", role: "assistant" }),
	];

	const service = new MessageService(
		{ findChatById: () => ({
			diffAdded: 0,
			diffRemoved: 0,
			id: "chat-id",
			projectId: "project-id",
			provider: "fake",
			status: "pending",
			title: "chat title",
			updatedAt: "",
		}) } as unknown as ChatRepository,
		{ listMessagesByChatId: () => messages } as unknown as MessageRepository,
	);

	const result = await service.listByChatId("chat-id");

	expect(result.chatExists).toBe(true);
	expect(result.messages).toEqual(messages);
});
