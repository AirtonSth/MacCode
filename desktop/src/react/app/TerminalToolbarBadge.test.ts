/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const appSource = readFileSync(resolve(__dirname, "App.tsx"), "utf-8");

describe("Desktop terminal toolbar badge", () => {
	it("derives active state from the shared terminal session status", () => {
		expect(appSource).toContain('const isTerminalActive = selectedThreadTerminal?.status === "running";');
	});

	it("renders a badge on the terminal button while the selected thread terminal is active", () => {
		expect(appSource).toContain('data-testid="desktop-terminal-active-badge"');
		expect(appSource).toContain("{isTerminalActive ? (");
	});
});
