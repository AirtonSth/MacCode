import { expect, test } from "bun:test";

import { createEdenClient, createEdenWsClient } from "../../eden-client";
import { createTestServer } from "../../shared/core/test-server";

type ServerEvent =
	| {
			data: {
				chatId: string;
				code?: string;
				delta?: string;
				diffAdded?: number;
				diffRemoved?: number;
				message?: string;
				status?: "pending" | "running" | "completed" | "failed";
				updatedAt?: string;
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

	const value = raw as { data: unknown; event: string };

	if (typeof value.event !== "string") {
		return null;
	}

	if (typeof value.data !== "object" || value.data === null) {
		return null;
	}

	const payload = value.data as { chatId?: unknown };

	if (typeof payload.chatId !== "string" && value.event !== "error") {
		return null;
	}

	return {
		data: value.data as ServerEvent["data"],
		event: value.event as ServerEvent["event"],
	};
};

const waitForCondition = async (predicate: () => boolean, timeoutMs = 4000): Promise<void> => {
	await new Promise<void>((resolve, reject) => {
		const startedAt = performance.now();
		const timer = setInterval(() => {
			if (!predicate()) {
				if (performance.now() - startedAt >= timeoutMs) {
					clearInterval(timer);
					reject(new Error("timed out waiting for ws condition"));
				}

				return;
			}

			clearInterval(timer);
			resolve();
		}, 20);
	});
};

const waitForEvent = async (predicate: () => boolean, timeoutMs = 4000): Promise<void> => {
	await new Promise<void>((resolve, reject) => {
		const startedAt = performance.now();
		const timer = setInterval(() => {
			if (!predicate()) {
				if (performance.now() - startedAt >= timeoutMs) {
					clearInterval(timer);
					reject(new Error("timed out waiting for ws event"));
				}

				return;
			}

			clearInterval(timer);
			resolve();
		}, 20);
	});
};

test("join_chat does not replay and stream emits assistant_delta + done", async () => {
	const { baseUrl, cleanup, client } = await createTestServer();

	try {
		const project = await client.v1.projects.post({ path: "/tmp" });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "chat" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		const authClient = createEdenClient({ baseUrl });
		const ws = await createEdenWsClient(authClient);
		const events: ServerEvent[] = [];

		ws.subscribe((event) => {
			const parsed = parseEvent((event as { data: unknown }).data);

			if (!parsed) {
				return;
			}

			events.push(parsed);
		});

		ws.send({ data: { chatId }, event: "join_chat" });
		await new Promise((resolve) => setTimeout(resolve, 30));
		expect(events.length).toBe(0);

		ws.send({ data: { chatId, text: "ping" }, event: "user_message" });
		await waitForCondition(() =>
			events.some(
				(event) => event.event === "assistant_done" && event.data.chatId === chatId,
			),
		);

		const orderedEvents = events.filter((event) => event.data.chatId === chatId);
		const runningIndex = orderedEvents.findIndex(
			(event) => event.event === "chat_updated" && event.data.status === "running",
		);
		const doneIndex = orderedEvents.findIndex(
			(event) => event.event === "assistant_done" && event.data.chatId === chatId,
		);
		const completedIndex = orderedEvents.findIndex(
			(event) => event.event === "chat_updated" && event.data.status === "completed",
		);
		const deltaIndex = orderedEvents.findIndex((event) => event.event === "assistant_delta");

		expect(runningIndex).toBeGreaterThanOrEqual(0);
		expect(deltaIndex).toBeGreaterThan(runningIndex);
		expect(doneIndex).toBeGreaterThan(deltaIndex);
		expect(completedIndex).toBeGreaterThan(doneIndex);

		const messages = await client.v1.chats({ id: chatId }).messages.get();
		const messagesResult = (messages.data as { messages: { role: "user" | "assistant" }[] }).messages;

		expect(messagesResult.length).toBe(2);
		expect(messagesResult[0].role).toBe("user");
		expect(messagesResult[1].role).toBe("assistant");
		ws.close();
	} finally {
		await cleanup();
	}
});

test("Provider fake failure marks chat as failed", async () => {
	const { baseUrl, cleanup, client } = await createTestServer();
	const previous = process.env.REMOTECODE_FAKE_PROVIDER_FORCE_FAIL;

	process.env.REMOTECODE_FAKE_PROVIDER_FORCE_FAIL = "1";

	let failureObserved = false;
	let chatUpdatedFailed = false;
	let ended = false;
	let socket: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;

	try {
		const project = await client.v1.projects.post({ path: "/tmp" });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "failure" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		socket = await createEdenWsClient(createEdenClient({ baseUrl }));
		await new Promise<void>((resolve) => {
			socket?.subscribe((event: any) => {
				const data = event?.data as { data?: unknown; event?: string } | undefined;

				if (!data || typeof data.event !== "string") {
					return;
				}

				const payload = data.data as { code?: string; status?: string } | undefined;

				if (data.event === "error" && payload?.code === "provider_failed") {
					failureObserved = true;
				}

				if (data.event === "chat_updated" && payload?.status === "failed") {
					chatUpdatedFailed = true;
				}

				if (failureObserved && chatUpdatedFailed) {
					ended = true;
					resolve();
				}
			});
			socket?.send({ data: { chatId, text: "will fail" }, event: "user_message" });
		});

		expect(ended).toBe(true);
		expect(failureObserved).toBe(true);
		expect(chatUpdatedFailed).toBe(true);
	} finally {
		if (previous === undefined) {
			delete process.env.REMOTECODE_FAKE_PROVIDER_FORCE_FAIL;
		} else {
			process.env.REMOTECODE_FAKE_PROVIDER_FORCE_FAIL = previous;
		}

		socket?.close();
		await cleanup();
	}
});

test("WS emits validation error for invalid payload", async () => {
	const { baseUrl, cleanup } = await createTestServer();

	let socket: WebSocket | undefined;

	const events: string[] = [];

	try {
		socket = new WebSocket(`${baseUrl}/v1/ws?token=local-dev-token`);
		await new Promise<void>((resolve) => {
			socket!.addEventListener("open", () => {
				resolve();
			});
		});

		socket.addEventListener("message", (event) => {
			const {data} = event;

			if (typeof data === "string") {
				events.push(data);

				return;
			}

			try {
				events.push(JSON.stringify(data));
			} catch {
				// ignore non-serializable payloads
			}
		});

		socket.send(JSON.stringify({ data: { bad: true }, event: "user_message" }));
		socket.send(JSON.stringify({ data: { chatId: "missing" }, event: "unknown" }));

		await new Promise((resolve) => setTimeout(resolve, 80));

		expect(events.some((event) => event.includes("validation"))).toBe(true);
	} finally {
		socket?.close();
		await cleanup();
	}
});

test("WS returns chat_not_found when user sends message to missing chat", async () => {
	const { baseUrl, cleanup, client } = await createTestServer();

	let missingChatError: ServerEvent | null = null;
	let socket: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;

	try {
		await client.v1.projects.post({ path: "/tmp" });

		socket = await createEdenWsClient(createEdenClient({ baseUrl }));
		socket?.subscribe((raw) => {
			const event = parseEvent((raw as { data: unknown }).data);

			if (!event) {
				return;
			}

			if (event.event === "error" && event.data.code === "chat_not_found") {
				missingChatError = event;
			}
		});

		socket?.send({ data: { chatId: "missing-chat-id", text: "should fail" }, event: "user_message" });
		await waitForEvent(() => missingChatError !== null, 5000);

		expect(missingChatError).toMatchObject({
			data: {
				chatId: "missing-chat-id",
				code: "chat_not_found",
			},
			event: "error",
		});
	} finally {
		socket?.close();
		await cleanup();
	}
});
