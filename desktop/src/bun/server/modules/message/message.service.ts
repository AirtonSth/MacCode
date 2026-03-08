import type { ChatStreamEventPageDTO, MessagePageDTO } from "../../types";
import type { ChatRepository } from "../chat/chat.repository";
import type { MessageRepository } from "./message.repository";
import type { ChatStreamEventRepositoryContract } from "../ws/chat-stream-event.repository";
import type { ChatTurnSnapshotRepositoryContract } from "./chat-turn-snapshot.repository";

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

export interface MessageServiceContract {
	listByChatId: (
		chatId: string,
		options?: { beforeMessageId?: string; limit?: number },
	) => Promise<{ chatExists: boolean } & MessagePageDTO>;
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
		private readonly chatTurnSnapshotRepository: ChatTurnSnapshotRepositoryContract = noopChatTurnSnapshotRepository,
	) {}

	async listByChatId(
		chatId: string,
		options?: { beforeMessageId?: string; limit?: number },
	): Promise<{ chatExists: boolean } & MessagePageDTO> {
		const chat = await this.chatRepository.findChatById(chatId);

		if (!chat) {
			return {
				chatExists: false,
				hasMore: false,
				messages: [],
				nextBeforeMessageId: null,
				turns: [],
			};
		}

		const page = await this.messageRepository.listMessagesByChatId(chatId, options);
		const turns = this.chatTurnSnapshotRepository.listByAnchorMessageIds(
			chatId,
			page.messages.map((message) => message.id),
		);

		return {
			chatExists: true,
			...page,
			turns,
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
	turnSnapshot?: ChatTurnSnapshotRepositoryContract;
}) => new MessageService(
	repositories.chat,
	repositories.message,
	repositories.streamEvent,
	repositories.turnSnapshot,
);

export const createMessageServiceFromRepositories = createMessageService;
