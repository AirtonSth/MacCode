// eslint-disable-next-line import/no-unresolved -- bun:test is a Bun built-in
import { describe, expect, test } from "bun:test";

import { buildActiveThreadPressActions } from "./active-threads-screen.model";

describe("buildActiveThreadPressActions", () => {
	const thread = { id: "chat-abc", projectId: "project-xyz" };

	test("must NOT call selectProjectById — it clears selectedChatId and persists null, causing a race condition with the subsequent selectChatById mutation", () => {
		const actions = buildActiveThreadPressActions(thread);
		const actionTypes = actions.map((action) => action.type);

		expect(actionTypes).not.toContain("selectProjectById");
	});

	test("must call selectChatById with both chatId and projectId so the project is set atomically with the chat", () => {
		const actions = buildActiveThreadPressActions(thread);
		const selectChatAction = actions.find(
			(action) => action.type === "selectChatById",
		);

		expect(selectChatAction).toBeDefined();
		expect(selectChatAction!.payload).toEqual({
			chatId: "chat-abc",
			projectId: "project-xyz",
		});
	});

	test("must push /chat with source: 'thread-list' so the chat screen redirect guard does not kick the user back to threads during the brief null selectedChatId window", () => {
		const actions = buildActiveThreadPressActions(thread);
		const pushAction = actions.find((action) => action.type === "push");

		expect(pushAction).toBeDefined();
		expect(pushAction!.payload).toEqual({
			pathname: "/chat",
			params: { source: "thread-list" },
		});
	});
});
