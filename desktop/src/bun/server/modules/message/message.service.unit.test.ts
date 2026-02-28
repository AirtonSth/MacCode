import { expect, test } from "bun:test";

import type { MessageDTO } from "../../types";
import type { ChatRepository } from "../chat/chat.repository";
import type { MessageRepository } from "./message.repository";
import { MessageService } from "./message.service";

const createMessage = (overrides: Partial<MessageDTO> = {}): MessageDTO => ({
	chatId: "chat-id",
	content: "text",
	createdAt: new Date().toISOString(),
	id: "message-id",
	role: "assistant",
	...overrides,
});

test("MessageService.listByChatId returns empty for missing chat", async () => {
	const service = new MessageService(
		{ findChatById: () => null } as unknown as ChatRepository,
		{ listMessagesByChatId: () => [] } as unknown as MessageRepository,
	);
	const result = await service.listByChatId("missing");

	expect(result.chatExists).toBe(false);
	expect(result.messages).toEqual([]);
});

test("MessageService.listByChatId returns messages for existing chat", async () => {
	const messages = [
		createMessage({ content: "hello", id: "1", role: "user" }),
		createMessage({ content: "hello as well", id: "2", role: "assistant" }),
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
