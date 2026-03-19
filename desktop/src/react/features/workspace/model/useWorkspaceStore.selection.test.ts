import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { ModuleKind, ScriptTarget, transpileModule } from "typescript";
import { describe, test, expect } from "bun:test";

import type { ChatDTO, MessageWindowState, WorkspaceAction, WorkspaceState } from "./useWorkspaceStore";

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

const makeChat = (overrides: Partial<ChatDTO> & { id: string }): ChatDTO => ({
	isActive: false,
	projectId: "project-1",
	title: overrides.id,
	provider: "fake",
	status: "completed",
	diffAdded: 0,
	diffRemoved: 0,
	updatedAt: "2026-01-01T00:00:00.000Z",
	...overrides,
});

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

describe("SET_CHATS selection preservation [D-04]", () => {
	test("preserves selectedChatId when current chat exists in new list", () => {
		const existingMessageWindow: MessageWindowState = {
			chatId: "chat-2",
			hasMore: true,
			latestDirty: false,
			messages: [
				{
					id: "msg-1",
					chatId: "chat-2",
					role: "user",
					content: "hello",
					createdAt: "2026-01-01T00:00:00.100Z",
				},
			],
			mode: "latest",
			nextBeforeMessageId: null,
			turns: [],
		};

		const initial: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: "chat-2",
			messageWindow: existingMessageWindow,
			chats: [
				makeChat({ id: "chat-2", updatedAt: "2026-01-02T00:00:00.000Z" }),
			],
		};

		const incomingChats = [
			makeChat({ id: "chat-1", updatedAt: "2026-01-03T00:00:00.000Z" }),
			makeChat({ id: "chat-2", updatedAt: "2026-01-02T00:00:00.000Z" }),
			makeChat({ id: "chat-3", updatedAt: "2026-01-01T00:00:00.000Z" }),
		];

		const result = workspaceReducer(initial, {
			type: "SET_CHATS",
			payload: incomingChats,
		});

		expect(result.selectedChatId).toBe("chat-2");
	});

	test("auto-selects first chat when current selection is not in list", () => {
		const initial: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: "chat-gone",
			chats: [makeChat({ id: "chat-gone" })],
		};

		const incomingChats = [
			makeChat({ id: "chat-a", updatedAt: "2026-01-02T00:00:00.000Z" }),
			makeChat({ id: "chat-b", updatedAt: "2026-01-01T00:00:00.000Z" }),
		];

		const result = workspaceReducer(initial, {
			type: "SET_CHATS",
			payload: incomingChats,
		});

		expect(result.selectedChatId).toBe("chat-a");
	});

	test("preserves messageWindow when selected chat is preserved", () => {
		const existingMessageWindow: MessageWindowState = {
			chatId: "chat-2",
			hasMore: true,
			latestDirty: false,
			messages: [
				{
					id: "msg-1",
					chatId: "chat-2",
					role: "user",
					content: "important context",
					createdAt: "2026-01-01T00:00:00.100Z",
				},
				{
					id: "msg-2",
					chatId: "chat-2",
					role: "assistant",
					content: "reply",
					createdAt: "2026-01-01T00:00:00.200Z",
				},
			],
			mode: "latest",
			nextBeforeMessageId: "msg-0",
			turns: [],
		};

		const initial: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: "chat-2",
			messageWindow: existingMessageWindow,
			chats: [
				makeChat({ id: "chat-2", updatedAt: "2026-01-02T00:00:00.000Z" }),
			],
		};

		const incomingChats = [
			makeChat({ id: "chat-1", updatedAt: "2026-01-03T00:00:00.000Z" }),
			makeChat({ id: "chat-2", updatedAt: "2026-01-02T00:00:00.000Z" }),
		];

		const result = workspaceReducer(initial, {
			type: "SET_CHATS",
			payload: incomingChats,
		});

		expect(result.messageWindow).toBe(existingMessageWindow);
		expect(result.messageWindow.messages).toHaveLength(2);
		expect(result.messageWindow.messages[0].content).toBe("important context");
	});

	test("resets messageWindow when selected chat is not in new list", () => {
		const initial: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: "chat-gone",
			messageWindow: {
				chatId: "chat-gone",
				hasMore: false,
				latestDirty: false,
				messages: [
					{
						id: "msg-old",
						chatId: "chat-gone",
						role: "user",
						content: "old",
						createdAt: "2026-01-01T00:00:00.000Z",
					},
				],
				mode: "latest",
				nextBeforeMessageId: null,
				turns: [],
			},
		};

		const incomingChats = [
			makeChat({ id: "chat-new", updatedAt: "2026-01-03T00:00:00.000Z" }),
		];

		const result = workspaceReducer(initial, {
			type: "SET_CHATS",
			payload: incomingChats,
		});

		expect(result.selectedChatId).toBe("chat-new");
		expect(result.messageWindow.chatId).toBe("chat-new");
		expect(result.messageWindow.messages).toEqual([]);
	});

	test("auto-selects null when new chat list is empty", () => {
		const initial: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: "chat-1",
			chats: [makeChat({ id: "chat-1" })],
		};

		const result = workspaceReducer(initial, {
			type: "SET_CHATS",
			payload: [],
		});

		expect(result.selectedChatId).toBeNull();
		expect(result.messageWindow.chatId).toBeNull();
		expect(result.messageWindow.messages).toEqual([]);
	});
});

describe("UPSERT_CHAT selection preservation [D-05]", () => {
	test("does NOT change selectedChatId when a chat is already selected", () => {
		const existingMessageWindow: MessageWindowState = {
			chatId: "chat-current",
			hasMore: false,
			latestDirty: false,
			messages: [
				{
					id: "msg-1",
					chatId: "chat-current",
					role: "user",
					content: "working here",
					createdAt: "2026-01-01T00:00:00.100Z",
				},
			],
			mode: "latest",
			nextBeforeMessageId: null,
			turns: [],
		};

		const initial: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: "chat-current",
			messageWindow: existingMessageWindow,
			chats: [
				makeChat({ id: "chat-current", updatedAt: "2026-01-01T00:00:00.000Z" }),
			],
		};

		const newChat = makeChat({
			id: "chat-from-other-client",
			updatedAt: "2026-01-02T00:00:00.000Z",
		});

		const result = workspaceReducer(initial, {
			type: "UPSERT_CHAT",
			payload: newChat,
		});

		expect(result.selectedChatId).toBe("chat-current");
		expect(result.messageWindow).toBe(existingMessageWindow);
		expect(result.chats.some((c) => c.id === "chat-from-other-client")).toBe(true);
	});

	test("sets selectedChatId when current selection is null", () => {
		const initial: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: null,
			chats: [],
		};

		const newChat = makeChat({
			id: "chat-new",
			updatedAt: "2026-01-01T00:00:00.000Z",
		});

		const result = workspaceReducer(initial, {
			type: "UPSERT_CHAT",
			payload: newChat,
		});

		expect(result.selectedChatId).toBe("chat-new");
		expect(result.messageWindow.chatId).toBe("chat-new");
		expect(result.messageWindow.messages).toEqual([]);
		expect(result.chats).toHaveLength(1);
		expect(result.chats[0].id).toBe("chat-new");
	});

	test("updates existing chat in list without changing selection", () => {
		const initial: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: "chat-1",
			chats: [
				makeChat({ id: "chat-1", updatedAt: "2026-01-02T00:00:00.000Z", title: "My Chat" }),
				makeChat({ id: "chat-2", updatedAt: "2026-01-01T00:00:00.000Z", title: "Other" }),
			],
		};

		const updatedChat = makeChat({
			id: "chat-2",
			updatedAt: "2026-01-03T00:00:00.000Z",
			title: "Other (updated)",
		});

		const result = workspaceReducer(initial, {
			type: "UPSERT_CHAT",
			payload: updatedChat,
		});

		expect(result.selectedChatId).toBe("chat-1");
		const chat2 = result.chats.find((c) => c.id === "chat-2");
		expect(chat2?.title).toBe("Other (updated)");
	});
});
