import { expect, test } from "bun:test";

import type { MessageDTO, MessagePageDTO } from "../../../shared/api/remotecode-http";
import type { MessageWindowState } from "./useWorkspaceStore";
import {
	appendMessageToMessagePage,
	cacheLatestMessageWindow,
	mergeBufferedMessagesIntoPage,
	pruneBufferedMessages,
	resolveSelectedMessageWindow,
} from "./message-window-cache";

const createPage = (messages: MessageDTO[] = []): MessagePageDTO => ({
	hasMore: false,
	messages,
	nextBeforeMessageId: null,
	turns: [],
});

const createWindow = (overrides: Partial<MessageWindowState> = {}): MessageWindowState => ({
	chatId: "chat-1",
	hasMore: false,
	latestDirty: false,
	messages: [],
	mode: "latest",
	nextBeforeMessageId: null,
	turns: [],
	...overrides,
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

test("cacheLatestMessageWindow stores latest windows by chat id", () => {
	const messageWindow = createWindow({
		messages: [createMessage({ createdAt: "2026-01-01T00:00:00.000Z", id: "msg-1" })],
	});

	expect(cacheLatestMessageWindow({}, messageWindow)).toEqual({
		"chat-1": messageWindow,
	});
});

test("cacheLatestMessageWindow ignores older windows", () => {
	const olderWindow = createWindow({
		mode: "older",
		nextBeforeMessageId: "msg-1",
	});

	expect(cacheLatestMessageWindow({}, olderWindow)).toEqual({});
});

test("resolveSelectedMessageWindow prefers the live selected window", () => {
	const liveWindow = createWindow({
		chatId: "chat-2",
		messages: [createMessage({ chatId: "chat-2", createdAt: "2026-01-01T00:00:00.000Z", id: "msg-2" })],
	});
	const cachedWindow = createWindow({
		chatId: "chat-2",
		messages: [createMessage({ chatId: "chat-2", createdAt: "2026-01-01T00:00:00.000Z", id: "msg-stale" })],
	});

	expect(resolveSelectedMessageWindow({
		cache: { "chat-2": cachedWindow },
		liveWindow,
		selectedChatId: "chat-2",
	})).toEqual({
		hasHydratedWindow: true,
		isLiveWindow: true,
		window: liveWindow,
	});
});

test("resolveSelectedMessageWindow falls back to the cached latest window while a new selection loads", () => {
	const liveWindow = createWindow({
		chatId: "chat-1",
		messages: [createMessage({ createdAt: "2026-01-01T00:00:00.000Z", id: "msg-1" })],
	});
	const cachedWindow = createWindow({
		chatId: "chat-2",
		messages: [createMessage({ chatId: "chat-2", createdAt: "2026-01-01T00:00:00.000Z", id: "msg-2" })],
	});

	expect(resolveSelectedMessageWindow({
		cache: { "chat-2": cachedWindow },
		liveWindow,
		selectedChatId: "chat-2",
	})).toEqual({
		hasHydratedWindow: true,
		isLiveWindow: false,
		window: cachedWindow,
	});
});

test("resolveSelectedMessageWindow returns an empty pending window when the selected chat has not loaded yet", () => {
	expect(resolveSelectedMessageWindow({
		cache: {},
		liveWindow: createWindow({ chatId: "chat-1" }),
		selectedChatId: "chat-2",
	})).toEqual({
		hasHydratedWindow: false,
		isLiveWindow: false,
		window: createWindow({ chatId: "chat-2" }),
	});
});
