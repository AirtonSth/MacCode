import { expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { RemoteCodeApi } from "../../../shared/api/remotecode-http";
import { createTestServer } from "../../../../bun/server/shared/core/test-server";
import { sendWorkspaceMessage } from "./send-message";

test("frontend e2e message send auto-creates thread when none selected", async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-frontend-send-e2e-"));
	const { baseUrl, cleanup } = await createTestServer();
	const sentPayloads: Array<{ chatId: string; text: string }> = [];
	const token = "local-dev-token";
	let selectedProjectId: string | null = null;
	let selectedChatId: string | null = null;

	const api = RemoteCodeApi.createClient({
		baseUrl,
		token,
	});

	try {
		const project = await api.createProject({ name: "Frontend e2e", path: workspaceRoot });
		selectedProjectId = project.id;

		const result = await sendWorkspaceMessage({
			createChatId: async () => {
				if (!selectedProjectId) {
					return null;
				}

				const chat = await api.createChat(selectedProjectId, "Auto thread");
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
				sentPayloads.push({ chatId, text });
			},
			selectedChatId,
			selectedChatProvider: null,
			selectedProjectId,
			text: "Hello auto thread",
		});

		const chats = await api.listChats(selectedProjectId!);

		expect(result.chatId).toBe(selectedChatId);
		expect(result.sent).toBe(true);
		expect(result.createdNewChat).toBe(true);
		expect(chats.some((chat) => chat.id === result.chatId && chat.provider === "codex")).toBe(true);
		expect(sentPayloads).toEqual([
			{
				chatId: result.chatId!,
				text: "Hello auto thread",
			},
		]);
	} finally {
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
});

test("frontend e2e message send creates a new codex chat when selected chat is legacy fake", async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-frontend-send-legacy-"));
	const { baseUrl, cleanup, databasePath } = await createTestServer();
	const sentPayloads: Array<{ chatId: string; text: string }> = [];
	const token = "local-dev-token";
	let selectedProjectId: string | null = null;
	let selectedChatId: string | null = null;
	let selectedChatProvider: "fake" | "codex" | "claude" | null = null;

	const api = RemoteCodeApi.createClient({
		baseUrl,
		token,
	});

	try {
		const project = await api.createProject({ name: "Frontend e2e legacy", path: workspaceRoot });
		selectedProjectId = project.id;

		const legacyChat = await api.createChat(selectedProjectId, "Legacy thread");
		selectedChatId = legacyChat.id;
		selectedChatProvider = "fake";

		const sqlite = new Database(databasePath);
		try {
			sqlite.prepare("UPDATE chats SET provider = 'fake' WHERE id = ?").run(selectedChatId);
		} finally {
			sqlite.close();
		}

		const result = await sendWorkspaceMessage({
			createChatId: async () => {
				if (!selectedProjectId) {
					return null;
				}

				const chat = await api.createChat(selectedProjectId, "Auto codex thread");
				selectedChatId = chat.id;
				selectedChatProvider = chat.provider;
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
				sentPayloads.push({ chatId, text });
			},
			selectedChatId,
			selectedChatProvider,
			selectedProjectId,
			text: "Continue from legacy",
		});

		const chats = await api.listChats(selectedProjectId!);

		expect(result.sent).toBe(true);
		expect(result.createdNewChat).toBe(true);
		expect(result.chatId).not.toBe(legacyChat.id);
		expect(chats.some((chat) => chat.id === legacyChat.id && chat.provider === "fake")).toBe(true);
		expect(chats.some((chat) => chat.id === result.chatId && chat.provider === "codex")).toBe(true);
		expect(sentPayloads).toEqual([
			{
				chatId: result.chatId!,
				text: "Continue from legacy",
			},
		]);
	} finally {
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
});
