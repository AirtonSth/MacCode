import { expect, test } from "bun:test";

import { RemoteCodeApi } from "../../../shared/api/remotecode-http";
import { RemoteCodeRealtime, type ServerWsEvent } from "../../../shared/realtime/remotecode-ws";
import { createTestServer } from "../../../bun/server/shared/core/test-server";
import { sendWorkspaceMessage } from "./send-message";

const waitForCondition = async (
	predicate: () => boolean,
	timeoutMs = 5000,
	intervalMs = 25,
): Promise<void> => {
	await new Promise<void>((resolve, reject) => {
		const start = Date.now();
		const timer = setInterval(() => {
			if (predicate()) {
				clearInterval(timer);
				resolve();
				return;
			}

			if (Date.now() - start >= timeoutMs) {
				clearInterval(timer);
				reject(new Error("Timed out waiting for e2e condition"));
			}
		}, intervalMs);
	});
};

test("frontend e2e message send auto-creates thread when none selected", async () => {
	const { baseUrl, cleanup } = await createTestServer();
	let connectionState: "idle" | "connected" | "disconnected" | "connecting" | "reconnecting" = "idle";
	const assistantDoneChats = new Set<string>();
	const capturedErrors: Array<ServerWsEvent> = [];
	const token = "local-dev-token";
	let selectedProjectId: string | null = null;
	let selectedChatId: string | null = null;

	const api = RemoteCodeApi.createClient({
		baseUrl,
		token,
	});
	const ws = RemoteCodeRealtime.createClient({
		baseUrl,
		onConnectionStateChange: (state) => {
			connectionState = state;
		},
		onEvent: (event) => {
			if (event.event === "assistant_done") {
				assistantDoneChats.add(event.data.chatId);
			}

			if (event.event === "error") {
				capturedErrors.push(event);
			}
		},
		token,
	});

	try {
		const project = await api.createProject({ name: "Frontend e2e", path: "/tmp/frontend-e2e-project" });
		selectedProjectId = project.id;

		ws.connect();
		await waitForCondition(() => connectionState === "connected");

		const result = await sendWorkspaceMessage({
			createChatId: async () => {
				if (!selectedProjectId) {
					return null;
				}

				const chat = await api.createChat(selectedProjectId, { title: "Auto thread" });
				selectedChatId = chat.id;
				return chat.id;
			},
			createTimestamp: () => "2026-01-01T00:00:00.000Z",
			hasOpenWebSocket: true,
			onAppendMessage: () => {
				// no-op for this e2e
			},
			onClearStreaming: () => {
				// no-op for this e2e
			},
			onCreateMessageError: () => {
				// no-op for this e2e
			},
			onSetSending: () => {
				// no-op for this e2e
			},
			onSendUserMessage: (chatId, text) => {
				ws.sendUserMessage(chatId, text);
			},
			selectedChatId,
			selectedProjectId,
			text: "Hello auto thread",
		});

		const createdChatId = result.chatId;
		await waitForCondition(() => {
			if (!createdChatId) {
				return false;
			}

			return assistantDoneChats.has(createdChatId);
		});

		const messages = await api.listMessages(createdChatId!);
		const stored = messages.map((item) => item.content);

		expect(result.chatId).toBe(selectedChatId);
		expect(result.sent).toBe(true);
		expect(result.createdNewChat).toBe(true);
		expect(stored).toEqual(expect.arrayContaining(["Hello auto thread"]));
		expect(capturedErrors).toHaveLength(0);
	} finally {
		ws.disconnect();
		await cleanup();
	});
});
