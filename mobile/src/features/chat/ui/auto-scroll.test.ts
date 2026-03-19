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

/**
 * Mirrors the flag assignment: only flag as scrolled up when the user actively
 * scrolled upward (offset decreased) AND is not at bottom.
 */
const shouldFlagUserScrolledUp = (input: {
	contentHeight: number;
	layoutHeight: number;
	offsetY: number;
	previousOffsetY: number;
}): boolean => {
	const distance = computeDistanceFromBottom(input.contentHeight, input.offsetY, input.layoutHeight);
	const atBottom = distance <= AUTO_SCROLL_BOTTOM_THRESHOLD;
	const scrolledUp = input.offsetY < input.previousOffsetY;
	return scrolledUp && !atBottom;
};

/** Mirrors the flag clear: reset when user reaches the bottom. */
const shouldClearFlag = (
	contentHeight: number,
	offsetY: number,
	layoutHeight: number,
): boolean => computeDistanceFromBottom(contentHeight, offsetY, layoutHeight) <= AUTO_SCROLL_BOTTOM_THRESHOLD;

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

describe("AUTO_SCROLL_BOTTOM_THRESHOLD", () => {
	it("is a positive number", () => {
		expect(AUTO_SCROLL_BOTTOM_THRESHOLD).toBeGreaterThan(0);
	});

	it("equals 48", () => {
		expect(AUTO_SCROLL_BOTTOM_THRESHOLD).toBe(48);
	});
});

describe("shouldFlagUserScrolledUp", () => {
	it("returns false when content grows but user did not scroll", () => {
		// Content grew from 2000 to 2500, offset unchanged at 1400, layout 600
		// distance = 2500 - (1400+600) = 500, but offset didn't decrease
		expect(shouldFlagUserScrolledUp({
			contentHeight: 2500,
			layoutHeight: 600,
			offsetY: 1400,
			previousOffsetY: 1400,
		})).toBe(false);
	});

	it("returns true when user actively scrolled up beyond threshold", () => {
		// User scrolled from offset 1400 to 1000, content 2000, layout 600
		// distance = 2000 - (1000+600) = 400, scrolledUp = true
		expect(shouldFlagUserScrolledUp({
			contentHeight: 2000,
			layoutHeight: 600,
			offsetY: 1000,
			previousOffsetY: 1400,
		})).toBe(true);
	});

	it("returns false when user scrolled up but is still at bottom", () => {
		// offset decreased slightly but still at bottom
		// distance = 2000 - (1380+600) = 20
		expect(shouldFlagUserScrolledUp({
			contentHeight: 2000,
			layoutHeight: 600,
			offsetY: 1380,
			previousOffsetY: 1400,
		})).toBe(false);
	});

	it("returns false when scrolling down (offset increased)", () => {
		expect(shouldFlagUserScrolledUp({
			contentHeight: 5000,
			layoutHeight: 600,
			offsetY: 1500,
			previousOffsetY: 1000,
		})).toBe(false);
	});

	it("returns false when content fits the viewport", () => {
		expect(shouldFlagUserScrolledUp({
			contentHeight: 600,
			layoutHeight: 600,
			offsetY: 0,
			previousOffsetY: 0,
		})).toBe(false);
	});
});

describe("shouldClearFlag", () => {
	it("returns true when at bottom", () => {
		expect(shouldClearFlag(2000, 1400, 600)).toBe(true);
	});

	it("returns true when within threshold", () => {
		expect(shouldClearFlag(2000, 1360, 600)).toBe(true);
	});

	it("returns false when scrolled beyond threshold", () => {
		expect(shouldClearFlag(2000, 1300, 600)).toBe(false);
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

describe("end-to-end scenario: user scrolls up during streaming", () => {
	it("prevents auto-scroll while scrolled up, resumes when user scrolls back to bottom", () => {
		let userScrolledUp = false;

		// Step 1: Streaming starts, user is at bottom — auto-scroll fires
		expect(shouldAutoScroll({
			hasNewTailMessage: false,
			hasStreaming: true,
			isViewingOlderMessages: false,
			userScrolledUp,
		})).toBe(true);

		// Step 2: User actively scrolls up
		userScrolledUp = shouldFlagUserScrolledUp({
			contentHeight: 5000,
			layoutHeight: 600,
			offsetY: 1000,
			previousOffsetY: 2000,
		});
		expect(userScrolledUp).toBe(true);

		// Auto-scroll should be suppressed
		expect(shouldAutoScroll({
			hasNewTailMessage: false,
			hasStreaming: true,
			isViewingOlderMessages: false,
			userScrolledUp,
		})).toBe(false);

		// Step 3: Streaming ends — flag does NOT reset (user must scroll to bottom)
		expect(shouldAutoScroll({
			hasNewTailMessage: true,
			hasStreaming: false,
			isViewingOlderMessages: false,
			userScrolledUp,
		})).toBe(false);

		// Step 4: User scrolls back to bottom — flag clears
		if (shouldClearFlag(5000, 4400, 600)) {
			userScrolledUp = false;
		}
		expect(userScrolledUp).toBe(false);

		// Step 5: Next message arrives — auto-scroll fires again
		expect(shouldAutoScroll({
			hasNewTailMessage: true,
			hasStreaming: false,
			isViewingOlderMessages: false,
			userScrolledUp,
		})).toBe(true);
	});
});
