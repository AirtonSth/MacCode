export interface ChatDTO {
	diffAdded: number;
	diffRemoved: number;
	id: string;
	projectId: string;
	provider: ChatProvider;
	status: ChatStatus;
	title: string;
	updatedAt: string;
}
export type ChatProvider = "fake" | "codex";

export type ChatStatus = "pending" | "running" | "completed" | "failed";

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
	};
	event: "user_message";
}

export type ClientWsEvent = ClientJoinEvent | ClientMessageEvent;

export interface ErrorPayload {
	error: string;
}

export interface FakeProviderResult {
	assistantText: string;
	diffAdded: number;
	diffRemoved: number;
	error?: string;
	status: "completed" | "failed";
}

export interface FakeProviderRunOptions {
	chatId: string;
	onDelta: (delta: string) => void;
	text: string;
}

export interface CodexProviderResult {
	assistantText: string;
	diffAdded: number;
	diffRemoved: number;
	error?: string;
	status: "completed" | "failed";
	threadId?: string;
}

export interface CodexProviderRunOptions {
	chatId: string;
	onDelta: (delta: string) => void;
	text: string;
	threadId?: string;
	workspacePath: string;
}

export interface MessageDTO {
	chatId: string;
	content: string;
	createdAt: string;
	id: string;
	role: "user" | "assistant";
}

export interface WorkspaceSelectionDTO {
	selectedProjectId: string | null;
	selectedChatId: string | null;
}

export interface ProjectDTO {
	createdAt: string;
	id: string;
	isFavorite: boolean;
	name: string;
	path: string;
	updatedAt: string;
}

export type ServerWsEvent =
	| {
			data: {
				chatId: string;
				delta: string;
			};
			event: "assistant_delta";
	  }
	| {
			data: {
				chatId: string;
			};
			event: "assistant_done";
	  }
	| {
			data: {
				chatId: string;
				diffAdded: number;
				diffRemoved: number;
				status: ChatStatus;
				updatedAt: string;
			};
			event: "chat_updated";
	  }
	| {
			data: {
				chatId?: string;
				code: string;
				message: string;
			};
			event: "error";
	  };
