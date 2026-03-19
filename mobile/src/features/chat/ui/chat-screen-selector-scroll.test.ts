/* eslint-disable import/no-unresolved */
import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

/**
 * [M-36] Tests that scrollToEnd calls triggered by keyboard show/hide
 * use `animated: true` for smooth scroll transitions.
 *
 * Previously, the selector bar scroll used `animated: false` when the
 * keyboard was hidden, causing an abrupt visual jump. The fix changes
 * these calls to `animated: true` so the transition is smooth.
 *
 * The exception is initial load / chat switch where `animated: false`
 * is acceptable to avoid a slow scroll on first render.
 */

const chatScreenSource = readFileSync(
	resolve(__dirname, "chat-screen.tsx"),
	"utf8",
);

/**
 * Extracts all scrollToEnd calls from the source, returning each call
 * along with its surrounding context to determine the trigger.
 */
const extractScrollToEndCalls = (source: string): { line: number; text: string; animated: boolean }[] => {
	const lines = source.split("\n");
	const results: { line: number; text: string; animated: boolean }[] = [];
	let i = 0;
	for (const line of lines) {
		if (line.includes("scrollToEnd(")) {
			const animated = line.includes("animated: true");
			results.push({ line: i + 1, text: line.trim(), animated });
		}
		i += 1;
	}
	return results;
};

describe("[M-36] selector bar scrollToEnd uses animated: true on keyboard hide", () => {
	it("selectorsScrollRef.scrollToEnd uses animated: true", () => {
		const calls = extractScrollToEndCalls(chatScreenSource);
		const selectorCalls = calls.filter((c) => c.text.includes("selectorsScrollRef"));
		expect(selectorCalls.length).toBeGreaterThanOrEqual(1);
		for (const call of selectorCalls) {
			expect(call.animated).toBe(true);
		}
	});

	it("messageScrollRef.scrollToEnd uses animated: true", () => {
		const calls = extractScrollToEndCalls(chatScreenSource);
		const messageCalls = calls.filter((c) => c.text.includes("messageScrollRef"));
		expect(messageCalls.length).toBeGreaterThanOrEqual(1);
		for (const call of messageCalls) {
			expect(call.animated).toBe(true);
		}
	});

	it("does not use animated: false for selector scroll calls", () => {
		const calls = extractScrollToEndCalls(chatScreenSource);
		const selectorCalls = calls.filter((c) => c.text.includes("selectorsScrollRef"));
		const nonAnimated = selectorCalls.filter((c) => !c.animated);
		expect(nonAnimated.length).toBe(0);
	});

	it("does not use instant terminal scroll for history hydration anymore", () => {
		expect(chatScreenSource).not.toContain('shouldScrollTerminalToEndRef.current = "instant"');
	});
});
