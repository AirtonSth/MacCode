/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, test } from "bun:test";

// Read the raw source for structural assertions that verify the fix patterns.
const sourcePath = fileURLToPath(new URL("./ConversationPanel.tsx", import.meta.url));
const source = readFileSync(sourcePath, "utf8");

// ---------------------------------------------------------------------------
// D-37: forceScrollToBottom uses single RAF with userScrolledUpRef guard
// ---------------------------------------------------------------------------
describe("D-37: forceScrollToBottom single-RAF pattern", () => {
	test("forceScrollToBottom uses exactly one requestAnimationFrame call", () => {
		// Extract the forceScrollToBottom function body from source
		const fnStart = source.indexOf("const forceScrollToBottom = useCallback(");
		expect(fnStart).not.toBe(-1);
		const fnEnd = source.indexOf("}, [scrollToBottom, updateIsAtBottom]);");
		expect(fnEnd).not.toBe(-1);
		const fnBody = source.slice(fnStart, fnEnd);

		// Count requestAnimationFrame calls — should be exactly 1
		const rafMatches = fnBody.match(/requestAnimationFrame/g);
		expect(rafMatches).not.toBeNull();
		expect(rafMatches!.length).toBe(1);
	});

	test("RAF callback checks userScrolledUpRef before scrolling", () => {
		const fnStart = source.indexOf("const forceScrollToBottom = useCallback(");
		const fnEnd = source.indexOf("], [scrollToBottom, updateIsAtBottom]);");
		const fnBody = source.slice(fnStart, fnEnd);

		// The RAF callback should check userScrolledUpRef.current
		expect(fnBody).toContain("userScrolledUpRef.current");
	});

	test("RAF callback guards with userScrolledUpRef before hasActiveSelection", () => {
		const fnStart = source.indexOf("const forceScrollToBottom = useCallback(");
		const fnEnd = source.indexOf("], [scrollToBottom, updateIsAtBottom]);");
		const fnBody = source.slice(fnStart, fnEnd);

		// Inside the RAF, userScrolledUpRef check should come first (short-circuit)
		expect(fnBody).toContain("userScrolledUpRef.current || hasActiveSelection()");
	});

	test("forceScrollToBottom calls scrollToBottom with auto behavior", () => {
		const fnStart = source.indexOf("const forceScrollToBottom = useCallback(");
		const fnEnd = source.indexOf("], [scrollToBottom, updateIsAtBottom]);");
		const fnBody = source.slice(fnStart, fnEnd);

		expect(fnBody).toContain('scrollToBottom("auto")');
	});

	test("forceScrollToBottom is stable with scrollToBottom and updateIsAtBottom deps", () => {
		expect(source).toContain("[scrollToBottom, updateIsAtBottom]");
	});
});
