import { expect, test } from "bun:test";

import type { MessageDTO, MessagePageDTO } from "../../../shared/api/remotecode-http";
import {
	appendMessageToMessagePage,
	mergeBufferedMessagesIntoPage,
	pruneBufferedMessages,
} from "./message-window-cache";

const createPage = (messages: MessageDTO[] = []): MessagePageDTO => ({
	hasMore: false,
	messages,
	nextBeforeMessageId: null,
	turns: [],
});

const createMessage = (input: {
	id: string;
	createdAt: string;
	chatId?: string;
	content?: string;
	role?: "assistant" | "user";
}): MessageDTO => ({
	chatId: input.chatId ?? "chat-1",
	content: input.content ?? input.id,
	createdAt: input.createdAt,
	id: input.id,
	role: input.role ?? "user",
});

test("appendMessageToMessagePage keeps messages sorted and trims to the latest window", () => {
	const page = createPage([
		createMessage({ createdAt: "2026-01-01T00:00:00.000Z", id: "msg-1" }),
		createMessage({ createdAt: "2026-01-01T00:01:00.000Z", id: "msg-2" }),
	]);

	const nextPage = appendMessageToMessagePage(
		appendMessageToMessagePage(
			appendMessageToMessagePage(page, createMessage({ createdAt: "2026-01-01T00:02:00.000Z", id: "msg-3" }), 3),
			createMessage({ createdAt: "2026-01-01T00:03:00.000Z", id: "msg-4" }),
			3,
		),
		createMessage({ createdAt: "2026-01-01T00:00:30.000Z", id: "msg-1_5" }),
		3,
	);

	expect(nextPage.messages.map((message) => message.id)).toEqual(["msg-2", "msg-3", "msg-4"]);
	expect(nextPage.hasMore).toBe(true);
	expect(nextPage.nextBeforeMessageId).toBe("msg-2");
});

test("mergeBufferedMessagesIntoPage preserves a first message that arrived after an empty latest fetch", () => {
	const emptyPage = createPage();
	const bufferedMessage = createMessage({
		createdAt: "2026-01-01T00:00:00.000Z",
		id: "msg-user-1",
	});

	const mergedPage = mergeBufferedMessagesIntoPage(emptyPage, [bufferedMessage], 5);

	expect(mergedPage.messages).toEqual([bufferedMessage]);
});

test("pruneBufferedMessages removes entries that the server already persisted", () => {
	const bufferedMessages = [
		createMessage({ createdAt: "2026-01-01T00:00:00.000Z", id: "msg-1" }),
		createMessage({ createdAt: "2026-01-01T00:01:00.000Z", id: "msg-2" }),
	];
	const persistedMessages = [
		createMessage({ createdAt: "2026-01-01T00:00:00.000Z", id: "msg-1" }),
	];

	expect(pruneBufferedMessages(bufferedMessages, persistedMessages)).toEqual([
		bufferedMessages[1],
	]);
});
