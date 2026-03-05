import type {
	ChatDTO,
	ChatStreamSnapshotDTO,
	ClientMessageEvent,
	ClientWsEvent,
	ServerWsEvent,
} from "../../types";
import type { WorkspaceEventEnvelope } from "../../types";

export type WsEventPayload = ClientWsEvent;

export interface StopRunningChatInput {
	chatId: string;
	clientId?: string;
	requestId?: string;
}

export interface StopRunningChatResult {
	chat: ChatDTO | null;
	state: "not_found" | "not_running" | "stale_cleared" | "stopping";
}

export interface WsService {
	getChatById: (chatId: string) => Promise<ChatDTO | null>;
	getChatStreamSnapshot: (chatId: string) => Promise<ChatStreamSnapshotDTO | null>;
	isChatRunning: (chatId: string) => boolean;
	listRunningChatIds: () => string[];
	listWorkspaceEventsAfter: (lastSeq: number, options?: { limit?: number }) => WorkspaceEventEnvelope[];
	stopRunningChat: (input: StopRunningChatInput) => Promise<StopRunningChatResult>;
	startUserMessage: (input: WsServiceInput) => Promise<void>;
}

export interface WsServiceInput {
	chatId: string;
	clientId?: string;
	emit: (event: ServerWsEvent) => void;
	model?: ClientMessageEvent["data"]["model"];
	permissionMode?: ClientMessageEvent["data"]["permissionMode"];
	projectId?: ClientMessageEvent["data"]["projectId"];
	requestId?: string;
	reasoningEffort?: ClientMessageEvent["data"]["reasoningEffort"];
	text: string;
}
