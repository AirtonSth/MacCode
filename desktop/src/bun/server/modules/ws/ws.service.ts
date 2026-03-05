import type { ChatDTO, ChatStreamSnapshotDTO, ServerWsEvent } from "../../types";
import type { WorkspaceEventEnvelope } from "../../types";
import { DEFAULT_CODEX_PERMISSION_MODE } from "../../../../shared/codex-permission-mode";
import type { ChatRepository } from "../chat/chat.repository";
import {
	type CodexProviderRunnerContract,
	CodexProviderRunner,
} from "../provider/codex-provider-runner";
import type { ProjectRepository } from "../project/project.repository";
import type { MessageRepository } from "../message/message.repository";
import type { WorkspaceEventsServiceContract } from "../workspace-events/workspace-events.model";
import type { ChatStreamEventRepositoryContract } from "./chat-stream-event.repository";
import type { ChatStreamSnapshotRepositoryContract } from "./chat-stream-snapshot.repository";
import type {
	StopRunningChatInput,
	StopRunningChatResult,
	WsService as WsServiceContract,
	WsServiceInput,
} from "./ws.model";

const noopChatStreamSnapshotRepository: ChatStreamSnapshotRepositoryContract = {
	appendDelta: (chatId: string, delta: string) => ({
		chatId,
		partialText: delta,
		updatedAt: new Date().toISOString(),
	}),
	clear: () => {
		// no-op
	},
	getByChatId: () => null,
	reset: (chatId: string) => ({
		chatId,
		partialText: "",
		updatedAt: new Date().toISOString(),
	}),
};

const noopChatStreamEventRepository: ChatStreamEventRepositoryContract = {
	append: (chatId, event) => ({
		id: Date.now(),
		chatId,
		createdAt: new Date().toISOString(),
		event,
		turnId: event.turnId,
	}),
	listByChatId: () => [],
};

export class WsService implements WsServiceContract {
	private readonly runningChats = new Set<string>();
	private readonly runningChatAbortControllers = new Map<string, AbortController>();

	constructor(
		private readonly chatRepository: ChatRepository,
		private readonly messageRepository: MessageRepository,
		private readonly projectRepository: ProjectRepository,
		private readonly codexProviderRunner: CodexProviderRunnerContract = new CodexProviderRunner(),
		private readonly workspaceEvents?: WorkspaceEventsServiceContract,
		private readonly chatStreamSnapshots: ChatStreamSnapshotRepositoryContract = noopChatStreamSnapshotRepository,
		private readonly chatStreamEvents: ChatStreamEventRepositoryContract = noopChatStreamEventRepository,
	) {}

	private static buildClientErrorEvent(
		code: string,
		message: string,
		chatId?: string,
	): ServerWsEvent {
		return {
			data: {
				code,
				message,
				...(chatId ? { chatId } : {}),
			},
			event: "error",
		};
	}

	static createClientErrorEvent(code: string, message: string, chatId?: string): ServerWsEvent {
		return WsService.buildClientErrorEvent(code, message, chatId);
	}

	private async emitChatUpdatedEvent(
		chatId: string,
		emit: (event: ServerWsEvent) => void,
		metadata?: {
			clientId?: string;
			requestId?: string;
		},
	): Promise<ChatDTO | null> {
		const updatedChat = await this.chatRepository.findChatById(chatId);

		if (!updatedChat) {
			return null;
		}

		emit({
			data: {
				chatId,
				diffAdded: updatedChat.diffAdded,
				diffRemoved: updatedChat.diffRemoved,
				isActive: updatedChat.isActive,
				status: updatedChat.status,
				updatedAt: updatedChat.updatedAt,
			},
			event: "chat_updated",
		});
		this.workspaceEvents?.append({
			type: "chat_updated",
			payload: {
				chatId,
				diffAdded: updatedChat.diffAdded,
				diffRemoved: updatedChat.diffRemoved,
				isActive: updatedChat.isActive,
				status: updatedChat.status,
				updatedAt: updatedChat.updatedAt,
			},
			originClientId: metadata?.clientId ?? null,
			requestId: metadata?.requestId ?? null,
		});

		return updatedChat;
	}

	isChatRunning(chatId: string): boolean {
		return this.runningChats.has(chatId);
	}

	listRunningChatIds(): string[] {
		return [...this.runningChats];
	}

	listWorkspaceEventsAfter(lastSeq: number, options?: { limit?: number }): WorkspaceEventEnvelope[] {
		if (!this.workspaceEvents) {
			return [];
		}

		return this.workspaceEvents.listAfterSeq(lastSeq, options?.limit);
	}

	async stopRunningChat(input: StopRunningChatInput): Promise<StopRunningChatResult> {
		const chat = await this.chatRepository.findChatById(input.chatId);

		if (!chat) {
			return {
				chat: null,
				state: "not_found",
			};
		}

		if (this.runningChats.has(input.chatId)) {
			const controller = this.runningChatAbortControllers.get(input.chatId);
			if (!controller) {
				return {
					chat,
					state: "not_running",
				};
			}

			controller.abort("force_stop");
			return {
				chat,
				state: "stopping",
			};
		}

		if (!chat.isActive && chat.status !== "running") {
			return {
				chat,
				state: "not_running",
			};
		}

		const updatedChat = await this.chatRepository.updateChat(input.chatId, {
			isActive: false,
			status: "failed",
		});

		if (updatedChat) {
			this.workspaceEvents?.append({
				type: "chat_updated",
				payload: {
					chatId: updatedChat.id,
					diffAdded: updatedChat.diffAdded,
					diffRemoved: updatedChat.diffRemoved,
					isActive: updatedChat.isActive,
					status: updatedChat.status,
					updatedAt: updatedChat.updatedAt,
				},
				originClientId: input.clientId ?? null,
				requestId: input.requestId ?? null,
			});
		}

		return {
			chat: updatedChat,
			state: "stale_cleared",
		};
	}

	async getChatById(chatId: string): Promise<ChatDTO | null> {
		return this.chatRepository.findChatById(chatId);
	}

	async getChatStreamSnapshot(chatId: string): Promise<ChatStreamSnapshotDTO | null> {
		return this.chatStreamSnapshots.getByChatId(chatId);
	}

	async startUserMessage(input: WsServiceInput): Promise<void> {
		const { chatId, clientId, emit, requestId, text } = input;
		const chat = await this.chatRepository.findChatById(chatId);

		if (!chat) {
			emit(WsService.createClientErrorEvent("chat_not_found", "chat not found", chatId));
			return;
		}

		const requestedProjectId = input.projectId?.trim();
		if (requestedProjectId && requestedProjectId !== chat.projectId) {
			emit(
				WsService.createClientErrorEvent(
					"chat_stale_target",
					"selected chat does not belong to the selected project",
					chatId,
				),
			);
			return;
		}

		if (chat.provider === "fake") {
			emit(
				WsService.createClientErrorEvent(
					"legacy_chat_provider",
					"legacy fake-provider chats are read-only. create a new codex chat to send messages",
					chatId,
				),
			);
			return;
		}

		if (this.runningChats.has(chatId) || chat.isActive) {
			emit(WsService.createClientErrorEvent("chat_running", "chat is already running", chatId));
			return;
		}

		const project = await this.projectRepository.findProjectById(chat.projectId);

		if (!project) {
			emit(WsService.createClientErrorEvent("project_not_found", "project not found", chatId));
			return;
		}

		const runningChat = await this.chatRepository.updateChat(chatId, {
			diffAdded: 0,
			diffRemoved: 0,
			isActive: true,
			status: "running",
		});
		const userMessage = await this.messageRepository.createMessage(chatId, "user", text);
		this.workspaceEvents?.append({
			type: "message_created",
			payload: {
				message: userMessage,
			},
			originClientId: clientId ?? null,
			requestId: requestId ?? null,
		});
		const runningUpdatedAt = runningChat?.updatedAt ?? new Date().toISOString();
		this.workspaceEvents?.append({
			type: "chat_updated",
			payload: {
				chatId,
				diffAdded: 0,
				diffRemoved: 0,
				isActive: true,
				status: "running",
				updatedAt: runningUpdatedAt,
			},
			originClientId: clientId ?? null,
			requestId: requestId ?? null,
		});
		emit({
			data: {
				chatId,
				diffAdded: 0,
				diffRemoved: 0,
				isActive: true,
				status: "running",
				updatedAt: runningUpdatedAt,
			},
			event: "chat_updated",
		});
		this.chatStreamSnapshots.reset(chatId);

		this.runningChats.add(chatId);
		const runAbortController = new AbortController();
		this.runningChatAbortControllers.set(chatId, runAbortController);

		try {
			const permissionMode = input.permissionMode ?? DEFAULT_CODEX_PERMISSION_MODE;
			const providerResult = await this.codexProviderRunner.run({
				chatId,
				model: input.model,
				onDelta: (delta: string) => {
					this.chatStreamSnapshots.appendDelta(chatId, delta);
					emit({
						data: {
							chatId,
							delta,
						},
						event: "assistant_delta",
					});
				},
				onEvent: (event) => {
					const persistedEvent = this.chatStreamEvents.append(chatId, event);
					emit({
						data: {
							chatId,
							eventId: persistedEvent.id,
							event,
						},
						event: "assistant_event",
					});
				},
				permissionMode,
				reasoningEffort: input.reasoningEffort,
				signal: runAbortController.signal,
				text,
				threadId: this.chatRepository.findProviderThreadIdByChatId(chatId) ?? undefined,
				workspacePath: project.path,
			});

			if (providerResult.threadId) {
				await this.chatRepository.updateProviderThreadId(chatId, providerResult.threadId);
			}

			if (providerResult.status === "failed") {
				await this.chatRepository.updateChat(chatId, {
					diffAdded: providerResult.diffAdded,
					diffRemoved: providerResult.diffRemoved,
					isActive: false,
					status: "failed",
				});
				await this.emitChatUpdatedEvent(chatId, emit, {
					clientId,
					requestId,
				});
				const wasCancelled = providerResult.cancelled === true || runAbortController.signal.aborted;
				emit(
					WsService.createClientErrorEvent(
						wasCancelled ? "chat_cancelled" : "provider_failed",
						wasCancelled ? "chat run cancelled" : (providerResult.error || "provider failed"),
						chatId,
					),
				);
				return;
			}

			const assistantMessage = await this.messageRepository.createMessage(chatId, "assistant", providerResult.assistantText);
			await this.chatRepository.updateChat(chatId, {
				diffAdded: providerResult.diffAdded,
				diffRemoved: providerResult.diffRemoved,
				isActive: false,
				status: "completed",
			});
			this.workspaceEvents?.append({
				type: "message_created",
				payload: {
					message: assistantMessage,
				},
				originClientId: clientId ?? null,
				requestId: requestId ?? null,
			});
			emit({
				data: {
					chatId,
				},
				event: "assistant_done",
			});
			await this.emitChatUpdatedEvent(chatId, emit, {
				clientId,
				requestId,
			});
		} catch (error) {
			await this.chatRepository.updateChat(chatId, {
				isActive: false,
				status: "failed",
			});
			await this.emitChatUpdatedEvent(chatId, emit, {
				clientId,
				requestId,
			});
			const wasCancelled = runAbortController.signal.aborted;
			emit(
				WsService.createClientErrorEvent(
					wasCancelled ? "chat_cancelled" : "provider_failed",
					wasCancelled ? "chat run cancelled" : (error instanceof Error ? error.message : "provider failed"),
					chatId,
				),
			);
		} finally {
			this.runningChats.delete(chatId);
			this.runningChatAbortControllers.delete(chatId);
			this.chatStreamSnapshots.clear(chatId);
		}
	}
}

export const createWsService = (repositories: {
	chat: ChatRepository;
	message: MessageRepository;
	project: ProjectRepository;
}, workspaceEvents?: WorkspaceEventsServiceContract, chatStreamSnapshots?: ChatStreamSnapshotRepositoryContract, chatStreamEvents?: ChatStreamEventRepositoryContract) =>
	new WsService(
		repositories.chat,
		repositories.message,
		repositories.project,
		undefined,
		workspaceEvents,
		chatStreamSnapshots,
		chatStreamEvents,
	);

export const { createClientErrorEvent } = WsService;
