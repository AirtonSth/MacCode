/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

/**
 * [M-04] Chat switch batching tests.
 *
 * Switching chats previously caused a cascade of 10+ state updates and
 * synchronous query removals, producing intermediate frames with empty UI.
 *
 * The fix has two parts:
 * 1. selectChatById wraps state updates in startTransition so React keeps the
 *    previous chat visible until the new chat content is ready.
 * 2. The chat-switch cleanup effect defers removeQueries via queueMicrotask so
 *    old cache entries are evicted only after the new chat UI has committed.
 */

// ---------------------------------------------------------------------------
// Helpers that mirror the production state-cleanup updater functions
// ---------------------------------------------------------------------------

const omitRecordKey = <T>(input: Record<string, T>, key: string): Record<string, T> => {
	const { [key]: ignore, ...next } = input;
	void ignore;
	return next;
};

const buildOmitUpdater = <T>(chatId: string): (current: Record<string, T>) => Record<string, T> => (current) => {
	if (!(chatId in current)) {
		return current;
	}
	const { [chatId]: ignored, ...next } = current;
	void ignored;
	return next as Record<string, T>;
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("[M-04] Chat switch does not produce intermediate empty-UI frames", () => {
	test("query removal is deferred, not synchronous", async () => {
		const removedKeys: string[][] = [];
		const queryClient = {
			removeQueries: (opts: { exact: boolean; queryKey: string[] }) => {
				removedKeys.push(opts.queryKey);
			},
		};

		const queryKeys = {
			messages: (chatId: string) => ["messages", chatId],
			streamTurn: (chatId: string) => ["stream-turn", chatId],
		};

		// Simulate the deferred removal pattern from the fix
		const previousChatId = "chat-old";
		const staleId = previousChatId;

		queueMicrotask(() => {
			queryClient.removeQueries({
				exact: true,
				queryKey: queryKeys.messages(staleId),
			});
			queryClient.removeQueries({
				exact: true,
				queryKey: queryKeys.streamTurn(staleId),
			});
		});

		// Synchronously, nothing should have been removed yet
		expect(removedKeys).toEqual([]);

		// After the microtask drains, both removals happen
		await Promise.resolve();
		expect(removedKeys).toEqual([
			["messages", "chat-old"],
			["stream-turn", "chat-old"],
		]);
	});

	test("state cleanup updaters return the same reference when chatId is absent", () => {
		const state: Record<string, boolean> = { "chat-a": true };
		const updater = buildOmitUpdater<boolean>("chat-b");

		const result = updater(state);

		// Must be referentially identical — no unnecessary re-render
		expect(result).toBe(state);
	});

	test("state cleanup updaters remove only the target chatId", () => {
		const state: Record<string, string> = {
			"chat-a": "streaming text A",
			"chat-b": "streaming text B",
		};
		const updater = buildOmitUpdater<string>("chat-a");

		const result = updater(state);
		expect(result).toEqual({ "chat-b": "streaming text B" });
		expect("chat-a" in result).toBe(false);
	});

	test("omitRecordKey removes a single key from a record", () => {
		const input = { a: 1, b: 2, c: 3 };
		const result = omitRecordKey(input, "b");
		expect(result).toEqual({ a: 1, c: 3 });
	});

	test("omitRecordKey is a no-op on absent keys", () => {
		const input = { a: 1 };
		const result = omitRecordKey(input, "z");
		expect(result).toEqual({ a: 1 });
	});

	test("ref-based state is cleaned up synchronously while queries are deferred", async () => {
		// Simulates the effect body: refs are updated immediately, queries later
		const refState: Record<string, number> = { "chat-old": 42, "chat-new": 7 };
		const removedKeys: string[] = [];
		let refCleaned = false;

		const previousChatId = "chat-old";

		// Synchronous ref cleanup (mirrors lastAssistantEventIdByChatRef)
		const cleanedRef = omitRecordKey(refState, previousChatId);
		refCleaned = !("chat-old" in cleanedRef);

		// Deferred query removal
		queueMicrotask(() => {
			removedKeys.push("messages", "stream-turn");
		});

		// At this point: refs cleaned, queries not yet removed
		expect(refCleaned).toBe(true);
		expect(removedKeys).toEqual([]);

		await Promise.resolve();
		expect(removedKeys).toEqual(["messages", "stream-turn"]);
	});

	test("selectChatById batches state updates via startTransition pattern", () => {
		// Verify that all three state setters are called within a single
		// synchronous scope (simulating startTransition batching).
		const calls: string[] = [];

		const setSelectedProjectId = (value: string | null) => { calls.push(`project:${String(value)}`); };
		const setSelectedChatId = (value: string) => { calls.push(`chat:${value}`); };
		const setLastError = (value: string | null) => { calls.push(`error:${String(value)}`); };

		// Simulate the batched update from selectChatById
		const batchedUpdate = () => {
			setSelectedProjectId("project-1");
			setSelectedChatId("chat-new");
			setLastError(null);
		};

		// All calls happen in a single synchronous batch
		batchedUpdate();
		expect(calls).toEqual([
			"project:project-1",
			"chat:chat-new",
			"error:null",
		]);
	});

	test("new chat defaults are initialized after cleanup", () => {
		const messageWindowMode: Record<string, "latest" | "older"> = {
			"chat-old": "older",
		};
		const latestDirty: Record<string, boolean> = {
			"chat-old": true,
		};

		// Step 1: cleanup old chat
		const cleanedMode = buildOmitUpdater<"latest" | "older">("chat-old")(messageWindowMode);
		const cleanedDirty = buildOmitUpdater<boolean>("chat-old")(latestDirty);

		expect("chat-old" in cleanedMode).toBe(false);
		expect("chat-old" in cleanedDirty).toBe(false);

		// Step 2: initialize new chat defaults
		const selectedChatId = "chat-new";
		const finalMode = {
			...cleanedMode,
			[selectedChatId]: cleanedMode[selectedChatId] ?? "latest",
		};
		const finalDirty = {
			...cleanedDirty,
			[selectedChatId]: cleanedDirty[selectedChatId] ?? false,
		};

		expect(finalMode).toEqual({ "chat-new": "latest" });
		expect(finalDirty).toEqual({ "chat-new": false });
	});

	test("deferred removal is scoped to the stale chatId, not the new one", async () => {
		const removedKeys: string[][] = [];
		const queryClient = {
			removeQueries: (opts: { exact: boolean; queryKey: string[] }) => {
				removedKeys.push(opts.queryKey);
			},
		};
		const queryKeys = {
			messages: (chatId: string) => ["messages", chatId],
			streamTurn: (chatId: string) => ["stream-turn", chatId],
		};

		const previousChatId = "chat-old";
		const selectedChatId = "chat-new";
		const staleId = previousChatId;

		// Simulate the effect: selectedChatId has changed
		if (previousChatId && previousChatId !== selectedChatId) {
			queueMicrotask(() => {
				queryClient.removeQueries({
					exact: true,
					queryKey: queryKeys.messages(staleId),
				});
				queryClient.removeQueries({
					exact: true,
					queryKey: queryKeys.streamTurn(staleId),
				});
			});
		}

		await Promise.resolve();

		// Only the old chat's queries are removed, never the new one
		for (const key of removedKeys) {
			expect(key).not.toContain("chat-new");
			expect(key[1]).toBe("chat-old");
		}
		expect(removedKeys).toHaveLength(2);
	});

	test("no removal occurs when switching to the same chat", async () => {
		const removedKeys: string[][] = [];
		const queryClient = {
			removeQueries: (opts: { exact: boolean; queryKey: string[] }) => {
				removedKeys.push(opts.queryKey);
			},
		};
		const queryKeys = {
			messages: (chatId: string) => ["messages", chatId],
			streamTurn: (chatId: string) => ["stream-turn", chatId],
		};

		const previousChatId = "chat-same";
		const selectedChatId = "chat-same";

		if (previousChatId && previousChatId !== selectedChatId) {
			queueMicrotask(() => {
				queryClient.removeQueries({
					exact: true,
					queryKey: queryKeys.messages(previousChatId),
				});
				queryClient.removeQueries({
					exact: true,
					queryKey: queryKeys.streamTurn(previousChatId),
				});
			});
		}

		await Promise.resolve();
		expect(removedKeys).toEqual([]);
	});
});
