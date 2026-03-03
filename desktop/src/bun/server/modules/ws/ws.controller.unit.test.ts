import { expect, test } from "bun:test";

import type { ChatDTO, ChatStreamSnapshotDTO, ServerWsEvent } from "../../types";
import { WsController } from "./ws.controller";
import type { WsService } from "./ws.model";

const createMockService = (): WsService => ({
	getChatById: async (): Promise<ChatDTO | null> => null,
	getChatStreamSnapshot: async (): Promise<ChatStreamSnapshotDTO | null> => null,
	isChatRunning: (): boolean => false,
	listWorkspaceEventsAfter: () => [],
	startUserMessage: async () => {
		// no-op
	},
});

const createSocket = (requestId: string) => {
	const events: ServerWsEvent[] = [];
	const socket = {
		data: {
			request: new Request(`http://localhost/${requestId}`),
		},
		send: (message: unknown) => {
			events.push(message as ServerWsEvent);
		},
	};

	return { events, socket };
};

test("WsController emits assistant stream events to chat and workspace subscribers without duplicates", () => {
	const controller = new WsController(createMockService());
	const both = createSocket("both");
	const workspaceOnly = createSocket("workspace");
	const chatOnly = createSocket("chat");

	(controller as unknown as { joinWorkspace: (socket: unknown) => void }).joinWorkspace(both.socket);
	(controller as unknown as { joinWorkspace: (socket: unknown) => void }).joinWorkspace(workspaceOnly.socket);
	(controller as unknown as { joinChat: (chatId: string, socket: unknown) => void }).joinChat("chat-1", both.socket);
	(controller as unknown as { joinChat: (chatId: string, socket: unknown) => void }).joinChat("chat-1", chatOnly.socket);

	const emit = (controller as unknown as {
		createChatEmitter: (chatId: string) => (event: ServerWsEvent) => void;
	}).createChatEmitter("chat-1");

	emit({
		data: {
			chatId: "chat-1",
			delta: "partial",
		},
		event: "assistant_delta",
	});

	expect(both.events).toHaveLength(1);
	expect(workspaceOnly.events).toHaveLength(1);
	expect(chatOnly.events).toHaveLength(1);

	emit({
		data: {
			chatId: "chat-1",
			diffAdded: 0,
			diffRemoved: 0,
			status: "running",
			updatedAt: "2026-01-01T00:00:00.000Z",
		},
		event: "chat_updated",
	});

	expect(both.events).toHaveLength(2);
	expect(chatOnly.events).toHaveLength(2);
	expect(workspaceOnly.events).toHaveLength(1);
});
