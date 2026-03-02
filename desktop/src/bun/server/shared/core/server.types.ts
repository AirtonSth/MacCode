import type { CodexPermissionMode } from "../../../../shared/codex-permission-mode";
import type { CodexReasoningEffort } from "../../../../shared/codex-model-config";
import type { AssistantStreamEvent } from "../../../../shared/assistant-stream-event";

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

export interface ClientJoinWorkspaceEvent {
	data: {
		clientId?: string;
		lastSeq?: number;
		requestId?: string;
	};
	event: "join_workspace";
}

export interface ClientMessageEvent {
	data: {
		chatId: string;
		clientId?: string;
		model?: string;
		permissionMode?: CodexPermissionMode;
		requestId?: string;
		reasoningEffort?: CodexReasoningEffort;
		text: string;
	};
	event: "user_message";
}

export type ClientWsEvent = ClientJoinEvent | ClientJoinWorkspaceEvent | ClientMessageEvent;

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
	model?: string;
	onDelta: (delta: string) => void;
	onEvent?: (event: AssistantStreamEvent) => void;
	permissionMode?: CodexPermissionMode;
	reasoningEffort?: CodexReasoningEffort;
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

export interface DiscoveryInfoDTO {
	serverId: string;
	hostname: string;
	port: number;
	version: string;
	authMode: "token_lan";
	capabilitiesVersion: string;
}

export interface AuthVerifyResponseDTO {
	ok: true;
	server: DiscoveryInfoDTO;
}

export interface FsRootEntryDTO {
	id: string;
	label: string;
	path: string;
}

export interface FsEntryDTO {
	type: "directory" | "file";
	name: string;
	path: string;
}

export interface FsListResponseDTO {
	parentPath: string | null;
	path: string;
	entries: FsEntryDTO[];
}

export type WorkspaceEventType =
	| "project_created"
	| "project_updated"
	| "project_deleted"
	| "chat_created"
	| "chat_updated"
	| "chat_deleted"
	| "message_created"
	| "selection_updated"
	| "git_updated"
	| "terminal_command_started"
	| "terminal_entry_appended"
	| "terminal_command_finished";

export interface WorkspaceEventEnvelope {
	seq: number;
	ts: string;
	type: WorkspaceEventType;
	payload: unknown;
	originClientId: string | null;
	requestId: string | null;
}

export interface ProjectDTO {
	createdAt: string;
	id: string;
	isFavorite: boolean;
	name: string;
	path: string;
	updatedAt: string;
}

export type TerminalCommandStatus = "running" | "completed" | "failed" | "timeout";

export interface TerminalCommandDTO {
	chatId: string;
	command: string;
	cwd: string;
	durationMs: number | null;
	exitCode: number | null;
	finishedAt: string | null;
	id: string;
	shell: string;
	startedAt: string;
	status: TerminalCommandStatus;
}

export interface TerminalEntryDTO {
	chatId: string;
	commandId: string;
	createdAt: string;
	data: string;
	id: number;
	stream: "stdout" | "stderr";
}

export type TerminalEntryStream = TerminalEntryDTO["stream"];

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
				event: AssistantStreamEvent;
			};
			event: "assistant_event";
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
			data: WorkspaceEventEnvelope;
			event: "workspace_event";
	  }
	| {
			data: {
				chatId?: string;
				code: string;
				message: string;
			};
			event: "error";
	  };
