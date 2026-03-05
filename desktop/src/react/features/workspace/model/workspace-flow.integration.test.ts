import { describe, expect, test } from "bun:test";

import { RemoteCodeApi } from "../../../shared/api/remotecode-http";
import {
	RemoteCodeRealtime,
	type ConnectionState,
	type ServerWsEvent,
} from "../../../shared/realtime/remotecode-ws";
import type {
	WorkspaceAction,
	WorkspaceState,
	ChatDTO,
	MessageDTO,
	ProjectDTO,
} from "./useWorkspaceStore";
import { sendWorkspaceMessage } from "./send-message";

type HttpRequest = {
	method: string;
	path: string;
	body?: unknown;
};

type RuntimeChat = Omit<ChatDTO, "isActive"> & { isActive?: boolean };

type RuntimeRoutes = {
	listProjects: () => ProjectDTO[];
	createProject: (input: { name?: string; path: string }) => ProjectDTO;
	createChat: (projectId: string, input: { title?: string }) => RuntimeChat;
	listMessages: (chatId: string) => MessageDTO[];
	listChats?: (projectId: string) => RuntimeChat[];
	getWorkspaceSelection?: () => { selectedChatId: string | null; selectedProjectId: string | null };
	updateWorkspaceSelection?: (
		selection: { selectedChatId: string | null; selectedProjectId: string | null },
	) => { selectedChatId: string | null; selectedProjectId: string | null };
	deleteProject?: (id: string) => { deleted: boolean };
	deleteChat?: (id: string) => { deleted: boolean };
};

const json = (body: unknown, status = 200): Response => {
	return new Response(JSON.stringify(body), {
		headers: {
			"content-type": "application/json",
		},
		status,
	});
};

const parseBody = (body: BodyInit | null | undefined): unknown => {
	if (typeof body !== "string" || body.length === 0) {
		return undefined;
	}

	try {
		return JSON.parse(body);
	} catch {
		return undefined;
	}
};

const toChatDto = (chat: RuntimeChat): ChatDTO => ({
	...chat,
	isActive: chat.isActive ?? false,
});

const setupMockFetch = (routes: RuntimeRoutes) => {
	const requests: HttpRequest[] = [];
	const previousFetch = globalThis.fetch;

	const mockFetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
		const url = typeof input === "string" ? new URL(input) : new URL(input.toString());
		const path = url.pathname.replace(/\/+$/, "");
		const method = (init?.method ?? "GET").toUpperCase();

		const body = parseBody(init?.body);
		requests.push({ method, path, body });

		if (method === "GET" && path === "/v1/projects") {
			return json({ projects: routes.listProjects() });
		}

		if (method === "POST" && path === "/v1/projects") {
			const payload = body as { name?: string; path: string };
			return json({ created: true, project: routes.createProject(payload) });
		}

		if (method === "GET" && path === "/v1/selection") {
			const selection = routes.getWorkspaceSelection?.() ?? {
				selectedChatId: null,
				selectedProjectId: null,
			};
			return json(selection);
		}

		if (method === "PATCH" && path === "/v1/selection") {
			const payload = body as { selectedChatId: string | null; selectedProjectId: string | null };
			const saved = routes.updateWorkspaceSelection?.(payload) ?? payload;
			return json(saved);
		}

		const createChatMatch = /^\/v1\/projects\/([^/]+)\/chats$/.exec(path);
		if (method === "POST" && createChatMatch) {
			const projectId = createChatMatch[1];
			const payload = body as { title?: string };
			return json({ chat: toChatDto(routes.createChat(projectId, payload)) });
		}
		if (method === "GET" && createChatMatch) {
			const projectId = createChatMatch[1];
			const chats = (routes.listChats?.(projectId) ?? []).map(toChatDto);
			return json({ chats });
		}

		const projectDeleteMatch = /^\/v1\/projects\/([^/]+)$/.exec(path);
		if (method === "DELETE" && projectDeleteMatch) {
			const payload = routes.deleteProject?.(projectDeleteMatch[1]) ?? { deleted: false };
			return json(payload);
		}

		const chatDeleteMatch = /^\/v1\/chats\/([^/]+)$/.exec(path);
		if (method === "DELETE" && chatDeleteMatch) {
			const payload = routes.deleteChat?.(chatDeleteMatch[1]) ?? { deleted: false };
			return json(payload);
		}

		const listMessagesMatch = /^\/v1\/chats\/([^/]+)\/messages$/.exec(path);
		if (method === "GET" && listMessagesMatch) {
			const chatId = listMessagesMatch[1];
			return json({ messages: routes.listMessages(chatId) });
		}

		return json({ error: "route not mocked" }, 501);
	};

	globalThis.fetch = mockFetch as typeof fetch;

	return {
		requests,
		restore: () => {
			globalThis.fetch = previousFetch;
		},
	};
};

class MockWebSocket {
	static instances: MockWebSocket[] = [];
	static CONNECTING = 0;
	static OPEN = 1;
	static CLOSING = 2;
	static CLOSED = 3;

	static clearInstances() {
		MockWebSocket.instances = [];
	}

	readyState = MockWebSocket.CONNECTING;
	sent: string[] = [];
	private readonly eventListeners: Map<string, Array<(event: { data?: unknown }) => void>> = new Map();

	constructor(public readonly url: string) {
		MockWebSocket.instances.push(this);
	}

	addEventListener(type: string, handler: (event: { data?: unknown }) => void) {
		const handlers = this.eventListeners.get(type) ?? [];
		handlers.push(handler);
		this.eventListeners.set(type, handlers);
	}

	private emit(type: string, event: { data?: unknown } = {}) {
		for (const handler of this.eventListeners.get(type) ?? []) {
			handler(event);
		}
	}

	send(payload: string) {
		if (this.readyState !== MockWebSocket.OPEN) {
			throw new Error("WebSocket is not open");
		}

		this.sent.push(payload);
	}

	triggerOpen() {
		this.readyState = MockWebSocket.OPEN;
		this.emit("open");
	}

	triggerMessage(raw: string) {
		this.emit("message", { data: raw });
	}

	triggerClose() {
		this.readyState = MockWebSocket.CLOSED;
		this.emit("close");
	}

	triggerError() {
		this.emit("error");
	}
}

const setupMockWebSocket = () => {
	const previousWebSocket = globalThis.WebSocket;
	MockWebSocket.clearInstances();
	globalThis.WebSocket = MockWebSocket as unknown as typeof WebSocket;

	return {
		restore: () => {
			globalThis.WebSocket = previousWebSocket;
			MockWebSocket.clearInstances();
		},
	};
};

const createInitialWorkspaceState = (): WorkspaceState => ({
	baseUrl: "http://127.0.0.1:3001",
	token: "local-dev-token",
	projects: [],
	selectedProjectId: null,
	chats: [],
	selectedChatId: null,
	messages: [],
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

const formatErrorId = () => `err-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;

	const applyWorkspaceAction = (state: WorkspaceState, action: WorkspaceAction): WorkspaceState => {
	switch (action.type) {
		case "BOOTSTRAP_CONFIG":
			return {
				...state,
				baseUrl: action.payload.baseUrl,
				token: action.payload.token,
			};
		case "SET_PROJECTS_LOADING":
			return {
				...state,
				projectsLoading: action.payload,
			};
		case "SET_PROJECTS":
			return {
				...state,
				projects: action.payload,
				projectsLoading: false,
			};
		case "UPSERT_PROJECT":
			return {
				...state,
				projects: [
					...state.projects.filter((project) => project.id !== action.payload.id),
					action.payload,
				].sort((a, b) => (a.updatedAt > b.updatedAt ? -1 : a.updatedAt < b.updatedAt ? 1 : 0)),
			};
			case "SET_SELECTED_PROJECT":
				if (action.payload === null) {
					return {
						...state,
						selectedProjectId: null,
						chats: [],
						selectedChatId: null,
						messages: [],
						streamingByChat: {},
						streamingActiveByChat: {},
						streamTurnsByChat: {},
						streamHistoryByChat: {},
						lastAssistantEventIdByChat: {},
						sendingByChat: {},
					};
				}
			if (state.selectedProjectId === action.payload) {
				return state;
			}
				return {
					...state,
					selectedProjectId: action.payload,
					chats: [],
					selectedChatId: null,
					messages: [],
					streamingByChat: {},
					streamingActiveByChat: {},
					streamTurnsByChat: {},
					streamHistoryByChat: {},
					lastAssistantEventIdByChat: {},
					sendingByChat: {},
				};
		case "SET_CHATS":
			return {
				...state,
				chats: action.payload,
				chatsLoading: false,
				selectedChatId: action.payload[0]?.id ?? null,
				messages: [],
			};
		case "UPSERT_CHAT":
			return {
				...state,
				chats: [
					...state.chats.filter((chat) => chat.id !== action.payload.id),
					action.payload,
				].sort((a, b) => (a.updatedAt > b.updatedAt ? -1 : a.updatedAt < b.updatedAt ? 1 : 0)),
				selectedChatId: action.payload.id,
				messages: [],
			};
		case "UPDATE_CHAT":
			return {
				...state,
				chats: state.chats.map((chat) =>
					chat.id === action.payload.id ? { ...chat, ...action.payload } : chat,
				),
			};
		case "SET_SELECTED_CHAT":
			return {
				...state,
				selectedChatId: action.payload,
				messages: [],
				streamingActiveByChat: {
					...state.streamingActiveByChat,
					...(!action.payload ? {} : { [action.payload]: state.streamingActiveByChat[action.payload] ?? false }),
				},
			};
		case "SET_MESSAGES_LOADING":
			return {
				...state,
				messagesLoading: action.payload,
			};
		case "SET_MESSAGES":
			return {
				...state,
				messages: action.payload,
			};
		case "APPEND_MESSAGE":
			return {
				...state,
				messages: [...state.messages, action.payload],
			};
		case "APPEND_STREAMING":
			return {
				...state,
				streamingByChat: {
					...state.streamingByChat,
					[action.payload.chatId]: `${state.streamingByChat[action.payload.chatId] ?? ""}${action.payload.delta}`,
				},
				streamingActiveByChat: {
					...state.streamingActiveByChat,
					[action.payload.chatId]: true,
				},
			};
		case "CLEAR_STREAMING":
			return {
				...state,
				streamingByChat: {
					...state.streamingByChat,
					[action.payload.chatId]: "",
				},
				streamingActiveByChat: {
					...state.streamingActiveByChat,
					[action.payload.chatId]: false,
				},
			};
			case "SET_SENDING_MESSAGE":
				return {
					...state,
					isSendingMessage: action.payload,
				};
			case "SET_CHAT_SENDING": {
				const nextSendingByChat = {
					...state.sendingByChat,
					[action.payload.chatId]: action.payload.sending,
				};

				return {
					...state,
					sendingByChat: nextSendingByChat,
					isSendingMessage: Object.values(nextSendingByChat).some(Boolean),
				};
			}
		case "SET_CREATING_PROJECT":
			return {
				...state,
				isCreatingProject: action.payload,
			};
		case "SET_CREATING_CHAT":
			return {
				...state,
				isCreatingChat: action.payload,
			};
		case "SET_CONNECTION_STATE":
			return {
				...state,
				connectionState: action.payload,
				connectionError: action.payload === "connected" ? null : state.connectionError,
			};
		case "SET_CONNECTION_ERROR":
			if (action.payload === null) {
				return {
					...state,
					connectionError: null,
				};
			}

			return {
				...state,
				connectionError: {
					...action.payload,
					id: formatErrorId(),
					timestamp: new Date().toISOString(),
				},
			};
		case "ADD_ERROR":
			return {
				...state,
				errors: [
					...state.errors,
					{
						...action.payload,
						id: formatErrorId(),
						timestamp: new Date().toISOString(),
					},
				],
			};
		default:
			return state;
	}
};

const createWorkspaceFlowHarness = () => {
	const state = { value: createInitialWorkspaceState() };
	const dispatch = (action: WorkspaceAction) => {
		state.value = applyWorkspaceAction(state.value, action);
	};

	const api = RemoteCodeApi.createClient({
		baseUrl: state.value.baseUrl,
		token: state.value.token,
	});
	let wsRef: ReturnType<typeof RemoteCodeRealtime.createClient> | null = null;
	let persistedSelectedChatIdRef: string | null = null;

	const addError = (message: string, source: "rest" | "ws", code = "unknown") => {
		dispatch({
			type: "ADD_ERROR",
			payload: { source, code, message },
		});
	};

	const loadMessagesForChat = async (chatId: string | null) => {
		if (!chatId) {
			dispatch({ type: "SET_MESSAGES", payload: [] });
			dispatch({ type: "SET_MESSAGES_LOADING", payload: false });
			return;
		}

		dispatch({ type: "SET_MESSAGES_LOADING", payload: true });
		try {
			const messages = await api.listMessages(chatId);
			dispatch({ type: "SET_MESSAGES", payload: messages });
		} catch {
			addError("Unable to fetch messages from chat", "rest", "NETWORK");
		} finally {
			dispatch({ type: "SET_MESSAGES_LOADING", payload: false });
		}
	};

	const persistWorkspaceSelection = async (selectedProjectId: string | null, selectedChatId: string | null) => {
		try {
			await api.updateWorkspaceSelection({
				selectedChatId,
				selectedProjectId,
			});
		} catch {
			addError("Unable to persist selection", "rest", "NETWORK");
		}
	};

	const loadChatsForProject = async (projectId: string | null, preferredChatId: string | null = null) => {
		if (!projectId) {
			dispatch({ type: "SET_CHATS", payload: [] });
			dispatch({ type: "SET_SELECTED_CHAT", payload: null });
			dispatch({ type: "SET_CHATS_LOADING", payload: false });
			return;
		}

		dispatch({ type: "SET_CHATS_LOADING", payload: true });
		dispatch({ type: "SET_SELECTED_CHAT", payload: null });
		try {
			const chats = await api.listChats(projectId);
			dispatch({ type: "SET_CHATS", payload: chats });
			if (preferredChatId && chats.some((chat) => chat.id === preferredChatId)) {
				dispatch({ type: "SET_SELECTED_CHAT", payload: preferredChatId });
			}
		} catch {
			addError("Unable to load chats for project", "rest", "NETWORK");
			dispatch({ type: "SET_CHATS", payload: [] });
		} finally {
			dispatch({ type: "SET_CHATS_LOADING", payload: false });
			persistedSelectedChatIdRef = null;
		}
	};

	const loadProjectsFromSelection = async () => {
		dispatch({ type: "SET_PROJECTS_LOADING", payload: true });
		try {
			const [projects, selection] = await Promise.all([
				api.listProjects(),
				api.getWorkspaceSelection().catch(() => ({ selectedChatId: null, selectedProjectId: null })),
			]);

			const hasSelection = selection.selectedProjectId ? projects.some((project) => project.id === selection.selectedProjectId) : false;
			const selectedProjectId = hasSelection ? selection.selectedProjectId : projects[0]?.id ?? null;
			persistedSelectedChatIdRef = hasSelection ? selection.selectedChatId : null;

			dispatch({ type: "SET_PROJECTS", payload: projects });
			dispatch({ type: "SET_SELECTED_PROJECT", payload: selectedProjectId });
			await loadChatsForProject(selectedProjectId, persistedSelectedChatIdRef);
		} catch {
			addError("Unable to load projects", "rest", "NETWORK");
		} finally {
			dispatch({ type: "SET_PROJECTS_LOADING", payload: false });
		}
	};

	const handleWsEvent = async (event: ServerWsEvent) => {
		switch (event.event) {
				case "assistant_delta": {
					dispatch({
						type: "APPEND_STREAMING",
						payload: {
							chatId: event.data.chatId,
							delta: event.data.delta,
						},
					});
					dispatch({
						type: "SET_CHAT_SENDING",
						payload: {
							chatId: event.data.chatId,
							sending: false,
						},
					});
					break;
				}
			case "assistant_done":
				dispatch({
					type: "CLEAR_STREAMING",
					payload: { chatId: event.data.chatId },
				});
					if (state.value.selectedChatId === event.data.chatId) {
						await loadMessagesForChat(event.data.chatId);
					}
					dispatch({
						type: "SET_CHAT_SENDING",
						payload: {
							chatId: event.data.chatId,
							sending: false,
						},
					});
					break;
			case "chat_updated":
				dispatch({
					type: "UPDATE_CHAT",
					payload: {
						id: event.data.chatId,
						diffAdded: event.data.diffAdded,
						diffRemoved: event.data.diffRemoved,
						isActive: event.data.isActive,
						status: event.data.status,
						updatedAt: event.data.updatedAt,
					},
				});
				break;
			case "error":
				addError(event.data.message, "ws", event.data.code);
					if (event.data.chatId) {
						dispatch({
							type: "CLEAR_STREAMING",
							payload: { chatId: event.data.chatId },
						});
						dispatch({
							type: "SET_CHAT_SENDING",
							payload: {
								chatId: event.data.chatId,
								sending: false,
							},
						});
					}
					break;
		}
	};

	const handleWsState = (connectionState: ConnectionState) => {
		dispatch({ type: "SET_CONNECTION_STATE", payload: connectionState });
		if (connectionState === "connected" && state.value.selectedChatId) {
			wsRef?.sendJoinChat(state.value.selectedChatId);
			void loadMessagesForChat(state.value.selectedChatId);
		}
	};

	const bootstrap = async () => {
		dispatch({ type: "SET_PROJECTS_LOADING", payload: true });
		try {
			const projects = await api.listProjects();
			dispatch({ type: "SET_PROJECTS", payload: projects });
			dispatch({
				type: "SET_SELECTED_PROJECT",
				payload: projects[0]?.id ?? null,
			});
		} catch {
			addError("Unable to load projects", "rest", "NETWORK");
		} finally {
			dispatch({ type: "SET_PROJECTS_LOADING", payload: false });
		}
	};

	const createProject = async (input: { name?: string; path: string }) => {
		dispatch({ type: "SET_CREATING_PROJECT", payload: true });
		try {
			const project = await api.createProject(input);
			dispatch({ type: "UPSERT_PROJECT", payload: project });
			if (!state.value.selectedProjectId) {
				dispatch({ type: "SET_SELECTED_PROJECT", payload: project.id });
			}
			return project;
		} finally {
			dispatch({ type: "SET_CREATING_PROJECT", payload: false });
		}
	};

	const createProjectWithSelection = async (input: { name?: string; path: string }) => {
		dispatch({ type: "SET_CREATING_PROJECT", payload: true });
		try {
			const project = await api.createProject(input);
			dispatch({ type: "UPSERT_PROJECT", payload: project });
			dispatch({ type: "SET_SELECTED_PROJECT", payload: project.id });
			await persistWorkspaceSelection(project.id, null);
			return project;
		} finally {
			dispatch({ type: "SET_CREATING_PROJECT", payload: false });
		}
	};

	const createChat = async (title?: string) => {
		if (!state.value.selectedProjectId) {
			addError("Select a project before creating a chat", "rest", "missing_project");
			return null;
		}

		dispatch({ type: "SET_CREATING_CHAT", payload: true });
		try {
			const chat = await api.createChat(state.value.selectedProjectId, title);
			dispatch({ type: "UPSERT_CHAT", payload: chat });
			return chat;
		} finally {
			dispatch({ type: "SET_CREATING_CHAT", payload: false });
		}
	};

	const createChatWithSelection = async (title?: string) => {
		if (!state.value.selectedProjectId) {
			addError("Select a project before creating a chat", "rest", "missing_project");
			return null;
		}

		dispatch({ type: "SET_CREATING_CHAT", payload: true });
		try {
			const chat = await api.createChat(state.value.selectedProjectId, title);
			dispatch({ type: "UPSERT_CHAT", payload: chat });
			persistedSelectedChatIdRef = chat.id;
			await persistWorkspaceSelection(state.value.selectedProjectId, chat.id);
			return chat;
		} finally {
			dispatch({ type: "SET_CREATING_CHAT", payload: false });
		}
	};

	const selectProject = (projectId: string) => {
		if (projectId === state.value.selectedProjectId) {
			return;
		}

		dispatch({ type: "SET_SELECTED_CHAT", payload: null });
		dispatch({ type: "SET_SELECTED_PROJECT", payload: projectId });
		persistedSelectedChatIdRef = null;
		void persistWorkspaceSelection(projectId, null);
	};

	const selectChat = (chatId: string) => {
		if (chatId === state.value.selectedChatId) {
			return;
		}

		dispatch({ type: "SET_SELECTED_CHAT", payload: chatId });
		persistedSelectedChatIdRef = chatId;
		void persistWorkspaceSelection(state.value.selectedProjectId, chatId);
	};

	const deleteProject = async (projectId: string) => {
		try {
			const deleted = await api.deleteProject(projectId);
			if (!deleted.deleted) {
				throw new Error("Unable to delete workspace");
			}

			if (state.value.selectedProjectId === projectId) {
				await persistWorkspaceSelection(null, null);
			}

			await loadProjectsFromSelection();
		} catch {
			addError("Unable to delete workspace", "rest", "NETWORK");
		}
	};

	const deleteChat = async (chatId: string) => {
		try {
			const deleted = await api.deleteChat(chatId);
			if (!deleted.deleted) {
				throw new Error("Unable to delete thread");
			}

			const preferredChatId = state.value.selectedChatId === chatId ? null : state.value.selectedChatId;

			if (state.value.selectedChatId === chatId && state.value.selectedProjectId) {
				await persistWorkspaceSelection(state.value.selectedProjectId, null);
			}

			if (state.value.selectedProjectId) {
				await loadChatsForProject(state.value.selectedProjectId, preferredChatId);
			}
		} catch {
			addError("Unable to delete thread", "rest", "NETWORK");
		}
	};

	const sendMessage = async (
		text: string,
		permissionMode?: "plan" | "default" | "full",
	) => {
		if (!state.value.selectedProjectId) {
			addError("Select a project before sending a message", "rest", "missing_project");
			return;
		}

		await sendWorkspaceMessage({
			createChatId: async () => {
				const chat = await createChatWithSelection("New thread");
				return chat?.id ?? null;
			},
			createTimestamp: () => new Date().toISOString(),
			generateMessageId: () => `local-${Date.now()}`,
			hasOpenWebSocket: Boolean(wsRef),
			onAppendMessage: (message) => {
				dispatch({ type: "APPEND_MESSAGE", payload: message });
			},
			onClearStreaming: (chatId) => {
				dispatch({ type: "CLEAR_STREAMING", payload: { chatId } });
			},
			onCreateMessageError: addError,
			onSendUserMessage: (chatId, messageText) => {
				wsRef?.sendUserMessage(
					chatId,
					messageText,
					state.value.selectedProjectId ?? undefined,
					permissionMode,
				);
			},
				onSetSending: (chatId, sending) => {
					dispatch({
						type: "SET_CHAT_SENDING",
						payload: {
							chatId,
							sending,
						},
					});
				},
			selectedChatId: state.value.selectedChatId,
			selectedProjectId: state.value.selectedProjectId,
			text,
		});
	};

	const connectRealtime = () => {
		const client = RemoteCodeRealtime.createClient({
			baseUrl: state.value.baseUrl,
			token: state.value.token,
			onEvent: handleWsEvent,
			onConnectionStateChange: handleWsState,
		});

		wsRef = client;
		client.connect();
	};

	return {
		getState: () => state.value,
		bootstrap,
		loadProjectsFromSelection,
		createProject,
		createProjectWithSelection,
		createChat,
		createChatWithSelection,
		sendMessage,
		connectRealtime,
		handleWsEvent,
		handleWsState,
		selectProject,
		selectChat,
		deleteProject,
		deleteChat,
	};
};

describe("workspace frontend flow coverage", () => {
	test("sendMessage auto-creates chat when no chat is selected", async () => {
		const routeFixture: RuntimeRoutes = {
			listProjects: () => [
				{
					createdAt: "2026-01-01T12:00:00.000Z",
					id: "project-1",
					isFavorite: false,
					name: "Project",
					path: "/tmp/demo",
					updatedAt: "2026-01-01T12:00:00.000Z",
				},
			],
			createProject: ({ name, path }) => ({
				createdAt: "2026-01-01T12:00:00.000Z",
				id: "project-1",
				isFavorite: false,
				name: name ?? "Project",
				path,
				updatedAt: "2026-01-01T12:00:00.000Z",
			}),
			createChat: (projectId, { title }) => ({
				diffAdded: 0,
				diffRemoved: 0,
				id: "chat-1",
				projectId,
				provider: "fake",
				status: "pending",
				title: title ?? "New chat",
				updatedAt: "2026-01-01T12:00:01.000Z",
			}),
			listMessages: () => [],
		};

		const fetchMock = setupMockFetch(routeFixture);
		const wsMock = setupMockWebSocket();

		try {
			const harness = createWorkspaceFlowHarness();
			await harness.bootstrap();
			harness.connectRealtime();
			MockWebSocket.instances[0]?.triggerOpen();

			await harness.sendMessage("Start my thread", "default");

			const state = harness.getState();
			const sent = MockWebSocket.instances[0]?.sent ?? [];
			const sendEvent = sent.find((payload) => {
				try {
					const parsed = JSON.parse(payload);
					return (
						parsed.event === "user_message" &&
						parsed.data?.chatId === "chat-1" &&
						parsed.data?.permissionMode === "default"
					);
				} catch {
					return false;
				}
			});

			expect(state.selectedProjectId).toBe("project-1");
			expect(state.selectedChatId).toBe("chat-1");
			expect(state.messages.at(-1)?.content).toBe("Start my thread");
			expect(fetchMock.requests).toContainEqual(
				expect.objectContaining({
					method: "POST",
					path: "/v1/projects/project-1/chats",
				}),
			);
			expect(sendEvent).toBeDefined();
		} finally {
			fetchMock.restore();
			wsMock.restore();
		}
	});

	test("project creation -> chat creation -> send -> assistant_delta/assistant_done", async () => {
		let messageLoads = 0;

		const routeFixture: RuntimeRoutes = {
			listProjects: () => [],
			createProject: ({ name, path }) => ({
				createdAt: "2026-01-01T12:00:00.000Z",
				id: "project-1",
				isFavorite: false,
				name: name ?? "Default project",
				path,
				updatedAt: "2026-01-01T12:00:00.000Z",
			}),
			createChat: (projectId, { title }) => ({
				diffAdded: 0,
				diffRemoved: 0,
				id: "chat-1",
				projectId,
				provider: "fake",
				status: "pending",
				title: title ?? "New chat",
				updatedAt: "2026-01-01T12:00:01.000Z",
			}),
			listMessages: (chatId) => {
				messageLoads += 1;
				if (chatId !== "chat-1") {
					return [];
				}
				if (messageLoads <= 1) {
					return [];
				}
				return [
					{
						chatId: "chat-1",
						content: "assistant response",
						createdAt: "2026-01-01T12:00:04.000Z",
						id: "msg-assistant",
						role: "assistant",
					},
				];
			},
		};

		const fetchMock = setupMockFetch(routeFixture);
		const wsMock = setupMockWebSocket();

		try {
			const harness = createWorkspaceFlowHarness();

			await harness.bootstrap();
			const project = await harness.createProject({
				name: "Demo project",
				path: "/tmp/demo",
			});
			const chat = await harness.createChat("Main chat");
			harness.connectRealtime();
			MockWebSocket.instances[0]?.triggerOpen();

			await harness.sendMessage("How are you?");
			await harness.handleWsEvent({
				event: "assistant_delta",
				data: {
					chatId: project.id === "unused" ? "unexpected" : "chat-1",
					delta: "Hello",
				},
			});
			await harness.handleWsEvent({
				event: "assistant_delta",
				data: {
					chatId: "chat-1",
					delta: " world",
				},
			});
			await harness.handleWsEvent({
				event: "assistant_done",
				data: {
					chatId: "chat-1",
				},
			});

			const state = harness.getState();

			expect(chat?.id).toBe("chat-1");
			expect(state.selectedProjectId).toBe(project.id);
			expect(state.selectedChatId).toBe(chat?.id ?? null);
			expect(state.messages.at(-1)?.role).toBe("assistant");
			expect(state.streamingByChat["chat-1"]).toBe("");
			expect(state.isSendingMessage).toBe(false);
			expect(MockWebSocket.instances[0].sent).toEqual(
				expect.arrayContaining([
					expect.stringContaining("\"event\":\"join_chat\""),
					expect.stringContaining("\"event\":\"user_message\""),
				]),
			);
			expect(messageLoads).toBeGreaterThanOrEqual(2);
		} finally {
			fetchMock.restore();
			wsMock.restore();
		}
	});

	test("error path handles provider_failed websocket errors", async () => {
		const routeFixture: RuntimeRoutes = {
			listProjects: () => [],
			createProject: ({ name, path }) => ({
				createdAt: "2026-01-01T12:00:00.000Z",
				id: "project-1",
				isFavorite: false,
				name: name ?? "Demo project",
				path,
				updatedAt: "2026-01-01T12:00:00.000Z",
			}),
			createChat: (projectId, { title }) => ({
				diffAdded: 0,
				diffRemoved: 0,
				id: "chat-1",
				projectId,
				provider: "fake",
				status: "pending",
				title: title ?? "New chat",
				updatedAt: "2026-01-01T12:00:01.000Z",
			}),
			listMessages: () => [],
		};

		const fetchMock = setupMockFetch(routeFixture);
		const wsMock = setupMockWebSocket();

		try {
			const harness = createWorkspaceFlowHarness();
			await harness.bootstrap();
			await harness.createProject({ name: "Demo", path: "/tmp/demo" });
			await harness.createChat("Main chat");
			harness.connectRealtime();
			MockWebSocket.instances[0]?.triggerOpen();
			await harness.sendMessage("Explain this error");
			await harness.handleWsEvent({
				event: "assistant_delta",
				data: {
					chatId: "chat-1",
					delta: "partial",
				},
			});
			await harness.handleWsEvent({
				event: "error",
				data: {
					chatId: "chat-1",
					code: "provider_failed",
					message: "provider execution failed",
				},
			});

			const state = harness.getState();

			expect(state.errors.at(-1)?.code).toBe("provider_failed");
			expect(state.errors.at(-1)?.source).toBe("ws");
			expect(state.isSendingMessage).toBe(false);
			expect(state.streamingByChat["chat-1"]).toBe("");
		} finally {
			fetchMock.restore();
			wsMock.restore();
		}
	});

	test("chat_updated event applies running status", async () => {
		const routeFixture: RuntimeRoutes = {
			listProjects: () => [],
			createProject: ({ name, path }) => ({
				createdAt: "2026-01-01T12:00:00.000Z",
				id: "project-1",
				isFavorite: false,
				name: name ?? "Demo project",
				path,
				updatedAt: "2026-01-01T12:00:00.000Z",
			}),
			createChat: (projectId, { title }) => ({
				diffAdded: 0,
				diffRemoved: 0,
				id: "chat-1",
				projectId,
				provider: "fake",
				status: "pending",
				title: title ?? "New chat",
				updatedAt: "2026-01-01T12:00:01.000Z",
			}),
			listMessages: () => [],
		};

		const fetchMock = setupMockFetch(routeFixture);
		const wsMock = setupMockWebSocket();

		try {
			const harness = createWorkspaceFlowHarness();
			await harness.bootstrap();
			await harness.createProject({ name: "Demo", path: "/tmp/demo" });
			await harness.createChat("Main chat");
				await harness.handleWsEvent({
					event: "chat_updated",
					data: {
						chatId: "chat-1",
						diffAdded: 5,
						diffRemoved: 2,
						isActive: true,
						status: "running",
						updatedAt: "2026-01-01T12:00:02.000Z",
					},
				});

			const chat = harness.getState().chats.find((item) => item.id === "chat-1");
			expect(chat?.status).toBe("running");
			expect(chat?.diffAdded).toBe(5);
			expect(chat?.diffRemoved).toBe(2);
		} finally {
			fetchMock.restore();
			wsMock.restore();
		}
	});

	test("assistant_done for non-selected chat does not reload messages", async () => {
		const routeFixture: RuntimeRoutes = {
			listProjects: () => [],
			createProject: ({ name, path }) => ({
				createdAt: "2026-01-01T12:00:00.000Z",
				id: "project-1",
				isFavorite: false,
				name: name ?? "Demo project",
				path,
				updatedAt: "2026-01-01T12:00:00.000Z",
			}),
			createChat: (projectId, { title }) => {
				const id = title?.includes("Second") ? "chat-2" : "chat-1";
				return {
					diffAdded: 0,
					diffRemoved: 0,
					id,
					projectId,
					provider: "fake",
					status: "pending",
					title: title ?? "New chat",
					updatedAt: "2026-01-01T12:00:01.000Z",
				};
			},
			listMessages: () => [],
		};

		const fetchMock = setupMockFetch(routeFixture);
		const wsMock = setupMockWebSocket();

		try {
			const harness = createWorkspaceFlowHarness();
			await harness.bootstrap();
			await harness.createProject({ name: "Demo", path: "/tmp/demo" });
			await harness.createChat("First chat");
			await harness.createChat("Second chat");

			expect(harness.getState().selectedChatId).toBe("chat-2");

			await harness.handleWsEvent({
				event: "assistant_done",
				data: {
					chatId: "chat-1",
				},
			});

			const messageLoads = fetchMock.requests.filter(
				(request) => request.method === "GET" && /^\/v1\/chats\/[^/]+\/messages$/.test(request.path),
			);
			expect(messageLoads).toHaveLength(0);
		} finally {
			fetchMock.restore();
			wsMock.restore();
		}
	});

	test("reconnect re-joins selected chat", async () => {
			const routeFixture: RuntimeRoutes = {
				listProjects: () => [],
				createProject: ({ name, path }) => ({
					createdAt: "2026-01-01T12:00:00.000Z",
					id: "project-1",
					isFavorite: false,
					name: name ?? "Project",
					path,
					updatedAt: "2026-01-01T12:00:00.000Z",
				}),
			createChat: (projectId, { title }) => ({
				diffAdded: 0,
				diffRemoved: 0,
				id: "chat-1",
				projectId,
				provider: "fake",
				status: "pending",
				title: title ?? "New chat",
				updatedAt: "2026-01-01T12:00:01.000Z",
			}),
			listMessages: () => [],
		};

		const fetchMock = setupMockFetch(routeFixture);
		const wsMock = setupMockWebSocket();
		const pendingReconnect: Array<() => void> = [];
		const originalSetTimeout = globalThis.setTimeout;
		const originalClearTimeout = globalThis.clearTimeout;

			try {
				globalThis.setTimeout = (((callback: TimerHandler) => {
					pendingReconnect.push(() => {
						if (typeof callback === "function") {
							callback();
						}
					});
					return 1 as unknown as ReturnType<typeof setTimeout>;
				}) as unknown) as typeof setTimeout;

			globalThis.clearTimeout = (() => undefined) as typeof clearTimeout;

			const harness = createWorkspaceFlowHarness();
			await harness.bootstrap();
			await harness.createProject({ name: "Demo", path: "/tmp/demo" });
			await harness.createChat("Main chat");
			harness.connectRealtime();

			const firstSocket = MockWebSocket.instances[0];
			firstSocket.triggerOpen();

			firstSocket.triggerClose();
			pendingReconnect.shift()?.();

			const reconnectSocket = MockWebSocket.instances.at(-1);
			reconnectSocket?.triggerOpen();

			const joinCalls = (reconnectSocket?.sent ?? []).filter((payload) => {
				const parsed = JSON.parse(payload);
				return parsed.event === "join_chat" && parsed.data?.chatId === "chat-1";
			});
			expect(joinCalls.length).toBeGreaterThan(0);

			const messageLoadRequests = fetchMock.requests.filter(
				(request) => request.method === "GET" && request.path === "/v1/chats/chat-1/messages",
			);
			expect(messageLoadRequests).toHaveLength(2);
		} finally {
			globalThis.setTimeout = originalSetTimeout;
			globalThis.clearTimeout = originalClearTimeout;
			fetchMock.restore();
			wsMock.restore();
		}
	});

	test("loadProjectsFromSelection restores selected project and chat from persisted selection", async () => {
		const chatsByProject: Record<string, ChatDTO[]> = {
			"project-1": [
				{
					diffAdded: 0,
					diffRemoved: 0,
					id: "chat-11",
					isActive: false,
					projectId: "project-1",
					provider: "fake",
					status: "pending",
					title: "Chat A",
					updatedAt: "2026-01-01T12:00:00.000Z",
				},
				{
					diffAdded: 0,
					diffRemoved: 0,
					id: "chat-12",
					isActive: false,
					projectId: "project-1",
					provider: "fake",
					status: "pending",
					title: "Chat B",
					updatedAt: "2026-01-01T12:00:01.000Z",
				},
			],
			"project-2": [
				{
					diffAdded: 0,
					diffRemoved: 0,
					id: "chat-21",
					isActive: false,
					projectId: "project-2",
					provider: "fake",
					status: "pending",
					title: "Chat C",
					updatedAt: "2026-01-01T12:00:02.000Z",
				},
			],
		};

			const routeFixture: RuntimeRoutes = {
			listProjects: () => [
				{
					createdAt: "2026-01-01T12:00:00.000Z",
					id: "project-1",
					isFavorite: false,
					name: "Project 1",
					path: "/tmp/project-1",
					updatedAt: "2026-01-01T12:00:00.000Z",
				},
				{
					createdAt: "2026-01-01T12:00:00.000Z",
					id: "project-2",
					isFavorite: false,
					name: "Project 2",
					path: "/tmp/project-2",
					updatedAt: "2026-01-01T12:00:00.000Z",
				},
			],
				createProject: ({ name, path }) => ({
					createdAt: "2026-01-01T12:00:00.000Z",
					id: "unused",
					isFavorite: false,
					name: name ?? "unused",
					path,
					updatedAt: "2026-01-01T12:00:00.000Z",
				}),
			createChat: () => ({
				diffAdded: 0,
				diffRemoved: 0,
				id: "unused",
				projectId: "unused",
				provider: "fake",
				status: "pending",
				title: "unused",
				updatedAt: "2026-01-01T12:00:00.000Z",
			}),
			listMessages: () => [],
			listChats: (projectId: string) => chatsByProject[projectId] ?? [],
			getWorkspaceSelection: () => ({
				selectedProjectId: "project-2",
				selectedChatId: "chat-21",
			}),
		};

		const fetchMock = setupMockFetch(routeFixture);
		const wsMock = setupMockWebSocket();

		try {
			const harness = createWorkspaceFlowHarness();
			await harness.loadProjectsFromSelection();

			const state = harness.getState();

			expect(state.selectedProjectId).toBe("project-2");
			expect(state.selectedChatId).toBe("chat-21");
		} finally {
			fetchMock.restore();
			wsMock.restore();
		}
	});

	test("loadProjectsFromSelection falls back to first project when saved project is missing", async () => {
		const chatsByProject: Record<string, ChatDTO[]> = {
			"project-1": [
				{
					diffAdded: 0,
					diffRemoved: 0,
					id: "chat-11",
					isActive: false,
					projectId: "project-1",
					provider: "fake",
					status: "pending",
					title: "Chat A",
					updatedAt: "2026-01-01T12:00:00.000Z",
				},
			],
			"project-2": [
				{
					diffAdded: 0,
					diffRemoved: 0,
					id: "chat-21",
					isActive: false,
					projectId: "project-2",
					provider: "fake",
					status: "pending",
					title: "Chat B",
					updatedAt: "2026-01-01T12:00:01.000Z",
				},
			],
		};

			const routeFixture: RuntimeRoutes = {
			listProjects: () => [
				{
					createdAt: "2026-01-01T12:00:00.000Z",
					id: "project-1",
					isFavorite: false,
					name: "Project 1",
					path: "/tmp/project-1",
					updatedAt: "2026-01-01T12:00:00.000Z",
				},
				{
					createdAt: "2026-01-01T12:00:00.000Z",
					id: "project-2",
					isFavorite: false,
					name: "Project 2",
					path: "/tmp/project-2",
					updatedAt: "2026-01-01T12:00:00.000Z",
				},
			],
				createProject: ({ name, path }) => ({
					createdAt: "2026-01-01T12:00:00.000Z",
					id: "unused",
					isFavorite: false,
					name: name ?? "unused",
					path,
					updatedAt: "2026-01-01T12:00:00.000Z",
				}),
			createChat: () => ({
				diffAdded: 0,
				diffRemoved: 0,
				id: "unused",
				projectId: "unused",
				provider: "fake",
				status: "pending",
				title: "unused",
				updatedAt: "2026-01-01T12:00:00.000Z",
			}),
			listMessages: () => [],
			listChats: (projectId: string) => chatsByProject[projectId] ?? [],
			getWorkspaceSelection: () => ({
				selectedProjectId: "missing-project",
				selectedChatId: "missing-chat",
			}),
		};

		const fetchMock = setupMockFetch(routeFixture);
		const wsMock = setupMockWebSocket();

		try {
			const harness = createWorkspaceFlowHarness();
			await harness.loadProjectsFromSelection();

			const state = harness.getState();

			expect(state.selectedProjectId).toBe("project-1");
			expect(state.selectedChatId).toBe("chat-11");
		} finally {
			fetchMock.restore();
			wsMock.restore();
		}
	});

	test("createProjectWithSelection persists workspace selection", async () => {
		let persistedSelection: { selectedProjectId: string | null; selectedChatId: string | null } = {
			selectedProjectId: null,
			selectedChatId: null,
		};

		const routeFixture: RuntimeRoutes = {
			listProjects: () => [],
			createProject: ({ name, path }) => ({
				createdAt: "2026-01-01T12:00:00.000Z",
				id: "project-1",
				isFavorite: false,
				name: name ?? "Project",
				path,
				updatedAt: "2026-01-01T12:00:00.000Z",
			}),
			createChat: () => ({
				diffAdded: 0,
				diffRemoved: 0,
				id: "unused",
				projectId: "unused",
				provider: "fake",
				status: "pending",
				title: "unused",
				updatedAt: "2026-01-01T12:00:00.000Z",
			}),
			listMessages: () => [],
			updateWorkspaceSelection: (selection) => {
				persistedSelection = selection;
				return selection;
			},
		};

		const fetchMock = setupMockFetch(routeFixture);
		const wsMock = setupMockWebSocket();

		try {
			const harness = createWorkspaceFlowHarness();
			const project = await harness.createProjectWithSelection({
				name: "Workspace with persistence",
				path: "/tmp/project",
			});

			expect(project.id).toBe("project-1");
			expect(persistedSelection).toEqual({
				selectedProjectId: project.id,
				selectedChatId: null,
			});
			expect(harness.getState().selectedProjectId).toBe(project.id);
		} finally {
			fetchMock.restore();
			wsMock.restore();
		}
	});

	test("createChatWithSelection persists selected chat and workspace selection", async () => {
		let persistedSelection: { selectedProjectId: string | null; selectedChatId: string | null } = {
			selectedProjectId: null,
			selectedChatId: null,
		};

		const routeFixture: RuntimeRoutes = {
			listProjects: () => [],
			createProject: ({ name, path }) => ({
				createdAt: "2026-01-01T12:00:00.000Z",
				id: "project-1",
				isFavorite: false,
				name: name ?? "Project",
				path,
				updatedAt: "2026-01-01T12:00:00.000Z",
			}),
			createChat: (projectId, { title }) => ({
				diffAdded: 0,
				diffRemoved: 0,
				id: "chat-1",
				projectId,
				provider: "fake",
				status: "pending",
				title: title ?? "Chat",
				updatedAt: "2026-01-01T12:00:01.000Z",
			}),
			listMessages: () => [],
			listChats: () => [],
			updateWorkspaceSelection: (selection) => {
				persistedSelection = selection;
				return selection;
			},
		};

		const fetchMock = setupMockFetch(routeFixture);
		const wsMock = setupMockWebSocket();

		try {
			const harness = createWorkspaceFlowHarness();
			const project = await harness.createProjectWithSelection({
				name: "Project",
				path: "/tmp/project",
			});
			const chat = await harness.createChatWithSelection("Chat with selection");

			expect(project.id).toBe("project-1");
			expect(chat?.id).toBe("chat-1");
			expect(persistedSelection).toEqual({
				selectedProjectId: project.id,
				selectedChatId: "chat-1",
			});
			expect(harness.getState().selectedChatId).toBe("chat-1");
		} finally {
			fetchMock.restore();
			wsMock.restore();
		}
	});

	test("selectProject persists workspace selection", async () => {
		let persistedSelection: { selectedProjectId: string | null; selectedChatId: string | null } = {
			selectedProjectId: null,
			selectedChatId: null,
		};

		const routeFixture: RuntimeRoutes = {
			listProjects: () => [],
			createProject: ({ name, path }) => ({
				createdAt: "2026-01-01T12:00:00.000Z",
				id: name?.includes("Second") ? "project-2" : "project-1",
				isFavorite: false,
				name: name ?? "Project",
				path,
				updatedAt: "2026-01-01T12:00:00.000Z",
			}),
			createChat: (projectId, { title }) => ({
				diffAdded: 0,
				diffRemoved: 0,
				id: `${projectId}-chat`,
				projectId,
				provider: "fake",
				status: "pending",
				title: title ?? "Chat",
				updatedAt: "2026-01-01T12:00:01.000Z",
			}),
			listMessages: () => [],
			updateWorkspaceSelection: (selection) => {
				persistedSelection = selection;
				return selection;
			},
		};

		const fetchMock = setupMockFetch(routeFixture);
		const wsMock = setupMockWebSocket();

		try {
			const harness = createWorkspaceFlowHarness();
			await harness.createProjectWithSelection({
				name: "First project",
				path: "/tmp/first",
			});
			await harness.createProject({
				name: "Second project",
				path: "/tmp/second",
			});

			await harness.selectProject("project-2");
			const state = harness.getState();

			expect(state.selectedProjectId).toBe("project-2");
			expect(persistedSelection).toEqual({
				selectedProjectId: "project-2",
				selectedChatId: null,
			});
		} finally {
			fetchMock.restore();
			wsMock.restore();
		}
	});

	test("selectChat persists workspace selection", async () => {
		const persistedSelections: Array<{ selectedProjectId: string | null; selectedChatId: string | null }> = [];

		const routeFixture: RuntimeRoutes = {
			listProjects: () => [],
			createProject: ({ name, path }) => ({
				createdAt: "2026-01-01T12:00:00.000Z",
				id: "project-1",
				isFavorite: false,
				name: name ?? "Project",
				path,
				updatedAt: "2026-01-01T12:00:00.000Z",
			}),
			createChat: (_projectId, { title }) => {
				const id = title?.includes("Second") ? "chat-2" : "chat-1";
				return {
					diffAdded: 0,
					diffRemoved: 0,
					id,
					projectId: "project-1",
					provider: "fake",
					status: "pending",
					title: title ?? "Chat",
					updatedAt: "2026-01-01T12:00:01.000Z",
				};
			},
			listMessages: () => [],
			updateWorkspaceSelection: (selection) => {
				persistedSelections.push(selection);
				return selection;
			},
		};

		const fetchMock = setupMockFetch(routeFixture);
		const wsMock = setupMockWebSocket();

		try {
			const harness = createWorkspaceFlowHarness();
			await harness.createProjectWithSelection({
				name: "Project",
				path: "/tmp/project",
			});
			await harness.createChat("First chat");
			await harness.createChat("Second chat");
			await harness.selectChat("chat-1");

			expect(persistedSelections.at(-1)).toEqual({
				selectedProjectId: "project-1",
				selectedChatId: "chat-1",
			});
			expect(harness.getState().selectedChatId).toBe("chat-1");
		} finally {
			fetchMock.restore();
			wsMock.restore();
		}
	});

	test("deleteChat when selected clears selected chat through persisted selection", async () => {
		let persistedSelection: { selectedProjectId: string | null; selectedChatId: string | null } = {
			selectedProjectId: null,
			selectedChatId: null,
		};

			const chatsByProject: Record<string, ChatDTO[]> = {
			"project-1": [
				{
					diffAdded: 0,
					diffRemoved: 0,
					id: "chat-1",
					isActive: false,
					projectId: "project-1",
					provider: "fake",
					status: "pending",
					title: "First chat",
					updatedAt: "2026-01-01T12:00:00.000Z",
				},
				{
					diffAdded: 0,
					diffRemoved: 0,
					id: "chat-2",
					isActive: false,
					projectId: "project-1",
					provider: "fake",
					status: "pending",
					title: "Second chat",
					updatedAt: "2026-01-01T12:00:01.000Z",
				},
			],
		};

		const routeFixture: RuntimeRoutes = {
			listProjects: () => [
				{
					createdAt: "2026-01-01T12:00:00.000Z",
					id: "project-1",
					isFavorite: false,
					name: "Project",
					path: "/tmp/project",
					updatedAt: "2026-01-01T12:00:00.000Z",
				},
			],
			createProject: ({ name, path }) => ({
				createdAt: "2026-01-01T12:00:00.000Z",
				id: "project-1",
				isFavorite: false,
				name: name ?? "Project",
				path,
				updatedAt: "2026-01-01T12:00:00.000Z",
			}),
				createChat: (projectId, { title }) => {
					const id = title?.includes("Second") ? "chat-2" : "chat-1";
					const chat: ChatDTO = {
						diffAdded: 0,
						diffRemoved: 0,
						id,
						isActive: false,
						projectId,
						provider: "fake",
						status: "pending",
						title: title ?? "Chat",
						updatedAt: "2026-01-01T12:00:01.000Z",
					};
				chatsByProject[projectId] = [...(chatsByProject[projectId] ?? []), chat];
				return chat;
			},
			listMessages: () => [],
			listChats: (projectId: string) => chatsByProject[projectId] ?? [],
			getWorkspaceSelection: () => ({
				selectedProjectId: "project-1",
				selectedChatId: "chat-2",
			}),
			updateWorkspaceSelection: (selection) => {
				persistedSelection = selection;
				return selection;
			},
			deleteChat: (chatId) => {
				chatsByProject["project-1"] = chatsByProject["project-1"].filter((chat) => chat.id !== chatId);
				return { deleted: true };
			},
		};

		const fetchMock = setupMockFetch(routeFixture);
		const wsMock = setupMockWebSocket();

		try {
			const harness = createWorkspaceFlowHarness();
			await harness.loadProjectsFromSelection();
			await harness.deleteChat("chat-2");

			expect(harness.getState().selectedProjectId).toBe("project-1");
			expect(harness.getState().selectedChatId).toBe("chat-1");
			expect(persistedSelection).toEqual({
				selectedProjectId: "project-1",
				selectedChatId: null,
			});
		} finally {
			fetchMock.restore();
			wsMock.restore();
		}
	});

	test("deleteProject when selected clears project and chat and reloads projects", async () => {
		let projects = [
			{
				createdAt: "2026-01-01T12:00:00.000Z",
				id: "project-1",
				isFavorite: false,
				name: "Project 1",
				path: "/tmp/project-1",
				updatedAt: "2026-01-01T12:00:00.000Z",
			},
			{
				createdAt: "2026-01-01T12:00:00.000Z",
				id: "project-2",
				isFavorite: false,
				name: "Project 2",
				path: "/tmp/project-2",
				updatedAt: "2026-01-01T12:00:00.000Z",
			},
		];
			const chatsByProject: Record<string, ChatDTO[]> = {
			"project-1": [],
			"project-2": [
				{
					diffAdded: 0,
					diffRemoved: 0,
					id: "chat-21",
					isActive: false,
					projectId: "project-2",
					provider: "fake",
					status: "pending",
					title: "New chat",
					updatedAt: "2026-01-01T12:00:01.000Z",
				},
			],
		};
		let persistedSelection: { selectedProjectId: string | null; selectedChatId: string | null } = {
			selectedProjectId: null,
			selectedChatId: null,
		};

		const routeFixture: RuntimeRoutes = {
			listProjects: () => projects,
			createProject: ({ name, path }) => ({
				createdAt: "2026-01-01T12:00:00.000Z",
				id: name?.includes("ignored") ? "project-ignored" : "project-generated",
				isFavorite: false,
				name: name ?? "Project",
				path,
				updatedAt: "2026-01-01T12:00:00.000Z",
			}),
			createChat: (projectId, { title }) => ({
				diffAdded: 0,
				diffRemoved: 0,
				id: "chat-created",
				projectId,
				provider: "fake",
				status: "pending",
				title: title ?? "Chat",
				updatedAt: "2026-01-01T12:00:01.000Z",
			}),
			listMessages: () => [],
			listChats: (projectId: string) => {
				return chatsByProject[projectId] ?? [];
			},
			getWorkspaceSelection: () => ({
				selectedProjectId: "project-1",
				selectedChatId: "chat-11",
			}),
			updateWorkspaceSelection: (selection) => {
				persistedSelection = selection;
				return selection;
			},
			deleteProject: (projectId) => {
				projects = projects.filter((project) => project.id !== projectId);
				return { deleted: true };
			},
		};

		const fetchMock = setupMockFetch(routeFixture);
		const wsMock = setupMockWebSocket();

		try {
			const harness = createWorkspaceFlowHarness();
			await harness.loadProjectsFromSelection();
			await harness.deleteProject("project-1");

			expect(persistedSelection).toEqual({
				selectedProjectId: null,
				selectedChatId: null,
			});
			expect(harness.getState().selectedProjectId).toBe("project-2");
			expect(harness.getState().selectedChatId).toBe("chat-21");
			expect(harness.getState().projects).toHaveLength(1);
		} finally {
			fetchMock.restore();
			wsMock.restore();
		}
	});
});
