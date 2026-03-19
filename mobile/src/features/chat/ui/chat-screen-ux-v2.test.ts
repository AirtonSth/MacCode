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
	it("checks the send result before clearing the input inside ChatComposer", () => {
		const submitBlock = /const handleSubmit = useCallback\(async \(\) => \{[\s\S]*?\n\t\}, \[input, onSend\]\);/.exec(
			source,
		);
		expect(submitBlock).not.toBeNull();
		expect(submitBlock![0]).toContain("const sent = await onSend(text);");
		expect(submitBlock![0]).toContain("if (sent) {");
		expect(submitBlock![0]).toContain("setInput(\"\");");
	});
});

describe("[M-52] composer input state is isolated from the chat screen root", () => {
	it("keeps the input state inside ChatComposer instead of ChatScreen", () => {
		expect(source).toContain("const ChatComposer = memo((");
		expect(source).toContain("const [input, setInput] = useState<string>(\"\");");

		const chatScreenBlock = /export const ChatScreen = \(\) => \{[\s\S]*$/.exec(source);
		expect(chatScreenBlock).not.toBeNull();
		expect(chatScreenBlock![0]).not.toContain("const [input, setInput] = useState<string>(\"\");");
	});
});

describe("[M-50] terminal re-scrolls on keyboard show and hide", () => {
	it("schedules a terminal scroll on keyboard visibility changes", () => {
		expect(source).toContain("const scheduleTerminalKeyboardScroll = () => {");
		expect(source).toContain("terminalScrollRef.current?.scrollToEnd({ animated: true });");
	});
});
