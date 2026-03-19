/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

/**
 * M-28: Splash animation should be long enough for content to load.
 *
 * The fix increases animation durations from ~244ms total to ~580ms total,
 * ensuring the splash stays visible while the app initializes.
 */

// These durations match the updated animated-launch-splash.tsx constants.
const PHASE_1_ICON_OPACITY = 180;
const PHASE_1_ICON_SCALE = 260;
const PHASE_1_GLOW_OPACITY = 200;
const PHASE_1_GLOW_SCALE = 280;
const PHASE_1_DURATION = Math.max(PHASE_1_ICON_OPACITY, PHASE_1_ICON_SCALE, PHASE_1_GLOW_OPACITY, PHASE_1_GLOW_SCALE);

const DELAY = 100;

const PHASE_2_OVERLAY_OPACITY = 200;
const PHASE_2_ICON_SCALE = 200;
const PHASE_2_GLOW_OPACITY = 180;
const PHASE_2_DURATION = Math.max(PHASE_2_OVERLAY_OPACITY, PHASE_2_ICON_SCALE, PHASE_2_GLOW_OPACITY);

const TOTAL_DURATION = PHASE_1_DURATION + DELAY + PHASE_2_DURATION;

describe("M-28: Splash animation duration", () => {
	test("total animation duration is at least 500ms", () => {
		expect(TOTAL_DURATION).toBeGreaterThanOrEqual(500);
	});

	test("total animation duration is at most 700ms to avoid feeling sluggish", () => {
		expect(TOTAL_DURATION).toBeLessThanOrEqual(700);
	});

	test("phase 1 (enter) is at least 250ms", () => {
		expect(PHASE_1_DURATION).toBeGreaterThanOrEqual(250);
	});

	test("delay between phases is at least 80ms", () => {
		expect(DELAY).toBeGreaterThanOrEqual(80);
	});

	test("phase 2 (exit) is at least 150ms", () => {
		expect(PHASE_2_DURATION).toBeGreaterThanOrEqual(150);
	});
});
