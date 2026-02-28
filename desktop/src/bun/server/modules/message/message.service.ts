import type { MessageDTO } from "../../types";
import type { ChatRepository } from "../chat/chat.repository";
import type { MessageRepository } from "./message.repository";

export interface MessageService {
	listByChatId: (chatId: string) => Promise<{ chatExists: boolean; messages: MessageDTO[] }>;
}

export const createMessageService = (repositories: {
	chat: ChatRepository;
	message: MessageRepository;
}): MessageService => ({
		listByChatId: async (chatId) => {
			const chat = await repositories.chat.findChatById(chatId);

			if (!chat) {
				return {
					chatExists: false,
					messages: [],
				};
			}

			const messages = await repositories.message.listMessagesByChatId(chatId);

			return {
				chatExists: true,
				messages,
			};
		},
	});

export const createMessageServiceFromRepositories = createMessageService;
