/* eslint-disable import/no-unresolved */
/* eslint-disable promise/avoid-new */
import { afterEach, beforeEach, describe, expect, it } from "bun:test";

import { TOOL_AUTO_EXPAND_MS } from "./streaming-timeline-constants";

/**
 * Pure-logic tests for the streaming timeline auto-expand and toggle
 * behaviour.
 *
 * The auto-expand timer and expand/collapse toggling live inside React
 * hooks, so we replicate the decision logic here to verify correctness
 * of the constant, the toggle, and timer cleanup.
 */

// ---------------------------------------------------------------------------
// Helpers that mirror the logic inside StreamingTimelineComponent
// ---------------------------------------------------------------------------

interface MinimalStreamItem {
	id: string;
	type: "tool" | "assistant_message" | "plan" | "reasoning";
	state: "running" | "completed" | "failed" | "cancelled" | "preview" | "collapsed";
	isExpanded: boolean;
	expandedByUser: boolean;
}

/** Mirrors the auto-expand eligibility check inside the useEffect. */
const shouldScheduleAutoExpand = (item: MinimalStreamItem): boolean =>
	item.type === "tool" &&
	item.state === "running" &&
	!item.isExpanded &&
	!item.expandedByUser;

/** Mirrors the manual toggle handler inside renderTimelineItem. */
const computeToggleResult = (
	item: MinimalStreamItem,
): { nextExpanded: boolean; shouldPromoteState: boolean } => {
	const nextExpanded = !item.isExpanded;
	const shouldPromoteState = nextExpanded && item.state === "collapsed";
	return { nextExpanded, shouldPromoteState };
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("TOOL_AUTO_EXPAND_MS constant", () => {
	it("equals 2000 milliseconds", () => {
		expect(TOOL_AUTO_EXPAND_MS).toBe(2000);
	});

	it("is a positive integer", () => {
		expect(TOOL_AUTO_EXPAND_MS).toBeGreaterThan(0);
		expect(Number.isInteger(TOOL_AUTO_EXPAND_MS)).toBe(true);
	});
});

describe("shouldScheduleAutoExpand (auto-expand eligibility)", () => {
	it("returns true for a running, collapsed tool item", () => {
		expect(shouldScheduleAutoExpand({
			id: "t1",
			type: "tool",
			state: "running",
			isExpanded: false,
			expandedByUser: false,
		})).toBe(true);
	});

	it("returns false when item is already expanded", () => {
		expect(shouldScheduleAutoExpand({
			id: "t2",
			type: "tool",
			state: "running",
			isExpanded: true,
			expandedByUser: false,
		})).toBe(false);
	});

	it("returns false when the user manually toggled expansion", () => {
		expect(shouldScheduleAutoExpand({
			id: "t3",
			type: "tool",
			state: "running",
			isExpanded: false,
			expandedByUser: true,
		})).toBe(false);
	});

	it("returns false for a completed tool item", () => {
		expect(shouldScheduleAutoExpand({
			id: "t4",
			type: "tool",
			state: "completed",
			isExpanded: false,
			expandedByUser: false,
		})).toBe(false);
	});

	it("returns false for non-tool item types", () => {
		const types: MinimalStreamItem["type"][] = ["assistant_message", "plan", "reasoning"];
		for (const type of types) {
			expect(shouldScheduleAutoExpand({
				id: `non-tool-${type}`,
				type,
				state: "running",
				isExpanded: false,
				expandedByUser: false,
			})).toBe(false);
		}
	});

	it("returns false for a failed tool item", () => {
		expect(shouldScheduleAutoExpand({
			id: "t5",
			type: "tool",
			state: "failed",
			isExpanded: false,
			expandedByUser: false,
		})).toBe(false);
	});
});

describe("computeToggleResult (expand/collapse toggling)", () => {
	it("expands a collapsed item", () => {
		const result = computeToggleResult({
			id: "t1",
			type: "tool",
			state: "completed",
			isExpanded: false,
			expandedByUser: false,
		});
		expect(result.nextExpanded).toBe(true);
		expect(result.shouldPromoteState).toBe(false);
	});

	it("collapses an expanded item", () => {
		const result = computeToggleResult({
			id: "t2",
			type: "tool",
			state: "completed",
			isExpanded: true,
			expandedByUser: true,
		});
		expect(result.nextExpanded).toBe(false);
		expect(result.shouldPromoteState).toBe(false);
	});

	it("promotes state from collapsed to completed when expanding a collapsed-state item", () => {
		const result = computeToggleResult({
			id: "t3",
			type: "tool",
			state: "collapsed",
			isExpanded: false,
			expandedByUser: false,
		});
		expect(result.nextExpanded).toBe(true);
		expect(result.shouldPromoteState).toBe(true);
	});

	it("does not promote state when collapsing a collapsed-state item", () => {
		const result = computeToggleResult({
			id: "t4",
			type: "tool",
			state: "collapsed",
			isExpanded: true,
			expandedByUser: true,
		});
		expect(result.nextExpanded).toBe(false);
		expect(result.shouldPromoteState).toBe(false);
	});
});

describe("auto-expand timer lifecycle", () => {
	/**
	 * Simulates the timer map that the component keeps in
	 * autoExpandTimersRef.current.
	 */
	let timers = new Map<string, ReturnType<typeof setTimeout>>();
	let expandedIds = new Set<string>();

	beforeEach(() => {
		timers = new Map();
		expandedIds = new Set();
	});

	afterEach(() => {
		for (const timeoutId of timers.values()) {
			clearTimeout(timeoutId);
		}
		timers.clear();
	});

	const scheduleOneTimer = (itemId: string) => {
		const timeoutId = setTimeout(() => {
			timers.delete(itemId);
			expandedIds.add(itemId);
		}, TOOL_AUTO_EXPAND_MS);
		timers.set(itemId, timeoutId);
	};

	/** Mirrors the scheduling loop inside the auto-expand useEffect. */
	const scheduleAutoExpand = (items: MinimalStreamItem[]) => {
		const pendingIds = new Set<string>();

		for (const item of items) {
			if (!shouldScheduleAutoExpand(item)) {
				continue;
			}

			pendingIds.add(item.id);
			if (!timers.has(item.id)) {
				scheduleOneTimer(item.id);
			}
		}

		// Cleanup stale timers
		for (const [itemId, timeoutId] of timers.entries()) {
			if (pendingIds.has(itemId)) {
				continue;
			}
			clearTimeout(timeoutId);
			timers.delete(itemId);
		}
	};

	/** Mirrors the cleanup effect on unmount. */
	const cleanupAll = () => {
		for (const timeoutId of timers.values()) {
			clearTimeout(timeoutId);
		}
		timers.clear();
	};

	it("schedules a timer for an eligible tool item", () => {
		const items: MinimalStreamItem[] = [{
			id: "tool-1",
			type: "tool",
			state: "running",
			isExpanded: false,
			expandedByUser: false,
		}];

		scheduleAutoExpand(items);
		expect(timers.size).toBe(1);
		expect(timers.has("tool-1")).toBe(true);
	});

	it("does not duplicate timers when called multiple times", () => {
		const items: MinimalStreamItem[] = [{
			id: "tool-1",
			type: "tool",
			state: "running",
			isExpanded: false,
			expandedByUser: false,
		}];

		scheduleAutoExpand(items);
		const firstTimerId = timers.get("tool-1");
		scheduleAutoExpand(items);

		expect(timers.size).toBe(1);
		expect(timers.get("tool-1")).toBe(firstTimerId);
	});

	it("cleans up stale timers for items that are no longer eligible", () => {
		const runningItem: MinimalStreamItem = {
			id: "tool-1",
			type: "tool",
			state: "running",
			isExpanded: false,
			expandedByUser: false,
		};

		scheduleAutoExpand([runningItem]);
		expect(timers.size).toBe(1);

		// Item completes, no longer eligible
		const completedItem: MinimalStreamItem = {
			...runningItem,
			state: "completed",
		};
		scheduleAutoExpand([completedItem]);
		expect(timers.size).toBe(0);
	});

	it("fires the expand callback after TOOL_AUTO_EXPAND_MS", async () => {
		const items: MinimalStreamItem[] = [{
			id: "tool-async",
			type: "tool",
			state: "running",
			isExpanded: false,
			expandedByUser: false,
		}];

		scheduleAutoExpand(items);
		expect(expandedIds.has("tool-async")).toBe(false);

		// Wait for the timer to fire
		await new Promise((resolve) => {
			setTimeout(resolve, TOOL_AUTO_EXPAND_MS + 100);
		});

		expect(expandedIds.has("tool-async")).toBe(true);
		expect(timers.has("tool-async")).toBe(false);
	});

	it("cleanupAll clears all pending timers", () => {
		const items: MinimalStreamItem[] = [
			{
				id: "tool-a",
				type: "tool",
				state: "running",
				isExpanded: false,
				expandedByUser: false,
			},
			{
				id: "tool-b",
				type: "tool",
				state: "running",
				isExpanded: false,
				expandedByUser: false,
			},
		];

		scheduleAutoExpand(items);
		expect(timers.size).toBe(2);

		cleanupAll();
		expect(timers.size).toBe(0);
	});

	it("does not fire expand after cleanup", async () => {
		const items: MinimalStreamItem[] = [{
			id: "tool-cancelled",
			type: "tool",
			state: "running",
			isExpanded: false,
			expandedByUser: false,
		}];

		scheduleAutoExpand(items);
		cleanupAll();

		await new Promise((resolve) => {
			setTimeout(resolve, TOOL_AUTO_EXPAND_MS + 100);
		});

		expect(expandedIds.has("tool-cancelled")).toBe(false);
	});

	it("handles multiple items independently", () => {
		const items: MinimalStreamItem[] = [
			{
				id: "tool-x",
				type: "tool",
				state: "running",
				isExpanded: false,
				expandedByUser: false,
			},
			{
				id: "msg-y",
				type: "assistant_message",
				state: "running",
				isExpanded: false,
				expandedByUser: false,
			},
			{
				id: "tool-z",
				type: "tool",
				state: "running",
				isExpanded: false,
				expandedByUser: false,
			},
		];

		scheduleAutoExpand(items);

		// Only tool items should get timers
		expect(timers.size).toBe(2);
		expect(timers.has("tool-x")).toBe(true);
		expect(timers.has("msg-y")).toBe(false);
		expect(timers.has("tool-z")).toBe(true);
	});
});

describe("end-to-end scenario: tool auto-expand then manual collapse", () => {
	it("auto-expands after delay, then user can manually collapse", () => {
		const item: MinimalStreamItem = {
			id: "tool-e2e",
			type: "tool",
			state: "running",
			isExpanded: false,
			expandedByUser: false,
		};

		// Step 1: Item is eligible for auto-expand
		expect(shouldScheduleAutoExpand(item)).toBe(true);

		// Step 2: After timer fires, item is expanded (simulate)
		const expandedItem: MinimalStreamItem = {
			...item,
			isExpanded: true,
		};
		expect(shouldScheduleAutoExpand(expandedItem)).toBe(false);

		// Step 3: User manually collapses
		const toggleResult = computeToggleResult(expandedItem);
		expect(toggleResult.nextExpanded).toBe(false);

		// Step 4: After manual collapse, user flag is set
		const collapsedByUser: MinimalStreamItem = {
			...expandedItem,
			isExpanded: false,
			expandedByUser: true,
		};

		// Auto-expand should not re-trigger because expandedByUser is true
		expect(shouldScheduleAutoExpand(collapsedByUser)).toBe(false);
	});
});

describe("[M-25] render cache invalidation", () => {
	/**
	 * Mirrors the CachedRenderedItem comparison logic after the fix.
	 * The cache now only compares item identity, not callback identity.
	 */
	interface CachedEntry {
		item: MinimalStreamItem;
		element: string; // simplified stand-in for JSX.Element
	}

	const shouldReuseCachedEntry = (
		cached: CachedEntry | undefined,
		nextItem: MinimalStreamItem,
	): boolean => {
		if (!cached) {
			return false;
		}

		// [M-25] Only compare item data, not callback references.
		return cached.item === nextItem;
	};

	it("reuses cache when item reference is unchanged", () => {
		const item: MinimalStreamItem = {
			id: "tool-1",
			type: "tool",
			state: "running",
			isExpanded: false,
			expandedByUser: false,
		};

		const cached: CachedEntry = { item, element: "<rendered />" };
		expect(shouldReuseCachedEntry(cached, item)).toBe(true);
	});

	it("invalidates cache when item reference changes (new data)", () => {
		const item: MinimalStreamItem = {
			id: "tool-1",
			type: "tool",
			state: "running",
			isExpanded: false,
			expandedByUser: false,
		};

		const cached: CachedEntry = { item, element: "<rendered />" };
		const updatedItem: MinimalStreamItem = { ...item, state: "completed" };

		expect(shouldReuseCachedEntry(cached, updatedItem)).toBe(false);
	});

	it("does NOT invalidate cache when only callback identity changes", () => {
		const item: MinimalStreamItem = {
			id: "tool-1",
			type: "tool",
			state: "running",
			isExpanded: false,
			expandedByUser: false,
		};

		// Simulate a cache entry with one callback identity
		const cached: CachedEntry = { item, element: "<rendered />" };

		// Even though the "callback" would be a new reference in the real
		// component, the cache comparison only checks the item.
		expect(shouldReuseCachedEntry(cached, item)).toBe(true);
	});

	it("returns false for undefined cache entry", () => {
		const item: MinimalStreamItem = {
			id: "tool-new",
			type: "tool",
			state: "running",
			isExpanded: false,
			expandedByUser: false,
		};

		expect(shouldReuseCachedEntry(undefined, item)).toBe(false);
	});
});
