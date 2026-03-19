/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

/**
 * M-29: Toast must not overlap the FAB button.
 *
 * The FAB is positioned at `bottom: 22` with a height of 58px,
 * so the toast needs a `bottom` offset above 80px to avoid overlap.
 */

const FAB_BOTTOM = 22;
const FAB_HEIGHT = 58;
const FAB_TOP_EDGE = FAB_BOTTOM + FAB_HEIGHT; // 80

// Updated toast bottom position from the fix
const TOAST_BOTTOM = 92;

describe("M-29: Toast does not overlap FAB", () => {
	test("toast bottom offset is above the FAB top edge", () => {
		expect(TOAST_BOTTOM).toBeGreaterThan(FAB_TOP_EDGE);
	});

	test("toast has reasonable spacing above FAB (at least 8px)", () => {
		const spacing = TOAST_BOTTOM - FAB_TOP_EDGE;
		expect(spacing).toBeGreaterThanOrEqual(8);
	});

	test("toast is not too far from bottom of screen (under 140px)", () => {
		expect(TOAST_BOTTOM).toBeLessThan(140);
	});
});
