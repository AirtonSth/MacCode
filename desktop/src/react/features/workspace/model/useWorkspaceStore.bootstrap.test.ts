import { describe, test, expect } from "bun:test";
import {
	type ChatDTO,
	type MessageWindowState,
	type ProjectDTO,
	type WorkspaceState,
	type WorkspaceAction,
	createEmptyMessageWindow,
	workspaceReducer,
} from "./useWorkspaceStore";

const createInitialState = (): WorkspaceState => ({
	baseUrl: "http://127.0.0.1:8835",
	token: "remotecode.io-token",
	projects: [],
	selectedProjectId: null,
	chats: [],
	selectedChatId: null,
	messageWindow: createEmptyMessageWindow(),
	streamingByChat: {},
	streamingActiveByChat: {},
	streamTurnsByChat: {},
	streamHistoryByChat: {},
	lastAssistantEventIdByChat: {},
	sendingByChat: {},
	isSendingMessage: false,
	isCreatingProject: false,
	isCreatingChat: false,
	projectsLoading: true,
	chatsLoading: true,
	messagesLoading: true,
	connectionError: null,
	connectionState: "idle",
	errors: [],
});

const makeProject = (id: string, name = `Project ${id}`): ProjectDTO => ({
	id,
	name,
	path: `/home/user/${name.toLowerCase().replace(/\s/g, "-")}`,
	isFavorite: false,
	createdAt: "2026-01-01T00:00:00.000Z",
	updatedAt: "2026-01-01T00:00:00.000Z",
});

const makeChat = (id: string, projectId: string, title = `Chat ${id}`): ChatDTO => ({
	id,
	isActive: false,
	projectId,
	title,
	provider: "codex",
	status: "pending",
	diffAdded: 0,
	diffRemoved: 0,
	updatedAt: "2026-01-01T00:00:00.000Z",
});

describe("useWorkspaceStore — BOOTSTRAP_COMPLETE", () => {
	test("sets all state atomically (projects, chats, selectedProjectId, selectedChatId, messageWindow)", () => {
		const state = createInitialState();

		const projects: ProjectDTO[] = [makeProject("p1"), makeProject("p2")];
		const chats: ChatDTO[] = [makeChat("c1", "p1"), makeChat("c2", "p1")];
		const messageWindow: MessageWindowState = {
			chatId: "c1",
			messages: [
				{
					id: "m1",
					chatId: "c1",
					role: "user",
					content: "Hello",
					createdAt: "2026-01-01T00:00:01.000Z",
				},
			],
			hasMore: false,
			nextBeforeMessageId: null,
			turns: [],
			mode: "latest",
			latestDirty: false,
		};

		const action: WorkspaceAction = {
			type: "BOOTSTRAP_COMPLETE",
			payload: {
				projects,
				selectedProjectId: "p1",
				chats,
				selectedChatId: "c1",
				messageWindow,
			},
		};

		const next = workspaceReducer(state, action);

		expect(next.projects).toEqual(projects);
		expect(next.selectedProjectId).toBe("p1");
		expect(next.chats).toEqual(chats);
		expect(next.selectedChatId).toBe("c1");
		expect(next.messageWindow).toEqual(messageWindow);
		expect(next.messageWindow.messages).toHaveLength(1);
		expect(next.messageWindow.messages[0].content).toBe("Hello");
	});

	test("resets streaming and sending maps", () => {
		const state: WorkspaceState = {
			...createInitialState(),
			streamingByChat: { old: "data" },
			streamingActiveByChat: { old: true },
			streamTurnsByChat: { old: undefined },
			streamHistoryByChat: {},
			lastAssistantEventIdByChat: { old: 5 },
			sendingByChat: { old: true },
		};

		const action: WorkspaceAction = {
			type: "BOOTSTRAP_COMPLETE",
			payload: {
				projects: [],
				selectedProjectId: null,
				chats: [],
				selectedChatId: null,
				messageWindow: createEmptyMessageWindow(),
			},
		};

		const next = workspaceReducer(state, action);

		expect(next.streamingByChat).toEqual({});
		expect(next.streamingActiveByChat).toEqual({});
		expect(next.streamTurnsByChat).toEqual({});
		expect(next.streamHistoryByChat).toEqual({});
		expect(next.lastAssistantEventIdByChat).toEqual({});
		expect(next.sendingByChat).toEqual({});
	});
});

describe("useWorkspaceStore — loading state initialization", () => {
	test("loading flags initialize as true", () => {
		const state = createInitialState();

		expect(state.projectsLoading).toBe(true);
		expect(state.chatsLoading).toBe(true);
		expect(state.messagesLoading).toBe(true);
	});
});

describe("useWorkspaceStore — BOOTSTRAP_COMPLETE sets loading to false", () => {
	test("after BOOTSTRAP_COMPLETE, all loading states are false", () => {
		const state = createInitialState();
		expect(state.projectsLoading).toBe(true);
		expect(state.chatsLoading).toBe(true);
		expect(state.messagesLoading).toBe(true);

		const action: WorkspaceAction = {
			type: "BOOTSTRAP_COMPLETE",
			payload: {
				projects: [makeProject("p1")],
				selectedProjectId: "p1",
				chats: [makeChat("c1", "p1")],
				selectedChatId: "c1",
				messageWindow: createEmptyMessageWindow("c1"),
			},
		};

		const next = workspaceReducer(state, action);

		expect(next.projectsLoading).toBe(false);
		expect(next.chatsLoading).toBe(false);
		expect(next.messagesLoading).toBe(false);
	});
});
