import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { initializeDatabaseSchema } from "../../shared/db/db.bootstrap";
import { createDatabaseClient } from "../../shared/db/db.client";
import type { ServerWsEvent } from "../../types";
import type { CodexProviderRunnerContract } from "../provider/codex-provider-runner";
import { createChatRepository } from "../chat/chat.repository";
import { createMessageRepository } from "../message/message.repository";
import { createProjectRepository } from "../project/project.repository";
import { WsService } from "./ws.service";

type ServerEvent = ServerWsEvent;

test("WsService runs streaming flow with codex runner and persists assistant message", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-ws-service-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);

		const projectRepository = createProjectRepository(client.orm);
		const chatRepository = createChatRepository(client.orm);
		const messageRepository = createMessageRepository(client.orm);
		const runner = {
			run: async ({
				onDelta,
			}: {
				onDelta: (delta: string) => void;
			}) => {
				onDelta("Codex is thinking...\n");
				onDelta("Final answer");
				return {
					assistantText: "Final answer",
					diffAdded: 12,
					diffRemoved: 0,
					status: "completed" as const,
					threadId: "thread-integration-1",
				};
			},
		} as CodexProviderRunnerContract;
		const service = new WsService(chatRepository, messageRepository, projectRepository, runner);

		const project = projectRepository.createProject("/tmp", "tmp");
		const chat = chatRepository.createChat(project.id, "stream");
		const events: ServerEvent[] = [];

		await service.startUserMessage({
			chatId: chat.id,
			emit: (event) => {
				if (typeof event === "object" && typeof event.event === "string") {
					events.push(event);
				}
			},
			text: "hello",
		});

		expect(events.some((event) => event.event === "chat_updated" && event.data.status === "running")).toBe(
			true,
		);
		expect(events.some((event) => event.event === "assistant_delta")).toBe(true);
		expect(events.some((event) => event.event === "assistant_done")).toBe(true);
		expect(events.some((event) => event.event === "chat_updated" && event.data.status === "completed")).toBe(
			true,
		);

		const updated = chatRepository.findChatById(chat.id);
		expect(updated?.status).toBe("completed");
		expect(updated?.diffAdded).toBe(12);
		expect(chatRepository.findProviderThreadIdByChatId(chat.id)).toBe("thread-integration-1");

		const messages = messageRepository.listMessagesByChatId(chat.id).messages;
		expect(messages).toHaveLength(2);
		expect(messages[0].role).toBe("user");
		expect(messages[1].role).toBe("assistant");
		expect(messages[1].content).toBe("Final answer");
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("WsService.startUserMessage emits legacy_chat_provider for fake chat", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-ws-service-legacy-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);

		const projectRepository = createProjectRepository(client.orm);
		const chatRepository = createChatRepository(client.orm);
		const messageRepository = createMessageRepository(client.orm);
		const service = new WsService(
			chatRepository,
			messageRepository,
			projectRepository,
			{
				run: async () => ({
					assistantText: "unexpected",
					diffAdded: 0,
					diffRemoved: 0,
					status: "completed" as const,
				}),
			},
		);

		const project = projectRepository.createProject("/tmp/ws-legacy", "tmp");
		const createdChat = chatRepository.createChat(project.id, "legacy");
		client.sqlite
			.prepare("UPDATE chats SET provider = 'fake' WHERE id = ?")
			.run(createdChat.id);

		const events: ServerEvent[] = [];
		await service.startUserMessage({
			chatId: createdChat.id,
			emit: (event) => {
				if (typeof event === "object" && typeof event.event === "string") {
					events.push(event);
				}
			},
			text: "hello",
		});

		expect(events).toEqual([
			{
				data: {
					chatId: createdChat.id,
					code: "legacy_chat_provider",
					message:
						"legacy fake-provider chats are read-only. create a new codex chat to send messages",
				},
				event: "error",
			},
		]);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("WsService.startUserMessage reuses persisted provider thread id across turns", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-ws-service-thread-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);

		const projectRepository = createProjectRepository(client.orm);
		const chatRepository = createChatRepository(client.orm);
		const messageRepository = createMessageRepository(client.orm);

		const runCalls: Array<{ threadId?: string; workspacePath: string }> = [];
		let threadSequence = 0;
		const memoryByThread = new Map<string, string>();

		const runner = {
			run: async ({
				onDelta,
				text,
				threadId,
				workspacePath,
			}: {
				onDelta: (delta: string) => void;
				text: string;
				threadId?: string;
				workspacePath: string;
			}) => {
				runCalls.push({
					threadId,
					workspacePath,
				});

				const activeThreadId = threadId ?? `thread-memory-${++threadSequence}`;
				if (text.startsWith("Remember token: ")) {
					const token = text.replace("Remember token: ", "").trim();
					memoryByThread.set(activeThreadId, token);
					onDelta(`stored ${token}`);
					return {
						assistantText: `stored ${token}`,
						diffAdded: 0,
						diffRemoved: 0,
						status: "completed" as const,
						threadId: activeThreadId,
					};
				}

				const remembered = memoryByThread.get(activeThreadId) ?? "NO_MEMORY";
				onDelta(remembered);
				return {
					assistantText: remembered,
					diffAdded: 0,
					diffRemoved: 0,
					status: "completed" as const,
					threadId: activeThreadId,
				};
			},
		} as CodexProviderRunnerContract;

		const service = new WsService(chatRepository, messageRepository, projectRepository, runner);

		const project = projectRepository.createProject("/tmp/ws-thread", "tmp");
		const chat = chatRepository.createChat(project.id, "thread");
		const token = `memory-${Date.now()}`;

		await service.startUserMessage({
			chatId: chat.id,
			emit: () => {
				// no-op
			},
			text: `Remember token: ${token}`,
		});

		const persistedThreadId = chatRepository.findProviderThreadIdByChatId(chat.id);
		expect(persistedThreadId).toBe("thread-memory-1");

		await service.startUserMessage({
			chatId: chat.id,
			emit: () => {
				// no-op
			},
			text: "What token should you remember? Reply token only.",
		});

		expect(runCalls).toEqual([
			{
				threadId: undefined,
				workspacePath: project.path,
			},
			{
				threadId: "thread-memory-1",
				workspacePath: project.path,
			},
		]);

		const messages = messageRepository.listMessagesByChatId(chat.id).messages;
		expect(messages).toHaveLength(4);
		expect(messages[3].role).toBe("assistant");
		expect(messages[3].content).toBe(token);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
