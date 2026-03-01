import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { createEdenClient, createEdenWsClient } from "../../eden-client";
import { createTestServer } from "../../shared/core/test-server";
import { getCodexAvailability } from "../provider/codex-test-gate";

type ServerEvent =
	| {
			data: {
				chatId: string;
				delta?: string;
				diffAdded?: number;
				diffRemoved?: number;
				status?: "pending" | "running" | "completed" | "failed";
				updatedAt?: string;
				code?: string;
				message?: string;
			};
			event: "assistant_delta" | "assistant_done" | "chat_updated" | "error";
	  };

const parseEvent = (raw: unknown): ServerEvent | null => {
	if (typeof raw === "string") {
		try {
			return parseEvent(JSON.parse(raw));
		} catch {
			return null;
		}
	}

	if (!raw || typeof raw !== "object") {
		return null;
	}

	const asOuter = raw as { data?: unknown; event?: unknown };
	if (typeof asOuter.event === "string" && asOuter.data && typeof asOuter.data === "object") {
		return {
			data: asOuter.data as ServerEvent["data"],
			event: asOuter.event as ServerEvent["event"],
		};
	}

	if (!asOuter.data || typeof asOuter.data !== "object") {
		return null;
	}

	const nested = asOuter.data as { data?: unknown; event?: unknown };
	if (typeof nested.event !== "string" || !nested.data || typeof nested.data !== "object") {
		return null;
	}

	return {
		data: nested.data as ServerEvent["data"],
		event: nested.event as ServerEvent["event"],
	};
};

const waitForCondition = async (
	predicate: () => boolean,
	timeoutMs = 60_000,
	label = "ws condition",
): Promise<void> => {
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
				reject(new Error(`timed out waiting for ${label}`));
			}
		}, 25);
	});
};

const codexAvailability = getCodexAvailability();
const codexTest = test.skipIf(!codexAvailability.available);
const skipReasonSuffix = codexAvailability.available ? "" : ` (skip: ${codexAvailability.reason})`;

codexTest(`WS emits intermediate thinking/tool deltas before assistant_done${skipReasonSuffix}`, async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-ws-codex-flow-"));
	const { baseUrl, cleanup, client } = await createTestServer();

	let ws: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "codex-stream" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		ws = await createEdenWsClient(createEdenClient({ baseUrl }));
		const events: ServerEvent[] = [];

		ws.subscribe((raw: unknown) => {
			const event = parseEvent((raw as { data: unknown }).data);
			if (!event || event.data.chatId !== chatId) {
				return;
			}

			events.push(event);
		});

		ws.send({
			data: {
				chatId,
				permissionMode: "default",
				text: "Run exactly one shell command: pwd. After that, reply with exactly: ws-codex-flow-ok",
			},
			event: "user_message",
		});

		await waitForCondition(
			() =>
				(events.some((event) => event.event === "assistant_done") &&
					events.some((event) => event.event === "chat_updated" && event.data.status === "completed")) ||
				events.some((event) => event.event === "error"),
			150_000,
		);

		const providerError = events.find((event) => event.event === "error");
		expect(providerError).toBeUndefined();

		const runningIndex = events.findIndex(
			(event) => event.event === "chat_updated" && event.data.status === "running",
		);
		const deltaIndex = events.findIndex((event) => event.event === "assistant_delta");
		const doneIndex = events.findIndex((event) => event.event === "assistant_done");
		const completedIndex = events.findIndex(
			(event) => event.event === "chat_updated" && event.data.status === "completed",
		);

		expect(runningIndex).toBeGreaterThanOrEqual(0);
		expect(deltaIndex).toBeGreaterThan(runningIndex);
		expect(doneIndex).toBeGreaterThan(deltaIndex);
		expect(completedIndex).toBeGreaterThan(doneIndex);

		const deltas = events
			.filter((event) => event.event === "assistant_delta")
			.map((event) => event.data.delta ?? "");
		const hasThinkingDelta = deltas.some((delta) => delta.includes("Thinking"));
		const hasToolDelta = deltas.some(
			(delta) =>
				delta.includes("Tool calling") || delta.includes("Tool output") || delta.includes("Tool finished"),
		);

		expect(hasThinkingDelta).toBe(true);
		expect(hasToolDelta).toBe(true);

		const messages = await client.v1.chats({ id: chatId }).messages.get();
		const storedMessages = (messages.data as { messages: { content: string; role: "user" | "assistant" }[] })
			.messages;
		const assistantMessage = storedMessages.find((item) => item.role === "assistant");

		expect(storedMessages).toHaveLength(2);
		expect(assistantMessage?.content.toLowerCase()).toContain("ws-codex-flow-ok");
	} finally {
		ws?.close();
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
}, 180_000);

codexTest(`WS keeps codex thread context after websocket reconnect${skipReasonSuffix}`, async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-ws-codex-resume-"));
	const { baseUrl, cleanup, client } = await createTestServer();
	const token = `ws-thread-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;

	let firstSocket: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;
	let secondSocket: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "codex-resume" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		firstSocket = await createEdenWsClient(createEdenClient({ baseUrl }));
		const firstEvents: ServerEvent[] = [];

		firstSocket.subscribe((raw: unknown) => {
			const event = parseEvent((raw as { data: unknown }).data);
			if (!event || event.data.chatId !== chatId) {
				return;
			}
			firstEvents.push(event);
		});

		firstSocket.send({
			data: {
				chatId,
				text: `Remember this token for this thread: ${token}. Reply exactly: STORED ${token}`,
			},
			event: "user_message",
		});

		await waitForCondition(
			() =>
				firstEvents.some((event) => event.event === "assistant_done") &&
				firstEvents.some((event) => event.event === "chat_updated" && event.data.status === "completed"),
			90_000,
		);

		firstSocket.close();

		secondSocket = await createEdenWsClient(createEdenClient({ baseUrl }));
		const secondEvents: ServerEvent[] = [];

		secondSocket.subscribe((raw: unknown) => {
			const event = parseEvent((raw as { data: unknown }).data);
			if (!event || event.data.chatId !== chatId) {
				return;
			}
			secondEvents.push(event);
		});

		secondSocket.send({
			data: {
				chatId,
				text: "What exact token did I ask you to remember earlier in this same thread? Reply with token only.",
			},
			event: "user_message",
		});

		await waitForCondition(
			() =>
				secondEvents.some((event) => event.event === "assistant_done") &&
				secondEvents.some((event) => event.event === "chat_updated" && event.data.status === "completed"),
			90_000,
		);

		const messages = await client.v1.chats({ id: chatId }).messages.get();
		const storedMessages = (messages.data as { messages: { content: string; role: "user" | "assistant" }[] })
			.messages;
		const lastAssistant = [...storedMessages].reverse().find((message) => message.role === "assistant");

		expect(storedMessages).toHaveLength(4);
		expect(lastAssistant?.content).toContain(token);
	} finally {
		firstSocket?.close();
		secondSocket?.close();
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
}, 120_000);

test("WS emits validation error for invalid payload", async () => {
	const { baseUrl, cleanup } = await createTestServer();

	let socket: WebSocket | undefined;
	const events: string[] = [];

	try {
		socket = new WebSocket(`${baseUrl}/v1/ws?token=local-dev-token`);
		await new Promise<void>((resolve) => {
			socket?.addEventListener("open", () => {
				resolve();
			});
		});

		socket.addEventListener("message", (event) => {
			const raw = event.data;
			if (typeof raw === "string") {
				events.push(raw);
				return;
			}

			try {
				events.push(JSON.stringify(raw));
			} catch {
				// ignore non-serializable message payloads
			}
		});

		socket.send(JSON.stringify({ data: { bad: true }, event: "user_message" }));
		socket.send(JSON.stringify({ data: { chatId: "missing" }, event: "unknown" }));
		socket.send(
			JSON.stringify({
				data: {
					chatId: "missing",
					permissionMode: "invalid-mode",
					text: "hello",
				},
				event: "user_message",
			}),
		);

		await new Promise((resolve) => setTimeout(resolve, 80));

		expect(events.some((event) => event.includes("validation"))).toBe(true);
		expect(events.some((event) => event.includes("invalid permission mode"))).toBe(true);
	} finally {
		socket?.close();
		await cleanup();
	}
});
