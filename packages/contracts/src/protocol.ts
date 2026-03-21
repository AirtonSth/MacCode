export interface MutationMetadata {
	clientId?: string;
	requestId?: string;
}

export interface DiscoveryConnectHintsDto {
	addresses: string[];
	recommendedBaseUrls: string[];
	tailscaleAddresses: string[];
}

export interface DiscoveryResponseDto {
	authMode: "token_lan";
	capabilitiesVersion: string;
	connectHints?: DiscoveryConnectHintsDto;
	hostname: string;
	port: number;
	serverId: string;
	version: string;
}

export interface AuthVerifyRequestDto extends MutationMetadata {
	token?: string;
}

export interface AuthVerifyResponseDto {
	// eslint-disable-next-line @typescript-eslint/naming-convention
	ok: true;
	server: DiscoveryResponseDto;
}

export interface FsRootDto {
	id: string;
	label: string;
	path: string;
}

export type FsEntryKind = "directory" | "file";

export interface FsEntryDto {
	type: FsEntryKind;
	name: string;
	path: string;
}

export interface FsRootsResponseDto {
	roots: FsRootDto[];
}

export interface FsListResponseDto {
	entries: FsEntryDto[];
	parentPath: string | null;
	path: string;
}

export type TerminalSessionStatus = "running" | "exited";

export interface TerminalSessionSnapshotDto {
	chatId: string;
	cols: number;
	cwd: string;
	exitCode: number | null;
	exitedAt: string | null;
	rows: number;
	seq: number;
	sessionId: string;
	shell: string;
	snapshot: string;
	startedAt: string;
	status: TerminalSessionStatus;
}

export interface TerminalSessionStateDto {
	chatId: string;
	cols: number;
	cwd: string;
	exitCode: number | null;
	exitedAt: string | null;
	rows: number;
	seq: number;
	sessionId: string;
	shell: string;
	startedAt: string;
	status: TerminalSessionStatus;
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

export interface WorkspaceEventEnvelope<Payload = unknown> {
	originClientId: string | null;
	payload: Payload;
	requestId: string | null;
	seq: number;
	ts: string;
	type: WorkspaceEventType;
}

export interface ClientJoinWorkspaceEvent {
	data: MutationMetadata & {
		lastSeq?: number;
	};
	event: "join_workspace";
}

export interface WorkspaceServerEvent {
	data: WorkspaceEventEnvelope;
	event: "workspace_event";
}

export interface ClientJoinChatEvent {
	data: {
		chatId: string;
	};
	event: "join_chat";
}

export interface ClientMessageEvent {
	data: MutationMetadata & {
		chatId: string;
		model?: string;
		permissionMode?: string;
		projectId?: string;
		reasoningEffort?: string;
		text: string;
	};
	event: "user_message";
}

export interface ClientJoinTerminalSessionEvent {
	data: {
		chatId: string;
		cols?: number;
		rows?: number;
	};
	event: "join_terminal_session";
}

export interface ClientLeaveTerminalSessionEvent {
	data: {
		chatId: string;
	};
	event: "leave_terminal_session";
}

export interface ClientTerminalInputEvent {
	data: {
		chatId: string;
		data: string;
	};
	event: "terminal_input";
}

export interface ClientTerminalResizeEvent {
	data: {
		chatId: string;
		cols: number;
		rows: number;
	};
	event: "terminal_resize";
}

export interface ClientTerminalSignalEvent {
	data: {
		chatId: string;
		signal: "SIGINT" | "SIGTERM";
	};
	event: "terminal_signal";
}

export interface ClientTerminalRestartEvent {
	data: {
		chatId: string;
		cols?: number;
		rows?: number;
	};
	event: "terminal_restart";
}

export type ClientWsEvent =
	| ClientJoinChatEvent
	| ClientJoinWorkspaceEvent
	| ClientMessageEvent
	| ClientJoinTerminalSessionEvent
	| ClientLeaveTerminalSessionEvent
	| ClientTerminalInputEvent
	| ClientTerminalResizeEvent
	| ClientTerminalSignalEvent
	| ClientTerminalRestartEvent;

export interface AssistantDeltaServerEvent {
	data: {
		chatId: string;
		delta: string;
	};
	event: "assistant_delta";
}

export interface AssistantDoneServerEvent {
	data: {
		chatId: string;
	};
	event: "assistant_done";
}

export interface AssistantSnapshotServerEvent {
	data: {
		chatId: string;
		partialText: string;
		updatedAt: string;
	};
	event: "assistant_snapshot";
}

export interface AssistantStructuredServerEvent {
	data: {
		chatId: string;
		eventId: number;
		event: unknown;
	};
	event: "assistant_event";
}

export interface ChatStreamEventDto {
	id: number;
	chatId: string;
	createdAt: string;
	event: unknown;
}

export interface ChatStreamEventsResponseDto {
	events: ChatStreamEventDto[];
	hasMore: boolean;
	nextAfterId: number | null;
}

export interface ChatUpdatedServerEvent {
	data: {
		chatId: string;
		diffAdded: number;
		diffRemoved: number;
		isActive: boolean;
		providerThreadId?: string | null;
		status: "pending" | "running" | "completed" | "failed";
		updatedAt: string;
	};
	event: "chat_updated";
}

export interface WsErrorServerEvent {
	data: {
		chatId?: string;
		code: string;
		message: string;
	};
	event: "error";
}

export interface TerminalSessionSnapshotServerEvent {
	data: TerminalSessionSnapshotDto;
	event: "terminal_session_snapshot";
}

export interface TerminalOutputServerEvent {
	data: {
		chatId: string;
		data: string;
		seq: number;
		sessionId: string;
	};
	event: "terminal_output";
}

export interface TerminalSessionStateServerEvent {
	data: TerminalSessionStateDto;
	event: "terminal_session_state";
}

export type ServerWsEvent =
	| AssistantDeltaServerEvent
	| AssistantDoneServerEvent
	| AssistantSnapshotServerEvent
	| AssistantStructuredServerEvent
	| ChatUpdatedServerEvent
	| WsErrorServerEvent
	| WorkspaceServerEvent
	| TerminalSessionSnapshotServerEvent
	| TerminalOutputServerEvent
	| TerminalSessionStateServerEvent;
