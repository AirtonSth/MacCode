import type { ChatDTO, ClientMessageEvent, ClientWsEvent, ServerWsEvent } from "../../types";

export type WsEventPayload = ClientWsEvent;

export interface WsService {
	getChatById: (chatId: string) => Promise<ChatDTO | null>;
	isChatRunning: (chatId: string) => boolean;
	startUserMessage: (input: WsServiceInput) => Promise<void>;
}

export interface WsServiceInput {
	chatId: string;
	emit: (event: ServerWsEvent) => void;
	permissionMode?: ClientMessageEvent["data"]["permissionMode"];
	text: string;
}
