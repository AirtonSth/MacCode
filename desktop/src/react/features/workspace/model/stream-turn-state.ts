import type {
	AssistantStreamEvent,
	AssistantStreamItemState,
	AssistantStreamItemType,
} from "../../../../shared/assistant-stream-event";
import type { ChatTurnDTO } from "../../../shared/api/remotecode-http";

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

const createStreamItem = (itemId: string, itemType: AssistantStreamItemType): StreamItem => ({
	body: "",
	expandedByUser: false,
	finishedAtMs: null,
	id: itemId,
	isExpanded: false,
	output: "",
	startedAtMs: Date.now(),
	state: "running",
	summary: "",
	type: itemType,
});

const shouldAutoExpandForState = (state: AssistantStreamItemState): boolean => state === "running";

export const createStreamTurnState = (turnId: string): StreamTurnState => ({
	finishedAtMs: null,
	itemOrder: [],
	itemsById: {},
	startedAtMs: Date.now(),
	status: "running",
	turnId,
});

export const cloneTurn = (turn: StreamTurnState): StreamTurnState => ({
	...turn,
	itemOrder: Array.from(turn.itemOrder),
	itemsById: { ...turn.itemsById },
});

export const mapChatTurnToStreamTurn = (turn: ChatTurnDTO): StreamTurnState => ({
	...turn,
	itemOrder: Array.from(turn.itemOrder),
	itemsById: Object.fromEntries(
		Object.entries(turn.itemsById).map(([itemId, item]) => [
			itemId,
			{
				...item,
			},
		]),
	),
});

export const mapChatTurnsToStreamTurns = (turns: ChatTurnDTO[]): StreamTurnState[] =>
	turns.map(mapChatTurnToStreamTurn);

const ensureTurnForEvent = (
	currentTurn: StreamTurnState | null,
	turnId: string,
): StreamTurnState => {
	if (currentTurn && currentTurn.turnId === turnId) {
		return cloneTurn(currentTurn);
	}

	return createStreamTurnState(turnId);
};

const ensureItemForTurn = (
	turn: StreamTurnState,
	itemId: string,
	defaultItemType: AssistantStreamItemType = "reasoning",
): { item: StreamItem; turn: StreamTurnState } => {
	const existing = turn.itemsById[itemId];
	if (existing) {
		return {
			item: {
				...existing,
			},
			turn,
		};
	}

	const created = createStreamItem(itemId, defaultItemType);
	return {
		item: created,
		turn: {
			...turn,
			itemOrder: turn.itemOrder.includes(itemId) ? Array.from(turn.itemOrder) : [...turn.itemOrder, itemId],
			itemsById: {
				...turn.itemsById,
				[itemId]: created,
			},
		},
	};
};

export const applyAssistantEventToTurn = (
	currentTurn: StreamTurnState | null,
	event: AssistantStreamEvent,
): StreamTurnState => {
	if (event.type === "turn_started") {
		return createStreamTurnState(event.turnId);
	}

	let turn = ensureTurnForEvent(currentTurn, event.turnId);

	if (event.type === "turn_completed") {
		turn.status = turn.status === "failed" ? "failed" : "completed";
		turn.finishedAtMs = Date.now();
		return turn;
	}

	const existingDefaultType = turn.itemsById[event.itemId]?.type ??
		(event.type === "item_delta" && event.target === "output" ? "tool" : "reasoning");
	const resolvedItem = ensureItemForTurn(turn, event.itemId, existingDefaultType);
	turn = resolvedItem.turn;
	const item = resolvedItem.item;

	if (event.type === "item_started") {
		item.type = event.itemType;
		item.state = event.state ?? "running";
		if (event.summary !== undefined) {
			item.summary = event.summary;
		}
		if (!item.expandedByUser) {
			item.isExpanded = shouldAutoExpandForState(item.state);
		}
		turn.itemsById[event.itemId] = item;
		return turn;
	}

	if (event.type === "item_delta") {
		if (event.target === "summary") {
			item.summary = `${item.summary}${event.delta}`;
		}
		if (event.target === "body") {
			item.body = `${item.body}${event.delta}`;
		}
		if (event.target === "output") {
			item.output = `${item.output}${event.delta}`;
		}
	}

	if (event.type === "item_state") {
		item.state = event.state;
		if (event.summary !== undefined) {
			item.summary = event.summary;
		}
		if (event.state === "failed" || event.state === "cancelled") {
			turn.status = "failed";
		}
		if (!item.expandedByUser) {
			item.isExpanded = shouldAutoExpandForState(item.state);
		}
	}

	if (event.type === "item_completed") {
		item.state ??= item.state === "failed" || item.state === "cancelled" ? item.state : "completed";
		item.finishedAtMs ??= Date.now();
		if (event.summary !== undefined) {
			item.summary = event.summary;
		}
		if (item.state === "failed" || item.state === "cancelled") {
			turn.status = "failed";
		}
		if (!item.expandedByUser) {
			item.isExpanded = shouldAutoExpandForState(item.state);
		}
	}

	turn.itemsById[event.itemId] = item;
	return turn;
};

export const setStreamItemExpanded = (
	turn: StreamTurnState,
	itemId: string,
	options: {
		expanded: boolean;
		byUser: boolean;
	},
): StreamTurnState => {
	const { byUser, expanded } = options;
	const currentItem = turn.itemsById[itemId];
	if (!currentItem) {
		return turn;
	}

	const nextTurn = cloneTurn(turn);
	nextTurn.itemsById[itemId] = {
		...currentItem,
		expandedByUser: byUser ? expanded : currentItem.expandedByUser,
		isExpanded: expanded,
	};
	return nextTurn;
};

export const setStreamItemState = (
	turn: StreamTurnState,
	itemId: string,
	state: AssistantStreamItemState,
): StreamTurnState => {
	const currentItem = turn.itemsById[itemId];
	if (!currentItem) {
		return turn;
	}

	const nextTurn = cloneTurn(turn);
	nextTurn.itemsById[itemId] = {
		...currentItem,
		finishedAtMs:
			state === "completed" || state === "failed" || state === "cancelled"
				? currentItem.finishedAtMs ?? Date.now()
				: currentItem.finishedAtMs,
		state,
	};
	return nextTurn;
};
