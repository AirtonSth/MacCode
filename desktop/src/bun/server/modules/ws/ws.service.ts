import type { ChatDTO, ChatStreamSnapshotDTO, ServerWsEvent } from "../../types";
import type { WorkspaceEventEnvelope } from "../../types";
import { DEFAULT_CODEX_PERMISSION_MODE } from "../../../../shared/codex-permission-mode";
import type { ChatRepository } from "../chat/chat.repository";
import type { ChatTurnSnapshotRepositoryContract } from "../message/chat-turn-snapshot.repository";
import {
	type CodexProviderRunnerContract,
	CodexProviderRunner,
} from "../provider/codex-provider-runner";
import { ClaudeProviderRunner } from "../provider/claude-provider-runner";
import type { ProjectRepository } from "../project/project.repository";
import type { MessageRepository } from "../message/message.repository";
import type { WorkspaceEventsServiceContract } from "../workspace-events/workspace-events.model";
import type {
	LiveActivityPushFinishInput,
	LiveActivityPushServiceContract,
	LiveActivityPushStartInput,
	LiveActivityPushSubscriptionInput,
	PushToStartTokenInput,
} from "../live-activity/live-activity-push.model";
import type { ChatStreamEventRepositoryContract } from "./chat-stream-event.repository";
import type { ChatStreamSnapshotRepositoryContract } from "./chat-stream-snapshot.repository";
import { buildTurnSnapshotsFromEvents } from "./chat-turn-snapshot";
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
	clearByChatId: () => {
		// no-op
	},
	listAllByChatId: () => [],
	listByChatId: () => [],
};

const noopChatTurnSnapshotRepository: ChatTurnSnapshotRepositoryContract = {
	listByAnchorMessageIds: () => [],
	upsertByAnchorMessageId: () => {
		// no-op
	},
};

const noopLiveActivityPushService: LiveActivityPushServiceContract = {
	getIsEnabled: () => false,
	getSupportedPushTokenTypes: async () => new Set(),
	onAssistantDelta: () => {
		// no-op
	},
	onAssistantEvent: () => {
		// no-op
	},
	onChatFinished: async () => {
		// no-op
	},
	onChatStarted: () => {
		// no-op
	},
	upsertSubscription: async () => false,
	registerPushToStartToken: async () => {
		// no-op
	},
};

export class WsService implements WsServiceContract {
	private readonly runningChats = new Set<string>();
	private readonly runningChatAbortControllers = new Map<string, AbortController>();
	private readonly acceptedRequestIds = new Map<string, number>();

	constructor(
		private readonly chatRepository: ChatRepository,
		private readonly messageRepository: MessageRepository,
		private readonly projectRepository: ProjectRepository,
		private readonly codexProviderRunner: CodexProviderRunnerContract = new CodexProviderRunner(),
		private readonly claudeProviderRunner: CodexProviderRunnerContract = new ClaudeProviderRunner(),
		private readonly workspaceEvents?: WorkspaceEventsServiceContract,
		private readonly chatStreamSnapshots: ChatStreamSnapshotRepositoryContract = noopChatStreamSnapshotRepository,
		private readonly chatStreamEvents: ChatStreamEventRepositoryContract = noopChatStreamEventRepository,
		private readonly liveActivityPushService: LiveActivityPushServiceContract = noopLiveActivityPushService,
		private readonly chatTurnSnapshots: ChatTurnSnapshotRepositoryContract = noopChatTurnSnapshotRepository,
	) {}

	getLiveActivityPushIsEnabled(): boolean {
		return this.liveActivityPushService.getIsEnabled();
	}

	async getLiveActivityPushSupportedTokenTypes(): Promise<ReadonlySet<"apns" | "fcm">> {
		return await this.liveActivityPushService.getSupportedPushTokenTypes();
	}

	async upsertLiveActivityPushSubscription(input: LiveActivityPushSubscriptionInput): Promise<boolean> {
		return await this.liveActivityPushService.upsertSubscription(input);
	}

	async registerPushToStartToken(input: PushToStartTokenInput): Promise<void> {
		try {
			await this.liveActivityPushService.registerPushToStartToken(input);
		} catch {
			// Keep ws execution resilient when push-to-start registration fails.
		}
	}

	private async finishLiveActivity(input: LiveActivityPushFinishInput): Promise<void> {
		try {
			await this.liveActivityPushService.onChatFinished(input);
		} catch {
			// Keep ws execution resilient when live-activity push fails.
		}
	}

	private startLiveActivity(input: LiveActivityPushStartInput): void {
		try {
			this.liveActivityPushService.onChatStarted(input);
		} catch {
			// Keep ws execution resilient when live-activity push fails.
		}
	}

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

	private persistTurnSnapshots(chatId: string, anchorMessageId: string): void {
		const events = this.chatStreamEvents.listAllByChatId(chatId);
		if (events.length === 0) {
			return;
		}

		const turns = buildTurnSnapshotsFromEvents(events);
		this.chatTurnSnapshots.upsertByAnchorMessageId(chatId, anchorMessageId, turns);
	}

	async startUserMessage(input: WsServiceInput): Promise<void> {
		const { chatId, clientId, emit, requestId, text } = input;
		if (requestId && this.hasAcceptedRequest(chatId, requestId)) {
			const snapshot = await this.chatRepository.findChatById(chatId);
			if (snapshot) {
				emit({
					data: {
						chatId,
						diffAdded: snapshot.diffAdded,
						diffRemoved: snapshot.diffRemoved,
						isActive: snapshot.isActive,
						status: snapshot.status,
						updatedAt: snapshot.updatedAt,
					},
					event: "chat_updated",
				});
				if (snapshot.isActive) {
					const streamSnapshot = await this.chatStreamSnapshots.getByChatId(chatId);
					if (streamSnapshot && streamSnapshot.partialText.length > 0) {
						emit({
							data: {
								chatId: streamSnapshot.chatId,
								partialText: streamSnapshot.partialText,
								updatedAt: streamSnapshot.updatedAt,
							},
							event: "assistant_snapshot",
						});
					}
				}
			}
			return;
		}
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

		const effectiveProvider = input.provider ?? chat.provider;
		const providerChanged = effectiveProvider !== chat.provider && effectiveProvider !== "fake";

		const runningChat = await this.chatRepository.updateChat(chatId, {
			diffAdded: 0,
			diffRemoved: 0,
			isActive: true,
			status: "running",
			...(providerChanged ? { provider: effectiveProvider } : {}),
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
		if (requestId) {
			this.markAcceptedRequest(chatId, requestId);
		}
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
		this.chatStreamEvents.clearByChatId(chatId);
		this.chatStreamSnapshots.reset(chatId);
		this.startLiveActivity({
			chatId,
			chatTitle: chat.title,
		});

		this.runningChats.add(chatId);
		const runAbortController = new AbortController();
		this.runningChatAbortControllers.set(chatId, runAbortController);

		try {
			const permissionMode = input.permissionMode ?? DEFAULT_CODEX_PERMISSION_MODE;
			const providerRunner = effectiveProvider === "claude"
				? this.claudeProviderRunner
				: this.codexProviderRunner;
			const providerResult = await providerRunner.run({
				chatId,
				model: input.model,
				onDelta: (delta: string) => {
					this.chatStreamSnapshots.appendDelta(chatId, delta);
					this.liveActivityPushService.onAssistantDelta(chatId, delta);
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
					this.liveActivityPushService.onAssistantEvent(chatId, event);
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
				this.persistTurnSnapshots(chatId, userMessage.id);
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
				await this.finishLiveActivity({
					chatId,
					chatTitle: chat.title,
					outcome: wasCancelled ? "error" : "failed",
				});
				return;
			}

			const assistantMessage = await this.messageRepository.createMessage(chatId, "assistant", providerResult.assistantText);
			this.persistTurnSnapshots(chatId, assistantMessage.id);
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
			await this.finishLiveActivity({
				chatId,
				chatTitle: chat.title,
				outcome: "completed",
			});
		} catch (error) {
			this.persistTurnSnapshots(chatId, userMessage.id);
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
			await this.finishLiveActivity({
				chatId,
				chatTitle: chat.title,
				outcome: wasCancelled ? "error" : "failed",
			});
		} finally {
			this.runningChats.delete(chatId);
			this.runningChatAbortControllers.delete(chatId);
			this.chatStreamEvents.clearByChatId(chatId);
			this.chatStreamSnapshots.clear(chatId);
		}
	}

	private markAcceptedRequest(chatId: string, requestId: string): void {
		this.acceptedRequestIds.set(`${chatId}:${requestId}`, Date.now());
		if (this.acceptedRequestIds.size <= 512) {
			return;
		}

		const cutoff = Date.now() - 10 * 60_000;
		for (const [key, acceptedAt] of this.acceptedRequestIds) {
			if (acceptedAt < cutoff) {
				this.acceptedRequestIds.delete(key);
			}
		}
	}

	private hasAcceptedRequest(chatId: string, requestId: string): boolean {
		const cacheKey = `${chatId}:${requestId}`;
		if (this.acceptedRequestIds.has(cacheKey)) {
			return true;
		}

		const recentEvents = this.workspaceEvents?.listAfterSeq(0, 5_000) ?? [];
		for (let index = recentEvents.length - 1; index >= 0; index -= 1) {
			const event = recentEvents[index];
			if (event.requestId !== requestId) {
				continue;
			}

			if (event.type !== "message_created" && event.type !== "chat_updated") {
				continue;
			}

			const payload = event.payload;
			const payloadChatId = typeof payload.chatId === "string"
				? payload.chatId
				: (
					typeof payload.chat === "object" &&
					payload.chat !== null &&
					"id" in payload.chat &&
					typeof payload.chat.id === "string"
				)
					? payload.chat.id
					: (
						typeof payload.message === "object" &&
						payload.message !== null &&
						"chatId" in payload.message &&
						typeof payload.message.chatId === "string"
					)
						? payload.message.chatId
						: null;
			if (payloadChatId !== chatId) {
				continue;
			}

			this.acceptedRequestIds.set(cacheKey, Date.now());
			return true;
		}

		return false;
	}
}

export const createWsService = (repositories: {
	chat: ChatRepository;
	message: MessageRepository;
	project: ProjectRepository;
}, workspaceEvents?: WorkspaceEventsServiceContract, chatStreamSnapshots?: ChatStreamSnapshotRepositoryContract, chatStreamEvents?: ChatStreamEventRepositoryContract, liveActivityPushService?: LiveActivityPushServiceContract, chatTurnSnapshots?: ChatTurnSnapshotRepositoryContract) =>
	new WsService(
		repositories.chat,
		repositories.message,
		repositories.project,
		undefined,
		undefined,
		workspaceEvents,
		chatStreamSnapshots,
		chatStreamEvents,
		liveActivityPushService,
		chatTurnSnapshots,
	);

export const { createClientErrorEvent } = WsService;
