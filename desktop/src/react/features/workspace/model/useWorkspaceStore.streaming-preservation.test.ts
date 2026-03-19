import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { ModuleKind, ScriptTarget, transpileModule } from "typescript";
import { describe, test, expect } from "bun:test";

import type { WorkspaceAction, WorkspaceState, StreamTurnState } from "./useWorkspaceStore";

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

const makeTurn = (turnId: string, status: "running" | "completed" | "failed" = "running"): StreamTurnState => ({
	turnId,
	status,
	itemsById: {},
	itemOrder: [],
	startedAtMs: 1000,
	finishedAtMs: status === "running" ? null : 2000,
});

describe("SET_SELECTED_CHAT transient chat state pruning", () => {
	test("keeps only the newly selected chat transient state when switching", () => {
		const initialState: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: "chat-A",
			messageWindow: {
				chatId: "chat-A",
				hasMore: false,
				latestDirty: false,
				messages: [
					{
						chatId: "chat-A",
						content: "hello from A",
						createdAt: "2026-01-01T00:00:00.100Z",
						id: "msg-a1",
						role: "user",
					},
				],
				mode: "latest",
				nextBeforeMessageId: null,
				turns: [],
			},
			streamingByChat: {
				"chat-A": "partial response for A",
				"chat-B": "partial response for B",
			},
			streamingActiveByChat: {
				"chat-A": true,
				"chat-B": false,
			},
			streamTurnsByChat: {
				"chat-A": makeTurn("turn-a1"),
				"chat-B": makeTurn("turn-b1", "completed"),
			},
			streamHistoryByChat: {
				"chat-A": [makeTurn("turn-a1")],
				"chat-B": [makeTurn("turn-b1", "completed")],
			},
			lastAssistantEventIdByChat: {
				"chat-A": 10,
				"chat-B": 5,
			},
			sendingByChat: {
				"chat-A": true,
				"chat-B": false,
			},
		};

		const updated = workspaceReducer(initialState, {
			type: "SET_SELECTED_CHAT",
			payload: "chat-B",
		});

		expect(updated.streamingByChat).toEqual({
			"chat-B": "partial response for B",
		});
		expect(updated.streamingActiveByChat).toEqual({});
		expect(updated.streamTurnsByChat).toEqual({
			"chat-B": makeTurn("turn-b1", "completed"),
		});
		expect(updated.lastAssistantEventIdByChat).toEqual({
			"chat-B": 5,
		});
		expect(updated.sendingByChat).toEqual({});
	});

	test("keeps only streamHistoryByChat entries for the newly selected chat", () => {
		const historyA: StreamTurnState[] = [
			makeTurn("turn-a1", "completed"),
			makeTurn("turn-a2", "completed"),
		];
		const historyB: StreamTurnState[] = [
			makeTurn("turn-b1", "completed"),
		];

		const initialState: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: "chat-A",
			messageWindow: {
				chatId: "chat-A",
				hasMore: false,
				latestDirty: false,
				messages: [],
				mode: "latest",
				nextBeforeMessageId: null,
				turns: historyA,
			},
			streamHistoryByChat: {
				"chat-A": historyA,
				"chat-B": historyB,
			},
		};

		const updated = workspaceReducer(initialState, {
			type: "SET_SELECTED_CHAT",
			payload: "chat-B",
		});

		expect(updated.streamHistoryByChat["chat-B"]).toEqual(historyB);
		expect(updated.streamHistoryByChat).toEqual({
			"chat-B": historyB,
		});
	});

	test("changes selectedChatId correctly", () => {
		const initialState: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: "chat-A",
			messageWindow: {
				chatId: "chat-A",
				hasMore: false,
				latestDirty: false,
				messages: [],
				mode: "latest",
				nextBeforeMessageId: null,
				turns: [],
			},
		};

		const updated = workspaceReducer(initialState, {
			type: "SET_SELECTED_CHAT",
			payload: "chat-B",
		});

		expect(updated.selectedChatId).toBe("chat-B");

		const setNull = workspaceReducer(initialState, {
			type: "SET_SELECTED_CHAT",
			payload: null,
		});

		expect(setNull.selectedChatId).toBeNull();
	});

	test("resets messageWindow for the new chat", () => {
		const initialState: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: "chat-A",
			messageWindow: {
				chatId: "chat-A",
				hasMore: true,
				latestDirty: true,
				messages: [
					{
						chatId: "chat-A",
						content: "hello",
						createdAt: "2026-01-01T00:00:00.100Z",
						id: "msg-1",
						role: "user",
					},
					{
						chatId: "chat-A",
						content: "world",
						createdAt: "2026-01-01T00:00:00.200Z",
						id: "msg-2",
						role: "assistant",
					},
				],
				mode: "older",
				nextBeforeMessageId: "msg-1",
				turns: [makeTurn("turn-old", "completed")],
			},
		};

		const updated = workspaceReducer(initialState, {
			type: "SET_SELECTED_CHAT",
			payload: "chat-B",
		});

		expect(updated.messageWindow).toEqual({
			chatId: "chat-B",
			hasMore: false,
			latestDirty: false,
			messages: [],
			mode: "latest",
			nextBeforeMessageId: null,
			turns: [],
		});
	});
});
