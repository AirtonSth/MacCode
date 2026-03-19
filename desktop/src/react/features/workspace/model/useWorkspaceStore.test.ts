import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { ModuleKind, ScriptTarget, transpileModule } from "typescript";
import { expect, test } from "bun:test";

import type { WorkspaceAction, WorkspaceState } from "./useWorkspaceStore";

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

test("SET_SELECTED_PROJECT updates selection and clears dependent state", () => {
	const initialState: WorkspaceState = {
		...baseWorkspaceState(),
		selectedProjectId: "project-old",
		chats: [
			{
				diffAdded: 3,
				diffRemoved: 1,
				id: "chat-1",
				isActive: false,
				projectId: "project-old",
				provider: "fake",
				status: "completed",
				title: "old chat",
				updatedAt: "2026-01-01T00:00:00.000Z",
			},
		],
		selectedChatId: "chat-1",
		messageWindow: {
			chatId: "chat-1",
			hasMore: false,
			latestDirty: false,
			messages: [
				{
					chatId: "chat-1",
					content: "hello",
					createdAt: "2026-01-01T00:00:00.100Z",
					id: "msg-1",
					role: "user",
				},
			],
			mode: "latest",
			nextBeforeMessageId: null,
			turns: [],
		},
		streamingByChat: {
			"chat-1": "partial",
		},
		streamingActiveByChat: {
			"chat-1": true,
		},
		streamTurnsByChat: {
			"chat-1": {
				turnId: "turn-1",
				status: "running",
				itemsById: {},
				itemOrder: [],
				startedAtMs: Date.now(),
				finishedAtMs: null,
			},
		},
	};

	const updated = workspaceReducer(initialState, {
		type: "SET_SELECTED_PROJECT",
		payload: "project-new",
	});

	expect(updated.selectedProjectId).toBe("project-new");
	expect(updated.chats).toEqual([]);
	expect(updated.selectedChatId).toBeNull();
	expect(updated.messageWindow.messages).toEqual([]);
	expect(updated.streamingByChat).toEqual({});
	expect(updated.streamingActiveByChat).toEqual({});
});

test("SET_SELECTED_PROJECT with same project id keeps state unchanged", () => {
	const initialState: WorkspaceState = {
		...baseWorkspaceState(),
		selectedProjectId: "project-1",
		chats: [
			{
				diffAdded: 0,
				diffRemoved: 0,
				id: "chat-keep",
				isActive: false,
				projectId: "project-1",
				provider: "fake",
				status: "pending",
				title: "chat-keep",
				updatedAt: "2026-01-01T00:00:00.000Z",
			},
		],
	};

	const same = workspaceReducer(initialState, {
		type: "SET_SELECTED_PROJECT",
		payload: "project-1",
	});

	expect(same).toBe(initialState);
});

test("streaming actions append and reset buffers as expected", () => {
	const initialState: WorkspaceState = {
		...baseWorkspaceState(),
		streamingByChat: {
			"chat-1": "first",
		},
		streamingActiveByChat: {
			"chat-1": false,
		},
	};

	const started = workspaceReducer(initialState, {
		type: "START_STREAMING",
		payload: { chatId: "chat-1" },
	});

	expect(started.streamingByChat["chat-1"]).toBe("first");
	expect(started.streamingActiveByChat["chat-1"]).toBe(true);

	const appended = workspaceReducer(started, {
		type: "APPEND_STREAMING",
		payload: { chatId: "chat-1", delta: " and second" },
	});

	expect(appended.streamingByChat["chat-1"]).toBe("first and second");
	expect(appended.streamingActiveByChat["chat-1"]).toBe(true);

	const cleared = workspaceReducer(appended, {
		type: "CLEAR_STREAMING",
		payload: { chatId: "chat-1" },
	});

	expect(cleared.streamingByChat["chat-1"]).toBe("");
	expect(cleared.streamingActiveByChat["chat-1"]).toBe(false);

	const resetAll = workspaceReducer(cleared, {
		type: "RESET_STREAMING",
	});

	expect(resetAll.streamingByChat).toEqual({});
	expect(resetAll.streamingActiveByChat).toEqual({});
});

test("connection and general errors can be added, removed, and cleared", () => {
	const connectionErrored = workspaceReducer(baseWorkspaceState(), {
		type: "SET_CONNECTION_ERROR",
		payload: {
			source: "ws",
			code: "socket_closed",
			message: "websocket disconnected",
		},
	});

	expect(connectionErrored.connectionError).not.toBeNull();
	expect(connectionErrored.connectionError?.source).toBe("ws");
	expect(connectionErrored.connectionError?.code).toBe("socket_closed");
	expect(connectionErrored.connectionError?.id).toEqual(expect.any(String));
	expect(connectionErrored.connectionError?.timestamp).toEqual(expect.any(String));

	const clearedByState = workspaceReducer(connectionErrored, {
		type: "SET_CONNECTION_STATE",
		payload: "connected",
	});

	expect(clearedByState.connectionError).toBeNull();

	const withErrors = workspaceReducer(clearedByState, {
		type: "ADD_ERROR",
		payload: {
			source: "rest",
			code: "request_failed",
			message: "bad request",
		},
	});

	const withMoreErrors = workspaceReducer(withErrors, {
		type: "ADD_ERROR",
		payload: {
			source: "ws",
			code: "provider_timeout",
			message: "provider timed out",
		},
	});

	expect(withMoreErrors.errors).toHaveLength(2);
	const firstError = withMoreErrors.errors[0];
	expect(firstError).toEqual(
		expect.objectContaining({
			source: "rest",
			code: "request_failed",
			message: "bad request",
			id: expect.any(String),
			timestamp: expect.any(String),
		}),
	);

	const removed = workspaceReducer(withMoreErrors, {
		type: "REMOVE_ERROR",
		payload: firstError.id,
	});

	expect(removed.errors).toHaveLength(1);

	const cleared = workspaceReducer(removed, {
		type: "CLEAR_ERRORS",
	});

	expect(cleared.errors).toEqual([]);
});

test("RESET_SELECTED_PROJECT and RESET_SELECTED_CHAT clear state slices", () => {
	const projectResetInput: WorkspaceState = {
		...baseWorkspaceState(),
		selectedProjectId: "project-1",
		selectedChatId: "chat-1",
		chats: [
			{
				diffAdded: 1,
				diffRemoved: 0,
				id: "chat-1",
				isActive: true,
				projectId: "project-1",
				provider: "fake",
				status: "running",
				title: "chat-1",
				updatedAt: "2026-01-01T00:00:00.000Z",
			},
		],
		messageWindow: {
			chatId: "chat-1",
			hasMore: false,
			latestDirty: false,
			messages: [
				{
					chatId: "chat-1",
					content: "hello",
					createdAt: "2026-01-01T00:00:00.100Z",
					id: "msg-1",
					role: "user",
				},
			],
			mode: "latest",
			nextBeforeMessageId: null,
			turns: [],
		},
		streamingByChat: {
			"chat-1": "draft",
		},
		streamingActiveByChat: {
			"chat-1": true,
		},
	};

	const projectReset = workspaceReducer(projectResetInput, { type: "RESET_SELECTED_PROJECT" });

	expect(projectReset.selectedProjectId).toBeNull();
	expect(projectReset.chats).toEqual([]);
	expect(projectReset.selectedChatId).toBeNull();
	expect(projectReset.messageWindow.messages).toEqual([]);
	expect(projectReset.streamingByChat).toEqual({});
	expect(projectReset.streamingActiveByChat).toEqual({});
	expect(projectReset.streamTurnsByChat).toEqual({});

	const chatStateInput: WorkspaceState = {
		...projectReset,
		selectedProjectId: "project-2",
		selectedChatId: "chat-2",
		chats: [
			{
				diffAdded: 0,
				diffRemoved: 0,
				id: "chat-2",
				isActive: false,
				projectId: "project-2",
				provider: "fake",
				status: "completed",
				title: "chat-2",
				updatedAt: "2026-01-01T00:00:00.200Z",
			},
		],
		messageWindow: {
			chatId: "chat-2",
			hasMore: false,
			latestDirty: false,
			messages: [
				{
					chatId: "chat-2",
					content: "assistant",
					createdAt: "2026-01-01T00:00:00.200Z",
					id: "msg-2",
					role: "assistant",
				},
			],
			mode: "latest",
			nextBeforeMessageId: null,
			turns: [],
		},
		streamingByChat: {
			"chat-2": "cache",
		},
		streamingActiveByChat: {
			"chat-2": true,
		},
		streamTurnsByChat: {
			"chat-2": {
				turnId: "turn-2",
				status: "running",
				itemsById: {},
				itemOrder: [],
				startedAtMs: Date.now(),
				finishedAtMs: null,
			},
		},
	};

	const chatReset = workspaceReducer(chatStateInput, { type: "RESET_SELECTED_CHAT" });

	expect(chatReset.selectedChatId).toBeNull();
	expect(chatReset.messageWindow.messages).toEqual([]);
	expect(chatReset.streamingByChat).toEqual({});
	expect(chatReset.streamingActiveByChat).toEqual({});
	expect(chatReset.streamTurnsByChat).toEqual({});
});

test("SET_MESSAGE_WINDOW prunes transient chat state to the visible chat", () => {
	const initialState: WorkspaceState = {
		...baseWorkspaceState(),
		selectedChatId: "chat-2",
		messageWindow: {
			chatId: "chat-2",
			hasMore: false,
			latestDirty: false,
			messages: [],
			mode: "latest",
			nextBeforeMessageId: null,
			turns: [],
		},
		streamingByChat: {
			"chat-1": "stale output",
			"chat-2": "",
		},
		streamingActiveByChat: {
			"chat-1": true,
			"chat-2": false,
		},
		streamTurnsByChat: {
			"chat-1": {
				turnId: "turn-1",
				status: "running",
				itemsById: {},
				itemOrder: [],
				startedAtMs: Date.now(),
				finishedAtMs: null,
			},
		},
		streamHistoryByChat: {
			"chat-1": [{
				turnId: "turn-1",
				status: "completed",
				itemsById: {},
				itemOrder: [],
				startedAtMs: Date.now(),
				finishedAtMs: Date.now(),
			}],
		},
		lastAssistantEventIdByChat: {
			"chat-1": 18,
		},
		sendingByChat: {
			"chat-1": true,
		},
	};

	const updated = workspaceReducer(initialState, {
		type: "SET_MESSAGE_WINDOW",
		payload: {
			chatId: "chat-2",
			hasMore: false,
			latestDirty: false,
			messages: [{
				chatId: "chat-2",
				content: "hello",
				createdAt: "2026-01-01T00:00:00.000Z",
				id: "message-1",
				role: "user",
			}],
			mode: "latest",
			nextBeforeMessageId: null,
			turns: [],
		},
	});

	expect(updated.streamingByChat).toEqual({});
	expect(updated.streamingActiveByChat).toEqual({});
	expect(updated.streamTurnsByChat).toEqual({});
	expect(updated.streamHistoryByChat).toEqual({ "chat-2": [] });
	expect(updated.lastAssistantEventIdByChat).toEqual({});
	expect(updated.sendingByChat).toEqual({});
});

test("SET_CHATS drops transient chat state for chats that are no longer selectable", () => {
	const initialState: WorkspaceState = {
		...baseWorkspaceState(),
		selectedChatId: "chat-stale",
		messageWindow: {
			chatId: "chat-stale",
			hasMore: false,
			latestDirty: false,
			messages: [],
			mode: "latest",
			nextBeforeMessageId: null,
			turns: [],
		},
		streamingByChat: {
			"chat-stale": "old output",
			"chat-next": "keep me",
		},
		streamingActiveByChat: {
			"chat-stale": true,
			"chat-next": true,
		},
		streamHistoryByChat: {
			"chat-stale": [{
				turnId: "turn-old",
				status: "completed",
				itemsById: {},
				itemOrder: [],
				startedAtMs: Date.now(),
				finishedAtMs: Date.now(),
			}],
			"chat-next": [{
				turnId: "turn-next",
				status: "completed",
				itemsById: {},
				itemOrder: [],
				startedAtMs: Date.now(),
				finishedAtMs: Date.now(),
			}],
		},
	};

	const updated = workspaceReducer(initialState, {
		type: "SET_CHATS",
		payload: [{
			diffAdded: 0,
			diffRemoved: 0,
			id: "chat-next",
			isActive: false,
			projectId: "project-1",
			provider: "fake",
			status: "completed",
			title: "Next Chat",
			updatedAt: "2026-01-01T00:00:01.000Z",
		}],
	});

	expect(updated.selectedChatId).toBe("chat-next");
	expect(updated.streamingByChat).toEqual({ "chat-next": "keep me" });
	expect(updated.streamingActiveByChat).toEqual({ "chat-next": true });
	expect(updated.streamHistoryByChat).toEqual({
		"chat-next": expect.any(Array),
	});
});

test("assistant stream events append by target and keep item identity", () => {
	const initial: WorkspaceState = {
		...baseWorkspaceState(),
		selectedChatId: "chat-1",
		messageWindow: {
			chatId: "chat-1",
			hasMore: false,
			latestDirty: false,
			messages: [],
			mode: "latest",
			nextBeforeMessageId: null,
			turns: [],
		},
	};
	const withTurn = workspaceReducer(initial, {
		type: "APPLY_ASSISTANT_EVENT",
		payload: {
			chatId: "chat-1",
			event: {
				type: "turn_started",
				turnId: "turn-1",
			},
		},
	});

	const withStartedItem = workspaceReducer(withTurn, {
		type: "APPLY_ASSISTANT_EVENT",
		payload: {
			chatId: "chat-1",
			event: {
				type: "item_started",
				turnId: "turn-1",
				itemId: "tool-1",
				itemType: "tool",
				state: "running",
				summary: "Running command: pwd",
			},
		},
	});

	const withOutput = workspaceReducer(withStartedItem, {
		type: "APPLY_ASSISTANT_EVENT",
		payload: {
			chatId: "chat-1",
			event: {
				type: "item_delta",
				turnId: "turn-1",
				itemId: "tool-1",
				target: "output",
				delta: "/tmp",
			},
		},
	});

	const withCompleted = workspaceReducer(withOutput, {
		type: "APPLY_ASSISTANT_EVENT",
		payload: {
			chatId: "chat-1",
			event: {
				type: "item_completed",
				turnId: "turn-1",
				itemId: "tool-1",
				state: "completed",
				summary: "Ran pwd",
			},
		},
	});

	const turn = withCompleted.streamTurnsByChat["chat-1"];
	expect(turn?.turnId).toBe("turn-1");
	expect(turn?.itemOrder).toEqual(["tool-1"]);
	expect(turn?.itemsById["tool-1"]?.output).toBe("/tmp");
	expect(turn?.itemsById["tool-1"]?.state).toBe("completed");
	expect(turn?.itemsById["tool-1"]?.summary).toBe("Ran pwd");
});
