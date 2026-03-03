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
