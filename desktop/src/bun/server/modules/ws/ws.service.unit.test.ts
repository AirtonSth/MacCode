import { expect, test } from "bun:test";

import type { ChatDTO, ServerWsEvent } from "../../types";
import type { ChatRepository } from "../chat/chat.repository";
import type { MessageRepository } from "../message/message.repository";
import { WsService } from "./ws.service";

const collectEvents = async (emit: (event: ServerWsEvent) => void) => {
	const events: ServerWsEvent[] = [];

	return {
		emit: (event: ServerWsEvent) => {
			events.push(event);
			emit(event);
		},

		events,
	};
};

test("WsService.startUserMessage returns chat_not_found for missing chat", async () => {
	const chatRepository = {
		findChatById: () => null,
		updateChat: () => null,
	} as unknown as ChatRepository;

	const messageRepository = {
		createMessage: () => {
			throw new Error("should not call");
		},
	} as unknown as MessageRepository;

	const service = new WsService(chatRepository, messageRepository);
	const collector = await collectEvents(() => {});

	await service.startUserMessage({ chatId: "missing", emit: collector.emit, text: "hi" });

	expect(collector.events).toEqual([
		{
			data: {
				chatId: "missing",
				code: "chat_not_found",
				message: "chat not found",
			},

			event: "error",
		},
	]);
});

test("WsService.startUserMessage blocks chat_running when already running", async () => {
	const runningChat: ChatDTO = {
		diffAdded: 0,
		diffRemoved: 0,
		id: "chat-id",
		projectId: "project-id",
		provider: "fake",
		status: "running",
		title: "Test",
		updatedAt: new Date().toISOString(),
	};

	const chatRepository = {
		findChatById: () => runningChat,
		updateChat: () => null,
	} as unknown as ChatRepository;

	const messageRepository = {
		createMessage: () => {
			throw new Error("should not call");
		},
	} as unknown as MessageRepository;

	const service = new WsService(chatRepository, messageRepository);
	const collector = await collectEvents(() => {});

	await service.startUserMessage({ chatId: "chat-id", emit: collector.emit, text: "hi" });

	expect(collector.events).toEqual([
		{
			data: {
				chatId: "chat-id",
				code: "chat_running",
				message: "chat is already running",
			},

			event: "error",
		},
	]);
});
