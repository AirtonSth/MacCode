import type { ChatStreamEventPageDTO } from "../../types";
import type { ChatRepository } from "../chat/chat.repository";
import type { MessageListPage, MessageRepository } from "./message.repository";
import type { ChatStreamEventRepositoryContract } from "../ws/chat-stream-event.repository";

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

export interface MessageServiceContract {
	listByChatId: (
		chatId: string,
		options?: { beforeMessageId?: string; limit?: number },
	) => Promise<{ chatExists: boolean } & MessageListPage>;
	listStreamEventsByChatId: (
		chatId: string,
		options?: { afterId?: number; limit?: number },
	) => Promise<{ chatExists: boolean } & ChatStreamEventPageDTO>;
}

export class MessageService implements MessageServiceContract {
	constructor(
		private readonly chatRepository: ChatRepository,
		private readonly messageRepository: MessageRepository,
		private readonly chatStreamEventRepository: ChatStreamEventRepositoryContract = noopChatStreamEventRepository,
	) {}

	async listByChatId(
		chatId: string,
		options?: { beforeMessageId?: string; limit?: number },
	): Promise<{ chatExists: boolean } & MessageListPage> {
		const chat = await this.chatRepository.findChatById(chatId);

		if (!chat) {
			return {
				chatExists: false,
				hasMore: false,
				messages: [],
				nextBeforeMessageId: null,
			};
		}

		const page = await this.messageRepository.listMessagesByChatId(chatId, options);

		return {
			chatExists: true,
			...page,
		};
	}

	async listStreamEventsByChatId(
		chatId: string,
		options?: { afterId?: number; limit?: number },
	): Promise<{ chatExists: boolean } & ChatStreamEventPageDTO> {
		const chat = await this.chatRepository.findChatById(chatId);

		if (!chat) {
			return {
				chatExists: false,
				events: [],
				hasMore: false,
				nextAfterId: null,
			};
		}

		const normalizedLimit = Math.max(1, Math.min(options?.limit ?? 500, 2000));
		const afterId = typeof options?.afterId === "number" && options.afterId > 0
			? Math.floor(options.afterId)
			: 0;
		const rows = this.chatStreamEventRepository.listByChatId(chatId, {
			afterId,
			limit: normalizedLimit + 1,
		});
		const hasMore = rows.length > normalizedLimit;
		const events = hasMore ? rows.slice(0, normalizedLimit) : rows;
		const nextAfterId = hasMore && events.length > 0 ? events.at(-1)?.id ?? null : null;

		return {
			chatExists: true,
			events,
			hasMore,
			nextAfterId,
		};
	}
}

export const createMessageService = (repositories: {
	chat: ChatRepository;
	message: MessageRepository;
	streamEvent?: ChatStreamEventRepositoryContract;
}) => new MessageService(repositories.chat, repositories.message, repositories.streamEvent);

export const createMessageServiceFromRepositories = createMessageService;
