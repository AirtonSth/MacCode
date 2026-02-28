import type { MessageDTO } from "../../types";
import type { ChatRepository } from "../chat/chat.repository";
import type { MessageRepository } from "./message.repository";

export interface MessageServiceContract {
	listByChatId: (chatId: string) => Promise<{ chatExists: boolean; messages: MessageDTO[] }>;
}

export class MessageService implements MessageServiceContract {
	constructor(
		private readonly chatRepository: ChatRepository,
		private readonly messageRepository: MessageRepository,
	) {}

	async listByChatId(chatId: string): Promise<{ chatExists: boolean; messages: MessageDTO[] }> {
		const chat = await this.chatRepository.findChatById(chatId);

		if (!chat) {
			return {
				chatExists: false,
				messages: [],
			};
		}

		const messages = await this.messageRepository.listMessagesByChatId(chatId);

		return {
			chatExists: true,
			messages,
		};
	}
}

export const createMessageService = (repositories: {
	chat: ChatRepository;
	message: MessageRepository;
}) => new MessageService(repositories.chat, repositories.message);

export const createMessageServiceFromRepositories = createMessageService;
