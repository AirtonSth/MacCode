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
	isActive: boolean;
	projectId: string;
	title: string;
	provider: "fake" | "codex" | "claude";
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

export interface MessageWindowState {
	chatId: string | null;
	messages: MessageDTO[];
	hasMore: boolean;
	nextBeforeMessageId: string | null;
	turns: StreamTurnState[];
	mode: "latest" | "older";
	latestDirty: boolean;
}

export interface WorkspaceState {
	baseUrl: string;
	token: string;
	projects: ProjectDTO[];
	selectedProjectId: string | null;
	chats: ChatDTO[];
	selectedChatId: string | null;
	messageWindow: MessageWindowState;
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
	| {
			type: "BOOTSTRAP_COMPLETE";
			payload: {
				projects: ProjectDTO[];
				selectedProjectId: string | null;
				chats: ChatDTO[];
				selectedChatId: string | null;
				messageWindow: MessageWindowState;
			};
	  }
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
	| { type: "SET_MESSAGE_WINDOW_LOADING"; payload: boolean }
	| {
			type: "SET_MESSAGE_WINDOW";
			payload: {
				chatId: string | null;
				hasMore: boolean;
				latestDirty?: boolean;
				messages: MessageDTO[];
				mode: "latest" | "older";
				nextBeforeMessageId: string | null;
				turns: StreamTurnState[];
			};
	  }
	| { type: "UPSERT_MESSAGE_IN_WINDOW"; payload: { chatId: string; message: MessageDTO } }
	| { type: "MARK_LATEST_WINDOW_DIRTY"; payload: { chatId: string; dirty: boolean } }
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
	| { type: "CLEAR_ERRORS" }
	| { type: "CLEAR_ERRORS_BY_SOURCE"; payload: "rest" | "ws" };

const formatErrorId = () => `err-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;

export const sortChatsByUpdatedAtDesc = (chats: ChatDTO[]): ChatDTO[] =>
	[...chats].sort((a, b) => {
		if (a.updatedAt > b.updatedAt) return -1;
		if (a.updatedAt < b.updatedAt) return 1;
		return 0;
	});

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

const shouldAutoExpandForState = (state: AssistantStreamItemState): boolean => state === "running";

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

const collapseTurnItems = (turn: StreamTurnState): StreamTurnState => {
	const collapsedItems = Object.fromEntries(
		turn.itemOrder
			.map((itemId) => [itemId, turn.itemsById[itemId]] as const)
			.filter((entry): entry is readonly [string, StreamItem] => Boolean(entry[1]))
			.map(([itemId, item]) => [
				itemId,
				{
					...item,
					state:
						item.state === "failed" || item.state === "cancelled"
							? item.state
							: "collapsed",
					isExpanded: false,
					expandedByUser: false,
				},
			]),
	) as Record<string, StreamItem>;

	return {
		...turn,
		itemsById: collapsedItems,
	};
};

const MESSAGE_WINDOW_PAGE_SIZE = 5;

export const createEmptyMessageWindow = (chatId: string | null = null): MessageWindowState => ({
	chatId,
	messages: [],
	hasMore: false,
	nextBeforeMessageId: null,
	turns: [],
	mode: "latest",
	latestDirty: false,
});

const normalizeTurnHistory = (turns: StreamTurnState[]): StreamTurnState[] =>
	turns.map((turn) => (turn.status === "running" ? turn : collapseTurnItems(turn)));

const sortMessagesAscending = (messages: MessageDTO[]): MessageDTO[] =>
	[...messages].sort((left, right) => {
		if (left.createdAt < right.createdAt) {
			return -1;
		}
		if (left.createdAt > right.createdAt) {
			return 1;
		}
		return left.id.localeCompare(right.id);
	});

const upsertMessageInList = (messages: MessageDTO[], message: MessageDTO): MessageDTO[] => {
	const existingIndex = messages.findIndex((entry) => entry.id === message.id);
	if (existingIndex === -1) {
		return sortMessagesAscending([...messages, message]);
	}

	const nextMessages = [...messages];
	nextMessages[existingIndex] = message;
	return sortMessagesAscending(nextMessages);
};

const trimMessageWindow = (messages: MessageDTO[]): {
	hasTrimmedOlderMessages: boolean;
	messages: MessageDTO[];
} => {
	if (messages.length <= MESSAGE_WINDOW_PAGE_SIZE) {
		return {
			hasTrimmedOlderMessages: false,
			messages,
		};
	}

	return {
		hasTrimmedOlderMessages: true,
		messages: messages.slice(-MESSAGE_WINDOW_PAGE_SIZE),
	};
};

export const workspaceReducer = (state: WorkspaceState, action: WorkspaceAction): WorkspaceState => {
	switch (action.type) {
		case "BOOTSTRAP_CONFIG":
			return {
				...state,
				baseUrl: action.payload.baseUrl,
				token: action.payload.token,
			};

		case "BOOTSTRAP_COMPLETE":
			return {
				...state,
				projects: action.payload.projects,
				selectedProjectId: action.payload.selectedProjectId,
				chats: action.payload.chats,
				selectedChatId: action.payload.selectedChatId,
				messageWindow: action.payload.messageWindow,
				projectsLoading: false,
				chatsLoading: false,
				messagesLoading: false,
				streamingByChat: {},
				streamingActiveByChat: {},
				streamTurnsByChat: {},
				streamHistoryByChat: {},
				lastAssistantEventIdByChat: {},
				sendingByChat: {},
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
					messageWindow: createEmptyMessageWindow(),
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
				messageWindow: createEmptyMessageWindow(),
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
				messageWindow: createEmptyMessageWindow(),
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

		case "SET_CHATS": {
			const sortedChats = sortChatsByUpdatedAtDesc(action.payload);
			return {
				...state,
				chats: sortedChats,
				chatsLoading: false,
				selectedChatId: sortedChats[0]?.id ?? null,
				messageWindow: createEmptyMessageWindow(sortedChats[0]?.id ?? null),
			};
		}

		case "UPSERT_CHAT":
			return {
				...state,
				chats: sortChatsByUpdatedAtDesc([
					...state.chats.filter((chat) => chat.id !== action.payload.id),
					action.payload,
				]),
				selectedChatId: action.payload.id,
				messageWindow: createEmptyMessageWindow(action.payload.id),
			};

		case "UPDATE_CHAT":
			return {
				...state,
				chats: sortChatsByUpdatedAtDesc(
					state.chats.map((chat) =>
						chat.id === action.payload.id ? { ...chat, ...action.payload } : chat,
					),
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
				messageWindow:
					state.selectedChatId === action.payload.chatId
						? createEmptyMessageWindow(action.payload.nextSelectedChatId)
						: state.messageWindow,
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
				messageWindow: createEmptyMessageWindow(action.payload),
				streamingByChat: {},
				streamingActiveByChat: action.payload ? { [action.payload]: false } : {},
				streamTurnsByChat: {},
				streamHistoryByChat: {},
				lastAssistantEventIdByChat: {},
				sendingByChat: {},
			};

		case "RESET_SELECTED_CHAT":
			return {
				...state,
				selectedChatId: null,
				messageWindow: createEmptyMessageWindow(),
				streamingByChat: {},
				streamingActiveByChat: {},
				streamTurnsByChat: {},
				streamHistoryByChat: {},
				lastAssistantEventIdByChat: {},
				sendingByChat: {},
			};

		case "SET_MESSAGE_WINDOW_LOADING":
			return {
				...state,
				messagesLoading: action.payload,
			};

		case "SET_MESSAGE_WINDOW": {
			const turns = normalizeTurnHistory(action.payload.turns);
			return {
				...state,
				messageWindow: {
					chatId: action.payload.chatId,
					hasMore: action.payload.hasMore,
					latestDirty: action.payload.latestDirty ?? false,
					messages: action.payload.messages,
					mode: action.payload.mode,
					nextBeforeMessageId: action.payload.nextBeforeMessageId,
					turns,
				},
				messagesLoading: false,
				streamHistoryByChat: action.payload.chatId ? { [action.payload.chatId]: turns } : {},
				streamTurnsByChat: action.payload.chatId
					? { [action.payload.chatId]: turns.at(-1)?.status === "running" ? turns.at(-1) : undefined }
					: {},
				lastAssistantEventIdByChat: action.payload.chatId
					? { [action.payload.chatId]: state.lastAssistantEventIdByChat[action.payload.chatId] ?? 0 }
					: {},
			};
		}

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

		case "UPSERT_MESSAGE_IN_WINDOW": {
			if (
				state.selectedChatId !== action.payload.chatId ||
				state.messageWindow.chatId !== action.payload.chatId
			) {
				return state;
			}

			if (state.messageWindow.mode !== "latest") {
				return {
					...state,
					messageWindow: {
						...state.messageWindow,
						latestDirty: true,
					},
				};
			}

			const nextMessages = upsertMessageInList(state.messageWindow.messages, action.payload.message);
			const trimmedWindow = trimMessageWindow(nextMessages);
			const oldestVisibleMessageId = trimmedWindow.messages[0]?.id ?? null;
			return {
				...state,
				messageWindow: {
					...state.messageWindow,
					hasMore: state.messageWindow.hasMore || trimmedWindow.hasTrimmedOlderMessages,
					latestDirty: false,
					messages: trimmedWindow.messages,
					nextBeforeMessageId:
						state.messageWindow.hasMore || trimmedWindow.hasTrimmedOlderMessages
							? oldestVisibleMessageId
							: state.messageWindow.nextBeforeMessageId,
				},
			};
		}

		case "MARK_LATEST_WINDOW_DIRTY":
			if (
				state.selectedChatId !== action.payload.chatId ||
				state.messageWindow.chatId !== action.payload.chatId
			) {
				return state;
			}

			return {
				...state,
				messageWindow: {
					...state.messageWindow,
					latestDirty: action.payload.dirty,
				},
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
			if (state.selectedChatId !== chatId || state.messageWindow.chatId !== chatId) {
				return state;
			}

			if (state.messageWindow.mode !== "latest") {
				return {
					...state,
					messageWindow: {
						...state.messageWindow,
						latestDirty: true,
					},
				};
			}

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
					messageWindow: {
						...state.messageWindow,
						turns: nextStreamHistoryByChat[chatId] ?? state.messageWindow.turns,
					},
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
					const collapsedTurn = collapseTurnItems(turn);
					nextStreamTurnsByChat[chatId] = collapsedTurn;
					nextStreamHistoryByChat[chatId] = upsertTurnHistory(
						nextStreamHistoryByChat[chatId],
						collapsedTurn,
					);
				}
				nextStreamingActiveByChat[chatId] = false;

				return {
					...state,
					messageWindow: {
						...state.messageWindow,
						turns: nextStreamHistoryByChat[chatId] ?? state.messageWindow.turns,
					},
					streamTurnsByChat: nextStreamTurnsByChat,
					streamHistoryByChat: nextStreamHistoryByChat,
					streamingActiveByChat: nextStreamingActiveByChat,
					lastAssistantEventIdByChat: nextLastAssistantEventIdByChat,
				};
			}

			let turn = ensureTurnForEvent(nextStreamTurnsByChat, chatId, streamEvent.turnId);
			nextStreamingActiveByChat[chatId] = true;

			if (streamEvent.type === "item_started") {
				const item = ensureItemForTurn(turn, streamEvent.itemId, streamEvent.itemType);
				item.type = streamEvent.itemType;
				item.state = streamEvent.state ?? "running";
				if (streamEvent.summary !== undefined) {
					item.summary = streamEvent.summary;
				}
				if (!item.expandedByUser) {
					item.isExpanded = shouldAutoExpandForState(item.state);
				}
				turn.itemsById[streamEvent.itemId] = item;
				nextStreamTurnsByChat[chatId] = turn;
				nextStreamHistoryByChat[chatId] = upsertTurnHistory(nextStreamHistoryByChat[chatId], turn);
				return {
					...state,
					messageWindow: {
						...state.messageWindow,
						turns: nextStreamHistoryByChat[chatId] ?? state.messageWindow.turns,
					},
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
				if (!item.expandedByUser) {
					item.isExpanded = shouldAutoExpandForState(item.state);
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
				if (!item.expandedByUser) {
					item.isExpanded = shouldAutoExpandForState(item.state);
				}
			}

			turn.itemsById[streamEvent.itemId] = item;
			if (
				streamEvent.type === "item_completed" &&
				(
					item.type === "assistant_message" ||
					(typeof streamEvent.summary === "string" && streamEvent.summary.toLowerCase().includes("response completed"))
				)
			) {
				turn = collapseTurnItems(turn);
			}
			nextStreamTurnsByChat[chatId] = turn;
			nextStreamHistoryByChat[chatId] = upsertTurnHistory(nextStreamHistoryByChat[chatId], turn);

			return {
				...state,
				messageWindow: {
					...state.messageWindow,
					turns: nextStreamHistoryByChat[chatId] ?? state.messageWindow.turns,
				},
				streamTurnsByChat: nextStreamTurnsByChat,
				streamHistoryByChat: nextStreamHistoryByChat,
				streamingActiveByChat: nextStreamingActiveByChat,
				lastAssistantEventIdByChat: nextLastAssistantEventIdByChat,
			};
		}

		case "SET_STREAM_HISTORY":
			const normalizedTurns = normalizeTurnHistory(action.payload.turns);
			return {
				...state,
				messageWindow:
					state.messageWindow.chatId === action.payload.chatId
						? {
							...state.messageWindow,
							turns: normalizedTurns,
						}
						: state.messageWindow,
				streamHistoryByChat: {
					...state.streamHistoryByChat,
					[action.payload.chatId]: normalizedTurns,
				},
				streamTurnsByChat: {
					...state.streamTurnsByChat,
					[action.payload.chatId]: normalizedTurns.at(-1)?.status === "running" ? normalizedTurns.at(-1) : undefined,
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
			const nextHistory = (state.streamHistoryByChat[action.payload.chatId] ?? []).map((historyTurn) =>
				historyTurn.turnId === turn.turnId
					? {
						...historyTurn,
						itemsById: {
							...historyTurn.itemsById,
							[action.payload.itemId]: turn.itemsById[action.payload.itemId],
						},
					}
					: historyTurn,
			);

			return {
				...state,
				messageWindow:
					state.messageWindow.chatId === action.payload.chatId
						? {
							...state.messageWindow,
							turns: nextHistory,
						}
						: state.messageWindow,
				streamHistoryByChat: {
					...state.streamHistoryByChat,
					[action.payload.chatId]: nextHistory,
				},
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
			const nextHistory = (state.streamHistoryByChat[action.payload.chatId] ?? []).map((historyTurn) =>
				historyTurn.turnId === turn.turnId
					? {
						...historyTurn,
						itemsById: {
							...historyTurn.itemsById,
							[action.payload.itemId]: turn.itemsById[action.payload.itemId],
						},
					}
					: historyTurn,
			);

			return {
				...state,
				messageWindow:
					state.messageWindow.chatId === action.payload.chatId
						? {
							...state.messageWindow,
							turns: nextHistory,
						}
						: state.messageWindow,
				streamHistoryByChat: {
					...state.streamHistoryByChat,
					[action.payload.chatId]: nextHistory,
				},
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

		case "CLEAR_ERRORS_BY_SOURCE":
			return {
				...state,
				errors: state.errors.filter((error) => error.source !== action.payload),
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
	} as WorkspaceState);

	return {
		state,
		dispatch,
	};
};
