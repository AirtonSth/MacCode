import type { ChatDTO, ServerWsEvent } from "../../types";
import type { ChatRepository } from "../chat/chat.repository";
import type { MessageRepository } from "../message/message.repository";
import { runFakeProvider } from "../provider/fake-provider-runner";
import type { WsService as WsServiceContract } from "./ws.model";

export const createClientErrorEvent = (code: string, message: string, chatId?: string): ServerWsEvent => ({
	data: {
		code,
		message,
		...(chatId ? { chatId } : {}),
	},

	event: "error",
});

export const createWsService = (repositories: {
	chat: ChatRepository;
	message: MessageRepository;
}): WsServiceContract => {
	const runningChats = new Set<string>();

	const emitRunningState = async (
		chatId: string,
		emit: (event: ServerWsEvent) => void,
	): Promise<ChatDTO | null> => {
		const updated = await repositories.chat.findChatById(chatId);

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
	};

	return {
		getChatById: async (chatId) => repositories.chat.findChatById(chatId),
		isChatRunning: (chatId) => runningChats.has(chatId),

		startUserMessage: async ({ chatId, emit, text }) => {
			const chat = await repositories.chat.findChatById(chatId);

			if (!chat) {
			emit(createClientErrorEvent("chat_not_found", "chat not found", chatId));

				return;
		}

			if (runningChats.has(chatId) || chat.status === "running") {
				emit(createClientErrorEvent("chat_running", "chat is already running", chatId));

				return;
			}

			await repositories.chat.updateChat(chatId, {
				diffAdded: 0,
				diffRemoved: 0,
				status: "running",
			});
			await repositories.message.createMessage(chatId, "user", text);
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

			runningChats.add(chatId);

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
					await repositories.chat.updateChat(chatId, {
						diffAdded: providerResult.diffAdded,
						diffRemoved: providerResult.diffRemoved,
						status: "failed",
					});
					await emitRunningState(chatId, emit);
					emit(createClientErrorEvent("provider_failed", providerResult.error || "provider failed", chatId));

					return;
				}

				await repositories.message.createMessage(
					chatId,
					"assistant",
					providerResult.assistantText,
				);
				await repositories.chat.updateChat(chatId, {
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
				await emitRunningState(chatId, emit);
			} finally {
				runningChats.delete(chatId);
			}
		},
	};
};
