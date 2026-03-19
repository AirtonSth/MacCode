/* eslint-disable import/no-unresolved */
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { ModuleKind, ScriptTarget, transpileModule } from "typescript";
import { describe, expect, test } from "bun:test";

import type { MessageDTO, WorkspaceAction, WorkspaceState } from "./useWorkspaceStore";

type WorkspaceReducer = (state: WorkspaceState, action: WorkspaceAction) => WorkspaceState;

const workspaceReducer = (() => {
	const sourcePath = fileURLToPath(new URL("./useWorkspaceStore.ts", import.meta.url));
	const sourceCode = readFileSync(sourcePath, "utf8");
	const instrumentedSourceCode = `${sourceCode}\n\nexports.__workspaceReducerForTests = workspaceReducer;`;
	const compiled = transpileModule(instrumentedSourceCode, {
		compilerOptions: {
			module: ModuleKind.CommonJS,
			target: ScriptTarget.ES2020,
		},
	});

	const moduleExports = {} as { [key: string]: unknown };
	const module = { exports: moduleExports };
	const require = createRequire(import.meta.url);
	const execute = new Function("require", "module", "exports", compiled.outputText);
	execute(require, module, moduleExports);

	const reducer = module.exports.__workspaceReducerForTests;

	if (typeof reducer !== "function") {
		throw new Error("Unable to access workspaceReducer from useWorkspaceStore.ts");
	}

	return reducer as WorkspaceReducer;
})();

const baseWorkspaceState = (): WorkspaceState => ({
	baseUrl: "http://127.0.0.1:3001",
	token: "local-dev-token",
	projects: [],
	selectedProjectId: null,
	chats: [],
	selectedChatId: null,
	messageWindow: {
		chatId: null,
		hasMore: false,
		latestDirty: false,
		messages: [],
		mode: "latest",
		nextBeforeMessageId: null,
		turns: [],
	},
	streamingByChat: {},
	streamingActiveByChat: {},
	streamTurnsByChat: {},
	streamHistoryByChat: {},
	lastAssistantEventIdByChat: {},
	sendingByChat: {},
	isSendingMessage: false,
	isCreatingProject: false,
	isCreatingChat: false,
	projectsLoading: false,
	chatsLoading: false,
	messagesLoading: false,
	connectionState: "idle",
	connectionError: null,
	errors: [],
});

const makeMessage = (id: string, index: number): MessageDTO => ({
	chatId: "chat-1",
	content: `message-${id}`,
	createdAt: `2026-01-01T00:00:00.${String(index).padStart(3, "0")}Z`,
	id,
	role: index % 2 === 0 ? "user" : "assistant",
});

describe("D-17: MESSAGE_WINDOW_PAGE_SIZE increased to 25", () => {
	test("window retains up to 25 messages without trimming", () => {
		const initialState: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: "chat-1",
			messageWindow: {
				chatId: "chat-1",
				hasMore: false,
				latestDirty: false,
				messages: Array.from({ length: 24 }, (_, i) => makeMessage(`msg-${i}`, i)),
				mode: "latest",
				nextBeforeMessageId: null,
				turns: [],
			},
		};

		// Upsert a 25th message via the reducer
		const result = workspaceReducer(initialState, {
			type: "UPSERT_MESSAGE_IN_WINDOW",
			payload: {
				chatId: "chat-1",
				message: makeMessage("msg-24", 24),
			},
		});

		// All 25 messages should be present (not trimmed)
		expect(result.messageWindow.messages.length).toBe(25);
		expect(result.messageWindow.hasMore).toBe(false);
	});

	test("window trims when exceeding 25 messages, keeping latest 25", () => {
		const initialState: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: "chat-1",
			messageWindow: {
				chatId: "chat-1",
				hasMore: false,
				latestDirty: false,
				messages: Array.from({ length: 25 }, (_, i) => makeMessage(`msg-${i}`, i)),
				mode: "latest",
				nextBeforeMessageId: null,
				turns: [],
			},
		};

		// Upsert a 26th message; the window should trim to 25
		const result = workspaceReducer(initialState, {
			type: "UPSERT_MESSAGE_IN_WINDOW",
			payload: {
				chatId: "chat-1",
				message: makeMessage("msg-25", 25),
			},
		});

		expect(result.messageWindow.messages.length).toBe(25);
		expect(result.messageWindow.hasMore).toBe(true);
		// The oldest message should have been trimmed
		const messageIds = result.messageWindow.messages.map((m: MessageDTO) => m.id);
		expect(messageIds).not.toContain("msg-0");
		expect(messageIds).toContain("msg-25");
	});

	test("6 messages are no longer trimmed (regression: old window size was 5)", () => {
		const initialState: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: "chat-1",
			messageWindow: {
				chatId: "chat-1",
				hasMore: false,
				latestDirty: false,
				messages: Array.from({ length: 5 }, (_, i) => makeMessage(`msg-${i}`, i)),
				mode: "latest",
				nextBeforeMessageId: null,
				turns: [],
			},
		};

		// Upsert a 6th message
		const result = workspaceReducer(initialState, {
			type: "UPSERT_MESSAGE_IN_WINDOW",
			payload: {
				chatId: "chat-1",
				message: makeMessage("msg-5", 5),
			},
		});

		// With the old page size of 5, this would have trimmed. Now it should keep all 6.
		expect(result.messageWindow.messages.length).toBe(6);
		expect(result.messageWindow.hasMore).toBe(false);
	});

	test("source code defines MESSAGE_WINDOW_PAGE_SIZE as 25", () => {
		const sourcePath = fileURLToPath(new URL("./useWorkspaceStore.ts", import.meta.url));
		const source = readFileSync(sourcePath, "utf8");
		expect(source).toContain("const MESSAGE_WINDOW_PAGE_SIZE = 25;");
	});
});
