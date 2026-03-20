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
		expect(source).toContain("!userScrolledUpRef.current");
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

	test("trigger guard resets when the user scrolls away from the top", () => {
		expect(source).toContain("topPaginationTriggeredRef.current = false;");
		expect(source).toContain("} else if (viewport.scrollTop > 32) {");
	});
});

// ---------------------------------------------------------------------------
// D-40: "Newer messages" badge disappears with fade animation
// ---------------------------------------------------------------------------
describe("D-40: newer messages badge fade animation", () => {
	test("AnimatePresence wraps the newer-messages badge", () => {
		const badgeBlock = source.match(
			/<AnimatePresence>[\s\S]*?newer-messages-badge[\s\S]*?<\/AnimatePresence>/,
		);
		expect(badgeBlock).not.toBeNull();
	});

	test("badge uses motion.span for animation", () => {
		const motionBadge = source.match(
			/<motion\.span[\s\S]*?key="newer-messages-badge"/,
		);
		expect(motionBadge).not.toBeNull();
	});

	test("badge has exit opacity animation", () => {
		const badgeBlock = source.match(
			/<motion\.span[\s\S]*?newer-messages-badge[\s\S]*?\/>/s,
		);
		expect(badgeBlock).not.toBeNull();
		expect(badgeBlock![0]).toContain("exit={{ opacity: 0 }}");
	});

	test("badge has initial opacity of 0", () => {
		const badgeBlock = source.match(
			/<motion\.span[\s\S]*?newer-messages-badge[\s\S]*?\/>/s,
		);
		expect(badgeBlock).not.toBeNull();
		expect(badgeBlock![0]).toContain("initial={{ opacity: 0 }}");
	});

	test("badge preserves data-testid for testing", () => {
		expect(source).toContain('data-testid="conversation-latest-dirty-indicator"');
	});
});

// ---------------------------------------------------------------------------
// D-41: Scroll-to-bottom button appears/disappears with animation
// ---------------------------------------------------------------------------
describe("D-41: scroll-to-bottom button animation", () => {
	test("AnimatePresence wraps the scroll-to-bottom button", () => {
		const fabBlock = source.match(
			/<AnimatePresence>[\s\S]*?scroll-to-bottom-fab[\s\S]*?<\/AnimatePresence>/,
		);
		expect(fabBlock).not.toBeNull();
	});

	test("button uses motion.button for animation", () => {
		const motionButton = source.match(
			/<motion\.button[\s\S]*?key="scroll-to-bottom-fab"/,
		);
		expect(motionButton).not.toBeNull();
	});

	test("button has scale and opacity in exit animation", () => {
		const fabBlock = source.match(
			/<motion\.button[\s\S]*?scroll-to-bottom-fab[\s\S]*?<\/motion\.button>/s,
		);
		expect(fabBlock).not.toBeNull();
		expect(fabBlock![0]).toContain("exit={{ opacity: 0, scale: 0.8 }}");
	});

	test("button has scale and opacity in initial state", () => {
		const fabBlock = source.match(
			/<motion\.button[\s\S]*?scroll-to-bottom-fab[\s\S]*?<\/motion\.button>/s,
		);
		expect(fabBlock).not.toBeNull();
		expect(fabBlock![0]).toContain("initial={{ opacity: 0, scale: 0.8 }}");
	});

	test("button animates to full opacity and scale", () => {
		const fabBlock = source.match(
			/<motion\.button[\s\S]*?scroll-to-bottom-fab[\s\S]*?<\/motion\.button>/s,
		);
		expect(fabBlock).not.toBeNull();
		expect(fabBlock![0]).toContain("animate={{ opacity: 1, scale: 1 }}");
	});

	test("button preserves scroll-to-latest aria-label", () => {
		expect(source).toContain('aria-label="Scroll to latest message"');
	});
});

describe("[D-45] Copy button timer cleanup", () => {
	test("tracks the reset timer in a ref", () => {
		expect(source).toContain("const resetCopiedTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)");
	});

	test("clears the timer on unmount", () => {
		const cleanupMatch = source.match(
			/useEffect\(\(\) => \{\s*return \(\) => \{\s*if \(resetCopiedTimerRef\.current\) \{\s*clearTimeout\(resetCopiedTimerRef\.current\);[\s\S]*?\}\s*\};\s*\}, \[\]\);/,
		);
		expect(cleanupMatch).not.toBeNull();
	});
});

describe("[D-52/D-53/D-55] content polish", () => {
	test("uses the same leading-6 line-height in focus and normal markdown paragraphs", () => {
		expect(source).toContain('const messageTextClass = focusMode ? "text-[15px] leading-6" : "text-sm leading-6"');
	});

	test("aligns table headers to the top", () => {
		expect(source).toContain('className="align-top border-b border-white/20 px-2 py-1 text-left text-xs font-semibold"');
	});

	test("uses mirror repeat type for the streaming activity dot", () => {
		expect(source).toContain('repeatType: "mirror"');
	});
});

describe("[D-63/D-64] resilient conversation hydration", () => {
	test("only renders the loading skeleton when there is no visible content yet", () => {
		expect(source).toContain("const showLoadingSkeleton = loading && !hasContent;");
		expect(source).toContain("{showLoadingSkeleton ? (");
	});

	test("treats historical run details as real content", () => {
		expect(source).toContain("const hasContent = hasMessages || hasStreaming || hasHistoricalRunDetails || isWorking;");
	});

	test("forces historical turn details open when they are the only content", () => {
		expect(source).toContain("const shouldForceRunDetails = !hasMessages && !hasStreaming && hasHistoricalRunDetails;");
		expect(source).toContain("const showHistoricalTurns = showRunDetails || shouldForceRunDetails;");
	});

	test("merges messages and historical turns chronologically", () => {
		expect(source).toContain("const mergedItems = useMemo(");
		expect(source).toContain("items.sort((a, b) => a.sortMs - b.sortMs)");
		expect(source).toContain("mergedItems.map(");
	});
});
