import { expect, test } from "bun:test";

import type { ChatDTO, ServerWsEvent } from "../../types";
import type { ChatRepository } from "../chat/chat.repository";
import type { MessageRepository } from "../message/message.repository";
import type { CodexProviderRunnerContract } from "../provider/codex-provider-runner";
import type { ProjectRepository } from "../project/project.repository";
import type { ChatStreamEventRepositoryContract } from "./chat-stream-event.repository";
import type { ChatStreamSnapshotRepositoryContract } from "./chat-stream-snapshot.repository";
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

test("WsService.startUserMessage allows concurrent runs for different chats", async () => {
	const statusByChat = new Map<string, ChatDTO["status"]>([
		["chat-a", "pending"],
		["chat-b", "pending"],
	]);
	const updatedAtByChat = new Map<string, string>([
		["chat-a", new Date().toISOString()],
		["chat-b", new Date().toISOString()],
	]);

	const chatRepository = {
		findChatById: (chatId: string) => {
			const status = statusByChat.get(chatId);
			if (!status) {
				return null;
			}

			return createChat({
				id: chatId,
				status,
				updatedAt: updatedAtByChat.get(chatId) ?? new Date().toISOString(),
			});
		},
		findProviderThreadIdByChatId: () => null,
		updateChat: (chatId: string, update: Partial<Pick<ChatDTO, "status" | "diffAdded" | "diffRemoved">>) => {
			if (update.status) {
				statusByChat.set(chatId, update.status);
			}
			const nextUpdatedAt = new Date().toISOString();
			updatedAtByChat.set(chatId, nextUpdatedAt);
			return createChat({
				id: chatId,
				status: statusByChat.get(chatId) ?? "pending",
				updatedAt: nextUpdatedAt,
			});
		},
		updateProviderThreadId: () => createChat(),
	} as unknown as ChatRepository;

	const messageRepository = {
		createMessage: (chatId: string, role: "user" | "assistant", content: string) => ({
			chatId,
			content,
			createdAt: new Date().toISOString(),
			id: crypto.randomUUID(),
			role,
		}),
	} as unknown as MessageRepository;

	const projectRepository = {
		findProjectById: () => ({ createdAt: "", id: "project-id", isFavorite: false, name: "p", path: "/tmp", updatedAt: "" }),
	} as unknown as ProjectRepository;

	const controls = new Map<string, { promise: Promise<void>; resolve: () => void }>();
	const getControl = (chatId: string) => {
		const current = controls.get(chatId);
		if (current) {
			return current;
		}
		let resolve = () => {};
		const promise = new Promise<void>((resolver) => {
			resolve = resolver;
		});
		const created = { promise, resolve };
		controls.set(chatId, created);
		return created;
	};

	const runner = {
		run: async ({ chatId, onDelta }: { chatId: string; onDelta: (delta: string) => void }) => {
			onDelta(`delta-${chatId}`);
			await getControl(chatId).promise;
			return {
				assistantText: `done-${chatId}`,
				diffAdded: 1,
				diffRemoved: 0,
				status: "completed" as const,
			};
		},
	} as unknown as CodexProviderRunnerContract;

	const service = new WsService(chatRepository, messageRepository, projectRepository, runner);
	const collector = await collectEvents(() => {});

	const first = service.startUserMessage({ chatId: "chat-a", emit: collector.emit, text: "one" });
	const second = service.startUserMessage({ chatId: "chat-b", emit: collector.emit, text: "two" });

	await new Promise((resolve) => setTimeout(resolve, 10));
	expect(service.isChatRunning("chat-a")).toBe(true);
	expect(service.isChatRunning("chat-b")).toBe(true);

	getControl("chat-a").resolve();
	getControl("chat-b").resolve();
	await Promise.all([first, second]);

	const doneChatIds = collector.events
		.filter((event) => event.event === "assistant_done")
		.map((event) => event.data.chatId)
		.sort();

	expect(doneChatIds).toEqual(["chat-a", "chat-b"]);
});

test("WsService.startUserMessage blocks a second concurrent run for the same chat", async () => {
	let chatStatus: ChatDTO["status"] = "pending";
	let updatedAt = new Date().toISOString();

	const chatRepository = {
		findChatById: (chatId: string) => {
			if (chatId !== "chat-a") {
				return null;
			}

			return createChat({
				id: "chat-a",
				status: chatStatus,
				updatedAt,
			});
		},
		findProviderThreadIdByChatId: () => null,
		updateChat: (_chatId: string, update: Partial<Pick<ChatDTO, "status" | "diffAdded" | "diffRemoved">>) => {
			if (update.status) {
				chatStatus = update.status;
			}
			updatedAt = new Date().toISOString();
			return createChat({
				id: "chat-a",
				status: chatStatus,
				updatedAt,
			});
		},
		updateProviderThreadId: () => createChat(),
	} as unknown as ChatRepository;

	const messageRepository = {
		createMessage: (chatId: string, role: "user" | "assistant", content: string) => ({
			chatId,
			content,
			createdAt: new Date().toISOString(),
			id: crypto.randomUUID(),
			role,
		}),
	} as unknown as MessageRepository;

	const projectRepository = {
		findProjectById: () => ({ createdAt: "", id: "project-id", isFavorite: false, name: "p", path: "/tmp", updatedAt: "" }),
	} as unknown as ProjectRepository;

	let resolveRunner = () => {};
	const runner = {
		run: async ({ onDelta }: { onDelta: (delta: string) => void }) => {
			onDelta("delta-chat-a");
			await new Promise<void>((resolve) => {
				resolveRunner = resolve;
			});
			return {
				assistantText: "done-chat-a",
				diffAdded: 1,
				diffRemoved: 0,
				status: "completed" as const,
			};
		},
	} as unknown as CodexProviderRunnerContract;

	const service = new WsService(chatRepository, messageRepository, projectRepository, runner);
	const firstEvents: ServerWsEvent[] = [];
	const secondEvents: ServerWsEvent[] = [];

	const firstRun = service.startUserMessage({
		chatId: "chat-a",
		emit: (event) => {
			firstEvents.push(event);
		},
		text: "first",
	});

	await new Promise((resolve) => setTimeout(resolve, 10));
	await service.startUserMessage({
		chatId: "chat-a",
		emit: (event) => {
			secondEvents.push(event);
		},
		text: "second",
	});

	expect(secondEvents).toEqual([
		{
			data: {
				chatId: "chat-a",
				code: "chat_running",
				message: "chat is already running",
			},
			event: "error",
		},
	]);

	resolveRunner();
	await firstRun;
	expect(firstEvents.some((event) => event.event === "assistant_done")).toBe(true);
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

	let nextEventId = 1;
	const streamEvents: ChatStreamEventRepositoryContract = {
		append: (chatId, event) => ({
			id: nextEventId++,
			chatId,
			createdAt: new Date().toISOString(),
			event,
			turnId: event.turnId,
		}),
		listByChatId: () => [],
	};

	const service = new WsService(chatRepository, messageRepository, projectRepository, runner, undefined, undefined, streamEvents);
	const collector = await collectEvents(() => {});

	await service.startUserMessage({ chatId: "chat-id", emit: collector.emit, text: "hi" });

	const assistantEvents = collector.events
		.filter((event) => event.event === "assistant_event")
		.map((event) => ({
			eventId: event.data.eventId,
			type: event.data.event.type,
		}));

	expect(assistantEvents).toEqual([
		{
			eventId: 1,
			type: "turn_started",
		},
		{
			eventId: 2,
			type: "item_started",
		},
	]);
});

test("WsService.startUserMessage updates and clears persisted stream snapshots", async () => {
	const chat = createChat();
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
		updateProviderThreadId: () => chat,
	} as unknown as ChatRepository;

	const messageRepository = {
		createMessage: (_chatId: string, role: "user" | "assistant", content: string) => ({
			chatId: chat.id,
			content,
			createdAt: new Date().toISOString(),
			id: crypto.randomUUID(),
			role,
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
			onDelta("partial-1 ");
			onDelta("partial-2");
			return {
				assistantText: "done",
				diffAdded: 0,
				diffRemoved: 0,
				status: "completed" as const,
			};
		},
	} as unknown as CodexProviderRunnerContract;

	const snapshotCalls = {
		append: [] as Array<{ chatId: string; delta: string }>,
		clear: [] as string[],
		reset: [] as string[],
	};
	const snapshots: ChatStreamSnapshotRepositoryContract = {
		appendDelta: (chatId: string, delta: string) => {
			snapshotCalls.append.push({ chatId, delta });
			return {
				chatId,
				partialText: snapshotCalls.append.filter((item) => item.chatId === chatId).map((item) => item.delta).join(""),
				updatedAt: new Date().toISOString(),
			};
		},
		clear: (chatId: string) => {
			snapshotCalls.clear.push(chatId);
		},
		getByChatId: () => null,
		reset: (chatId: string) => {
			snapshotCalls.reset.push(chatId);
			return {
				chatId,
				partialText: "",
				updatedAt: new Date().toISOString(),
			};
		},
	};

	const service = new WsService(
		chatRepository,
		messageRepository,
		projectRepository,
		runner,
		undefined,
		snapshots,
	);
	const collector = await collectEvents(() => {});

	await service.startUserMessage({ chatId: "chat-id", emit: collector.emit, text: "hi" });

	expect(snapshotCalls.reset).toEqual(["chat-id"]);
	expect(snapshotCalls.append).toEqual([
		{ chatId: "chat-id", delta: "partial-1 " },
		{ chatId: "chat-id", delta: "partial-2" },
	]);
	expect(snapshotCalls.clear).toEqual(["chat-id"]);
});
