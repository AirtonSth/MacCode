export const WORKSPACE_EVENT_TYPES = [
	"project_created",
	"project_updated",
	"project_deleted",
	"chat_created",
	"chat_updated",
	"chat_deleted",
	"message_created",
	"selection_updated",
	"git_updated",
	"terminal_command_started",
	"terminal_entry_appended",
	"terminal_command_finished",
] as const;

export type WorkspaceEventType = (typeof WORKSPACE_EVENT_TYPES)[number];

export interface WorkspaceEventEnvelope {
	seq: number;
	ts: string;
	type: WorkspaceEventType;
	payload: Record<string, unknown>;
	originClientId: string | null;
	requestId: string | null;
}

export interface WorkspaceEventPublishInput {
	type: WorkspaceEventType;
	payload: Record<string, unknown>;
	originClientId?: string | null;
	requestId?: string | null;
}

export interface WorkspaceEventRepositoryContract {
	append: (input: WorkspaceEventPublishInput) => WorkspaceEventEnvelope;
	listAfterSeq: (seq: number, limit?: number) => WorkspaceEventEnvelope[];
}

export interface WorkspaceEventServiceContract {
	append: (input: WorkspaceEventPublishInput) => WorkspaceEventEnvelope;
	listAfterSeq: (seq: number, limit?: number) => WorkspaceEventEnvelope[];
	publish: (input: WorkspaceEventPublishInput) => WorkspaceEventEnvelope;
	subscribe: (listener: (event: WorkspaceEventEnvelope) => void) => () => void;
}

export type WorkspaceEventsServiceContract = WorkspaceEventServiceContract;
