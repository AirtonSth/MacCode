/* eslint-disable import/no-unresolved, functional/immutable-data */
import { expect, test } from "bun:test";

import type { ServerWsEvent } from "./protocol";
import { createTerminalSessionController, type TerminalSessionControllerDependencies } from "./terminal-session-controller";

const createDependencies = () => {
	const calls: { chatId: string; kind: keyof TerminalSessionControllerDependencies }[] = [];
	const dependencies: TerminalSessionControllerDependencies = {
		join: (chatId) => {
			calls.push({ chatId, kind: "join" });
		},

		leave: (chatId) => {
			calls.push({ chatId, kind: "leave" });
		},

		restart: (chatId) => {
			calls.push({ chatId, kind: "restart" });
		},

		sendInput: () => undefined,
		sendResize: () => undefined,
		sendSignal: () => undefined,
	};

	return { calls, dependencies };
};

const exitedSnapshot = (chatId: string): ServerWsEvent => ({
	data: {
		chatId,
		cols: 120,
		cwd: "/tmp/workspace",
		exitCode: 0,
		exitedAt: "2026-03-21T11:18:09.000Z",
		rows: 30,
		seq: 4,
		sessionId: "session-exited",
		shell: "/bin/zsh",
		snapshot: "last prompt",
		startedAt: "2026-03-21T11:17:09.000Z",
		status: "exited",
	},

	event: "terminal_session_snapshot",
});

test("terminal session controller restarts instead of joining when reopening an exited chat", () => {
	const { calls, dependencies } = createDependencies();
	const controller = createTerminalSessionController(() => dependencies);

	controller.applyServerEvent(exitedSnapshot("chat-1"));
	controller.setOpen("chat-1", true, { cols: 140, rows: 40 });

	expect(calls).toEqual([{ chatId: "chat-1", kind: "restart" }]);
	expect(controller.getState().chats["chat-1"]).toMatchObject({
		isOpen: true,
		status: "joining",
	});
});

test("terminal session controller join() restarts exited chats", () => {
	const { calls, dependencies } = createDependencies();
	const controller = createTerminalSessionController(() => dependencies);

	controller.applyServerEvent(exitedSnapshot("chat-2"));
	controller.join("chat-2", { cols: 100, rows: 24 });

	expect(calls).toEqual([{ chatId: "chat-2", kind: "restart" }]);
	expect(controller.getState().chats["chat-2"]).toMatchObject({
		isOpen: true,
		status: "joining",
	});
});

test("terminal session controller accumulates consecutive output chunks for the same session", () => {
	const { dependencies } = createDependencies();
	const controller = createTerminalSessionController(() => dependencies);

	controller.applyServerEvent({
		data: {
			chatId: "chat-3",
			cols: 120,
			cwd: "/tmp/workspace",
			exitCode: null,
			exitedAt: null,
			rows: 30,
			seq: 2,
			sessionId: "session-running",
			shell: "/bin/zsh",
			snapshot: "prompt> ",
			startedAt: "2026-03-21T11:17:09.000Z",
			status: "running",
		},

		event: "terminal_session_snapshot",
	});

	controller.applyServerEvent({
		data: {
			chatId: "chat-3",
			data: "pwd\r\n",
			seq: 3,
			sessionId: "session-running",
		},

		event: "terminal_output",
	});
	controller.applyServerEvent({
		data: {
			chatId: "chat-3",
			data: "/tmp/workspace\r\n",
			seq: 4,
			sessionId: "session-running",
		},

		event: "terminal_output",
	});

	expect(controller.getState().chats["chat-3"]?.lastOutput).toEqual({
		data: "pwd\r\n/tmp/workspace\r\n",
		id: "session-running:4",
		seq: 4,
		sessionId: "session-running",
	});
});
