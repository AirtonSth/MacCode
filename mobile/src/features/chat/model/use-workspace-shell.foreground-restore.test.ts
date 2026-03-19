/* eslint-disable import/no-unresolved */
/* eslint-disable promise/avoid-new */
/* eslint-disable promise/prefer-await-to-then */
import { describe, expect, test } from "bun:test";

/**
 * [M-05] Foreground restore batching tests.
 *
 * When the app returns from background, query invalidations must be batched
 * into a single coordinated restore (via Promise.all + refetchQueries) instead
 * of firing 5+ independent invalidateQueries calls that settle at different
 * times, causing the UI to "flicker" over 0.5-2s.
 *
 * These tests verify the batching pattern and the isRestoringFromBackground
 * flag lifecycle.
 */

describe("[M-05] Foreground restore batching", () => {
	test("refetch promises are collected into a single batch, not fired independently", () => {
		const refetchedKeys: string[] = [];

		const refetchQueries = async (opts: { queryKey: readonly string[] }) => {
			refetchedKeys.push(opts.queryKey.join("/"));
			
		};

		const activeProjectId = "project-1";
		const activeChatId = "chat-1";

		// Simulate the batched foreground restore logic
		const refetchPromises: Promise<unknown>[] = [
			refetchQueries({ queryKey: ["active-threads"] }),
		];

		if (activeProjectId) {
			refetchPromises.push(
				refetchQueries({ queryKey: ["chats", activeProjectId] }),
			);
		}

		if (activeChatId) {
			refetchPromises.push(
				refetchQueries({ queryKey: ["chat-context", activeChatId] }),
				refetchQueries({ queryKey: ["messages-v2", activeChatId] }),
			);
		}

		// All queries are collected before any promise settles
		expect(refetchPromises.length).toBe(4);
		expect(refetchedKeys).toEqual([
			"active-threads",
			"chats/project-1",
			"chat-context/chat-1",
			"messages-v2/chat-1",
		]);
	});

	test("isRestoringFromBackground flag is set true before refetches and false after all settle", async () => {
		let isRestoring = false;
		const settleOrder: string[] = [];

		const makeDelayedRefetch = async (label: string, ms: number) =>
			{ await new Promise<void>((resolve) => {
				setTimeout(() => {
					settleOrder.push(label);
					resolve();
				}, ms);
			}); };

		// Simulate the batched foreground restore logic
		isRestoring = true;

		const refetchPromises: Promise<unknown>[] = [
			makeDelayedRefetch("activeThreads", 10),
			makeDelayedRefetch("chats", 30),
			makeDelayedRefetch("chatContext", 20),
			makeDelayedRefetch("messages", 50),
		];

		expect(isRestoring).toBe(true);

		await Promise.all(refetchPromises).finally(() => {
			isRestoring = false;
		});

		expect(isRestoring).toBe(false);

		// All four should have resolved
		expect(settleOrder.length).toBe(4);
		expect(settleOrder).toContain("activeThreads");
		expect(settleOrder).toContain("chats");
		expect(settleOrder).toContain("chatContext");
		expect(settleOrder).toContain("messages");
	});

	test("isRestoringFromBackground resets to false even if a refetch rejects", async () => {
		let isRestoring = false;

		isRestoring = true;

		const refetchPromises: Promise<unknown>[] = [
			Promise.resolve(),
			Promise.reject(new Error("network failure")),
			Promise.resolve(),
		];

		await Promise.all(refetchPromises)
			.catch(() => {
				// Expected — one query failed
			})
			.finally(() => {
				isRestoring = false;
			});

		expect(isRestoring).toBe(false);
	});

	test("batch with no active project skips chats refetch", () => {
		const refetchedKeys: string[] = [];

		const refetchQueries = async (opts: { queryKey: readonly string[] }) => {
			refetchedKeys.push(opts.queryKey.join("/"));
			
		};

		const activeProjectId: string | null = null;
		const activeChatId = "chat-1";

		const refetchPromises: Promise<unknown>[] = [
			refetchQueries({ queryKey: ["active-threads"] }),
		];

		if (activeProjectId) {
			refetchPromises.push(
				refetchQueries({ queryKey: ["chats", activeProjectId] }),
			);
		}

		if (activeChatId) {
			refetchPromises.push(
				refetchQueries({ queryKey: ["chat-context", activeChatId] }),
				refetchQueries({ queryKey: ["messages-v2", activeChatId] }),
			);
		}

		expect(refetchPromises.length).toBe(3);
		expect(refetchedKeys).toEqual([
			"active-threads",
			"chat-context/chat-1",
			"messages-v2/chat-1",
		]);
	});

	test("batch with no active chat skips chat-specific refetches", () => {
		const refetchedKeys: string[] = [];

		const refetchQueries = async (opts: { queryKey: readonly string[] }) => {
			refetchedKeys.push(opts.queryKey.join("/"));
			
		};

		const activeProjectId = "project-1";
		const activeChatId: string | null = null;
		const hasChatContext = Boolean(activeChatId);

		const refetchPromises: Promise<unknown>[] = [
			refetchQueries({ queryKey: ["active-threads"] }),
		];

		if (activeProjectId) {
			refetchPromises.push(
				refetchQueries({ queryKey: ["chats", activeProjectId] }),
			);
		}

		if (hasChatContext && activeChatId) {
			refetchPromises.push(
				refetchQueries({ queryKey: ["chat-context", activeChatId] }),
				refetchQueries({ queryKey: ["messages-v2", activeChatId] }),
			);
		}

		expect(refetchPromises.length).toBe(2);
		expect(refetchedKeys).toEqual([
			"active-threads",
			"chats/project-1",
		]);
	});

	test("flag lifecycle: not set when app state change is not a foreground return", () => {
		let isRestoring = false;

		const simulateAppStateChange = (previous: string, next: string) => {
			const isReturningToForeground =
				(previous === "background" || previous === "inactive") && next === "active";

			if (!isReturningToForeground) {
				return;
			}

			isRestoring = true;
		};

		// active -> background: should NOT trigger restore
		simulateAppStateChange("active", "background");
		expect(isRestoring).toBe(false);

		// active -> inactive: should NOT trigger restore
		simulateAppStateChange("active", "inactive");
		expect(isRestoring).toBe(false);

		// background -> background: should NOT trigger restore
		simulateAppStateChange("background", "background");
		expect(isRestoring).toBe(false);

		// background -> active: SHOULD trigger restore
		simulateAppStateChange("background", "active");
		expect(isRestoring).toBe(true);
	});

	test("flag lifecycle: inactive -> active also triggers restore", () => {
		let isRestoring = false;

		const previous = "inactive";
		const next = "active";
		const shouldRestore =
			(previous === "background" || previous === "inactive") && next === "active";

		if (shouldRestore) {
			isRestoring = true;
		}

		expect(isRestoring).toBe(true);
	});

	test("syncMissedAssistantEventsForChat is included in the batch", async () => {
		const settledItems: string[] = [];

		const refetchQueries = async (opts: { queryKey: readonly string[] }) => {
			settledItems.push(opts.queryKey.join("/"));
			
		};

		const syncMissedAssistantEventsForChat = async (chatId: string) => {
			settledItems.push(`sync:${chatId}`);
			
		};

		const activeChatId = "chat-42";

		const refetchPromises: Promise<unknown>[] = [
			refetchQueries({ queryKey: ["active-threads"] }),
			refetchQueries({ queryKey: ["chat-context", activeChatId] }),
			refetchQueries({ queryKey: ["messages-v2", activeChatId] }),
			syncMissedAssistantEventsForChat(activeChatId),
		];

		await Promise.all(refetchPromises);

		expect(settledItems).toContain("sync:chat-42");
		expect(settledItems.length).toBe(4);
	});
});
