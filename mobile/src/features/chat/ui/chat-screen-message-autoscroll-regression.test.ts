/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const source = readFileSync(resolve(__dirname, "chat-screen.tsx"), "utf8");

describe("[M-53] chat screen keeps the mobile transcript pinned during agent streaming", () => {
	it("re-subscribes the auto-scroll effect to every streamingText update", () => {
		expect(source).toContain("}, [isViewingOlderMessages, messages, streamingText, streamingTurn]);");
	});

	it("re-scrolls after layout updates by wiring onContentSizeChange", () => {
		expect(source).toContain("onContentSizeChange={handleMessageContentSizeChange}");
	});
});
