/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const source = readFileSync(resolve(__dirname, "use-workspace-shell.ts"), "utf8");

describe("[M-42] self-originated message_created workspace events still update the open thread", () => {
	it("ignores self-originated workspace events except message_created", () => {
		expect(source).toContain('const shouldIgnoreWorkspaceEvent =');
		expect(source).toContain('isSelfOriginatedWorkspaceEvent && event.data.type !== "message_created"');
	});

	it("still handles the message_created branch after the self-origin check", () => {
		const workspaceEventBlock = /if \(event\.event === "workspace_event"\) \{[\s\S]*?case "message_created": \{[\s\S]*?appendMessageToMessagePage/.exec(
			source,
		);
		expect(workspaceEventBlock).not.toBeNull();
	});
});
