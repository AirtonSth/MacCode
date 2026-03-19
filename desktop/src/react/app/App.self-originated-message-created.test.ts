/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, test } from "bun:test";

const sourcePath = fileURLToPath(new URL("./App.tsx", import.meta.url));
const source = readFileSync(sourcePath, "utf8");

describe("D-58: self-originated message_created workspace events update the selected thread", () => {
	test("does not short-circuit the message_created branch for self-originated events", () => {
		const messageCreatedBlock = /case "message_created":[\s\S]*?case "selection_updated":/.exec(source);
		expect(messageCreatedBlock).not.toBeNull();
		expect(messageCreatedBlock?.[0]).not.toContain("if (isSelfWorkspaceEvent)");
	});

	test("message_created appends directly into the query-backed latest page", () => {
		expect(source).toContain("queryClient.setQueryData<MessagePageDTO>(");
		expect(source).toContain("queryKeys.messages(messagePayload.chatId)");
		expect(source).toContain("appendMessageToMessagePage(current, messagePayload)");
	});
});
