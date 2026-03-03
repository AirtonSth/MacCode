import { useReducer } from "react";
import type {
	AssistantStreamEvent,
	AssistantStreamItemState,
	AssistantStreamItemType,
} from "../../../../shared/assistant-stream-event";

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
	provider: "fake" | "codex";
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

export interface StreamItem {
	id: string;
	type: AssistantStreamItemType;
	state: AssistantStreamItemState;
	summary: string;
	body: string;
	output: string;
	startedAtMs: number;
	finishedAtMs: number | null;
	expandedByUser: boolean;
	isExpanded: boolean;
}

export interface StreamTurnState {
	turnId: string;
	status: "running" | "completed" | "failed";
	itemsById: Record<string, StreamItem>;
	itemOrder: string[];
	startedAtMs: number;
	finishedAtMs: number | null;
}

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
	streamTurnsByChat: Record<string, StreamTurnState | undefined>;
	streamHistoryByChat: Record<string, StreamTurnState[]>;
	lastAssistantEventIdByChat: Record<string, number>;
	sendingByChat: Record<string, boolean>;
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
	| { type: "REMOVE_CHAT"; payload: { chatId: string; nextSelectedChatId: string | null } }
	| { type: "SET_SELECTED_CHAT"; payload: string | null }
	| { type: "RESET_SELECTED_CHAT" }
	| { type: "SET_MESSAGES_LOADING"; payload: boolean }
	| { type: "SET_MESSAGES"; payload: MessageDTO[] }
	| { type: "APPEND_MESSAGE"; payload: MessageDTO }
	| { type: "START_STREAMING"; payload: { chatId: string } }
	| { type: "APPEND_STREAMING"; payload: { chatId: string; delta: string } }
	| { type: "SET_STREAMING_SNAPSHOT"; payload: { chatId: string; text: string } }
	| { type: "CLEAR_STREAMING"; payload: { chatId: string } }
	| { type: "RESET_STREAMING"; payload?: { chatId: string | null } }
	| { type: "APPLY_ASSISTANT_EVENT"; payload: { chatId: string; event: AssistantStreamEvent; eventId?: number } }
	| { type: "SET_STREAM_HISTORY"; payload: { chatId: string; turns: StreamTurnState[]; lastEventId: number } }
	| { type: "SET_STREAM_ITEM_EXPANDED"; payload: { chatId: string; itemId: string; expanded: boolean; byUser: boolean } }
	| { type: "SET_STREAM_ITEM_STATE"; payload: { chatId: string; itemId: string; state: AssistantStreamItemState } }
	| { type: "CLEAR_STREAM_TURN"; payload: { chatId: string } }
	| { type: "SET_CHAT_SENDING"; payload: { chatId: string; sending: boolean } }
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

const createStreamTurnState = (turnId: string): StreamTurnState => ({
	turnId,
	status: "running",
	itemsById: {},
	itemOrder: [],
	startedAtMs: Date.now(),
	finishedAtMs: null,
});

const createStreamItem = (itemId: string, itemType: AssistantStreamItemType): StreamItem => ({
	id: itemId,
	type: itemType,
	state: "running",
	summary: "",
	body: "",
	output: "",
	startedAtMs: Date.now(),
	finishedAtMs: null,
	expandedByUser: false,
	isExpanded: false,
});

const cloneTurn = (turn: StreamTurnState): StreamTurnState => ({
	...turn,
	itemsById: { ...turn.itemsById },
	itemOrder: [...turn.itemOrder],
});

const ensureTurnForEvent = (
	streamTurnsByChat: Record<string, StreamTurnState | undefined>,
	chatId: string,
	turnId: string,
): StreamTurnState => {
	const currentTurn = streamTurnsByChat[chatId];
	if (currentTurn && currentTurn.turnId === turnId) {
		return cloneTurn(currentTurn);
	}

	return createStreamTurnState(turnId);
};

const ensureItemForTurn = (
	turn: StreamTurnState,
	itemId: string,
	defaultItemType: AssistantStreamItemType = "reasoning",
): StreamItem => {
	const existing = turn.itemsById[itemId];
	if (existing) {
		return {
			...existing,
		};
	}

	const created = createStreamItem(itemId, defaultItemType);
	turn.itemOrder = turn.itemOrder.includes(itemId) ? turn.itemOrder : [...turn.itemOrder, itemId];
	return created;
};

const upsertTurnHistory = (
	turns: StreamTurnState[] | undefined,
	turn: StreamTurnState,
): StreamTurnState[] => {
	const current = turns ?? [];
	const index = current.findIndex((item) => item.turnId === turn.turnId);
	if (index < 0) {
		return [...current, turn];
	}

	const next = [...current];
	next[index] = turn;
	return next;
};

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

		case "RESET_SELECTED_PROJECT":
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

		case "REMOVE_CHAT": {
			const nextStreamingByChat = { ...state.streamingByChat };
			const nextStreamingActiveByChat = { ...state.streamingActiveByChat };
			const nextStreamTurnsByChat = { ...state.streamTurnsByChat };
			const nextStreamHistoryByChat = { ...state.streamHistoryByChat };
			const nextLastAssistantEventIdByChat = { ...state.lastAssistantEventIdByChat };
			const nextSendingByChat = { ...state.sendingByChat };
			delete nextStreamingByChat[action.payload.chatId];
			delete nextStreamingActiveByChat[action.payload.chatId];
			delete nextStreamTurnsByChat[action.payload.chatId];
			delete nextStreamHistoryByChat[action.payload.chatId];
			delete nextLastAssistantEventIdByChat[action.payload.chatId];
			delete nextSendingByChat[action.payload.chatId];

			return {
				...state,
				chats: state.chats.filter((chat) => chat.id !== action.payload.chatId),
				selectedChatId: action.payload.nextSelectedChatId,
				messages: state.selectedChatId === action.payload.chatId ? [] : state.messages,
				streamingByChat: nextStreamingByChat,
				streamingActiveByChat: nextStreamingActiveByChat,
				streamTurnsByChat: nextStreamTurnsByChat,
				streamHistoryByChat: nextStreamHistoryByChat,
				lastAssistantEventIdByChat: nextLastAssistantEventIdByChat,
				sendingByChat: nextSendingByChat,
				isSendingMessage: Object.values(nextSendingByChat).some(Boolean),
			};
		}

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
				streamTurnsByChat: {},
				streamHistoryByChat: {},
				lastAssistantEventIdByChat: {},
				sendingByChat: {},
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

		case "SET_STREAMING_SNAPSHOT":
			return {
				...state,
				streamingByChat: {
					...state.streamingByChat,
					[action.payload.chatId]: action.payload.text,
				},
				streamingActiveByChat: {
					...state.streamingActiveByChat,
					[action.payload.chatId]: action.payload.text.trim().length > 0,
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

		case "RESET_STREAMING": {
			if (action.payload?.chatId) {
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
					streamTurnsByChat: {
						...state.streamTurnsByChat,
						[action.payload.chatId]: undefined,
					},
				};
			}

			return {
				...state,
				streamingByChat: {},
				streamingActiveByChat: {},
				streamTurnsByChat: {},
			};
		}

		case "APPLY_ASSISTANT_EVENT": {
			const chatId = action.payload.chatId;
			const streamEvent = action.payload.event;
			const incomingEventId = action.payload.eventId;
			const lastAppliedEventId = state.lastAssistantEventIdByChat[chatId] ?? 0;
			if (typeof incomingEventId === "number" && incomingEventId <= lastAppliedEventId) {
				return state;
			}
			const nextStreamTurnsByChat = { ...state.streamTurnsByChat };
			const nextStreamHistoryByChat = { ...state.streamHistoryByChat };
			const nextStreamingActiveByChat = { ...state.streamingActiveByChat };
			const nextLastAssistantEventIdByChat = { ...state.lastAssistantEventIdByChat };
			if (typeof incomingEventId === "number") {
				nextLastAssistantEventIdByChat[chatId] = incomingEventId;
			}

			if (streamEvent.type === "turn_started") {
				const turn = createStreamTurnState(streamEvent.turnId);
				nextStreamTurnsByChat[chatId] = turn;
				nextStreamHistoryByChat[chatId] = upsertTurnHistory(nextStreamHistoryByChat[chatId], turn);
				nextStreamingActiveByChat[chatId] = true;

				return {
					...state,
					streamTurnsByChat: nextStreamTurnsByChat,
					streamHistoryByChat: nextStreamHistoryByChat,
					streamingActiveByChat: nextStreamingActiveByChat,
					lastAssistantEventIdByChat: nextLastAssistantEventIdByChat,
				};
			}

			if (streamEvent.type === "turn_completed") {
				const currentTurn = nextStreamTurnsByChat[chatId];
				if (currentTurn && currentTurn.turnId === streamEvent.turnId) {
					const turn = cloneTurn(currentTurn);
					turn.status = turn.status === "failed" ? "failed" : "completed";
					turn.finishedAtMs = Date.now();
					nextStreamTurnsByChat[chatId] = turn;
					nextStreamHistoryByChat[chatId] = upsertTurnHistory(nextStreamHistoryByChat[chatId], turn);
				}
				nextStreamingActiveByChat[chatId] = false;

				return {
					...state,
					streamTurnsByChat: nextStreamTurnsByChat,
					streamHistoryByChat: nextStreamHistoryByChat,
					streamingActiveByChat: nextStreamingActiveByChat,
					lastAssistantEventIdByChat: nextLastAssistantEventIdByChat,
				};
			}

			const turn = ensureTurnForEvent(nextStreamTurnsByChat, chatId, streamEvent.turnId);
			nextStreamingActiveByChat[chatId] = true;

			if (streamEvent.type === "item_started") {
				const item = ensureItemForTurn(turn, streamEvent.itemId, streamEvent.itemType);
				item.type = streamEvent.itemType;
				item.state = streamEvent.state ?? "running";
				if (streamEvent.summary !== undefined) {
					item.summary = streamEvent.summary;
				}
				turn.itemsById[streamEvent.itemId] = item;
				nextStreamTurnsByChat[chatId] = turn;
				nextStreamHistoryByChat[chatId] = upsertTurnHistory(nextStreamHistoryByChat[chatId], turn);
				return {
					...state,
					streamTurnsByChat: nextStreamTurnsByChat,
					streamHistoryByChat: nextStreamHistoryByChat,
					streamingActiveByChat: nextStreamingActiveByChat,
					lastAssistantEventIdByChat: nextLastAssistantEventIdByChat,
				};
			}

			const existingDefaultType =
				turn.itemsById[streamEvent.itemId]?.type ??
				(streamEvent.type === "item_delta" && streamEvent.target === "output"
					? "tool"
					: "reasoning");
			const item = ensureItemForTurn(turn, streamEvent.itemId, existingDefaultType);

			if (streamEvent.type === "item_delta") {
				if (streamEvent.target === "summary") {
					item.summary = `${item.summary}${streamEvent.delta}`;
				}
				if (streamEvent.target === "body") {
					item.body = `${item.body}${streamEvent.delta}`;
				}
				if (streamEvent.target === "output") {
					item.output = `${item.output}${streamEvent.delta}`;
				}
			}

			if (streamEvent.type === "item_state") {
				item.state = streamEvent.state;
				if (streamEvent.summary !== undefined) {
					item.summary = streamEvent.summary;
				}
				if (streamEvent.state === "failed" || streamEvent.state === "cancelled") {
					turn.status = "failed";
				}
			}

			if (streamEvent.type === "item_completed") {
				item.state =
					streamEvent.state ?? (item.state === "failed" || item.state === "cancelled" ? item.state : "completed");
				item.finishedAtMs = item.finishedAtMs ?? Date.now();
				if (streamEvent.summary !== undefined) {
					item.summary = streamEvent.summary;
				}
				if (item.state === "failed" || item.state === "cancelled") {
					turn.status = "failed";
				}
			}

			turn.itemsById[streamEvent.itemId] = item;
			nextStreamTurnsByChat[chatId] = turn;
			nextStreamHistoryByChat[chatId] = upsertTurnHistory(nextStreamHistoryByChat[chatId], turn);

			return {
				...state,
				streamTurnsByChat: nextStreamTurnsByChat,
				streamHistoryByChat: nextStreamHistoryByChat,
				streamingActiveByChat: nextStreamingActiveByChat,
				lastAssistantEventIdByChat: nextLastAssistantEventIdByChat,
			};
		}

		case "SET_STREAM_HISTORY":
			return {
				...state,
				streamHistoryByChat: {
					...state.streamHistoryByChat,
					[action.payload.chatId]: action.payload.turns,
				},
				streamTurnsByChat: {
					...state.streamTurnsByChat,
					[action.payload.chatId]: action.payload.turns.at(-1),
				},
				lastAssistantEventIdByChat: {
					...state.lastAssistantEventIdByChat,
					[action.payload.chatId]: action.payload.lastEventId,
				},
			};

		case "SET_STREAM_ITEM_EXPANDED": {
			const currentTurn = state.streamTurnsByChat[action.payload.chatId];
			if (!currentTurn) {
				return state;
			}

			const currentItem = currentTurn.itemsById[action.payload.itemId];
			if (!currentItem) {
				return state;
			}

			const turn = cloneTurn(currentTurn);
			turn.itemsById[action.payload.itemId] = {
				...currentItem,
				isExpanded: action.payload.expanded,
				expandedByUser: action.payload.byUser ? action.payload.expanded : currentItem.expandedByUser,
			};

			return {
				...state,
				streamTurnsByChat: {
					...state.streamTurnsByChat,
					[action.payload.chatId]: turn,
				},
			};
		}

		case "SET_STREAM_ITEM_STATE": {
			const currentTurn = state.streamTurnsByChat[action.payload.chatId];
			if (!currentTurn) {
				return state;
			}

			const currentItem = currentTurn.itemsById[action.payload.itemId];
			if (!currentItem) {
				return state;
			}

			const turn = cloneTurn(currentTurn);
			turn.itemsById[action.payload.itemId] = {
				...currentItem,
				state: action.payload.state,
				finishedAtMs:
					action.payload.state === "completed" ||
					action.payload.state === "failed" ||
					action.payload.state === "cancelled"
						? currentItem.finishedAtMs ?? Date.now()
						: currentItem.finishedAtMs,
			};

			return {
				...state,
				streamTurnsByChat: {
					...state.streamTurnsByChat,
					[action.payload.chatId]: turn,
				},
			};
		}

		case "CLEAR_STREAM_TURN":
			return {
				...state,
				streamTurnsByChat: {
					...state.streamTurnsByChat,
					[action.payload.chatId]: undefined,
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
		baseUrl: "http://127.0.0.1:8835",
		token: "remotecode.io-token",
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
		connectionError: null,
		connectionState: "idle",
		errors: [],
	} as WorkspaceState);

	return {
		state,
		dispatch,
	};
};
