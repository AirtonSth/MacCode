import type { ChatDTO, ServerWsEvent } from "../../types";
import type { ChatRepository } from "../chat/chat.repository";
import {
	type CodexProviderRunnerContract,
	CodexProviderRunner,
} from "../provider/codex-provider-runner";
import type { ProjectRepository } from "../project/project.repository";
import type { MessageRepository } from "../message/message.repository";
import type { WsService as WsServiceContract, WsServiceInput } from "./ws.model";

export class WsService implements WsServiceContract {
	private readonly runningChats = new Set<string>();

	constructor(
		private readonly chatRepository: ChatRepository,
		private readonly messageRepository: MessageRepository,
		private readonly projectRepository: ProjectRepository,
		private readonly codexProviderRunner: CodexProviderRunnerContract = new CodexProviderRunner(),
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
				status: updatedChat.status,
				updatedAt: updatedChat.updatedAt,
			},
			event: "chat_updated",
		});

		return updatedChat;
	}

	isChatRunning(chatId: string): boolean {
		return this.runningChats.has(chatId);
	}

	async getChatById(chatId: string): Promise<ChatDTO | null> {
		return this.chatRepository.findChatById(chatId);
	}

	async startUserMessage({ chatId, emit, text }: WsServiceInput): Promise<void> {
		const chat = await this.chatRepository.findChatById(chatId);

		if (!chat) {
			emit(WsService.createClientErrorEvent("chat_not_found", "chat not found", chatId));
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

		if (this.runningChats.has(chatId) || chat.status === "running") {
			emit(WsService.createClientErrorEvent("chat_running", "chat is already running", chatId));
			return;
		}

		const project = await this.projectRepository.findProjectById(chat.projectId);

		if (!project) {
			emit(WsService.createClientErrorEvent("project_not_found", "project not found", chatId));
			return;
		}

		await this.chatRepository.updateChat(chatId, {
			diffAdded: 0,
			diffRemoved: 0,
			status: "running",
		});
		await this.messageRepository.createMessage(chatId, "user", text);
		emit({
			data: {
				chatId,
				diffAdded: 0,
				diffRemoved: 0,
				status: "running",
				updatedAt: new Date().toISOString(),
			},
			event: "chat_updated",
		});

		this.runningChats.add(chatId);

		try {
			const providerResult = await this.codexProviderRunner.run({
				chatId,
				onDelta: (delta: string) => {
					emit({
						data: {
							chatId,
							delta,
						},
						event: "assistant_delta",
					});
				},
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
					status: "failed",
				});
				await this.emitChatUpdatedEvent(chatId, emit);
				emit(
					WsService.createClientErrorEvent(
						"provider_failed",
						providerResult.error || "provider failed",
						chatId,
					),
				);
				return;
			}

			await this.messageRepository.createMessage(chatId, "assistant", providerResult.assistantText);
			await this.chatRepository.updateChat(chatId, {
				diffAdded: providerResult.diffAdded,
				diffRemoved: providerResult.diffRemoved,
				status: "completed",
			});
			emit({
				data: {
					chatId,
				},
				event: "assistant_done",
			});
			await this.emitChatUpdatedEvent(chatId, emit);
		} finally {
			this.runningChats.delete(chatId);
		}
	}
}

export const createWsService = (repositories: {
	chat: ChatRepository;
	message: MessageRepository;
	project: ProjectRepository;
}) => new WsService(repositories.chat, repositories.message, repositories.project);

export const { createClientErrorEvent } = WsService;
