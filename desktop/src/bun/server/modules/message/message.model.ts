import type { MessageDTO } from "../../types";

export interface CreateMessageInput {
	chatId: string;
	content: string;
}

export type MessageList = MessageDTO[];
