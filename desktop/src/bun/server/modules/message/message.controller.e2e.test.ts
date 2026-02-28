import { expect, test } from "bun:test";

import { createTestServer } from "../../shared/core/test-server";

test("GET /v1/chats/:id/messages returns messages in ascending createdAt order", async () => {
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

		await new Promise<void>((resolve) => {
			const interval = setInterval(() => {
				const hasDone = events.some((item) => {
					if (typeof item.data !== "string") {
						return false;
					}

					try {
						const parsed = JSON.parse(item.data);

						return parsed?.event === "assistant_done" && parsed?.data?.chatId === chatId;
					} catch {
						return false;
					}
				});

				if (hasDone) {
					clearInterval(interval);
					resolve();
				}
			}, 40);
		});

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
});

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
