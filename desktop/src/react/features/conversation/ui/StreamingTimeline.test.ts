/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

import {
	DETAIL_EXPAND_TRANSITION,
	DETAIL_EXPAND_WRAPPER_STYLE,
	TOOL_AUTO_EXPAND_MS,
} from "./StreamingTimeline";

// ---------------------------------------------------------------------------
// 1. The animation wrapper must use overflow: hidden so content is clipped
//    during the height transition (prevents layout jump).
// ---------------------------------------------------------------------------
describe("DETAIL_EXPAND_WRAPPER_STYLE", () => {
	test("has overflow hidden to clip content during height animation", () => {
		expect(DETAIL_EXPAND_WRAPPER_STYLE.overflow).toBe("hidden");
	});
});

// ---------------------------------------------------------------------------
// 2. The transition config uses Material-style cubic-bezier easing instead of
//    the default framer-motion spring, keeping the expand/collapse smooth.
// ---------------------------------------------------------------------------
describe("DETAIL_EXPAND_TRANSITION", () => {
	test("uses a 250ms duration for the expand/collapse animation", () => {
		expect(DETAIL_EXPAND_TRANSITION.duration).toBe(0.25);
	});

	test("uses Material-style cubic-bezier easing [0.4, 0, 0.2, 1]", () => {
		expect(DETAIL_EXPAND_TRANSITION.ease).toEqual([0.4, 0, 0.2, 1]);
	});

	test("easing array has exactly four control points", () => {
		expect(DETAIL_EXPAND_TRANSITION.ease.length).toBe(4);
	});
});

// ---------------------------------------------------------------------------
// 3. Auto-expand timer fires after the expected delay.
// ---------------------------------------------------------------------------
describe("TOOL_AUTO_EXPAND_MS", () => {
	test("auto-expand fires after 2 000 ms", () => {
		expect(TOOL_AUTO_EXPAND_MS).toBe(2_000);
	});

	test("value is a positive integer", () => {
		expect(Number.isInteger(TOOL_AUTO_EXPAND_MS)).toBe(true);
		expect(TOOL_AUTO_EXPAND_MS).toBeGreaterThan(0);
	});
});
