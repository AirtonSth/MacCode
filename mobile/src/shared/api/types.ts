export interface ProjectDTO {
	id: string;
	name: string;
	path: string;
	isFavorite: boolean;
	createdAt: string;
	unreadFinishedThreadCount?: number;
	updatedAt: string;
}

export interface WorkspaceSummaryDTO {
	id: string;
	name: string;
	path: string;
	unreadFinishedThreadCount?: number;
}

export interface ProjectSummaryDTO {
	id: string;
	name: string;
	path: string;
	unreadFinishedThreadCount?: number;
}

export type ChatStatus = "pending" | "running" | "completed" | "failed";

export interface ChatDTO {
	id: string;
	isActive: boolean;
	projectId: string;
	provider: "fake" | "codex" | "claude";
	providerThreadId?: string | null;
	title: string;
	status: ChatStatus;
	diffAdded: number;
	diffRemoved: number;
	finishedAt?: string | null;
	hasUnreadFinished?: boolean;
	lastReadAt?: string | null;
	updatedAt: string;
}

export interface ThreadSummaryDTO {
	hasUnreadFinished?: boolean;
	id: string;
	isActive: boolean;
	title: string;
	updatedAt: string;
}

export interface ActiveThreadSummaryDTO {
	id: string;
	projectId: string;
	projectName: string;
	title: string;
	updatedAt: string;
}

export interface RecentThreadSummaryDTO {
	hasUnreadFinished?: boolean;
	id: string;
	isActive: boolean;
	projectId: string;
	projectName: string;
	title: string;
	updatedAt: string;
}

export interface ChatContextDTO {
	chat: ChatDTO;
	project: ProjectSummaryDTO;
}

export interface MessageDTO {
	id: string;
	chatId: string;
	role: "user" | "assistant";
	content: string;
	createdAt: string;
}

export interface ChatTurnItemDTO {
	body: string;
	expandedByUser: boolean;
	finishedAtMs: number | null;
	id: string;
	isExpanded: boolean;
	output: string;
	startedAtMs: number;
	state: AssistantStreamItemState;
	summary: string;
	type: AssistantStreamItemType;
}

export interface ChatTurnDTO {
	finishedAtMs: number | null;
	itemOrder: string[];
	itemsById: Record<string, ChatTurnItemDTO>;
	startedAtMs: number;
	status: "running" | "completed" | "failed";
	turnId: string;
}

export interface MessagePageDTO {
	hasMore: boolean;
	messages: MessageDTO[];
	nextBeforeMessageId: string | null;
	turns: ChatTurnDTO[];
}

export interface ChatStreamEventDTO {
	id: number;
	chatId: string;
	createdAt: string;
	event: AssistantStreamEvent;
}

export interface ChatStreamEventsResponseDTO {
	events: ChatStreamEventDTO[];
	hasMore: boolean;
	nextAfterId: number | null;
}

export interface WorkspaceSelectionDTO {
	selectedProjectId: string | null;
	selectedChatId: string | null;
	permissionMode: string;
	selectedModel: string | null;
	selectedProvider: string | null;
	selectedReasoningEffort: string | null;
}

export interface DiscoveryInfoDTO {
	serverId: string;
	hostname: string;
	port: number;
	version: string;
	authMode: "token_lan";
	capabilitiesVersion: string;
	connectHints?: DiscoveryConnectHintsDTO;
}

export interface DiscoveryConnectHintsDTO {
	addresses: string[];
	recommendedBaseUrls: string[];
	tailscaleAddresses: string[];
}

export interface AuthVerifyResponseDTO {
	ok: boolean;
	server: DiscoveryInfoDTO;
}

export interface FsRootEntryDTO {
	id: string;
	label: string;
	path: string;
}

export interface FsEntryDTO {
	name: string;
	path: string;
	type: "directory" | "file";
}

export interface FsListResponseDTO {
	path: string;
	parentPath: string | null;
	entries: FsEntryDTO[];
}

export interface CodexModelReasoningEffortDTO {
	reasoningEffort: string;
}

export interface CodexModelDescriptorDTO {
	id: string;
	model: string;
	displayName: string;
	isDefault: boolean;
	defaultReasoningEffort: string;
	supportedReasoningEfforts: CodexModelReasoningEffortDTO[];
}

export interface CodexModelsCatalogDTO {
	models: CodexModelDescriptorDTO[];
	nextCursor: string | null;
}

export interface GitStatusDTO {
	isRepo: boolean;
	currentBranch: string | null;
	ahead: number;
	behind: number;
	changedFiles: number;
	stagedFiles: number;
	unstagedFiles: number;
	untrackedFiles: number;
	conflictedFiles: number;
	isDetachedHead: boolean;
	added: number;
	removed: number;
}

export interface GitBranchListDTO {
	currentBranch: string | null;
	branches: string[];
}

export interface GitCommitResultDTO {
	branch: string | null;
	commitHash: string | null;
	commitMessage: string;
	pushed: boolean;
	pushedWithUpstream: boolean;
}

export interface TerminalCommandDTO {
	id: string;
	chatId: string;
	command: string;
	cwd: string;
	shell: string;
	status: "running" | "completed" | "failed" | "timeout";
	exitCode: number | null;
	durationMs: number | null;
	startedAt: string;
	finishedAt: string | null;
}

export interface TerminalEntryDTO {
	id: number;
	commandId: string;
	chatId: string;
	stream: "stdout" | "stderr";
	data: string;
	createdAt: string;
}

export type TerminalSessionStatus = "running" | "exited";

export interface TerminalSessionSnapshotDTO {
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

export interface TerminalSessionStateDTO {
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

export interface AssistantSnapshotEvent {
	data: {
		chatId: string;
		partialText: string;
		updatedAt: string;
	};
	event: "assistant_snapshot";
}

export interface AssistantEvent {
	data: {
		chatId: string;
		eventId?: number;
		event: AssistantStreamEvent;
	};
	event: "assistant_event";
}

export interface ChatUpdatedEvent {
	data: {
		chatId: string;
		diffAdded: number;
		diffRemoved: number;
		isActive: boolean;
		providerThreadId?: string | null;
		status: ChatStatus;
		updatedAt: string;
	};
	event: "chat_updated";
}

export interface TerminalSessionSnapshotEvent {
	data: TerminalSessionSnapshotDTO;
	event: "terminal_session_snapshot";
}

export interface TerminalOutputEvent {
	data: {
		chatId: string;
		data: string;
		seq: number;
		sessionId: string;
	};
	event: "terminal_output";
}

export interface TerminalSessionStateEvent {
	data: TerminalSessionStateDTO;
	event: "terminal_session_state";
}

export interface WorkspaceEventEnvelope {
	seq: number;
	ts: string;
	type: string;
	payload: unknown;
	originClientId: string | null;
	requestId: string | null;
}

export interface WorkspaceEvent {
	data: WorkspaceEventEnvelope;
	event: "workspace_event";
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
	| AssistantSnapshotEvent
	| AssistantEvent
	| ChatUpdatedEvent
	| TerminalSessionSnapshotEvent
	| TerminalOutputEvent
	| TerminalSessionStateEvent
	| WorkspaceEvent
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
		clientId?: string;
		text: string;
		model?: string;
		permissionMode?: string;
		projectId?: string;
		provider?: string;
		requestId?: string;
		reasoningEffort?: string;
	};
	event: "user_message";
}

export interface ClientJoinWorkspaceEvent {
	data: {
		clientId?: string;
		lastSeq?: number;
	};
	event: "join_workspace";
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
	| ClientJoinEvent
	| ClientJoinWorkspaceEvent
	| ClientMessageEvent
	| ClientJoinTerminalSessionEvent
	| ClientLeaveTerminalSessionEvent
	| ClientTerminalInputEvent
	| ClientTerminalResizeEvent
	| ClientTerminalSignalEvent
	| ClientTerminalRestartEvent;

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
