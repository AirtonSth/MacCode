/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, test } from "bun:test";

import { SCROLL_BOTTOM_THRESHOLD_PX, TOP_PAGINATION_DEBOUNCE_MS } from "./ConversationPanel";

// Read the raw source for structural assertions that verify the fix patterns.
const sourcePath = fileURLToPath(new URL("./ConversationPanel.tsx", import.meta.url));
const source = readFileSync(sourcePath, "utf8");

// ---------------------------------------------------------------------------
// D-18: Scroll-to-bottom threshold increased to 80px
// ---------------------------------------------------------------------------
describe("D-18: scroll-to-bottom threshold", () => {
	test("SCROLL_BOTTOM_THRESHOLD_PX is 80", () => {
		expect(SCROLL_BOTTOM_THRESHOLD_PX).toBe(80);
	});

	test("threshold is used in updateIsAtBottom callback", () => {
		expect(source).toContain("distanceFromBottom <= SCROLL_BOTTOM_THRESHOLD_PX");
	});

	test("userScrolledUpRef is declared to track user scroll direction", () => {
		expect(source).toContain("const userScrolledUpRef = useRef(false)");
	});

	test("auto-scroll is gated by userScrolledUpRef", () => {
		expect(source).toContain("isAtBottomRef.current && !userScrolledUpRef.current");
	});

	test("userScrolledUpRef is reset when at bottom", () => {
		// When the viewport reaches the bottom, the flag should be cleared
		expect(source).toContain("userScrolledUpRef.current = false");
	});

	test("userScrolledUpRef is set when user scrolls up and not at bottom", () => {
		expect(source).toContain("userScrolledUpRef.current = true");
	});

	test("userScrolledUpRef is reset on chat change", () => {
		// The chat change useEffect should reset the flag
		const chatEffectMatch = source.match(/useEffect\(\(\) => \{[\s\S]*?userScrolledUpRef\.current = false[\s\S]*?\}, \[chat\?\.id\]\)/);
		expect(chatEffectMatch).not.toBeNull();
	});
});

// ---------------------------------------------------------------------------
// D-19: AnimatePresence shimmer suppression on chat switch
// ---------------------------------------------------------------------------
describe("D-19: animation suppression on chat switch", () => {
	test("prevChatIdRef is declared to track previous chat id", () => {
		expect(source).toContain("prevChatIdRef");
	});

	test("isChatSwitchRef is declared to flag chat switches", () => {
		expect(source).toContain("isChatSwitchRef");
	});

	test("chat switch detection compares prevChatIdRef to current chat id", () => {
		expect(source).toContain("prevChatIdRef.current !== chat?.id");
	});

	test("bubbleMotion is disabled when isChatSwitchRef is true", () => {
		expect(source).toContain("shouldReduceMotion || isChatSwitchRef.current");
	});

	test("MessageBubble receives disableAnimation prop", () => {
		expect(source).toContain("disableAnimation={isChatSwitchRef.current}");
	});

	test("MessageBubble uses disableAnimation to suppress motion", () => {
		expect(source).toContain("shouldReduceMotion || disableAnimation");
	});

	test("isChatSwitchRef is cleared after the render via useEffect", () => {
		expect(source).toContain("isChatSwitchRef.current = false");
	});
});

// ---------------------------------------------------------------------------
// D-20: Top pagination debounce
// ---------------------------------------------------------------------------
describe("D-20: top pagination debounce", () => {
	test("TOP_PAGINATION_DEBOUNCE_MS is 300", () => {
		expect(TOP_PAGINATION_DEBOUNCE_MS).toBe(300);
	});

	test("debounce timer uses TOP_PAGINATION_DEBOUNCE_MS constant", () => {
		expect(source).toContain("TOP_PAGINATION_DEBOUNCE_MS");
	});

	test("topPaginationTimerRef is declared", () => {
		expect(source).toContain("topPaginationTimerRef");
	});

	test("debounce timer is created with setTimeout", () => {
		expect(source).toContain("topPaginationTimerRef.current = setTimeout");
	});

	test("timer is cancelled when scrolling away from trigger zone", () => {
		expect(source).toContain("clearTimeout(topPaginationTimerRef.current)");
	});

	test("re-checks scroll position inside debounce callback before triggering", () => {
		// The debounce callback should re-verify the scroll position
		expect(source).toContain("vp.scrollTop <= 32 && !topPaginationTriggeredRef.current");
	});

	test("timer is cleared on chat change", () => {
		// The chat change effect should clear the timer
		const chatEffectMatch = source.match(
			/useEffect\(\(\) => \{[\s\S]*?clearTimeout\(topPaginationTimerRef\.current\)[\s\S]*?\}, \[chat\?\.id\]\)/,
		);
		expect(chatEffectMatch).not.toBeNull();
	});

	test("timer is cleared when loading/messages/mode changes", () => {
		// The dependency change effect should also clear the timer
		const depEffectMatch = source.match(
			/useEffect\(\(\) => \{[\s\S]*?clearTimeout\(topPaginationTimerRef\.current\)[\s\S]*?\}, \[loading, messageWindowMode, messages\]\)/,
		);
		expect(depEffectMatch).not.toBeNull();
	});
});
