import { expect, test } from "bun:test";

import { parseServerWsEvent } from "../../../shared/realtime/remotecode-ws";

test("parseServerWsEvent parses assistant_delta from JSON text", () => {
	const parsed = parseServerWsEvent(
		JSON.stringify({
			event: "assistant_delta",
			data: {
				chatId: "chat-1",
				delta: "hello ",
			},
		}),
	);

	expect(parsed).toEqual({
		event: "assistant_delta",
		data: {
			chatId: "chat-1",
			delta: "hello ",
		},
	});
});

test("parseServerWsEvent parses assistant_delta from binary payload", () => {
	const payload = new TextEncoder().encode(
		JSON.stringify({
			event: "assistant_delta",
			data: {
				chatId: "chat-2",
				delta: "world",
			},
		}),
	);
	const parsed = parseServerWsEvent(payload);

	expect(parsed).toEqual({
		event: "assistant_delta",
		data: {
			chatId: "chat-2",
			delta: "world",
		},
	});
});

test("parseServerWsEvent parses assistant_done", () => {
	const parsed = parseServerWsEvent({
		event: "assistant_done",
		data: {
			chatId: "chat-1",
		},
	});

	expect(parsed).toEqual({
		event: "assistant_done",
		data: {
			chatId: "chat-1",
		},
	});
});

test("parseServerWsEvent parses chat_updated with expected fields", () => {
	const parsed = parseServerWsEvent(
		JSON.stringify({
			event: "chat_updated",
			data: {
				chatId: "chat-1",
				diffAdded: 3,
				diffRemoved: 1,
				status: "running",
				updatedAt: "2026-01-01T00:00:00.000Z",
			},
		}),
	);

	expect(parsed).toEqual({
		event: "chat_updated",
		data: {
			chatId: "chat-1",
			diffAdded: 3,
			diffRemoved: 1,
			status: "running",
			updatedAt: "2026-01-01T00:00:00.000Z",
		},
	});
});

test("parseServerWsEvent parses error without chatId", () => {
	const parsed = parseServerWsEvent({
		event: "error",
		data: {
			code: "provider_timeout",
			message: "provider did not respond",
		},
	});

	expect(parsed).toEqual({
		event: "error",
		data: {
			code: "provider_timeout",
			message: "provider did not respond",
			chatId: undefined,
		},
	});
});

test("parseServerWsEvent rejects invalid payloads", () => {
	expect(parseServerWsEvent("not-json")).toBeNull();
	expect(parseServerWsEvent(null)).toBeNull();
	expect(
		parseServerWsEvent({
			event: "chat_updated",
			data: {
				chatId: "chat-1",
				diffAdded: "invalid",
				diffRemoved: 0,
				status: "running",
				updatedAt: "2026-01-01T00:00:00.000Z",
			},
		}),
	).toBeNull();
	expect(
		parseServerWsEvent({
			event: "assistant_delta",
			data: {
				chatId: "chat-1",
				other: "missing delta",
			},
		}),
	).toBeNull();
	expect(
		parseServerWsEvent({
			event: "assistant_done",
		}),
	).toBeNull();
	expect(
		parseServerWsEvent({
			event: "chat_updated",
			data: {
				chatId: "chat-1",
				diffAdded: 0,
				diffRemoved: 0,
				status: "unknown",
				startedAt: "2026-01-01T00:00:00.000Z",
				updatedAt: "2026-01-01T00:00:00.000Z",
			},
		}),
	).toBeNull();
});
