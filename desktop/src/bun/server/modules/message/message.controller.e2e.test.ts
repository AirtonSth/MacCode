import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";
import { Database } from "bun:sqlite";

import { getCodexAvailability } from "../provider/codex-test-gate";
import { createTestServer } from "../../shared/core/test-server";

const codexAvailability = getCodexAvailability();
const codexTest = test.skipIf(!codexAvailability.available);
const skipReasonSuffix = codexAvailability.available ? "" : ` (skip: ${codexAvailability.reason})`;

const waitForCondition = async (predicate: () => boolean, timeoutMs = 90_000): Promise<void> => {
	await new Promise<void>((resolve, reject) => {
		const startedAt = performance.now();
		const timer = setInterval(() => {
			if (predicate()) {
				clearInterval(timer);
				resolve();
				return;
			}

			if (performance.now() - startedAt >= timeoutMs) {
				clearInterval(timer);
				reject(new Error("timed out waiting for websocket message"));
			}
		}, 40);
	});
};

codexTest(`GET /v1/chats/:id/messages returns messages in ascending createdAt order${skipReasonSuffix}`, async () => {
	const { baseUrl, cleanup, client } = await createTestServer();

	let ws: WebSocket | undefined;

	try {
		const project = await client.v1.projects.post({ path: "/tmp" });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "stream" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		const events: { data: unknown; event: string }[] = [];
		const url = new URL(`${baseUrl}/v1/ws?token=local-dev-token`);

		ws = new WebSocket(url);
		await new Promise<void>((resolve, reject) => {
			ws!.addEventListener("open", () => {
				resolve();
			});
			ws!.addEventListener("error", (event) => {
				reject(new Error(`ws open error: ${String(event)}`));
			});
		});
		ws.addEventListener("message", (event) => {
			events.push({ data: event.data as unknown, event: "message" });
		});

		ws.send(JSON.stringify({ data: { chatId }, event: "join_chat" }));
		await new Promise((resolve) => setTimeout(resolve, 20));

		ws.send(
			JSON.stringify({
				data: { chatId, text: "message test" },
				event: "user_message",
			}),
		);

		await waitForCondition(() =>
			events.some((item) => {
				if (typeof item.data !== "string") {
					return false;
				}

				try {
					const parsed = JSON.parse(item.data);
					return parsed?.event === "assistant_done" && parsed?.data?.chatId === chatId;
				} catch {
					return false;
				}
			}),
		);

		const messages = await client.v1.chats({ id: chatId }).messages.get();
		const sortedMessages = (messages.data as { messages: { role: "user" | "assistant" }[] }).messages;

		expect(messages.status).toBe(200);
		expect(sortedMessages.length).toBeGreaterThanOrEqual(2);
		expect(sortedMessages[0].role).toBe("user");
		expect(sortedMessages[1].role).toBe("assistant");
	} finally {
		ws?.close();
		await cleanup();
	}
}, 120_000);

test("GET /v1/chats/:id/messages returns 404 for missing chat", async () => {
	const { cleanup, client } = await createTestServer();

	try {
		const response = await client.v1.chats({ id: "non-existing" }).messages.get();
		const errorPayload = response.error && "value" in response.error ? (response.error as { value: { error?: string } }).value : undefined;

		expect(response.status).toBe(404);
		expect(errorPayload?.error).toBe("chat not found");
	} finally {
		await cleanup();
	}
});

test("GET /v1/chats/:id/messages supports cursor pagination keeping ascending order", async () => {
	const { baseUrl, cleanup, client, databasePath } = await createTestServer();
	const database = new Database(databasePath);
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-message-pagination-"));

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "message-pagination" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		for (let index = 1; index <= 12; index += 1) {
			const messageId = `message-${String(index).padStart(2, "0")}`;
			const createdAt = `2026-01-01T00:00:${String(index).padStart(2, "0")}.000Z`;
			database
				.prepare("INSERT INTO messages (id, chatId, role, content, createdAt) VALUES (?, ?, ?, ?, ?)")
				.run(messageId, chatId, "user", `content-${String(index)}`, createdAt);
		}

		const firstResponse = await fetch(`${baseUrl}/v1/chats/${chatId}/messages?limit=5`, {
			headers: {
				authorization: "Bearer local-dev-token",
			},
		});
		const firstPayload = await firstResponse.json() as {
			hasMore: boolean;
			messages: Array<{ id: string }>;
			nextBeforeMessageId: string | null;
		};

		expect(firstResponse.status).toBe(200);
		expect(firstPayload.hasMore).toBe(true);
		expect(firstPayload.nextBeforeMessageId).toBe("message-08");
		expect(firstPayload.messages.map((message) => message.id)).toEqual([
			"message-08",
			"message-09",
			"message-10",
			"message-11",
			"message-12",
		]);

		const secondResponse = await fetch(
			`${baseUrl}/v1/chats/${chatId}/messages?limit=5&beforeMessageId=${encodeURIComponent(firstPayload.nextBeforeMessageId ?? "")}`,
			{
				headers: {
					authorization: "Bearer local-dev-token",
				},
			},
		);
		const secondPayload = await secondResponse.json() as {
			hasMore: boolean;
			messages: Array<{ id: string }>;
			nextBeforeMessageId: string | null;
		};

		expect(secondResponse.status).toBe(200);
		expect(secondPayload.hasMore).toBe(true);
		expect(secondPayload.nextBeforeMessageId).toBe("message-03");
		expect(secondPayload.messages.map((message) => message.id)).toEqual([
			"message-03",
			"message-04",
			"message-05",
			"message-06",
			"message-07",
		]);

		const thirdResponse = await fetch(
			`${baseUrl}/v1/chats/${chatId}/messages?limit=5&beforeMessageId=${encodeURIComponent(secondPayload.nextBeforeMessageId ?? "")}`,
			{
				headers: {
					authorization: "Bearer local-dev-token",
				},
			},
		);
		const thirdPayload = await thirdResponse.json() as {
			hasMore: boolean;
			messages: Array<{ id: string }>;
			nextBeforeMessageId: string | null;
		};

		expect(thirdResponse.status).toBe(200);
		expect(thirdPayload.hasMore).toBe(false);
		expect(thirdPayload.nextBeforeMessageId).toBeNull();
		expect(thirdPayload.messages.map((message) => message.id)).toEqual([
			"message-01",
			"message-02",
		]);
	} finally {
		database.close();
		rmSync(workspaceRoot, { force: true, recursive: true });
		await cleanup();
	}
});

test("GET /v1/chats/:id/messages returns turn snapshots for only the visible page", async () => {
	const { baseUrl, cleanup, client, databasePath } = await createTestServer();
	const database = new Database(databasePath);
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-message-turn-page-"));

	const createTurnPayload = (turnId: string, summary: string) => ({
		finishedAtMs: 2,
		itemOrder: ["item-1"],
		itemsById: {
			"item-1": {
				body: "",
				expandedByUser: false,
				finishedAtMs: 2,
				id: "item-1",
				isExpanded: false,
				output: "",
				startedAtMs: 1,
				state: "collapsed",
				summary,
				type: "tool",
			},
		},
		startedAtMs: 1,
		status: "completed",
		turnId,
	});

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "message-turn-page" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		for (let index = 1; index <= 12; index += 1) {
			const messageId = `message-${String(index).padStart(2, "0")}`;
			const createdAt = `2026-01-01T00:00:${String(index).padStart(2, "0")}.000Z`;
			database
				.prepare("INSERT INTO messages (id, chatId, role, content, createdAt) VALUES (?, ?, ?, ?, ?)")
				.run(messageId, chatId, index % 2 === 0 ? "assistant" : "user", `content-${String(index)}`, createdAt);
		}

		database
			.prepare(
				"INSERT INTO chat_turn_snapshots (turnId, chatId, anchorMessageId, payloadJson, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)",
			)
			.run(
				"turn-01",
				chatId,
				"message-01",
				JSON.stringify(createTurnPayload("turn-01", "oldest page")),
				"2026-01-01T00:00:01.000Z",
				"2026-01-01T00:00:01.000Z",
			);
		database
			.prepare(
				"INSERT INTO chat_turn_snapshots (turnId, chatId, anchorMessageId, payloadJson, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)",
			)
			.run(
				"turn-09",
				chatId,
				"message-09",
				JSON.stringify(createTurnPayload("turn-09", "visible page first")),
				"2026-01-01T00:00:09.000Z",
				"2026-01-01T00:00:09.000Z",
			);
		database
			.prepare(
				"INSERT INTO chat_turn_snapshots (turnId, chatId, anchorMessageId, payloadJson, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)",
			)
			.run(
				"turn-12",
				chatId,
				"message-12",
				JSON.stringify(createTurnPayload("turn-12", "visible page last")),
				"2026-01-01T00:00:12.000Z",
				"2026-01-01T00:00:12.000Z",
			);

		const response = await fetch(`${baseUrl}/v1/chats/${chatId}/messages?limit=5`, {
			headers: {
				authorization: "Bearer local-dev-token",
			},
		});
		const payload = await response.json() as {
			messages: Array<{ id: string }>;
			turns: Array<{ turnId: string; itemsById: Record<string, { summary: string }> }>;
		};

		expect(response.status).toBe(200);
		expect(payload.messages.map((message) => message.id)).toEqual([
			"message-08",
			"message-09",
			"message-10",
			"message-11",
			"message-12",
		]);
		expect(payload.turns.map((turn) => turn.turnId)).toEqual(["turn-09", "turn-12"]);
		expect(payload.turns[0]?.itemsById["item-1"]?.summary).toBe("visible page first");
		expect(payload.turns[1]?.itemsById["item-1"]?.summary).toBe("visible page last");
	} finally {
		database.close();
		rmSync(workspaceRoot, { force: true, recursive: true });
		await cleanup();
	}
});

test("GET /v1/chats/:id/messages responds with gzip when accepted by client", async () => {
	const { baseUrl, cleanup, client, databasePath } = await createTestServer();
	const database = new Database(databasePath);
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-message-gzip-"));

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "message-gzip" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		database
			.prepare("INSERT INTO messages (id, chatId, role, content, createdAt) VALUES (?, ?, ?, ?, ?)")
			.run(
				"message-gzip-1",
				chatId,
				"assistant",
				"x".repeat(3_000),
				"2026-01-01T00:00:00.000Z",
			);

		const response = await fetch(`${baseUrl}/v1/chats/${chatId}/messages`, {
			headers: {
				"accept-encoding": "gzip",
				authorization: "Bearer local-dev-token",
			},
		});
		const payload = await response.json() as {
			messages: Array<{ id: string }>;
		};

		expect(response.status).toBe(200);
		expect(response.headers.get("content-encoding")).toBe("gzip");
		expect(response.headers.get("vary")).toContain("accept-encoding");
		expect(payload.messages).toHaveLength(1);
		expect(payload.messages[0]?.id).toBe("message-gzip-1");
	} finally {
		database.close();
		rmSync(workspaceRoot, { force: true, recursive: true });
		await cleanup();
	}
});

test("GET /v1/chats/:id/stream-events returns ordered and paginated events", async () => {
	const { baseUrl, cleanup, client, databasePath } = await createTestServer();
	const database = new Database(databasePath);
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-stream-events-"));

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "stream-events" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		database
			.prepare("INSERT INTO chat_stream_events (chatId, eventJson, turnId, createdAt) VALUES (?, ?, ?, ?)")
			.run(chatId, "{\"type\":\"turn_started\",\"turnId\":\"turn-1\"}", "turn-1", "2026-01-01T00:00:00.001Z");
		database
			.prepare("INSERT INTO chat_stream_events (chatId, eventJson, turnId, createdAt) VALUES (?, ?, ?, ?)")
			.run(
				chatId,
				"{\"type\":\"item_started\",\"turnId\":\"turn-1\",\"itemId\":\"tool-1\",\"itemType\":\"tool\"}",
				"turn-1",
				"2026-01-01T00:00:00.002Z",
			);
		database
			.prepare("INSERT INTO chat_stream_events (chatId, eventJson, turnId, createdAt) VALUES (?, ?, ?, ?)")
			.run(chatId, "{\"type\":\"turn_completed\",\"turnId\":\"turn-1\"}", "turn-1", "2026-01-01T00:00:00.003Z");

		const firstResponse = await fetch(
			`${baseUrl}/v1/chats/${chatId}/stream-events?afterId=0&limit=2`,
			{
				headers: {
					authorization: "Bearer local-dev-token",
				},
			},
		);
		const firstPayload = await firstResponse.json() as {
			events: Array<{ id: number; event: { type: string } }>;
			hasMore: boolean;
			nextAfterId: number | null;
		};

		expect(firstResponse.status).toBe(200);
		expect(firstPayload.events).toHaveLength(2);
		expect(firstPayload.events[0]?.event.type).toBe("turn_started");
		expect(firstPayload.events[1]?.event.type).toBe("item_started");
		expect(firstPayload.hasMore).toBe(true);
		expect(firstPayload.nextAfterId).toBe(firstPayload.events[1]?.id ?? null);

		const secondResponse = await fetch(
			`${baseUrl}/v1/chats/${chatId}/stream-events?afterId=${firstPayload.nextAfterId ?? 0}&limit=2`,
			{
				headers: {
					authorization: "Bearer local-dev-token",
				},
			},
		);
		const secondPayload = await secondResponse.json() as {
			events: Array<{ id: number; event: { type: string } }>;
			hasMore: boolean;
			nextAfterId: number | null;
		};

		expect(secondResponse.status).toBe(200);
		expect(secondPayload.events).toHaveLength(1);
		expect(secondPayload.events[0]?.event.type).toBe("turn_completed");
		expect(secondPayload.hasMore).toBe(false);
		expect(secondPayload.nextAfterId).toBeNull();
	} finally {
		database.close();
		rmSync(workspaceRoot, { force: true, recursive: true });
		await cleanup();
	}
});

test("GET /v1/chats/:id/stream-events returns 404 for missing chat", async () => {
	const { baseUrl, cleanup } = await createTestServer();

	try {
		const response = await fetch(
			`${baseUrl}/v1/chats/non-existing/stream-events`,
			{
				headers: {
					authorization: "Bearer local-dev-token",
				},
			},
		);
		const payload = await response.json() as { error?: string };

		expect(response.status).toBe(404);
		expect(payload.error).toBe("chat not found");
	} finally {
		await cleanup();
	}
});
