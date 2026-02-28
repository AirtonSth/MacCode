import { expect, test } from "bun:test";

import type { MessageDTO } from "./useWorkspaceStore";
import { sendWorkspaceMessage } from "./send-message";

type EventPayload = {
	code?: string;
	message?: string;
	source?: "rest" | "ws";
};

const createCollector = () => {
	const messages: MessageDTO[] = [];
	const clearCalls: string[] = [];
	const sentPayloads: Array<{ chatId: string; text: string }> = [];
	const errors: EventPayload[] = [];
	const sendingFlags: boolean[] = [];

	return {
		actions: {
			messages,
			clearCalls,
			sentPayloads,
			errors,
			sendingFlags,
		},
		messages,
		clearCalls,
		sentPayloads,
		errors,
		sendingFlags,
		onAppendMessage: (message: MessageDTO) => {
			messages.push(message);
		},
		onClearStreaming: (chatId: string) => {
			clearCalls.push(chatId);
		},
		onCreateMessageError: (message: string, source: "rest" | "ws", code: string) => {
			errors.push({ message, source, code });
		},
		onSetSending: (sending: boolean) => {
			sendingFlags.push(sending);
		},
		onSendUserMessage: (chatId: string, text: string) => {
			sentPayloads.push({ chatId, text });
		},
	};
};

test("sendWorkspaceMessage reports missing project before attempting to create chat", async () => {
	const callbacks = createCollector();

	const result = await sendWorkspaceMessage({
		createChatId: async () => "chat-should-not-be-created",
		createTimestamp: () => "2026-01-01T00:00:00.000Z",
		generateMessageId: () => "message-1",
		hasOpenWebSocket: true,
		onAppendMessage: callbacks.onAppendMessage,
		onClearStreaming: callbacks.onClearStreaming,
		onCreateMessageError: callbacks.onCreateMessageError,
		onSetSending: callbacks.onSetSending,
		onSendUserMessage: callbacks.onSendUserMessage,
		selectedChatId: null,
		selectedProjectId: null,
		text: "ping",
	});

	expect(result).toEqual({
		chatId: null,
		sent: false,
		createdNewChat: false,
	});
	expect(callbacks.errors).toEqual([
		{
			source: "rest",
			code: "missing_project",
			message: "Select a project before sending a message",
		},
	]);
	expect(callbacks.messages).toHaveLength(0);
	expect(callbacks.sentPayloads).toHaveLength(0);
	expect(callbacks.sendingFlags).toHaveLength(0);
});

test("sendWorkspaceMessage auto-creates a chat when no chat is selected", async () => {
	const callbacks = createCollector();
	let createCount = 0;

	const result = await sendWorkspaceMessage({
		createChatId: async () => {
			createCount += 1;
			return "chat-1";
		},
		createTimestamp: () => "2026-01-01T00:00:00.000Z",
		generateMessageId: () => "message-1",
		hasOpenWebSocket: true,
		onAppendMessage: callbacks.onAppendMessage,
		onClearStreaming: callbacks.onClearStreaming,
		onCreateMessageError: callbacks.onCreateMessageError,
		onSetSending: callbacks.onSetSending,
		onSendUserMessage: callbacks.onSendUserMessage,
		selectedChatId: null,
		selectedProjectId: "project-1",
		text: "start thread",
	});

	expect(result).toEqual({
		chatId: "chat-1",
		sent: true,
		createdNewChat: true,
	});
	expect(createCount).toBe(1);
	expect(callbacks.sendingFlags).toEqual([true]);
	expect(callbacks.messages).toHaveLength(1);
	expect(callbacks.messages[0]).toEqual({
		chatId: "chat-1",
		role: "user",
		content: "start thread",
		createdAt: "2026-01-01T00:00:00.000Z",
		id: "message-1",
	});
	expect(callbacks.clearCalls).toEqual(["chat-1"]);
	expect(callbacks.sentPayloads).toEqual([
		{
			chatId: "chat-1",
			text: "start thread",
		},
	]);
	expect(callbacks.errors).toHaveLength(0);
});

test("sendWorkspaceMessage auto-creates a codex chat when selected chat is legacy fake", async () => {
	const callbacks = createCollector();
	let createCount = 0;

	const result = await sendWorkspaceMessage({
		createChatId: async () => {
			createCount += 1;
			return "chat-codex";
		},
		createTimestamp: () => "2026-01-01T00:00:00.000Z",
		generateMessageId: () => "message-legacy",
		hasOpenWebSocket: true,
		onAppendMessage: callbacks.onAppendMessage,
		onClearStreaming: callbacks.onClearStreaming,
		onCreateMessageError: callbacks.onCreateMessageError,
		onSetSending: callbacks.onSetSending,
		onSendUserMessage: callbacks.onSendUserMessage,
		selectedChatId: "legacy-chat",
		selectedChatProvider: "fake",
		selectedProjectId: "project-1",
		text: "continue in codex",
	});

	expect(result).toEqual({
		chatId: "chat-codex",
		sent: true,
		createdNewChat: true,
	});
	expect(createCount).toBe(1);
	expect(callbacks.sentPayloads).toEqual([
		{
			chatId: "chat-codex",
			text: "continue in codex",
		},
	]);
});

test("sendWorkspaceMessage does not send when websocket is not connected", async () => {
	const callbacks = createCollector();

	const result = await sendWorkspaceMessage({
		createChatId: async () => "chat-1",
		createTimestamp: () => "2026-01-01T00:00:00.000Z",
		generateMessageId: () => "message-1",
		hasOpenWebSocket: false,
		onAppendMessage: callbacks.onAppendMessage,
		onClearStreaming: callbacks.onClearStreaming,
		onCreateMessageError: callbacks.onCreateMessageError,
		onSetSending: callbacks.onSetSending,
		onSendUserMessage: callbacks.onSendUserMessage,
		selectedChatId: "chat-1",
		selectedProjectId: "project-1",
		text: "offline",
	});

	expect(result).toEqual({
		chatId: "chat-1",
		sent: false,
		createdNewChat: false,
	});
	expect(callbacks.messages).toHaveLength(1);
	expect(callbacks.messages[0]?.chatId).toBe("chat-1");
	expect(callbacks.sentPayloads).toHaveLength(0);
	expect(callbacks.sendingFlags).toEqual([true, false]);
	expect(callbacks.errors).toEqual([
		{
			source: "ws",
			code: "not_ready",
			message: "WebSocket client is not ready",
		},
	]);
});
