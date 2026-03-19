/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

/**
 * M-11 — Thread list loading behavior.
 *
 * The screen derives two booleans from the workspace-shell hook:
 *
 *   shouldShowThreadsLoading = !isLoaded || isChatsLoading
 *   isBackgroundRefetching   = !shouldShowThreadsLoading && isChatsFetching
 *
 * `isChatsLoading` (from use-workspace-shell) is true ONLY when there is no
 * cached data (first load). `isChatsFetching` is true when the query is
 * refetching AND cached data already exists.
 *
 * These tests codify the invariant that a background refetch must never replace
 * the visible thread list with a full-page spinner.
 */

interface LoadingInputs {
	isLoaded: boolean;
	isChatsLoading: boolean;
	isChatsFetching: boolean;
}

function deriveLoadingState(inputs: LoadingInputs) {
	const shouldShowThreadsLoading = !inputs.isLoaded || inputs.isChatsLoading;
	const isBackgroundRefetching = !shouldShowThreadsLoading && inputs.isChatsFetching;
	return { shouldShowThreadsLoading, isBackgroundRefetching };
}

describe("thread list loading behavior (M-11)", () => {
	test("shows full spinner when isChatsLoading is true and there is no cached data (first load)", () => {
		const result = deriveLoadingState({
			isLoaded: true,
			isChatsLoading: true,
			isChatsFetching: false,
		});

		expect(result.shouldShowThreadsLoading).toBe(true);
		expect(result.isBackgroundRefetching).toBe(false);
	});

	test("shows full spinner when workspace shell is not yet loaded", () => {
		const result = deriveLoadingState({
			isLoaded: false,
			isChatsLoading: false,
			isChatsFetching: false,
		});

		expect(result.shouldShowThreadsLoading).toBe(true);
		expect(result.isBackgroundRefetching).toBe(false);
	});

	test("shows the list (not spinner) when isChatsFetching is true and cached data exists (background refetch)", () => {
		// isChatsFetching=true means query is fetching AND cached data exists.
		// isChatsLoading=false means there IS cached data (the hook only sets
		// isChatsLoading when there is no cached data).
		const result = deriveLoadingState({
			isLoaded: true,
			isChatsLoading: false,
			isChatsFetching: true,
		});

		expect(result.shouldShowThreadsLoading).toBe(false);
		expect(result.isBackgroundRefetching).toBe(true);
	});

	test("the thread list remains visible during background refetches", () => {
		// Simulate steady state then a background refetch — the list should
		// never flip to the spinner.
		const steadyState = deriveLoadingState({
			isLoaded: true,
			isChatsLoading: false,
			isChatsFetching: false,
		});
		expect(steadyState.shouldShowThreadsLoading).toBe(false);

		const duringRefetch = deriveLoadingState({
			isLoaded: true,
			isChatsLoading: false,
			isChatsFetching: true,
		});
		expect(duringRefetch.shouldShowThreadsLoading).toBe(false);
		expect(duringRefetch.isBackgroundRefetching).toBe(true);

		const afterRefetch = deriveLoadingState({
			isLoaded: true,
			isChatsLoading: false,
			isChatsFetching: false,
		});
		expect(afterRefetch.shouldShowThreadsLoading).toBe(false);
		expect(afterRefetch.isBackgroundRefetching).toBe(false);
	});

	test("isChatsLoading and isChatsFetching cannot both be true (mutual exclusion by the hook)", () => {
		// The hook guarantees: isChatsLoading requires !hasChatsData,
		// isChatsFetching requires hasChatsData. They are mutually exclusive.
		// If both were somehow true, the spinner should still win (defensive).
		const result = deriveLoadingState({
			isLoaded: true,
			isChatsLoading: true,
			isChatsFetching: true,
		});

		// shouldShowThreadsLoading wins — spinner is shown, not the refetch state.
		expect(result.shouldShowThreadsLoading).toBe(true);
		expect(result.isBackgroundRefetching).toBe(false);
	});
});

// Mirror the logic from the hook to verify it only fires without cached data.
function deriveIsChatsLoading(inputs: {
	selectedProjectId: string | null;
	shouldEnableChatsQuery: boolean;
	isPending: boolean;
	fetchStatus: "fetching" | "idle" | "paused";
	hasChatsData: boolean;
}) {
	return (
		Boolean(inputs.selectedProjectId) &&
		inputs.shouldEnableChatsQuery &&
		(inputs.isPending || (inputs.fetchStatus === "fetching" && !inputs.hasChatsData))
	);
}

function deriveIsChatsFetching(inputs: {
	selectedProjectId: string | null;
	shouldEnableChatsQuery: boolean;
	fetchStatus: "fetching" | "idle" | "paused";
	hasChatsData: boolean;
}) {
	return (
		Boolean(inputs.selectedProjectId) &&
		inputs.shouldEnableChatsQuery &&
		inputs.fetchStatus === "fetching" &&
		inputs.hasChatsData
	);
}

describe("use-workspace-shell isChatsLoading derivation", () => {
	test("isChatsLoading is true during initial fetch with no cached data", () => {
		expect(
			deriveIsChatsLoading({
				selectedProjectId: "proj-1",
				shouldEnableChatsQuery: true,
				isPending: true,
				fetchStatus: "fetching",
				hasChatsData: false,
			}),
		).toBe(true);
	});

	test("isChatsLoading is false during refetch when cached data exists", () => {
		expect(
			deriveIsChatsLoading({
				selectedProjectId: "proj-1",
				shouldEnableChatsQuery: true,
				isPending: false,
				fetchStatus: "fetching",
				hasChatsData: true,
			}),
		).toBe(false);
	});

	test("isChatsFetching is true during refetch when cached data exists", () => {
		expect(
			deriveIsChatsFetching({
				selectedProjectId: "proj-1",
				shouldEnableChatsQuery: true,
				fetchStatus: "fetching",
				hasChatsData: true,
			}),
		).toBe(true);
	});

	test("isChatsFetching is false when not fetching", () => {
		expect(
			deriveIsChatsFetching({
				selectedProjectId: "proj-1",
				shouldEnableChatsQuery: true,
				fetchStatus: "idle",
				hasChatsData: true,
			}),
		).toBe(false);
	});

	test("isChatsFetching is false when fetching but no cached data (initial load)", () => {
		expect(
			deriveIsChatsFetching({
				selectedProjectId: "proj-1",
				shouldEnableChatsQuery: true,
				fetchStatus: "fetching",
				hasChatsData: false,
			}),
		).toBe(false);
	});
});
