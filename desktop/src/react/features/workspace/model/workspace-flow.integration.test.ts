import { describe, expect, test } from "bun:test";

import { RemoteCodeApi } from "../../shared/api/remotecode-http";
import {
	RemoteCodeRealtime,
	type ConnectionState,
	type ServerWsEvent,
} from "../../shared/realtime/remotecode-ws";
import type {
	WorkspaceAction,
	WorkspaceState,
	type ChatDTO,
	type MessageDTO,
	type ProjectDTO,
} from "./useWorkspaceStore";

type HttpRequest = {
	method: string;
	path: string;
	body?: unknown;
};

type RuntimeRoutes = {
	listProjects: () => ProjectDTO[];
	createProject: (input: { name?: string; path: string }) => ProjectDTO;
	createChat: (projectId: string, input: { title?: string }) => ChatDTO;
	listMessages: (chatId: string) => MessageDTO[];
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

		const createChatMatch = /^\/v1\/projects\/([^/]+)\/chats$/.exec(path);
		if (method === "POST" && createChatMatch) {
			const projectId = createChatMatch[1];
			const payload = body as { title?: string };
			return json({ chat: routes.createChat(projectId, payload) });
		}

		const listMessagesMatch = /^\/v1\/chats\/([^/]+)\/messages$/.exec(path);
		if (method === "GET" && listMessagesMatch) {
			const chatId = listMessagesMatch[1];
			return json({ messages: routes.listMessages(chatId) });
		}

		return json({ error: "route not mocked" }, 501);
	};

	globalThis.fetch = mockFetch;

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
				if (state.value.selectedChatId === event.data.chatId) {
					dispatch({ type: "SET_SENDING_MESSAGE", payload: false });
				}
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
				dispatch({ type: "SET_SENDING_MESSAGE", payload: false });
				break;
			case "chat_updated":
				dispatch({
					type: "UPDATE_CHAT",
					payload: {
						id: event.data.chatId,
						diffAdded: event.data.diffAdded,
						diffRemoved: event.data.diffRemoved,
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
					if (state.value.selectedChatId === event.data.chatId) {
						dispatch({ type: "SET_SENDING_MESSAGE", payload: false });
					}
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

	const sendMessage = async (text: string) => {
		if (!state.value.selectedChatId || !wsRef) {
			addError("No chat selected", "ws", "missing_chat");
			return;
		}

		const chatId = state.value.selectedChatId;

		dispatch({ type: "SET_SENDING_MESSAGE", payload: true });
		dispatch({
			type: "APPEND_MESSAGE",
			payload: {
				id: `local-${chatId}-${Date.now()}`,
				chatId,
				role: "user",
				content: text,
				createdAt: new Date().toISOString(),
			},
		});
		dispatch({
			type: "CLEAR_STREAMING",
			payload: { chatId },
		});
		wsRef.sendUserMessage(chatId, text);
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
		createProject,
		createChat,
		sendMessage,
		connectRealtime,
		handleWsEvent,
	};
};

describe("workspace frontend flow coverage", () => {
	test("project creation -> chat creation -> send -> assistant_delta/assistant_done", async () => {
		let messageLoads = 0;

		const routeFixture = {
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
			expect(state.selectedChatId).toBe(chat?.id);
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
		const routeFixture = {
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
		const routeFixture = {
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

	test("reconnect re-joins selected chat", async () => {
		const routeFixture = {
			listProjects: () => [],
			createProject: ({ name, path }) => ({
				createdAt: "2026-01-01T12:00:00.000Z",
				id: "project-1",
				isFavorite: false,
				name,
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
			globalThis.setTimeout = ((callback) => {
				pendingReconnect.push(() => callback());
				return 1 as ReturnType<typeof setTimeout>;
			}) as typeof setTimeout;

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
		} finally {
			globalThis.setTimeout = originalSetTimeout;
			globalThis.clearTimeout = originalClearTimeout;
			fetchMock.restore();
			wsMock.restore();
		}
	});
});
