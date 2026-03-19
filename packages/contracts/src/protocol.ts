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

export type ClientWsEvent =
	| ClientJoinChatEvent
	| ClientJoinWorkspaceEvent
	| ClientMessageEvent;

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

export type ServerWsEvent =
	| AssistantDeltaServerEvent
	| AssistantDoneServerEvent
	| AssistantSnapshotServerEvent
	| AssistantStructuredServerEvent
	| ChatUpdatedServerEvent
	| WsErrorServerEvent
	| WorkspaceServerEvent;
