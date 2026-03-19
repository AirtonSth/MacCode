/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

/**
 * M-31: Active threads screen should show loading state during initial fetch.
 *
 * The fix introduces `shouldShowLoading` which checks both `isLoaded` and
 * `isActiveThreadsLoading` to avoid the race condition where the empty
 * state flashes before the first fetch completes.
 */

interface ActiveThreadsLoadingInputs {
	isActiveThreadsLoading: boolean;
	isLoaded: boolean;
	visibleThreadsCount: number;
}

const computeShouldShowLoading = (inputs: ActiveThreadsLoadingInputs): boolean =>
	!inputs.isLoaded || inputs.isActiveThreadsLoading;

const computeShouldShowEmptyState = (inputs: ActiveThreadsLoadingInputs): boolean =>
	!computeShouldShowLoading(inputs) && inputs.visibleThreadsCount === 0;

describe("M-31: Active threads loading/empty race", () => {
	test("shows loading when workspace shell is not yet loaded", () => {
		expect(computeShouldShowLoading({
			isActiveThreadsLoading: false,
			isLoaded: false,
			visibleThreadsCount: 0,
		})).toBe(true);
	});

	test("shows loading when active threads query is pending", () => {
		expect(computeShouldShowLoading({
			isActiveThreadsLoading: true,
			isLoaded: true,
			visibleThreadsCount: 0,
		})).toBe(true);
	});

	test("does NOT show empty state when shell is not loaded (prevents flash)", () => {
		expect(computeShouldShowEmptyState({
			isActiveThreadsLoading: false,
			isLoaded: false,
			visibleThreadsCount: 0,
		})).toBe(false);
	});

	test("does NOT show empty state when active threads are still loading", () => {
		expect(computeShouldShowEmptyState({
			isActiveThreadsLoading: true,
			isLoaded: true,
			visibleThreadsCount: 0,
		})).toBe(false);
	});

	test("shows empty state only when fully loaded and no threads exist", () => {
		expect(computeShouldShowEmptyState({
			isActiveThreadsLoading: false,
			isLoaded: true,
			visibleThreadsCount: 0,
		})).toBe(true);
	});

	test("does not show loading when loaded and data is available", () => {
		expect(computeShouldShowLoading({
			isActiveThreadsLoading: false,
			isLoaded: true,
			visibleThreadsCount: 3,
		})).toBe(false);
	});
});
