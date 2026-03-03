import type {
	AssistantStreamEvent,
	AssistantStreamItemState,
	AssistantStreamItemType,
} from "../../../shared/api/types";

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
	id: itemId,
	type: itemType,
	state: "running",
	summary: "",
	body: "",
	output: "",
	startedAtMs: Date.now(),
	finishedAtMs: null,
	expandedByUser: false,
	isExpanded: true,
});

export const createStreamTurnState = (turnId: string): StreamTurnState => ({
	turnId,
	status: "running",
	itemsById: {},
	itemOrder: [],
	startedAtMs: Date.now(),
	finishedAtMs: null,
});

export const cloneTurn = (turn: StreamTurnState): StreamTurnState => ({
	...turn,
	itemsById: { ...turn.itemsById },
	itemOrder: Array.from(turn.itemOrder),
});

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
			itemsById: {
				...turn.itemsById,
				[itemId]: created,
			},
			itemOrder: turn.itemOrder.includes(itemId) ? Array.from(turn.itemOrder) : [...turn.itemOrder, itemId],
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

	const existingDefaultType =
		turn.itemsById[event.itemId]?.type ??
		(event.type === "item_delta" && event.target === "output"
			? "tool"
			: "reasoning");

	const resolvedItem = ensureItemForTurn(turn, event.itemId, existingDefaultType);
	turn = resolvedItem.turn;
	const item = resolvedItem.item;

	if (event.type === "item_started") {
		item.type = event.itemType;
		item.state = event.state ?? "running";
		if (event.summary !== undefined) {
			item.summary = event.summary;
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
	const { expanded, byUser } = options;
	const currentItem = turn.itemsById[itemId];
	if (!currentItem) {
		return turn;
	}

	const nextTurn = cloneTurn(turn);
	nextTurn.itemsById[itemId] = {
		...currentItem,
		isExpanded: expanded,
		expandedByUser: byUser ? expanded : currentItem.expandedByUser,
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
		state,
		finishedAtMs:
			state === "completed" || state === "failed" || state === "cancelled"
				? currentItem.finishedAtMs ?? Date.now()
				: currentItem.finishedAtMs,
	};
	return nextTurn;
};
