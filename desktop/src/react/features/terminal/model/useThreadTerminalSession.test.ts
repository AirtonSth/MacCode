import { expect, test } from "bun:test";

import { createThreadTerminalSessionController } from "./useThreadTerminalSession";

test("thread terminal controller loads history, executes commands, and avoids duplication after reopen", async () => {
	const loadCalls: Array<{ chatId: string; cursor?: number; limit?: number }> = [];
	const executeCalls: Array<{ chatId: string; command: string; timeoutMs?: number }> = [];
	let historyCall = 0;

	const controller = createThreadTerminalSessionController(() => ({
		historyLimit: 1000,
		execCommand: async (chatId, input) => {
			executeCalls.push({ chatId, command: input.command, timeoutMs: input.timeoutMs });
			return {
				command: {
					id: "1700000000000-b",
					chatId,
					command: input.command,
					cwd: "/tmp/workspace",
					shell: "/bin/zsh",
					status: "completed",
					exitCode: 0,
					durationMs: 4,
					startedAt: "2026-01-01T00:00:01.000Z",
					finishedAt: "2026-01-01T00:00:01.004Z",
				},
				entries: [
					{
						id: 2,
						commandId: "1700000000000-b",
						chatId,
						stream: "stdout",
						data: "ok\n",
						createdAt: "2026-01-01T00:00:01.003Z",
					},
				],
			};
		},
		getHistory: async (chatId, options) => {
			loadCalls.push({ chatId, cursor: options?.cursor, limit: options?.limit });
			historyCall += 1;

			if (historyCall === 1) {
				return {
					commands: [
						{
							id: "1700000000000-a",
							chatId,
							command: "pwd",
							cwd: "/tmp/workspace",
							shell: "/bin/zsh",
							status: "completed",
							exitCode: 0,
							durationMs: 3,
							startedAt: "2026-01-01T00:00:00.000Z",
							finishedAt: "2026-01-01T00:00:00.003Z",
						},
					],
					entries: [
						{
							id: 1,
							commandId: "1700000000000-a",
							chatId,
							stream: "stdout",
							data: "/tmp/workspace\n",
							createdAt: "2026-01-01T00:00:00.002Z",
						},
					],
				};
			}

			return {
				commands: [
					{
						id: "1700000000000-a",
						chatId,
						command: "pwd",
						cwd: "/tmp/workspace",
						shell: "/bin/zsh",
						status: "completed",
						exitCode: 0,
						durationMs: 3,
						startedAt: "2026-01-01T00:00:00.000Z",
						finishedAt: "2026-01-01T00:00:00.003Z",
					},
					{
						id: "1700000000000-b",
						chatId,
						command: "echo ok",
						cwd: "/tmp/workspace",
						shell: "/bin/zsh",
						status: "completed",
						exitCode: 0,
						durationMs: 4,
						startedAt: "2026-01-01T00:00:01.000Z",
						finishedAt: "2026-01-01T00:00:01.004Z",
					},
				],
				entries: [
					{
						id: 2,
						commandId: "1700000000000-b",
						chatId,
						stream: "stdout",
						data: "ok\n",
						createdAt: "2026-01-01T00:00:01.003Z",
					},
				],
			};
		},
	}));

	controller.setOpen("chat-1", true);
	await controller.syncHistory("chat-1");

	let state = controller.getState().chats["chat-1"];
	expect(state?.isOpen).toBe(true);
	expect(state?.cursor).toBe(1);
	expect(state?.items.map((item) => item.text)).toEqual(["$ pwd", "/tmp/workspace\n"]);

	await controller.runCommand("chat-1", "echo ok");

	state = controller.getState().chats["chat-1"];
	expect(state?.isExecuting).toBe(false);
	expect(state?.items.map((item) => item.text)).toEqual(["$ pwd", "/tmp/workspace\n", "$ echo ok", "ok\n"]);

	controller.setOpen("chat-1", false);
	controller.setOpen("chat-1", true);
	await controller.syncHistory("chat-1");

	state = controller.getState().chats["chat-1"];
	expect(state?.items.map((item) => item.text)).toEqual(["$ pwd", "/tmp/workspace\n", "$ echo ok", "ok\n"]);
	expect(loadCalls).toEqual([
		{ chatId: "chat-1", cursor: undefined, limit: 1000 },
		{ chatId: "chat-1", cursor: 2, limit: 1000 },
	]);
	expect(executeCalls).toEqual([{ chatId: "chat-1", command: "echo ok", timeoutMs: undefined }]);
});

test("thread terminal controller captures execution and history errors", async () => {
	const errors: string[] = [];
	let runCount = 0;
	const controller = createThreadTerminalSessionController(() => ({
		execCommand: async () => {
			runCount += 1;
			throw new Error("exec failed");
		},
		getHistory: async () => {
			throw new Error("history failed");
		},
		onError: (message) => {
			errors.push(message);
		},
	}));

	await controller.syncHistory("chat-2");
	await controller.runCommand("chat-2", "echo nope");

	const state = controller.getState().chats["chat-2"];
	expect(state?.error).toBe("exec failed");
	expect(state?.isExecuting).toBe(false);
	expect(runCount).toBe(1);
	expect(errors).toEqual(["history failed", "exec failed"]);
});
