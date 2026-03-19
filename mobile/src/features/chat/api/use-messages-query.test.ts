/* eslint-disable import/no-unresolved */
import { describe, expect, it } from "bun:test";

import {
	appendMessageToMessagePage,
	replaceVisibleMessagePage,
} from "./use-messages-query";
import type { MessageDTO, MessagePageDTO } from "../../../shared/api/types";

const makeMessage = (overrides: Partial<MessageDTO> = {}): MessageDTO => ({
	chatId: "chat-1",
	content: "hello",
	createdAt: new Date().toISOString(),
	id: `msg-${Date.now()}`,
	role: "user",
	...overrides,
});

const makeEmptyPage = (): MessagePageDTO => ({
	hasMore: false,
	messages: [],
	nextBeforeMessageId: null,
	turns: [],
});

describe("appendMessageToMessagePage", () => {
	it("appends a message to an empty page", () => {
		const message = makeMessage({ id: "msg-1" });
		const result = appendMessageToMessagePage(undefined, message);

		expect(result.messages).toHaveLength(1);
		expect(result.messages[0].id).toBe("msg-1");
	});

	it("appends a message to an existing page", () => {
		const existing = makeMessage({ id: "msg-1", createdAt: "2025-01-01T00:00:00Z" });
		const page: MessagePageDTO = {
			...makeEmptyPage(),
			messages: [existing],
		};
		const newMsg = makeMessage({ id: "msg-2", createdAt: "2025-01-01T00:01:00Z" });
		const result = appendMessageToMessagePage(page, newMsg);

		expect(result.messages).toHaveLength(2);
		expect(result.messages[1].id).toBe("msg-2");
	});

	it("upserts a message with the same id", () => {
		const existing = makeMessage({ id: "msg-1", content: "original" });
		const page: MessagePageDTO = {
			...makeEmptyPage(),
			messages: [existing],
		};
		const updated = makeMessage({ id: "msg-1", content: "updated", createdAt: existing.createdAt });
		const result = appendMessageToMessagePage(page, updated);

		expect(result.messages).toHaveLength(1);
		expect(result.messages[0].content).toBe("updated");
	});

	it("handles optimistic messages with temp chat IDs", () => {
		const optimisticMsg = makeMessage({
			chatId: "temp-chat-12345",
			id: "user-12345",
		});
		const result = appendMessageToMessagePage(undefined, optimisticMsg);

		expect(result.messages).toHaveLength(1);
		expect(result.messages[0].chatId).toBe("temp-chat-12345");
	});
});

describe("replaceVisibleMessagePage", () => {
	it("returns the new page when replacing", () => {
		const current: MessagePageDTO = {
			...makeEmptyPage(),
			messages: [makeMessage({ id: "old" })],
		};
		const next: MessagePageDTO = {
			...makeEmptyPage(),
			messages: [makeMessage({ id: "new" })],
		};
		const result = replaceVisibleMessagePage(current, next);

		expect(result.messages).toHaveLength(1);
		expect(result.messages[0].id).toBe("new");
	});
});
