/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const source = readFileSync(resolve(__dirname, "chat-screen.tsx"), "utf8");

describe("[M-53] mobile terminal mirrors the desktop toggle flow", () => {
	it("derives terminal visibility from the shared terminal session state", () => {
		expect(source).toContain("const isTerminalOpen = Boolean(terminalSession?.isOpen);");
		expect(source).toContain('const isTerminalActive = terminalSession?.status === "running";');
	});

	it("toggles the terminal through the shared controller instead of opening a modal", () => {
		expect(source).toContain("setTerminalOpen(selectedChatId, !isTerminalOpen);");
		expect(source).toContain("Keyboard.dismiss();");
		expect(source).not.toContain("<TerminalOverlay");
	});

	it("renders the terminal inline and exposes an active badge on the toolbar icon", () => {
		expect(source).toContain('testID="terminal-inline-panel"');
		expect(source).toContain('testID="chat-terminal-active-badge"');
	});
});
