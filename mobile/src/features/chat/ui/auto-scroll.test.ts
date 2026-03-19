/* eslint-disable import/no-unresolved */
import { describe, expect, it } from "bun:test";

import { AUTO_SCROLL_BOTTOM_THRESHOLD } from "./auto-scroll-constants";

/**
 * Pure-logic tests for the userScrolledUp flag auto-scroll behaviour
 * introduced in the mobile chat screen.
 *
 * The actual scroll guard lives inside React hooks/refs, so we replicate
 * the decision logic here to verify correctness of the threshold and the
 * flag-based approach.
 */

/** Mirrors the distance check inside handleMessageScroll. */
const computeDistanceFromBottom = (
	contentHeight: number,
	offsetY: number,
	layoutHeight: number,
): number => contentHeight - (offsetY + layoutHeight);

/** Mirrors the flag assignment: `userScrolledUpRef.current = distance > threshold`. */
const shouldFlagUserScrolledUp = (
	contentHeight: number,
	offsetY: number,
	layoutHeight: number,
): boolean => computeDistanceFromBottom(contentHeight, offsetY, layoutHeight) > AUTO_SCROLL_BOTTOM_THRESHOLD;

/** Mirrors the auto-scroll guard: scroll only when the flag is false. */
const shouldAutoScroll = (input: {
	hasNewTailMessage: boolean;
	hasStreaming: boolean;
	isViewingOlderMessages: boolean;
	userScrolledUp: boolean;
}): boolean => {
	if (input.isViewingOlderMessages) {
		return false;
	}

	if (!input.hasNewTailMessage && !input.hasStreaming) {
		return false;
	}

	return !input.userScrolledUp;
};

/** Mirrors the reset logic: when streaming ends, the flag resets to false. */
const shouldResetFlag = (hasStreaming: boolean): boolean => !hasStreaming;

describe("AUTO_SCROLL_BOTTOM_THRESHOLD", () => {
	it("is a positive number", () => {
		expect(AUTO_SCROLL_BOTTOM_THRESHOLD).toBeGreaterThan(0);
	});

	it("equals 48", () => {
		expect(AUTO_SCROLL_BOTTOM_THRESHOLD).toBe(48);
	});
});

describe("shouldFlagUserScrolledUp", () => {
	it("returns false when scrolled to the bottom", () => {
		// contentHeight=2000, offsetY=1400, layoutHeight=600 => distance=0
		expect(shouldFlagUserScrolledUp(2000, 1400, 600)).toBe(false);
	});

	it("returns false when within the threshold", () => {
		// distance = 2000 - (1360 + 600) = 40
		expect(shouldFlagUserScrolledUp(2000, 1360, 600)).toBe(false);
	});

	it("returns false when exactly at threshold boundary", () => {
		// distance = 2000 - (1352 + 600) = 48, NOT > 48
		expect(shouldFlagUserScrolledUp(2000, 1352, 600)).toBe(false);
	});

	it("returns true when scrolled up beyond the threshold", () => {
		// distance = 2000 - (1300 + 600) = 100
		expect(shouldFlagUserScrolledUp(2000, 1300, 600)).toBe(true);
	});

	it("returns true when scrolled to the very top of long content", () => {
		// distance = 5000 - (0 + 600) = 4400
		expect(shouldFlagUserScrolledUp(5000, 0, 600)).toBe(true);
	});

	it("returns false when content fits the viewport", () => {
		// contentHeight=600, offsetY=0, layoutHeight=600 => distance=0
		expect(shouldFlagUserScrolledUp(600, 0, 600)).toBe(false);
	});
});

describe("shouldAutoScroll", () => {
	it("returns true for new message when user is at bottom", () => {
		expect(shouldAutoScroll({
			hasNewTailMessage: true,
			hasStreaming: false,
			isViewingOlderMessages: false,
			userScrolledUp: false,
		})).toBe(true);
	});

	it("returns true during streaming when user is at bottom", () => {
		expect(shouldAutoScroll({
			hasNewTailMessage: false,
			hasStreaming: true,
			isViewingOlderMessages: false,
			userScrolledUp: false,
		})).toBe(true);
	});

	it("returns false during streaming when user has scrolled up", () => {
		expect(shouldAutoScroll({
			hasNewTailMessage: false,
			hasStreaming: true,
			isViewingOlderMessages: false,
			userScrolledUp: true,
		})).toBe(false);
	});

	it("returns false for new message when user has scrolled up", () => {
		expect(shouldAutoScroll({
			hasNewTailMessage: true,
			hasStreaming: false,
			isViewingOlderMessages: false,
			userScrolledUp: true,
		})).toBe(false);
	});

	it("returns false when viewing older messages regardless of flag", () => {
		expect(shouldAutoScroll({
			hasNewTailMessage: true,
			hasStreaming: true,
			isViewingOlderMessages: true,
			userScrolledUp: false,
		})).toBe(false);
	});

	it("returns false when there is nothing new to scroll to", () => {
		expect(shouldAutoScroll({
			hasNewTailMessage: false,
			hasStreaming: false,
			isViewingOlderMessages: false,
			userScrolledUp: false,
		})).toBe(false);
	});
});

describe("shouldResetFlag (streaming end)", () => {
	it("returns true when streaming has ended", () => {
		expect(shouldResetFlag(false)).toBe(true);
	});

	it("returns false while streaming is active", () => {
		expect(shouldResetFlag(true)).toBe(false);
	});
});

describe("end-to-end scenario: user scrolls up during streaming", () => {
	it("prevents auto-scroll while scrolled up, resumes after streaming ends", () => {
		// Step 1: Streaming starts, user is at bottom
		let userScrolledUp = false;
		const hasStreaming = true;

		// Auto-scroll should fire
		expect(shouldAutoScroll({
			hasNewTailMessage: false,
			hasStreaming,
			isViewingOlderMessages: false,
			userScrolledUp,
		})).toBe(true);

		// Step 2: User scrolls up manually
		userScrolledUp = shouldFlagUserScrolledUp(5000, 1000, 600);
		expect(userScrolledUp).toBe(true);

		// Auto-scroll should be suppressed
		expect(shouldAutoScroll({
			hasNewTailMessage: false,
			hasStreaming,
			isViewingOlderMessages: false,
			userScrolledUp,
		})).toBe(false);

		// Step 3: Streaming ends — flag resets
		const streamingEnded = !hasStreaming; // false (still streaming in this scenario)
		// Simulate streaming actually ending:
		const nowStreaming = false;
		if (shouldResetFlag(nowStreaming)) {
			userScrolledUp = false;
		}
		expect(userScrolledUp).toBe(false);

		// Step 4: Next message arrives — auto-scroll fires again
		expect(shouldAutoScroll({
			hasNewTailMessage: true,
			hasStreaming: false,
			isViewingOlderMessages: false,
			userScrolledUp,
		})).toBe(true);

		void streamingEnded; // suppress unused variable
	});
});
