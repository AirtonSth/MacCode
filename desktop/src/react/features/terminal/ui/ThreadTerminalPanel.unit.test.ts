import { expect, test } from "bun:test";

import { statusLabel } from "./ThreadTerminalPanel";

test("statusLabel prioritizes running over loading", () => {
	expect(statusLabel({ isExecuting: true, isLoading: true })).toBe("Running");
});

test("statusLabel returns loading and idle states", () => {
	expect(statusLabel({ isExecuting: false, isLoading: true })).toBe("Loading");
	expect(statusLabel({ isExecuting: false, isLoading: false })).toBe("Idle");
});
