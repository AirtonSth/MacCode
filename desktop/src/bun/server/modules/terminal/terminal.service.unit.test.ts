import { expect, test } from "bun:test";

import type { ChatDTO, TerminalCommandDTO, TerminalEntryDTO } from "../../types";
import { TerminalService, sanitizeTerminalOutput } from "./terminal.service";

const createChat = (overrides: Partial<ChatDTO> = {}): ChatDTO => ({
	diffAdded: 0,
	diffRemoved: 0,
	id: "chat-id",
	isActive: false,
	projectId: "project-id",
	provider: "codex",
	status: "pending",
	title: "chat",
	updatedAt: "2026-01-01T00:00:00.000Z",
	...overrides,
});

const createInMemoryTerminalRepository = () => {
	const commands = new Map<string, TerminalCommandDTO>();
	const entries: TerminalEntryDTO[] = [];
	let commandCount = 0;
	let entryCount = 0;

	return {
		appendEntries: (commandId: string, chatId: string, stream: "stdout" | "stderr", data: string) => {
			if (!data) {
				return [];
			}

			entryCount += 1;
			const entry: TerminalEntryDTO = {
				chatId,
				commandId,
				createdAt: `2026-01-01T00:00:${String(entryCount).padStart(2, "0")}.000Z`,
				data,
				id: entryCount,
				stream,
			};
			entries.push(entry);
			return [entry];
		},
		createCommand: (input: { chatId: string; command: string; cwd: string; shell: string }): TerminalCommandDTO => {
			commandCount += 1;
			const startedAt = `2026-01-01T00:00:${String(commandCount).padStart(2, "0")}.000Z`;
			const command: TerminalCommandDTO = {
				chatId: input.chatId,
				command: input.command,
				cwd: input.cwd,
				durationMs: null,
				exitCode: null,
				finishedAt: null,
				id: `cmd-${commandCount}`,
				shell: input.shell,
				startedAt,
				status: "running",
			};
			commands.set(command.id, command);
			return command;
		},
		listCommandsByChatId: (chatId: string) => {
			return [...commands.values()].filter((command) => command.chatId === chatId);
		},
		listEntriesByChatId: (chatId: string) => {
			return entries.filter((entry) => entry.chatId === chatId);
		},
		setCommandResult: (
			commandId: string,
			result: { durationMs: number; exitCode: number | null; finishedAt: string; status: "completed" | "failed" | "timeout" },
		) => {
			const existing = commands.get(commandId);
			if (!existing) {
				return null;
			}

			const updated: TerminalCommandDTO = {
				...existing,
				durationMs: result.durationMs,
				exitCode: result.exitCode,
				finishedAt: result.finishedAt,
				status: result.status,
			};
			commands.set(commandId, updated);
			return updated;
		},
		state: {
			commands,
			entries,
		},
	};
};

test("sanitizeTerminalOutput removes ANSI/control noise and normalizes line breaks", () => {
	const raw = "line1\r\n\u001B[8;24;108t\u001B]0;title\u0007line2\u0000\rline3\u0007";
	const sanitized = sanitizeTerminalOutput(raw);

	expect(sanitized).toBe("line1\nline2\nline3");
});

test("TerminalService.getHistoryByChatId returns chatExists=false when chat is missing", async () => {
	const terminalRepository = createInMemoryTerminalRepository();
	const service = new TerminalService(
		{
			findChatById: () => null,
		} as never,
		{
			findProjectById: () => null,
		} as never,
		terminalRepository as never,
		async () => ({ exitCode: 0, status: "completed", stderr: "", stdout: "" }),
	);

	const result = await service.getHistoryByChatId("missing-chat");
	expect(result).toEqual({
		chatExists: false,
		commands: [],
		entries: [],
	});
});

test("TerminalService execCommand persists command and stdout/stderr entries", async () => {
	const repository = createInMemoryTerminalRepository();
	const executeCalls: Array<{ command: string; cwd: string; shell: string; timeoutMs: number }> = [];

	const service = new TerminalService(
		{
			findChatById: () => createChat(),
		} as never,
		{
			findProjectById: () => ({
				createdAt: "",
				id: "project-id",
				isFavorite: false,
				name: "project",
				path: "/tmp/workspace-terminal",
				updatedAt: "",
			}),
		} as never,
		repository as never,
		async (input) => {
			executeCalls.push(input);
			return {
				exitCode: 0,
				status: "completed",
				stderr: "warn\n",
				stdout: "hello\n",
			};
		},
	);

	const result = await service.execCommand({
		chatId: "chat-id",
		command: "echo hello",
	});

	expect(result.chatExists).toBe(true);
	expect(result.projectExists).toBe(true);
	expect(result.command?.status).toBe("completed");
	expect(result.command?.exitCode).toBe(0);
	expect(result.entries.map((entry) => entry.stream)).toEqual(["stdout", "stderr"]);
	expect(result.entries.map((entry) => entry.data)).toEqual(["hello\n", "warn\n"]);
	expect(executeCalls).toEqual([
		{
			command: "echo hello",
			cwd: "/tmp/workspace-terminal",
			shell: expect.any(String),
			timeoutMs: 30_000,
		},
	]);
});

test("TerminalService execCommand stores timeout status and null exit code", async () => {
	const repository = createInMemoryTerminalRepository();
	const service = new TerminalService(
		{
			findChatById: () => createChat(),
		} as never,
		{
			findProjectById: () => ({
				createdAt: "",
				id: "project-id",
				isFavorite: false,
				name: "project",
				path: "/tmp/workspace-terminal",
				updatedAt: "",
			}),
		} as never,
		repository as never,
		async () => ({
			exitCode: null,
			status: "timeout",
			stderr: "[output truncated]\n",
			stdout: "",
		}),
	);

	const result = await service.execCommand({
		chatId: "chat-id",
		command: "sleep 60",
		timeoutMs: 5000,
	});

	expect(result.command?.status).toBe("timeout");
	expect(result.command?.exitCode).toBeNull();
	expect(result.entries).toHaveLength(1);
	expect(result.entries[0]?.stream).toBe("stderr");
});

test("TerminalService execCommand reports missing project and does not execute", async () => {
	const repository = createInMemoryTerminalRepository();
	let executeCalled = false;
	const service = new TerminalService(
		{
			findChatById: () => createChat(),
		} as never,
		{
			findProjectById: () => null,
		} as never,
		repository as never,
		async () => {
			executeCalled = true;
			return {
				exitCode: 0,
				status: "completed",
				stderr: "",
				stdout: "",
			};
		},
	);

	const result = await service.execCommand({
		chatId: "chat-id",
		command: "pwd",
	});

	expect(result).toEqual({
		chatExists: true,
		command: null,
		entries: [],
		projectExists: false,
	});
	expect(executeCalled).toBe(false);
});
