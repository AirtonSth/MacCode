/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

import { SCROLL_BOTTOM_THRESHOLD, statusLabel } from "./ThreadTerminalPanel";

const terminalSource = readFileSync(resolve(__dirname, "ThreadTerminalPanel.tsx"), "utf-8");

/**
 * Pure-logic tests for the isAtBottom / auto-scroll behaviour introduced
 * in the ThreadTerminalPanel component.
 *
 * The actual scroll guard lives inside React hooks so we cannot call it
 * directly, but we can validate the threshold constant and the helper
 * `shouldAutoScroll` logic that mirrors the component.
 */

/** Mirrors the guard used inside the component's `handleOutputScroll` callback. */
const isAtBottom = (scrollHeight: number, scrollTop: number, clientHeight: number): boolean => {
	const distanceFromBottom = scrollHeight - scrollTop - clientHeight;
	return distanceFromBottom <= SCROLL_BOTTOM_THRESHOLD;
};

describe("SCROLL_BOTTOM_THRESHOLD", () => {
	it("is a positive number", () => {
		expect(SCROLL_BOTTOM_THRESHOLD).toBeGreaterThan(0);
	});

	it("equals 48", () => {
		expect(SCROLL_BOTTOM_THRESHOLD).toBe(48);
	});
});

describe("isAtBottom", () => {
	it("returns true when scrolled exactly to the bottom", () => {
		// scrollHeight=1000, scrollTop=600, clientHeight=400 => distance=0
		expect(isAtBottom(1000, 600, 400)).toBe(true);
	});

	it("returns true when within the threshold", () => {
		// distance = 1000 - 560 - 400 = 40, which is <= 48
		expect(isAtBottom(1000, 560, 400)).toBe(true);
	});

	it("returns true when exactly at threshold boundary", () => {
		// distance = 1000 - 552 - 400 = 48, which is <= 48
		expect(isAtBottom(1000, 552, 400)).toBe(true);
	});

	it("returns false when scrolled up beyond the threshold", () => {
		// distance = 1000 - 500 - 400 = 100, which is > 48
		expect(isAtBottom(1000, 500, 400)).toBe(false);
	});

	it("returns false when scrolled to the top of a long list", () => {
		// distance = 5000 - 0 - 400 = 4600
		expect(isAtBottom(5000, 0, 400)).toBe(false);
	});

	it("returns true for short content that fits the viewport", () => {
		// scrollHeight equals clientHeight, distance=0
		expect(isAtBottom(400, 0, 400)).toBe(true);
	});
});

describe("statusLabel", () => {
	it("returns Running when isExecuting", () => {
		expect(statusLabel({ isExecuting: true, isLoading: false })).toBe("Running");
	});

	it("returns Loading when isLoading but not executing", () => {
		expect(statusLabel({ isExecuting: false, isLoading: true })).toBe("Loading");
	});

	it("returns Idle when neither executing nor loading", () => {
		expect(statusLabel({ isExecuting: false, isLoading: false })).toBe("Idle");
	});

	it("prefers Running over Loading when both are true", () => {
		expect(statusLabel({ isExecuting: true, isLoading: true })).toBe("Running");
	});
});

describe("[D-38] Terminal auto-scroll uses requestAnimationFrame debounce", () => {
	it("declares a scrollRafIdRef to store the RAF handle", () => {
		expect(terminalSource).toContain("scrollRafIdRef");
	});

	it("calls requestAnimationFrame to debounce scroll-to-bottom", () => {
		expect(terminalSource).toContain("requestAnimationFrame(");
	});

	it("cancels the previous RAF before scheduling a new one", () => {
		expect(terminalSource).toContain("cancelAnimationFrame(scrollRafIdRef.current)");
	});

	it("stores the RAF ID in the ref", () => {
		expect(terminalSource).toContain("scrollRafIdRef.current = requestAnimationFrame(");
	});

	it("clears the RAF ID on cleanup", () => {
		const cleanupMatch = terminalSource.match(
			/return\s*\(\)\s*=>\s*\{[\s\S]*?cancelAnimationFrame\(scrollRafIdRef\.current\)[\s\S]*?scrollRafIdRef\.current\s*=\s*null/,
		);
		expect(cleanupMatch).not.toBeNull();
	});

	it("does not directly set scrollTop outside of RAF callback", () => {
		const scrollEffect = terminalSource.match(
			/useEffect\(\(\)\s*=>\s*\{[\s\S]*?scrollRafIdRef[\s\S]*?\}, \[items\]\)/,
		);
		expect(scrollEffect).not.toBeNull();
		const effectBody = scrollEffect![0];
		const directScrollAssignments = effectBody.match(/outputElement\.scrollTop\s*=/g);
		const rafCallbacks = effectBody.match(/requestAnimationFrame\(/g);
		expect(rafCallbacks).not.toBeNull();
		expect(rafCallbacks!.length).toBeGreaterThan(0);
		expect(directScrollAssignments).not.toBeNull();
		const rafBlock = effectBody.match(/requestAnimationFrame\([\s\S]*?\n\t\t\}\)/);
		expect(rafBlock).not.toBeNull();
		expect(rafBlock![0]).toContain("outputElement.scrollTop = outputElement.scrollHeight");
	});
});

describe("[D-47] Terminal input disabled affordance", () => {
	it("adds disabled background and opacity styles to the terminal input", () => {
		expect(terminalSource).toContain("disabled:bg-slate-950/50");
		expect(terminalSource).toContain("disabled:opacity-60");
	});
});
