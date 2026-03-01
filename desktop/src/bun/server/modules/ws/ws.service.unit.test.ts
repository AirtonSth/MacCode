import { expect, test } from "bun:test";

import type { ChatDTO, ServerWsEvent } from "../../types";
import type { ChatRepository } from "../chat/chat.repository";
import type { MessageRepository } from "../message/message.repository";
import type { CodexProviderRunnerContract } from "../provider/codex-provider-runner";
import type { ProjectRepository } from "../project/project.repository";
import { WsService } from "./ws.service";

const createChat = (overrides: Partial<ChatDTO> = {}): ChatDTO => ({
	diffAdded: 0,
	diffRemoved: 0,
	id: "chat-id",
	projectId: "project-id",
	provider: "codex",
	status: "pending",
	title: "Chat",
	updatedAt: new Date().toISOString(),
	...overrides,
});

const collectEvents = async (emit: (event: ServerWsEvent) => void) => {
	const events: ServerWsEvent[] = [];

	return {
		emit: (event: ServerWsEvent) => {
			events.push(event);
			emit(event);
		},
		events,
	};
};

test("WsService.startUserMessage returns chat_not_found for missing chat", async () => {
	const chatRepository = {
		findChatById: () => null,
	} as unknown as ChatRepository;

	const messageRepository = {
		createMessage: () => {
			throw new Error("should not call");
		},
	} as unknown as MessageRepository;

	const projectRepository = {
		findProjectById: () => null,
	} as unknown as ProjectRepository;

	const runner = {
		run: async () => ({
			assistantText: "never",
			diffAdded: 0,
			diffRemoved: 0,
			status: "completed" as const,
		}),
	} as CodexProviderRunnerContract;

	const service = new WsService(chatRepository, messageRepository, projectRepository, runner);
	const collector = await collectEvents(() => {});

	await service.startUserMessage({ chatId: "missing", emit: collector.emit, text: "hi" });

	expect(collector.events).toEqual([
		{
			data: {
				chatId: "missing",
				code: "chat_not_found",
				message: "chat not found",
			},
			event: "error",
		},
	]);
});

test("WsService.startUserMessage blocks legacy fake chats", async () => {
	const chatRepository = {
		findChatById: () =>
			createChat({
				provider: "fake",
			}),
	} as unknown as ChatRepository;

	const messageRepository = {
		createMessage: () => {
			throw new Error("should not call");
		},
	} as unknown as MessageRepository;

	const projectRepository = {
		findProjectById: () => ({ createdAt: "", id: "project-id", isFavorite: false, name: "p", path: "/tmp", updatedAt: "" }),
	} as unknown as ProjectRepository;

	const runner = {
		run: async () => {
			throw new Error("should not call");
		},
	} as unknown as CodexProviderRunnerContract;

	const service = new WsService(chatRepository, messageRepository, projectRepository, runner);
	const collector = await collectEvents(() => {});

	await service.startUserMessage({ chatId: "chat-id", emit: collector.emit, text: "hi" });

	expect(collector.events).toEqual([
		{
			data: {
				chatId: "chat-id",
				code: "legacy_chat_provider",
				message: "legacy fake-provider chats are read-only. create a new codex chat to send messages",
			},
			event: "error",
		},
	]);
});

test("WsService.startUserMessage blocks chat_running when already running", async () => {
	const chatRepository = {
		findChatById: () =>
			createChat({
				status: "running",
			}),
	} as unknown as ChatRepository;

	const messageRepository = {
		createMessage: () => {
			throw new Error("should not call");
		},
	} as unknown as MessageRepository;

	const projectRepository = {
		findProjectById: () => ({ createdAt: "", id: "project-id", isFavorite: false, name: "p", path: "/tmp", updatedAt: "" }),
	} as unknown as ProjectRepository;

	const runner = {
		run: async () => {
			throw new Error("should not call");
		},
	} as unknown as CodexProviderRunnerContract;

	const service = new WsService(chatRepository, messageRepository, projectRepository, runner);
	const collector = await collectEvents(() => {});

	await service.startUserMessage({ chatId: "chat-id", emit: collector.emit, text: "hi" });

	expect(collector.events).toEqual([
		{
			data: {
				chatId: "chat-id",
				code: "chat_running",
				message: "chat is already running",
			},
			event: "error",
		},
	]);
});

test("WsService.startUserMessage emits project_not_found when project does not exist", async () => {
	const chatRepository = {
		findChatById: () => createChat(),
	} as unknown as ChatRepository;

	const messageRepository = {
		createMessage: () => {
			throw new Error("should not call");
		},
	} as unknown as MessageRepository;

	const projectRepository = {
		findProjectById: () => null,
	} as unknown as ProjectRepository;

	const runner = {
		run: async () => {
			throw new Error("should not call");
		},
	} as unknown as CodexProviderRunnerContract;

	const service = new WsService(chatRepository, messageRepository, projectRepository, runner);
	const collector = await collectEvents(() => {});

	await service.startUserMessage({ chatId: "chat-id", emit: collector.emit, text: "hi" });

	expect(collector.events).toEqual([
		{
			data: {
				chatId: "chat-id",
				code: "project_not_found",
				message: "project not found",
			},
			event: "error",
		},
	]);
});

test("WsService.startUserMessage forwards explicit permission mode to codex runner", async () => {
	const chat = createChat();
	let capturedModel: string | undefined;
	let capturedPermissionMode: string | undefined;
	let capturedReasoningEffort: string | undefined;
	let findChatCalls = 0;

	const chatRepository = {
		findChatById: () => {
			findChatCalls += 1;
			if (findChatCalls === 1) {
				return chat;
			}

			return {
				...chat,
				status: "completed",
				updatedAt: new Date().toISOString(),
			};
		},
		findProviderThreadIdByChatId: () => null,
		updateChat: (_chatId: string, update: Partial<Pick<ChatDTO, "status" | "diffAdded" | "diffRemoved">>) => ({
			...chat,
			...update,
			updatedAt: new Date().toISOString(),
		}),
	} as unknown as ChatRepository;

	const messageRepository = {
		createMessage: () => ({
			chatId: chat.id,
			content: "",
			createdAt: new Date().toISOString(),
			id: crypto.randomUUID(),
			role: "assistant" as const,
		}),
	} as unknown as MessageRepository;

	const projectRepository = {
		findProjectById: () => ({ createdAt: "", id: "project-id", isFavorite: false, name: "p", path: "/tmp", updatedAt: "" }),
	} as unknown as ProjectRepository;

	const runner = {
		run: async (options: {
			model?: string;
			onDelta: (delta: string) => void;
			permissionMode?: string;
			reasoningEffort?: string;
		}) => {
			capturedModel = options.model;
			capturedPermissionMode = options.permissionMode;
			capturedReasoningEffort = options.reasoningEffort;
			options.onDelta("hello");
			return {
				assistantText: "hello",
				diffAdded: 5,
				diffRemoved: 0,
				status: "completed" as const,
			};
		},
	} as unknown as CodexProviderRunnerContract;

	const service = new WsService(chatRepository, messageRepository, projectRepository, runner);
	const collector = await collectEvents(() => {});

	await service.startUserMessage({
		chatId: "chat-id",
		emit: collector.emit,
		model: "gpt-5.3-codex",
		permissionMode: "plan",
		reasoningEffort: "xhigh",
		text: "hi",
	});

	expect(capturedModel).toBe("gpt-5.3-codex");
	expect(capturedPermissionMode).toBe("plan");
	expect(capturedReasoningEffort).toBe("xhigh");
});

test("WsService.startUserMessage defaults permission mode to default", async () => {
	const chat = createChat();
	let capturedPermissionMode: string | undefined;
	let findChatCalls = 0;

	const chatRepository = {
		findChatById: () => {
			findChatCalls += 1;
			if (findChatCalls === 1) {
				return chat;
			}

			return {
				...chat,
				status: "completed",
				updatedAt: new Date().toISOString(),
			};
		},
		findProviderThreadIdByChatId: () => null,
		updateChat: (_chatId: string, update: Partial<Pick<ChatDTO, "status" | "diffAdded" | "diffRemoved">>) => ({
			...chat,
			...update,
			updatedAt: new Date().toISOString(),
		}),
	} as unknown as ChatRepository;

	const messageRepository = {
		createMessage: () => ({
			chatId: chat.id,
			content: "",
			createdAt: new Date().toISOString(),
			id: crypto.randomUUID(),
			role: "assistant" as const,
		}),
	} as unknown as MessageRepository;

	const projectRepository = {
		findProjectById: () => ({ createdAt: "", id: "project-id", isFavorite: false, name: "p", path: "/tmp", updatedAt: "" }),
	} as unknown as ProjectRepository;

	const runner = {
		run: async (options: {
			model?: string;
			onDelta: (delta: string) => void;
			permissionMode?: string;
			reasoningEffort?: string;
		}) => {
			capturedPermissionMode = options.permissionMode;
			expect(options.model).toBeUndefined();
			expect(options.reasoningEffort).toBeUndefined();
			options.onDelta("hello");
			return {
				assistantText: "hello",
				diffAdded: 5,
				diffRemoved: 0,
				status: "completed" as const,
			};
		},
	} as unknown as CodexProviderRunnerContract;

	const service = new WsService(chatRepository, messageRepository, projectRepository, runner);
	const collector = await collectEvents(() => {});

	await service.startUserMessage({
		chatId: "chat-id",
		emit: collector.emit,
		text: "hi",
	});

	expect(capturedPermissionMode).toBe("default");
});

test("WsService persists providerThreadId returned by codex runner", async () => {
	const chat = createChat();
	const updates: Array<{ chatId: string; providerThreadId: string | null }> = [];

	let updateCallCount = 0;
	const chatRepository = {
		findChatById: () => {
			updateCallCount += 1;

			if (updateCallCount === 1) {
				return chat;
			}

			return {
				...chat,
				status: "completed",
				updatedAt: new Date().toISOString(),
			};
		},
		findProviderThreadIdByChatId: () => null,
		updateChat: (_chatId: string, _update: Partial<Pick<ChatDTO, "status" | "diffAdded" | "diffRemoved">>) => ({
			...chat,
			status: "running",
			updatedAt: new Date().toISOString(),
		}),
		updateProviderThreadId: (chatId: string, providerThreadId: string | null) => {
			updates.push({ chatId, providerThreadId });
			return chat;
		},
	} as unknown as ChatRepository;

	const messageRepository = {
		createMessage: () => ({
			chatId: chat.id,
			content: "",
			createdAt: new Date().toISOString(),
			id: crypto.randomUUID(),
			role: "assistant" as const,
		}),
	} as unknown as MessageRepository;

	const projectRepository = {
		findProjectById: () => ({ createdAt: "", id: "project-id", isFavorite: false, name: "p", path: "/tmp", updatedAt: "" }),
	} as unknown as ProjectRepository;

	const runner = {
		run: async ({ onDelta }: { onDelta: (delta: string) => void }) => {
			onDelta("hello");
			return {
				assistantText: "hello",
				diffAdded: 5,
				diffRemoved: 0,
				status: "completed" as const,
				threadId: "thread-42",
			};
		},
	} as unknown as CodexProviderRunnerContract;

	const service = new WsService(chatRepository, messageRepository, projectRepository, runner);
	const collector = await collectEvents(() => {});

	await service.startUserMessage({ chatId: "chat-id", emit: collector.emit, text: "hi" });

	expect(updates).toEqual([
		{
			chatId: "chat-id",
			providerThreadId: "thread-42",
		},
	]);
	expect(collector.events.some((event) => event.event === "assistant_done")).toBe(true);
});

test("WsService.startUserMessage forwards intermediate assistant deltas in order", async () => {
	const chat = createChat();
	let updateCallCount = 0;
	const chatRepository = {
		findChatById: () => {
			updateCallCount += 1;

			if (updateCallCount === 1) {
				return chat;
			}

			return {
				...chat,
				status: "completed",
				updatedAt: new Date().toISOString(),
			};
		},
		findProviderThreadIdByChatId: () => null,
		updateChat: (_chatId: string, _update: Partial<Pick<ChatDTO, "status" | "diffAdded" | "diffRemoved">>) => ({
			...chat,
			status: "running",
			updatedAt: new Date().toISOString(),
		}),
		updateProviderThreadId: () => chat,
	} as unknown as ChatRepository;

	const messageRepository = {
		createMessage: () => ({
			chatId: chat.id,
			content: "",
			createdAt: new Date().toISOString(),
			id: crypto.randomUUID(),
			role: "assistant" as const,
		}),
	} as unknown as MessageRepository;

	const projectRepository = {
		findProjectById: () => ({
			createdAt: "",
			id: "project-id",
			isFavorite: false,
			name: "p",
			path: "/tmp",
			updatedAt: "",
		}),
	} as unknown as ProjectRepository;

	const runner = {
		run: async ({ onDelta }: { onDelta: (delta: string) => void }) => {
			onDelta("Thinking...\n");
			onDelta("Tool calling: /bin/zsh -lc pwd\n");
			onDelta("Tool output: /tmp\n");
			onDelta("final answer");
			return {
				assistantText: "final answer",
				diffAdded: 12,
				diffRemoved: 0,
				status: "completed" as const,
				threadId: "thread-stream-1",
			};
		},
	} as unknown as CodexProviderRunnerContract;

	const service = new WsService(chatRepository, messageRepository, projectRepository, runner);
	const collector = await collectEvents(() => {});

	await service.startUserMessage({ chatId: "chat-id", emit: collector.emit, text: "hi" });

	const deltas = collector.events
		.filter((event) => event.event === "assistant_delta")
		.map((event) => event.data.delta);

	expect(deltas).toEqual([
		"Thinking...\n",
		"Tool calling: /bin/zsh -lc pwd\n",
		"Tool output: /tmp\n",
		"final answer",
	]);
});

test("WsService.startUserMessage forwards structured assistant_event payloads", async () => {
	const chat = createChat();
	let updateCallCount = 0;
	const chatRepository = {
		findChatById: () => {
			updateCallCount += 1;

			if (updateCallCount === 1) {
				return chat;
			}

			return {
				...chat,
				status: "completed",
				updatedAt: new Date().toISOString(),
			};
		},
		findProviderThreadIdByChatId: () => null,
		updateChat: (_chatId: string, _update: Partial<Pick<ChatDTO, "status" | "diffAdded" | "diffRemoved">>) => ({
			...chat,
			status: "running",
			updatedAt: new Date().toISOString(),
		}),
		updateProviderThreadId: () => chat,
	} as unknown as ChatRepository;

	const messageRepository = {
		createMessage: () => ({
			chatId: chat.id,
			content: "",
			createdAt: new Date().toISOString(),
			id: crypto.randomUUID(),
			role: "assistant" as const,
		}),
	} as unknown as MessageRepository;

	const projectRepository = {
		findProjectById: () => ({
			createdAt: "",
			id: "project-id",
			isFavorite: false,
			name: "p",
			path: "/tmp",
			updatedAt: "",
		}),
	} as unknown as ProjectRepository;

	const runner = {
		run: async ({
			onDelta,
			onEvent,
		}: {
			onDelta: (delta: string) => void;
			onEvent?: (event: { type: string; [key: string]: unknown }) => void;
		}) => {
			onEvent?.({
				type: "turn_started",
				turnId: "turn-1",
			});
			onEvent?.({
				type: "item_started",
				turnId: "turn-1",
				itemId: "tool-1",
				itemType: "tool",
				state: "running",
				summary: "Running command: pwd",
			});
			onDelta("final answer");
			return {
				assistantText: "final answer",
				diffAdded: 12,
				diffRemoved: 0,
				status: "completed" as const,
				threadId: "thread-stream-2",
			};
		},
	} as unknown as CodexProviderRunnerContract;

	const service = new WsService(chatRepository, messageRepository, projectRepository, runner);
	const collector = await collectEvents(() => {});

	await service.startUserMessage({ chatId: "chat-id", emit: collector.emit, text: "hi" });

	const assistantEvents = collector.events
		.filter((event) => event.event === "assistant_event")
		.map((event) => event.data.event.type);

	expect(assistantEvents).toEqual(["turn_started", "item_started"]);
});
