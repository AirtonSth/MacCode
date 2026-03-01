export interface ProjectDTO {
	id: string;
	name: string;
	path: string;
	isFavorite: boolean;
	createdAt: string;
	updatedAt: string;
}

export type ChatStatus = "pending" | "running" | "completed" | "failed";

export interface ChatDTO {
	id: string;
	projectId: string;
	provider: "fake" | "codex";
	title: string;
	status: ChatStatus;
	diffAdded: number;
	diffRemoved: number;
	updatedAt: string;
}

export interface MessageDTO {
	id: string;
	chatId: string;
	role: "user" | "assistant";
	content: string;
	createdAt: string;
}

export interface WorkspaceSelectionDTO {
	selectedProjectId: string | null;
	selectedChatId: string | null;
}

export interface AssistantDeltaEvent {
	data: {
		chatId: string;
		delta: string;
	};
	event: "assistant_delta";
}

export interface AssistantDoneEvent {
	data: {
		chatId: string;
	};
	event: "assistant_done";
}

export interface AssistantEvent {
	data: {
		chatId: string;
		event: AssistantStreamEvent;
	};
	event: "assistant_event";
}

export interface ChatUpdatedEvent {
	data: {
		chatId: string;
		diffAdded: number;
		diffRemoved: number;
		status: ChatStatus;
		updatedAt: string;
	};
	event: "chat_updated";
}

export interface WsErrorEvent {
	data: {
		chatId?: string;
		code: string;
		message: string;
	};
	event: "error";
}

export type ServerWsEvent =
	| AssistantDeltaEvent
	| AssistantDoneEvent
	| AssistantEvent
	| ChatUpdatedEvent
	| WsErrorEvent;

export interface ClientJoinEvent {
	data: {
		chatId: string;
	};
	event: "join_chat";
}

export interface ClientMessageEvent {
	data: {
		chatId: string;
		text: string;
		model?: string;
		permissionMode?: string;
		reasoningEffort?: string;
	};
	event: "user_message";
}

export type ClientWsEvent = ClientJoinEvent | ClientMessageEvent;

export type AssistantStreamItemType = "reasoning" | "tool" | "plan" | "assistant_message";
export type AssistantStreamItemState = "running" | "preview" | "collapsed" | "completed" | "failed" | "cancelled";
export type AssistantStreamDeltaTarget = "summary" | "body" | "output";

export type AssistantStreamEvent =
	| {
		turnId: string;
		type: "turn_started";
	}
	| {
		itemId: string;
		itemType: AssistantStreamItemType;
		state?: AssistantStreamItemState;
		summary?: string;
		turnId: string;
		type: "item_started";
	}
	| {
		delta: string;
		itemId: string;
		target: AssistantStreamDeltaTarget;
		turnId: string;
		type: "item_delta";
	}
	| {
		itemId: string;
		state: AssistantStreamItemState;
		summary?: string;
		turnId: string;
		type: "item_state";
	}
	| {
		itemId: string;
		state?: AssistantStreamItemState;
		summary?: string;
		turnId: string;
		type: "item_completed";
	}
	| {
		turnId: string;
		type: "turn_completed";
	};
