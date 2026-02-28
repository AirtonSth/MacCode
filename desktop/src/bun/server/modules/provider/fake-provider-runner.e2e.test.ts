import { expect, test } from "bun:test";

import { createEdenClient, createEdenWsClient } from "../../eden-client";
import { createTestServer } from "../../shared/core/test-server";

interface ProviderEvent {
	data: {
		chatId: string;
		code?: string;
		status?: "pending" | "running" | "completed" | "failed";
	};
	event: "assistant_delta" | "assistant_done" | "chat_updated" | "error";
}

const parseProviderEvent = (raw: unknown): ProviderEvent | null => {
	if (typeof raw === "string") {
		try {
			return parseProviderEvent(JSON.parse(raw));
		} catch {
			return null;
		}
	}

	if (!raw || typeof raw !== "object") {
		return null;
	}

	const outer = raw as { data?: unknown; event?: string };

	if (typeof outer.event === "string" && outer.data && typeof outer.data === "object") {
		return {
			data: outer.data as ProviderEvent["data"],
			event: outer.event as ProviderEvent["event"],
		};
	}

	const {data} = (raw as { data?: { data?: unknown; event?: string; } });

	if (!data || typeof data !== "object") {
		return null;
	}

	const nested = data as { data?: unknown; event?: string; };

	if (typeof nested.event !== "string" || !nested.data || typeof nested.data !== "object") {
		return null;
	}

	return {
		data: nested.data as ProviderEvent["data"],
		event: nested.event as ProviderEvent["event"],
	};
};

const waitFor = async (predicate: () => boolean, timeoutMs = 4000): Promise<void> => {
	await new Promise<void>((resolve, reject) => {
		const startedAt = performance.now();
		const timer = setInterval(() => {
			if (!predicate()) {
				if (performance.now() - startedAt >= timeoutMs) {
					clearInterval(timer);
					reject(new Error("timeout while waiting for provider event"));
				}

				return;
			}

			clearInterval(timer);
			resolve();
		}, 20);
	});
};

test("FakeProviderRunner participa do fluxo end-to-end via WS", async () => {
	const { baseUrl, cleanup, client } = await createTestServer();

	let ws: Awaited<ReturnType<typeof createEdenWsClient>> | undefined;

	try {
		const project = await client.v1.projects.post({ path: "/tmp" });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "provider e2e" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		ws = await createEdenWsClient(createEdenClient({ baseUrl }));

		const events: ProviderEvent[] = [];

		ws.subscribe((event) => {
			const parsed = parseProviderEvent((event as { data: unknown }).data);

			if (!parsed) {
				return;
			}

			if (parsed.data.chatId !== chatId) {
				return;
			}

			events.push(parsed);
		});

		ws.send({ data: { chatId, text: "provider e2e ping" }, event: "user_message" });

		await waitFor(
			() =>
				events.some((event) => event.event === "assistant_done") &&
				events.some((event) => event.event === "chat_updated" && event.data.status === "completed"),
		);

		expect(events.some((event) => event.event === "assistant_done")).toBe(true);
		expect(
			events.some((event) => event.event === "chat_updated" && event.data.status === "completed"),
		).toBe(true);

		const messages = await client.v1.chats({ id: chatId }).messages.get();
		const list = (messages.data as { messages: { role: "user" | "assistant" }[] }).messages;

		expect(list.length).toBe(2);
		expect(list[0].role).toBe("user");
		expect(list[1].role).toBe("assistant");

	} finally {
		ws?.close();
		await cleanup();
	}
});
