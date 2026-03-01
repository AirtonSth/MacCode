import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { initializeDatabaseSchema } from "../../shared/db/db.bootstrap";
import { createDatabaseClient } from "../../shared/db/db.client";
import { createChatRepository } from "../chat/chat.repository";
import { createProjectRepository } from "../project/project.repository";
import { TerminalRepository } from "./terminal.repository";

test("TerminalRepository persists command and lists entries in ascending order", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-terminal-repository-order-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);

		const projectRepository = createProjectRepository(client.orm);
		const chatRepository = createChatRepository(client.orm);
		const terminalRepository = new TerminalRepository(client.orm);
		const project = await projectRepository.createProject("/tmp/terminal-order", "Terminal order");
		const chat = await chatRepository.createChat(project.id, "Terminal order chat");

		const command = terminalRepository.createCommand({
			chatId: chat.id,
			command: "echo first",
			cwd: project.path,
			shell: "/bin/zsh",
		});

		const stdoutEntry = terminalRepository.appendEntry(command.id, chat.id, "stdout", "first\n");
		const stderrEntry = terminalRepository.appendEntry(command.id, chat.id, "stderr", "warn\n");

		const entries = terminalRepository.listEntriesByChatId(chat.id);
		expect(entries).toHaveLength(2);
		expect(entries[0]).toMatchObject({ id: stdoutEntry.id, stream: "stdout" });
		expect(entries[1]).toMatchObject({ id: stderrEntry.id, stream: "stderr" });

		const commands = terminalRepository.listCommandsByChatId(chat.id);
		expect(commands).toHaveLength(1);
		expect(commands[0]?.id).toBe(command.id);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("TerminalRepository lists entries using id cursor and bounded limit", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-terminal-repository-cursor-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);

		const projectRepository = createProjectRepository(client.orm);
		const chatRepository = createChatRepository(client.orm);
		const terminalRepository = new TerminalRepository(client.orm);
		const project = await projectRepository.createProject("/tmp/terminal-cursor", "Terminal cursor");
		const chat = await chatRepository.createChat(project.id, "Terminal cursor chat");

		const command = terminalRepository.createCommand({
			chatId: chat.id,
			command: "printf one two three",
			cwd: project.path,
			shell: "/bin/zsh",
		});

		const first = terminalRepository.appendEntry(command.id, chat.id, "stdout", "one\n");
		const second = terminalRepository.appendEntry(command.id, chat.id, "stdout", "two\n");
		const third = terminalRepository.appendEntry(command.id, chat.id, "stdout", "three\n");

		const cursorEntries = terminalRepository.listEntriesByChatId(chat.id, {
			cursor: first.id,
			limit: 2,
		});

		expect(cursorEntries).toHaveLength(2);
		expect(cursorEntries[0]?.id).toBe(second.id);
		expect(cursorEntries[1]?.id).toBe(third.id);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("TerminalRepository updates command final status", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-terminal-repository-status-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);

		const projectRepository = createProjectRepository(client.orm);
		const chatRepository = createChatRepository(client.orm);
		const terminalRepository = new TerminalRepository(client.orm);
		const project = await projectRepository.createProject("/tmp/terminal-status", "Terminal status");
		const chat = await chatRepository.createChat(project.id, "Terminal status chat");

		const command = terminalRepository.createCommand({
			chatId: chat.id,
			command: "false",
			cwd: project.path,
			shell: "/bin/zsh",
		});

		const finalized = terminalRepository.setCommandResult(command.id, {
			durationMs: 18,
			exitCode: 1,
			finishedAt: "2026-01-01T00:00:00.018Z",
			status: "failed",
		});

		expect(finalized?.status).toBe("failed");
		expect(finalized?.exitCode).toBe(1);
		expect(finalized?.durationMs).toBe(18);
		expect(finalized?.finishedAt).toBe("2026-01-01T00:00:00.018Z");
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
