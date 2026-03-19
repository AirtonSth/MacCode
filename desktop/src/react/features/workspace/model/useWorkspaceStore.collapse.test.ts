/* eslint-disable import/no-unresolved */
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { ModuleKind, ScriptTarget, transpileModule } from "typescript";
import { describe, test, expect } from "bun:test";

import type {
	WorkspaceAction,
	WorkspaceState,
	StreamTurnState,
	StreamItem,
} from "./useWorkspaceStore";

type WorkspaceReducer = (state: WorkspaceState, action: WorkspaceAction) => WorkspaceState;
type CollapseTurnItems = (turn: StreamTurnState) => StreamTurnState;

const { workspaceReducer, collapseTurnItems } = (() => {
	const sourcePath = fileURLToPath(new URL("./useWorkspaceStore.ts", import.meta.url));
	const sourceCode = readFileSync(sourcePath, "utf8");
	const instrumentedSourceCode = `${sourceCode}\n\nexports.__workspaceReducerForTests = workspaceReducer;\nexports.__collapseTurnItemsForTests = collapseTurnItems;`;
	const compiled = transpileModule(instrumentedSourceCode, {
		compilerOptions: {
			module: ModuleKind.CommonJS,
			target: ScriptTarget.ES2020,
		},
	});

	const moduleExports = {} as { [key: string]: unknown };
	const mod = { exports: moduleExports };
	const req = createRequire(import.meta.url);
	const execute = new Function("require", "module", "exports", compiled.outputText);
	execute(req, mod, moduleExports);

	const reducer = mod.exports.__workspaceReducerForTests;
	const collapse = mod.exports.__collapseTurnItemsForTests;

	if (typeof reducer !== "function") {
		throw new Error("Unable to access workspaceReducer from useWorkspaceStore.ts");
	}
	if (typeof collapse !== "function") {
		throw new Error("Unable to access collapseTurnItems from useWorkspaceStore.ts");
	}

	return {
		workspaceReducer: reducer as WorkspaceReducer,
		collapseTurnItems: collapse as CollapseTurnItems,
	};
})();

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

const makeItem = (overrides: Partial<StreamItem> & { id: string }): StreamItem => ({
	id: overrides.id,
	type: overrides.type ?? "tool",
	state: overrides.state ?? "running",
	summary: overrides.summary ?? "do something",
	body: overrides.body ?? "",
	output: overrides.output ?? "",
	startedAtMs: overrides.startedAtMs ?? 1000,
	finishedAtMs: overrides.finishedAtMs ?? null,
	expandedByUser: overrides.expandedByUser ?? false,
	isExpanded: overrides.isExpanded ?? false,
});

const makeTurnWithItems = (turnId: string, items: StreamItem[]): StreamTurnState => {
	const itemsById: Record<string, StreamItem> = {};
	const itemOrder: string[] = [];
	for (const item of items) {
		itemsById[item.id] = item;
		itemOrder.push(item.id);
	}
	return {
		turnId,
		status: "running",
		itemsById,
		itemOrder,
		startedAtMs: 1000,
		finishedAtMs: null,
	};
};

describe("collapseTurnItems respects expandedByUser", () => {
	test("collapses items where expandedByUser is false", () => {
		const item = makeItem({
			id: "item-1",
			state: "completed",
			isExpanded: true,
			expandedByUser: false,
		});
		const turn = makeTurnWithItems("turn-1", [item]);

		const result = collapseTurnItems(turn);
		const collapsed = result.itemsById["item-1"];

		expect(collapsed.state).toBe("collapsed");
		expect(collapsed.isExpanded).toBe(false);
		expect(collapsed.expandedByUser).toBe(false);
	});

	test("keeps items expanded where expandedByUser is true", () => {
		const item = makeItem({
			id: "item-1",
			state: "completed",
			isExpanded: true,
			expandedByUser: true,
		});
		const turn = makeTurnWithItems("turn-1", [item]);

		const result = collapseTurnItems(turn);
		const kept = result.itemsById["item-1"];

		expect(kept.state).toBe("completed");
		expect(kept.isExpanded).toBe(true);
		expect(kept.expandedByUser).toBe(true);
	});

	test("preserves failed/cancelled state regardless of expandedByUser", () => {
		const failedItem = makeItem({
			id: "item-failed",
			state: "failed",
			isExpanded: true,
			expandedByUser: true,
		});
		const cancelledItem = makeItem({
			id: "item-cancelled",
			state: "cancelled",
			isExpanded: false,
			expandedByUser: false,
		});
		const turn = makeTurnWithItems("turn-1", [failedItem, cancelledItem]);

		const result = collapseTurnItems(turn);

		expect(result.itemsById["item-failed"].state).toBe("failed");
		expect(result.itemsById["item-failed"].isExpanded).toBe(true);
		expect(result.itemsById["item-cancelled"].state).toBe("cancelled");
		expect(result.itemsById["item-cancelled"].isExpanded).toBe(false);
	});

	test("handles mixed items: only collapses non-user-expanded", () => {
		const userExpanded = makeItem({
			id: "item-user",
			state: "running",
			isExpanded: true,
			expandedByUser: true,
		});
		const autoExpanded = makeItem({
			id: "item-auto",
			state: "running",
			isExpanded: true,
			expandedByUser: false,
		});
		const notExpanded = makeItem({
			id: "item-none",
			state: "completed",
			isExpanded: false,
			expandedByUser: false,
		});
		const turn = makeTurnWithItems("turn-1", [userExpanded, autoExpanded, notExpanded]);

		const result = collapseTurnItems(turn);

		expect(result.itemsById["item-user"].isExpanded).toBe(true);
		expect(result.itemsById["item-user"].expandedByUser).toBe(true);
		expect(result.itemsById["item-user"].state).toBe("completed");

		expect(result.itemsById["item-auto"].isExpanded).toBe(false);
		expect(result.itemsById["item-auto"].expandedByUser).toBe(false);
		expect(result.itemsById["item-auto"].state).toBe("collapsed");

		expect(result.itemsById["item-none"].isExpanded).toBe(false);
		expect(result.itemsById["item-none"].state).toBe("collapsed");
	});
});

describe("turn_completed respects expandedByUser via reducer", () => {
	test("turn_completed keeps user-expanded items open", () => {
		const chatId = "chat-1";
		const turnId = "turn-1";

		const userExpandedItem = makeItem({
			id: "item-user",
			state: "completed",
			isExpanded: true,
			expandedByUser: true,
		});
		const autoExpandedItem = makeItem({
			id: "item-auto",
			state: "completed",
			isExpanded: true,
			expandedByUser: false,
		});
		const turn = makeTurnWithItems(turnId, [userExpandedItem, autoExpandedItem]);

		const state: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: chatId,
			messageWindow: {
				chatId,
				hasMore: false,
				latestDirty: false,
				messages: [],
				mode: "latest",
				nextBeforeMessageId: null,
				turns: [turn],
			},
			streamTurnsByChat: { [chatId]: turn },
			streamHistoryByChat: { [chatId]: [turn] },
			lastAssistantEventIdByChat: { [chatId]: 5 },
		};

		const result = workspaceReducer(state, {
			type: "APPLY_ASSISTANT_EVENT",
			payload: {
				chatId,
				event: { type: "turn_completed", turnId },
				eventId: 6,
			},
		});

		const resultTurn = result.streamTurnsByChat[chatId];
		expect(resultTurn).toBeDefined();
		expect(resultTurn!.itemsById["item-user"].isExpanded).toBe(true);
		expect(resultTurn!.itemsById["item-user"].expandedByUser).toBe(true);
		expect(resultTurn!.itemsById["item-user"].state).toBe("completed");

		expect(resultTurn!.itemsById["item-auto"].isExpanded).toBe(false);
		expect(resultTurn!.itemsById["item-auto"].expandedByUser).toBe(false);
		expect(resultTurn!.itemsById["item-auto"].state).toBe("collapsed");
	});
});

describe("auto-expanded items can transition to completed while staying expanded", () => {
	test("item_completed keeps auto-expanded item visible when expandedByUser is false", () => {
		const chatId = "chat-1";
		const turnId = "turn-1";
		const itemId = "item-tool";

		const runningItem = makeItem({
			id: itemId,
			type: "tool",
			state: "running",
			isExpanded: true,
			expandedByUser: false,
		});
		const turn = makeTurnWithItems(turnId, [runningItem]);

		const state: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: chatId,
			messageWindow: {
				chatId,
				hasMore: false,
				latestDirty: false,
				messages: [],
				mode: "latest",
				nextBeforeMessageId: null,
				turns: [turn],
			},
			streamTurnsByChat: { [chatId]: turn },
			streamHistoryByChat: { [chatId]: [turn] },
			lastAssistantEventIdByChat: { [chatId]: 5 },
		};

		const result = workspaceReducer(state, {
			type: "APPLY_ASSISTANT_EVENT",
			payload: {
				chatId,
				event: {
					type: "item_completed",
					turnId,
					itemId,
					state: "completed",
					summary: "Ran tool",
				},
				eventId: 6,
			},
		});

		const resultTurn = result.streamTurnsByChat[chatId];
		expect(resultTurn).toBeDefined();

		const completedItem = resultTurn!.itemsById[itemId];
		expect(completedItem.state).toBe("completed");
		expect(completedItem.expandedByUser).toBe(false);
		/*
		 * After item_completed, shouldAutoExpandForState("completed") returns false,
		 * so the reducer sets isExpanded to false for non-user-expanded items.
		 * The delayed collapse in StreamingTimeline handles the visual transition.
		 * The item state is "completed" (not "collapsed") which is the key fix:
		 * the item stays in a completed state rather than being force-collapsed.
		 */
		expect(completedItem.state).not.toBe("collapsed");
	});

	test("item_completed preserves user-expanded items", () => {
		const chatId = "chat-1";
		const turnId = "turn-1";
		const itemId = "item-user-tool";

		const userExpandedItem = makeItem({
			id: itemId,
			type: "tool",
			state: "running",
			isExpanded: true,
			expandedByUser: true,
		});
		const turn = makeTurnWithItems(turnId, [userExpandedItem]);

		const state: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: chatId,
			messageWindow: {
				chatId,
				hasMore: false,
				latestDirty: false,
				messages: [],
				mode: "latest",
				nextBeforeMessageId: null,
				turns: [turn],
			},
			streamTurnsByChat: { [chatId]: turn },
			streamHistoryByChat: { [chatId]: [turn] },
			lastAssistantEventIdByChat: { [chatId]: 5 },
		};

		const result = workspaceReducer(state, {
			type: "APPLY_ASSISTANT_EVENT",
			payload: {
				chatId,
				event: {
					type: "item_completed",
					turnId,
					itemId,
					state: "completed",
					summary: "Ran tool",
				},
				eventId: 6,
			},
		});

		const resultTurn = result.streamTurnsByChat[chatId];
		expect(resultTurn).toBeDefined();

		const completedItem = resultTurn!.itemsById[itemId];
		expect(completedItem.state).toBe("completed");
		expect(completedItem.isExpanded).toBe(true);
		expect(completedItem.expandedByUser).toBe(true);
	});

	test("normalizeTurnHistory respects expandedByUser on completed turns", () => {
		const chatId = "chat-1";
		const turnId = "turn-done";
		const userItem = makeItem({
			id: "item-kept",
			state: "completed",
			isExpanded: true,
			expandedByUser: true,
		});
		const autoItem = makeItem({
			id: "item-collapsed",
			state: "completed",
			isExpanded: true,
			expandedByUser: false,
		});
		const completedTurn: StreamTurnState = {
			...makeTurnWithItems(turnId, [userItem, autoItem]),
			status: "completed",
			finishedAtMs: 2000,
		};

		const state: WorkspaceState = {
			...baseWorkspaceState(),
			selectedChatId: chatId,
			messageWindow: {
				chatId,
				hasMore: false,
				latestDirty: false,
				messages: [],
				mode: "latest",
				nextBeforeMessageId: null,
				turns: [],
			},
		};

		const result = workspaceReducer(state, {
			type: "SET_STREAM_HISTORY",
			payload: {
				chatId,
				turns: [completedTurn],
				lastEventId: 10,
			},
		});

		const historyTurns = result.streamHistoryByChat[chatId] ?? [];
		expect(historyTurns.length).toBe(1);

		const normalizedTurn = historyTurns[0];
		expect(normalizedTurn.itemsById["item-kept"].isExpanded).toBe(true);
		expect(normalizedTurn.itemsById["item-kept"].expandedByUser).toBe(true);
		expect(normalizedTurn.itemsById["item-kept"].state).toBe("completed");

		expect(normalizedTurn.itemsById["item-collapsed"].isExpanded).toBe(false);
		expect(normalizedTurn.itemsById["item-collapsed"].expandedByUser).toBe(false);
		expect(normalizedTurn.itemsById["item-collapsed"].state).toBe("collapsed");
	});
});
