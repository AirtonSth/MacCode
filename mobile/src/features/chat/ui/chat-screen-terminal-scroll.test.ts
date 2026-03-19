/* eslint-disable import/no-unresolved */
import { describe, expect, it } from "bun:test";

/**
 * [M-38] Tests for the terminal scroll onLayout pattern.
 *
 * Previously, scrollToEnd was called via setTimeout(0) after setting
 * terminal output. This created a race condition where the scroll
 * fired before the DOM had updated, causing the terminal to briefly
 * show the top of the content for 16-33ms.
 *
 * The fix replaces setTimeout(0) with an onLayout/onContentSizeChange
 * callback approach: a `shouldScrollTerminalToEndRef` flag is set
 * when new output arrives, and the ScrollView's onContentSizeChange
 * callback checks the flag and scrolls only after layout completes.
 */

type ScrollMode = "animated" | "instant" | null;

/**
 * Simulates the shouldScrollTerminalToEndRef pattern used in chat-screen.tsx.
 * The ref stores the desired scroll mode ("animated" or "instant") or null
 * when no scroll is pending.
 */
class TerminalScrollController {
	public pendingScrollMode: ScrollMode = null;

	public scrollCalls: { animated: boolean }[] = [];

	public setScrollPending(mode: "animated" | "instant"): void {
		this.pendingScrollMode = mode;
	}

	/**
	 * Called when the ScrollView content size changes (onContentSizeChange).
	 * Mirrors handleTerminalContentLayout in chat-screen.tsx.
	 */
	public handleContentLayout(): void {
		const mode = this.pendingScrollMode;
		if (mode === null) {
			return;
		}
		this.pendingScrollMode = null;
		this.scrollCalls.push({ animated: mode === "animated" });
	}
}

describe("[M-38] terminal scroll onLayout pattern", () => {
	it("does not scroll when no flag is set", () => {
		const controller = new TerminalScrollController();
		controller.handleContentLayout();
		expect(controller.scrollCalls.length).toBe(0);
	});

	it("scrolls with animated=false when mode is instant", () => {
		const controller = new TerminalScrollController();
		controller.setScrollPending("instant");
		controller.handleContentLayout();
		expect(controller.scrollCalls.length).toBe(1);
		expect(controller.scrollCalls[0]).toEqual({ animated: false });
	});

	it("scrolls with animated=true when mode is animated", () => {
		const controller = new TerminalScrollController();
		controller.setScrollPending("animated");
		controller.handleContentLayout();
		expect(controller.scrollCalls.length).toBe(1);
		expect(controller.scrollCalls[0]).toEqual({ animated: true });
	});

	it("clears the flag after scrolling", () => {
		const controller = new TerminalScrollController();
		controller.setScrollPending("instant");
		controller.handleContentLayout();
		expect(controller.pendingScrollMode).toBeNull();

		// Second layout should not trigger another scroll
		controller.handleContentLayout();
		expect(controller.scrollCalls.length).toBe(1);
	});

	it("uses the latest mode when set multiple times before layout", () => {
		const controller = new TerminalScrollController();
		controller.setScrollPending("instant");
		controller.setScrollPending("animated");
		controller.handleContentLayout();
		expect(controller.scrollCalls.length).toBe(1);
		expect(controller.scrollCalls[0]).toEqual({ animated: true });
	});
});

describe("[M-36/M-38] history load uses animated terminal scroll after layout", () => {
	it("sets animated mode after terminal output is set from history", () => {
		const controller = new TerminalScrollController();

		// Simulate: history loaded -> setTerminalOutput -> set ref to "animated"
		controller.setScrollPending("animated");

		expect(controller.pendingScrollMode).toBe("animated");

		// Simulate: onContentSizeChange fires after DOM updates
		controller.handleContentLayout();

		expect(controller.scrollCalls.length).toBe(1);
		expect(controller.scrollCalls[0]).toEqual({ animated: true });
		expect(controller.pendingScrollMode).toBeNull();
	});
});

describe("[M-38] command execution sets animated scroll", () => {
	it("sets animated mode after terminal command completes", () => {
		const controller = new TerminalScrollController();

		// Simulate: command run -> output appended -> set ref to "animated"
		controller.setScrollPending("animated");

		expect(controller.pendingScrollMode).toBe("animated");

		// Simulate: onContentSizeChange fires after DOM updates
		controller.handleContentLayout();

		expect(controller.scrollCalls.length).toBe(1);
		expect(controller.scrollCalls[0]).toEqual({ animated: true });
		expect(controller.pendingScrollMode).toBeNull();
	});
});
