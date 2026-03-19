/* eslint-disable import/no-unresolved */
import { describe, expect, it } from "bun:test";

/**
 * [M-20] Tests for the streaming text fallback logic.
 *
 * Previously, streaming text was hidden as soon as `hasStreamingItems` was
 * true. This could cause a 1-frame flash where the streaming text disappears
 * before the timeline items actually render content.
 *
 * The fix keeps streaming text visible as a fallback until the live turn
 * actually has items in its itemOrder array. Only then does the timeline
 * take over.
 */

interface StreamingVisibilityInput {
	hasStreamingText: boolean;
	hasStreamingItems: boolean;
	liveTurnItemCount: number;
	isRunning: boolean;
}

/**
 * Mirrors the updated condition for showing streaming text:
 * ```
 * hasStreamingText && (isRunning) && (!hasStreamingItems || !liveTurn || liveTurn.itemOrder.length === 0)
 * ```
 */
const shouldShowStreamingText = (input: StreamingVisibilityInput): boolean => {
	const hasLiveTurnItems = input.hasStreamingItems && input.liveTurnItemCount > 0;
	return input.hasStreamingText && input.isRunning && !hasLiveTurnItems;
};

/** Mirrors the condition for showing the timeline */
const shouldShowTimeline = (input: StreamingVisibilityInput): boolean => {
	return input.hasStreamingItems && input.liveTurnItemCount > 0;
};

describe("[M-20] streaming text fallback", () => {
	it("shows streaming text when there are no timeline items yet", () => {
		expect(
			shouldShowStreamingText({
				hasStreamingItems: false,
				hasStreamingText: true,
				isRunning: true,
				liveTurnItemCount: 0,
			}),
		).toBe(true);
	});

	it("shows streaming text even when hasStreamingItems is true but itemOrder is empty", () => {
		// This is the key transition case: the turn object exists but has no items yet
		expect(
			shouldShowStreamingText({
				hasStreamingItems: true,
				hasStreamingText: true,
				isRunning: true,
				liveTurnItemCount: 0,
			}),
		).toBe(true);
	});

	it("hides streaming text once timeline items actually exist", () => {
		expect(
			shouldShowStreamingText({
				hasStreamingItems: true,
				hasStreamingText: true,
				isRunning: true,
				liveTurnItemCount: 3,
			}),
		).toBe(false);
	});

	it("does not show streaming text when there is none", () => {
		expect(
			shouldShowStreamingText({
				hasStreamingItems: false,
				hasStreamingText: false,
				isRunning: true,
				liveTurnItemCount: 0,
			}),
		).toBe(false);
	});

	it("does not show streaming text when not running", () => {
		expect(
			shouldShowStreamingText({
				hasStreamingItems: false,
				hasStreamingText: true,
				isRunning: false,
				liveTurnItemCount: 0,
			}),
		).toBe(false);
	});
});

describe("[M-20] no content gap during transition", () => {
	it("always shows either streaming text or timeline during transition", () => {
		// Step 1: Only streaming text
		const step1 = {
			hasStreamingItems: false,
			hasStreamingText: true,
			isRunning: true,
			liveTurnItemCount: 0,
		};
		expect(shouldShowStreamingText(step1)).toBe(true);
		expect(shouldShowTimeline(step1)).toBe(false);

		// Step 2: Streaming items flag is set, but no actual items yet
		// (this is the problematic frame in the old implementation)
		const step2 = {
			hasStreamingItems: true,
			hasStreamingText: true,
			isRunning: true,
			liveTurnItemCount: 0,
		};

		// Fix ensures streaming text is STILL visible here
		expect(shouldShowStreamingText(step2)).toBe(true);
		expect(shouldShowTimeline(step2)).toBe(false);

		// Step 3: Items actually arrive
		const step3 = {
			hasStreamingItems: true,
			hasStreamingText: true,
			isRunning: true,
			liveTurnItemCount: 2,
		};
		expect(shouldShowStreamingText(step3)).toBe(false);
		expect(shouldShowTimeline(step3)).toBe(true);
	});
});
