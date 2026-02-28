import { useReducer } from "react";

export interface ProjectDTO {
	id: string;
	name: string;
	path: string;
	isFavorite: boolean;
	createdAt: string;
	updatedAt: string;
}

export type ChatStatus = "pending" | "running" | "completed" | "failed";

export interface ChatDTO {
	id: string;
	projectId: string;
	title: string;
	provider: "fake";
	status: ChatStatus;
	diffAdded: number;
	diffRemoved: number;
	updatedAt: string;
}

export interface MessageDTO {
	id: string;
	chatId: string;
	role: "user" | "assistant";
	content: string;
	createdAt: string;
}

export interface UiError {
	id: string;
	source: "rest" | "ws";
	code: string;
	message: string;
	timestamp: string;
}

export type ConnectionState = "idle" | "connecting" | "connected" | "reconnecting" | "disconnected";

export type LoadingState = boolean;

export interface WorkspaceState {
	baseUrl: string;
	token: string;
	projects: ProjectDTO[];
	selectedProjectId: string | null;
	chats: ChatDTO[];
	selectedChatId: string | null;
	messages: MessageDTO[];
	streamingByChat: Record<string, string>;
	streamingActiveByChat: Record<string, boolean>;
	isSendingMessage: boolean;
	isCreatingProject: boolean;
	isCreatingChat: boolean;
	projectsLoading: LoadingState;
	chatsLoading: LoadingState;
	messagesLoading: LoadingState;
	connectionState: ConnectionState;
	connectionError: UiError | null;
	errors: UiError[];
}

export type WorkspaceAction =
	| { type: "BOOTSTRAP_CONFIG"; payload: { baseUrl: string; token: string } }
	| { type: "SET_PROJECTS_LOADING"; payload: boolean }
	| { type: "SET_PROJECTS"; payload: ProjectDTO[] }
	| { type: "UPSERT_PROJECT"; payload: ProjectDTO }
	| { type: "TOGGLE_FAVORITE"; payload: { id: string; isFavorite: boolean } }
	| { type: "SET_SELECTED_PROJECT"; payload: string | null }
	| { type: "RESET_SELECTED_PROJECT" }
	| { type: "SET_CHATS_LOADING"; payload: boolean }
	| { type: "SET_CHATS"; payload: ChatDTO[] }
	| { type: "UPSERT_CHAT"; payload: ChatDTO }
	| { type: "UPDATE_CHAT"; payload: Partial<ChatDTO> & { id: string } }
	| { type: "SET_SELECTED_CHAT"; payload: string | null }
	| { type: "RESET_SELECTED_CHAT" }
	| { type: "SET_MESSAGES_LOADING"; payload: boolean }
	| { type: "SET_MESSAGES"; payload: MessageDTO[] }
	| { type: "APPEND_MESSAGE"; payload: MessageDTO }
	| { type: "START_STREAMING"; payload: { chatId: string } }
	| { type: "APPEND_STREAMING"; payload: { chatId: string; delta: string } }
	| { type: "CLEAR_STREAMING"; payload: { chatId: string } }
	| { type: "RESET_STREAMING"; payload?: { chatId: string | null } }
	| { type: "SET_SENDING_MESSAGE"; payload: boolean }
	| { type: "SET_CREATING_PROJECT"; payload: boolean }
	| { type: "SET_CREATING_CHAT"; payload: boolean }
	| { type: "SET_CONNECTION_STATE"; payload: ConnectionState }
	| { type: "SET_CONNECTION_ERROR"; payload: Omit<UiError, "id" | "timestamp"> | null }
	| { type: "CLEAR_CONNECTION_ERROR" }
	| { type: "ADD_ERROR"; payload: Omit<UiError, "id" | "timestamp"> }
	| { type: "REMOVE_ERROR"; payload: string }
	| { type: "CLEAR_ERRORS" };

const formatErrorId = () => `err-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;

const workspaceReducer = (state: WorkspaceState, action: WorkspaceAction): WorkspaceState => {
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
				].sort((a, b) => {
					if (a.updatedAt > b.updatedAt) return -1;
					if (a.updatedAt < b.updatedAt) return 1;
					return 0;
				}),
			};

		case "TOGGLE_FAVORITE":
			return {
				...state,
				projects: state.projects.map((project) =>
					project.id === action.payload.id
						? { ...project, isFavorite: action.payload.isFavorite }
						: project,
				),
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

			case "RESET_SELECTED_PROJECT":
				return {
					...state,
					selectedProjectId: null,
					chats: [],
					selectedChatId: null,
					messages: [],
					streamingByChat: {},
					streamingActiveByChat: {},
				};

		case "SET_CHATS_LOADING":
			return {
				...state,
				chatsLoading: action.payload,
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
				]
					.sort((a, b) => {
						if (a.updatedAt > b.updatedAt) return -1;
						if (a.updatedAt < b.updatedAt) return 1;
						return 0;
					}),
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
						...(!action.payload
							? {}
							: { [action.payload]: state.streamingActiveByChat[action.payload] ?? false }),
					},
				};

			case "RESET_SELECTED_CHAT":
				return {
					...state,
					selectedChatId: null,
					messages: [],
					streamingByChat: {},
					streamingActiveByChat: {},
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
					messagesLoading: false,
				};

			case "START_STREAMING":
				return {
					...state,
					streamingByChat: {
						...state.streamingByChat,
						[action.payload.chatId]: state.streamingByChat[action.payload.chatId] ?? "",
					},
					streamingActiveByChat: {
						...state.streamingActiveByChat,
						[action.payload.chatId]: true,
					},
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

			case "RESET_STREAMING":
				return {
					...state,
					streamingByChat: action.payload?.chatId ? {
						...state.streamingByChat,
						[action.payload.chatId]: "",
					} : {},
					streamingActiveByChat: action.payload?.chatId
						? {
							...state.streamingActiveByChat,
							[action.payload.chatId]: false,
						}
						: {},
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

			case "SET_CONNECTION_ERROR": {
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
			}

			case "CLEAR_CONNECTION_ERROR":
				return {
					...state,
					connectionError: null,
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

		case "REMOVE_ERROR":
			return {
				...state,
				errors: state.errors.filter((error) => error.id !== action.payload),
			};

		case "CLEAR_ERRORS":
			return {
				...state,
				errors: [],
			};

		default:
			return state;
	}
};

export type PendingAssistantBuffer = Record<string, string>;

export const useWorkspaceStore = () => {
	const [state, dispatch] = useReducer(workspaceReducer, {
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
		connectionError: null,
		connectionState: "idle",
		errors: [],
	} as WorkspaceState);

	return {
		state,
			dispatch,
	};
};
