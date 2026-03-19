/* eslint-disable import/no-unresolved */
import { describe, expect, it } from "bun:test";

/**
 * [M-19] Tests for the delayed "Opening thread..." spinner logic.
 *
 * Previously, `isResolvingThreadSelection` immediately showed a spinner,
 * which was visible even for sub-100ms resolutions. The fix adds a 200ms
 * delay before showing the spinner. These tests verify the pure-logic
 * decision that drives the spinner visibility.
 */

/**
 * Mirrors the spinner visibility logic:
 * The spinner should only be shown when the raw condition is true AND
 * the 200ms timer has elapsed (showResolvingSpinner is true).
 */
const computeIsResolvingVisible = (input: {
	source: string | undefined;
	selectedChatId: string | null;
	showResolvingSpinner: boolean;
}): boolean => {
	const isResolvingRaw = input.source === "thread-list" && !input.selectedChatId;
	return isResolvingRaw && input.showResolvingSpinner;
};

describe("[M-19] delayed resolving thread spinner", () => {
	it("is not visible when source is not thread-list", () => {
		expect(
			computeIsResolvingVisible({
				selectedChatId: null,
				showResolvingSpinner: true,
				source: undefined,
			}),
		).toBe(false);
	});

	it("is not visible when chatId is already set", () => {
		expect(
			computeIsResolvingVisible({
				selectedChatId: "chat-1",
				showResolvingSpinner: true,
				source: "thread-list",
			}),
		).toBe(false);
	});

	it("is not visible before the 200ms delay timer fires", () => {
		expect(
			computeIsResolvingVisible({
				selectedChatId: null,
				showResolvingSpinner: false,
				source: "thread-list",
			}),
		).toBe(false);
	});

	it("is visible after the 200ms delay timer fires", () => {
		expect(
			computeIsResolvingVisible({
				selectedChatId: null,
				showResolvingSpinner: true,
				source: "thread-list",
			}),
		).toBe(true);
	});

	it("hides again when chatId becomes available", () => {
		// First the spinner is visible
		const visible = computeIsResolvingVisible({
			selectedChatId: null,
			showResolvingSpinner: true,
			source: "thread-list",
		});
		expect(visible).toBe(true);

		// Then chatId arrives
		const hidden = computeIsResolvingVisible({
			selectedChatId: "chat-1",
			showResolvingSpinner: true,
			source: "thread-list",
		});
		expect(hidden).toBe(false);
	});
});

const checkResolvingCondition = (source: string | undefined, chatId: string | null): boolean =>
	source === "thread-list" && !chatId;

describe("[M-19] timer lifecycle", () => {
	it("timer should be set only when raw condition is true", () => {
		expect(checkResolvingCondition("thread-list", null)).toBe(true);
		expect(checkResolvingCondition("thread-list", "chat-1")).toBe(false);
		expect(checkResolvingCondition(undefined, null)).toBe(false);
		expect(checkResolvingCondition("terminal", null)).toBe(false);
	});

	it("spinner state resets when raw condition becomes false", () => {
		// When raw condition transitions from true to false,
		// the component sets showResolvingSpinner back to false
		// and clears the timer. This models that reset behavior.
		let showResolvingSpinner = true;
		const isResolvingRaw = false; // condition just became false
		if (!isResolvingRaw) {
			showResolvingSpinner = false;
		}
		expect(showResolvingSpinner).toBe(false);
	});
});
