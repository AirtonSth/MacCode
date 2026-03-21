import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const terminalSource = readFileSync(resolve(__dirname, "ThreadTerminalPtyPanel.tsx"), "utf-8");

describe("ThreadTerminalPtyPanel", () => {
	it("keeps the keyboard textarea transparent to pointer events so xterm can receive wheel scrolling", () => {
		expect(terminalSource).toContain("pointer-events-none absolute inset-0 z-10");
	});

	it("still focuses the hidden keyboard input from terminal surface interactions", () => {
		expect(terminalSource).toContain("focusTerminal();");
		expect(terminalSource).toContain("onMouseDown={() => {");
	});
});
