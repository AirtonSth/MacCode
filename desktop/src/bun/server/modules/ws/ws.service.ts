import type { ChatDTO, ServerWsEvent } from "../../types";
import type { ChatRepository } from "../chat/chat.repository";
import type { MessageRepository } from "../message/message.repository";
import { runFakeProvider } from "../provider/fake-provider-runner";
import type { WsService as WsServiceContract, WsServiceInput } from "./ws.model";

export class WsService implements WsServiceContract {
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

	private readonly runningChats = new Set<string>();

	constructor(
		private readonly chatRepository: ChatRepository,
		private readonly messageRepository: MessageRepository,
	) {}

	private async emitRunningState(
		chatId: string,
		emit: (event: ServerWsEvent) => void,
	): Promise<ChatDTO | null> {
		const updated = await this.chatRepository.findChatById(chatId);

		if (!updated) {
			return null;
		}

		emit({
			data: {
				chatId,
				diffAdded: updated.diffAdded,
				diffRemoved: updated.diffRemoved,
				status: updated.status,
				updatedAt: updated.updatedAt,
			},

			event: "chat_updated",
		});

		return updated;
	}

	static createClientErrorEvent(code: string, message: string, chatId?: string): ServerWsEvent {
		return WsService.buildClientErrorEvent(code, message, chatId);
	}

	getChatById(chatId: string): Promise<ChatDTO | null> {
		return Promise.resolve(this.chatRepository.findChatById(chatId));
	}

	isChatRunning(chatId: string): boolean {
		return this.runningChats.has(chatId);
	}

	async startUserMessage({ chatId, emit, text }: WsServiceInput): Promise<void> {
		const chat = await this.chatRepository.findChatById(chatId);

		if (!chat) {
			emit(WsService.createClientErrorEvent("chat_not_found", "chat not found", chatId));

			return;
		}

		if (this.runningChats.has(chatId) || chat.status === "running") {
			emit(WsService.createClientErrorEvent("chat_running", "chat is already running", chatId));

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
			const providerResult = await runFakeProvider({
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
			});

			if (providerResult.status === "failed") {
				await this.chatRepository.updateChat(chatId, {
					diffAdded: providerResult.diffAdded,
					diffRemoved: providerResult.diffRemoved,
					status: "failed",
				});
				await this.emitRunningState(chatId, emit);
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
			await this.emitRunningState(chatId, emit);
		} finally {
			this.runningChats.delete(chatId);
		}
	}
}

export const createWsService = (repositories: {
	chat: ChatRepository;
	message: MessageRepository;
}) => new WsService(repositories.chat, repositories.message);

export const createClientErrorEvent = WsService.createClientErrorEvent;
