import type {
	ChatDTO,
	ChatStreamSnapshotDTO,
	ClientMessageEvent,
	ClientWsEvent,
	ServerWsEvent,
} from "../../types";
import type { WorkspaceEventEnvelope } from "../../types";

export type WsEventPayload = ClientWsEvent;

export interface WsService {
	getChatById: (chatId: string) => Promise<ChatDTO | null>;
	getChatStreamSnapshot: (chatId: string) => Promise<ChatStreamSnapshotDTO | null>;
	isChatRunning: (chatId: string) => boolean;
	listWorkspaceEventsAfter: (lastSeq: number, options?: { limit?: number }) => WorkspaceEventEnvelope[];
	startUserMessage: (input: WsServiceInput) => Promise<void>;
}

export interface WsServiceInput {
	chatId: string;
	clientId?: string;
	emit: (event: ServerWsEvent) => void;
	model?: ClientMessageEvent["data"]["model"];
	permissionMode?: ClientMessageEvent["data"]["permissionMode"];
	requestId?: string;
	reasoningEffort?: ClientMessageEvent["data"]["reasoningEffort"];
	text: string;
}
