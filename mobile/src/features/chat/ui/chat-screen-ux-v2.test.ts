/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const source = readFileSync(resolve(__dirname, "chat-screen.tsx"), "utf8");

describe("[M-44] message scroll ref updates are gated by threshold changes", () => {
	it("compares the next userScrolledUp state before writing to the ref", () => {
		expect(source).toContain("const nextUserScrolledUp = distanceFromBottom > AUTO_SCROLL_BOTTOM_THRESHOLD;");
		expect(source).toContain("if (userScrolledUpRef.current !== nextUserScrolledUp)");
	});
});

describe("[M-42] drawer open is guarded while an animation is already running", () => {
	it("returns early in openDrawer when isDrawerAnimatingRef is active", () => {
		const openDrawerBlock = /const openDrawer = \(\) => \{[\s\S]*?\n\t\};/.exec(
			source,
		);
		expect(openDrawerBlock).not.toBeNull();
		expect(openDrawerBlock![0]).toContain("if (isDrawerAnimatingRef.current) {");
		expect(openDrawerBlock![0]).toContain("return;");
	});
});

describe("[M-48] long model names truncate in the selector", () => {
	it("uses tail ellipsis on the selected model text", () => {
		expect(source).toContain('ellipsizeMode="tail"');
	});
});

describe("[M-49] composer input is only cleared after a successful send", () => {
	it("checks the send result before clearing the input", () => {
		const submitBlock = /const submit = async \(\) => \{[\s\S]*?\n\t\};/.exec(
			source,
		);
		expect(submitBlock).not.toBeNull();
		expect(submitBlock![0]).toContain("const sent = await sendMessage(text);");
		expect(submitBlock![0]).toContain("if (sent) {");
		expect(submitBlock![0]).toContain("setInput(\"\");");
	});
});

describe("[M-50] terminal re-scrolls on keyboard show and hide", () => {
	it("schedules a terminal scroll on keyboard visibility changes", () => {
		expect(source).toContain("const scheduleTerminalKeyboardScroll = () => {");
		expect(source).toContain("terminalScrollRef.current?.scrollToEnd({ animated: true });");
	});
});
