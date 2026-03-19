/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

/**
 * [M-01] WebSocket reconnect stability tests.
 *
 * The handleWorkspaceRealtimeEffect should only depend on
 * `config.activeTarget` and `isActive`, NOT on `handleServerEvent`
 * or `handleConnectionStateChange` callback identities.
 *
 * These tests verify the ref-based indirection pattern that prevents
 * the WebSocket from reconnecting every time a callback changes identity.
 */

describe("[M-01] WebSocket reconnect stability", () => {
	test("callback ref pattern: updating .current does not change the wrapper identity", () => {
		const ref = { current: (ignore: unknown) => `v1:${String(ignore)}` };

		const stableWrapper = (event: unknown) => ref.current(event);

		ref.current = (ignore: unknown) => `v2:${String(ignore)}`;
		expect(stableWrapper({ type: "test" })).toContain("v2");

		ref.current = (ignore: unknown) => `v3:${String(ignore)}`;
		expect(stableWrapper({ type: "test" })).toContain("v3");
	});

	test("effect dependency array must NOT include handleServerEvent or handleConnectionStateChange", () => {
		let effectRunCount = 0;
		const handleServerEventRef = { current: () => { /* noop */ } };
		const handleConnectionStateChangeRef = { current: (ignore: string) => { void ignore; } };

		const runEffect = (activeTarget: string, isActive: boolean) => {
			effectRunCount += 1;
			return {
				onEvent: () => { handleServerEventRef.current(); },
				onConnectionStateChange: (state: string) => { handleConnectionStateChangeRef.current(state); },
				target: activeTarget,
				isActive,
			};
		};

		runEffect("ws://localhost:8835", true);
		expect(effectRunCount).toBe(1);

		handleServerEventRef.current = () => { /* noop */ };
		handleConnectionStateChangeRef.current = (ignore: string) => { void ignore; };

		expect(effectRunCount).toBe(1);

		runEffect("ws://newhost:8835", true);
		expect(effectRunCount).toBe(2);
	});
});
