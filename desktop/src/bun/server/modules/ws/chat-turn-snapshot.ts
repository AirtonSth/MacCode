import type {
	ChatStreamEventDTO,
	ChatTurnDTO,
	ChatTurnItemDTO,
} from "../../types";
import type {
	AssistantStreamEvent,
	AssistantStreamItemState,
	AssistantStreamItemType,
} from "../../../../shared/assistant-stream-event";

const toTimestampMs = (createdAt: string): number => {
	const parsed = Date.parse(createdAt);
	return Number.isFinite(parsed) ? parsed : Date.now();
};

const createTurn = (turnId: string, createdAt: string): ChatTurnDTO => ({
	finishedAtMs: null,
	itemOrder: [],
	itemsById: {},
	startedAtMs: toTimestampMs(createdAt),
	status: "running",
	turnId,
});

const createItem = (
	itemId: string,
	itemType: AssistantStreamItemType,
	createdAt: string,
): ChatTurnItemDTO => ({
	body: "",
	expandedByUser: false,
	finishedAtMs: null,
	id: itemId,
	isExpanded: false,
	output: "",
	startedAtMs: toTimestampMs(createdAt),
	state: "running",
	summary: "",
	type: itemType,
});

const shouldAutoExpandForState = (state: AssistantStreamItemState): boolean => state === "running";

const collapseTurnItems = (turn: ChatTurnDTO): ChatTurnDTO => {
	const itemsById = Object.fromEntries(
		turn.itemOrder
			.map((itemId) => [itemId, turn.itemsById[itemId]] as const)
			.filter((entry): entry is readonly [string, ChatTurnItemDTO] => Boolean(entry[1]))
			.map(([itemId, item]) => [
				itemId,
				{
					...item,
					expandedByUser: false,
					isExpanded: false,
					state: item.state === "failed" || item.state === "cancelled" ? item.state : "collapsed",
				},
			]),
	) as Record<string, ChatTurnItemDTO>;

	return {
		...turn,
		itemsById,
	};
};

const ensureTurn = (
	turnsById: Map<string, ChatTurnDTO>,
	event: ChatStreamEventDTO,
): ChatTurnDTO => {
	const existing = turnsById.get(event.turnId);
	if (existing) {
		return existing;
	}

	const created = createTurn(event.turnId, event.createdAt);
	turnsById.set(event.turnId, created);
	return created;
};

const ensureItem = (
	turn: ChatTurnDTO,
	event: AssistantStreamEvent & { itemId: string },
	createdAt: string,
): ChatTurnItemDTO => {
	const existing = turn.itemsById[event.itemId];
	if (existing) {
		return existing;
	}

	const defaultType = turn.itemsById[event.itemId]?.type
		?? (event.type === "item_started"
			? event.itemType
			: event.type === "item_delta" && event.target === "output"
				? "tool"
				: "reasoning");
	const item = createItem(event.itemId, defaultType, createdAt);
	turn.itemsById[event.itemId] = item;
	if (!turn.itemOrder.includes(event.itemId)) {
		turn.itemOrder.push(event.itemId);
	}
	return item;
};

const applyEventToTurn = (turn: ChatTurnDTO, event: ChatStreamEventDTO): ChatTurnDTO => {
	const eventTime = toTimestampMs(event.createdAt);
	const payload = event.event;

	if (payload.type === "turn_started") {
		turn.startedAtMs = eventTime;
		return turn;
	}

	if (payload.type === "turn_completed") {
		turn.finishedAtMs = eventTime;
		turn.status = turn.status === "failed" ? "failed" : "completed";
		return collapseTurnItems(turn);
	}

	const item = ensureItem(turn, payload, event.createdAt);

	if (payload.type === "item_started") {
		item.type = payload.itemType;
		item.state = payload.state ?? "running";
		if (payload.summary !== undefined) {
			item.summary = payload.summary;
		}
		if (!item.expandedByUser) {
			item.isExpanded = shouldAutoExpandForState(item.state);
		}
		return turn;
	}

	if (payload.type === "item_delta") {
		if (payload.target === "summary") {
			item.summary = `${item.summary}${payload.delta}`;
		}
		if (payload.target === "body") {
			item.body = `${item.body}${payload.delta}`;
		}
		if (payload.target === "output") {
			item.output = `${item.output}${payload.delta}`;
		}
		return turn;
	}

	if (payload.type === "item_state") {
		item.state = payload.state;
		if (payload.summary !== undefined) {
			item.summary = payload.summary;
		}
		if (payload.state === "failed" || payload.state === "cancelled") {
			turn.status = "failed";
		}
		if (!item.expandedByUser) {
			item.isExpanded = shouldAutoExpandForState(item.state);
		}
		return turn;
	}

	item.state =
		payload.state ?? (item.state === "failed" || item.state === "cancelled" ? item.state : "completed");
	item.finishedAtMs = item.finishedAtMs ?? eventTime;
	if (payload.summary !== undefined) {
		item.summary = payload.summary;
	}
	if (item.state === "failed" || item.state === "cancelled") {
		turn.status = "failed";
	}
	if (!item.expandedByUser) {
		item.isExpanded = shouldAutoExpandForState(item.state);
	}

	const shouldCollapse =
		item.type === "assistant_message"
		|| (typeof payload.summary === "string" && payload.summary.toLowerCase().includes("response completed"));
	return shouldCollapse ? collapseTurnItems(turn) : turn;
};

export const buildTurnSnapshotsFromEvents = (events: ChatStreamEventDTO[]): ChatTurnDTO[] => {
	const turnsById = new Map<string, ChatTurnDTO>();

	for (const event of events) {
		const turn = ensureTurn(turnsById, event);
		const nextTurn = applyEventToTurn(turn, event);
		turnsById.set(nextTurn.turnId, nextTurn);
	}

	return Array.from(turnsById.values())
		.map((turn) => (turn.status === "running" ? turn : collapseTurnItems(turn)))
		.sort((left, right) => {
			if (left.startedAtMs !== right.startedAtMs) {
				return left.startedAtMs - right.startedAtMs;
			}
			return left.turnId.localeCompare(right.turnId);
		});
};
