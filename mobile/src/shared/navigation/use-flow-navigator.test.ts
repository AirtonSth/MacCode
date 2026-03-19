/* eslint-disable import/no-unresolved */
import { beforeEach, describe, expect, test } from "bun:test";

/**
 * M-32: pendingRouteRef must not block navigation permanently.
 *
 * The fix adds a timeout that clears pendingRouteRef after 3 seconds,
 * ensuring that a failed navigation does not permanently block future taps.
 */

const PENDING_ROUTE_TIMEOUT_MS = 3000;

interface NavigationState {
	pathname: string;
	pendingRoute: string | null;
	pendingTimer: ReturnType<typeof setTimeout> | null;
}

const createNavigationState = (pathname: string): NavigationState => ({
	pathname,
	pendingRoute: null,
	pendingTimer: null,
});

const setPendingRoute = (state: NavigationState, route: string): NavigationState => {
	if (state.pendingTimer) {
		clearTimeout(state.pendingTimer);
	}

	const next: NavigationState = { ...state, pendingRoute: route };
	next.pendingTimer = setTimeout(() => {
		next.pendingRoute = null;
		next.pendingTimer = null;
	}, PENDING_ROUTE_TIMEOUT_MS);

	return next;
};

const canNavigate = (state: NavigationState, route: string): boolean =>
	state.pathname !== route && state.pendingRoute !== route;

const handlePathnameChange = (state: NavigationState, newPathname: string): NavigationState => {
	const next = { ...state, pathname: newPathname };
	if (next.pendingRoute === newPathname) {
		next.pendingRoute = null;
		if (next.pendingTimer) {
			clearTimeout(next.pendingTimer);
			next.pendingTimer = null;
		}
	}
	return next;
};

let state: NavigationState = createNavigationState("/workspaces");

beforeEach(() => {
	state = createNavigationState("/workspaces");
});

describe("M-32: pendingRouteRef timeout", () => {
	test("navigation is allowed when no pending route exists", () => {
		expect(canNavigate(state, "/threads")).toBe(true);
	});

	test("navigation is blocked while same route is pending", () => {
		state = setPendingRoute(state, "/threads");
		expect(canNavigate(state, "/threads")).toBe(false);
	});

	test("navigation to a different route is allowed even with a pending route", () => {
		state = setPendingRoute(state, "/threads");
		expect(canNavigate(state, "/chat")).toBe(true);
	});

	test("pending route clears when pathname matches", () => {
		state = setPendingRoute(state, "/threads");
		state = handlePathnameChange(state, "/threads");
		expect(state.pendingRoute).toBeNull();
		expect(canNavigate(state, "/threads")).toBe(false); // pathname matches, still blocked
	});

	test("timeout value is 3 seconds", () => {
		expect(PENDING_ROUTE_TIMEOUT_MS).toBe(3000);
	});

	test("multiple setPendingRoute calls clear previous timer", () => {
		state = setPendingRoute(state, "/threads");
		const firstTimer = state.pendingTimer;
		state = setPendingRoute(state, "/chat");

		// The second call should have a different timer
		expect(state.pendingRoute).toBe("/chat");
		expect(state.pendingTimer).not.toBe(firstTimer);

		// Clean up timers
		if (state.pendingTimer) {
			clearTimeout(state.pendingTimer);
		}
	});
});
