import type { AssistantStreamEvent } from "../../../../shared/assistant-stream-event";

export type LiveActivityPhase =
	| "background"
	| "completed"
	| "error"
	| "failed"
	| "finalizing"
	| "running";

export interface LiveActivityPushStartInput {
	chatId: string;
	chatTitle?: string;
}

export interface LiveActivityPushFinishInput {
	chatId: string;
	chatTitle?: string;
	outcome: "completed" | "error" | "failed";
}

export interface LiveActivityPushSubscriptionInput {
	chatId: string;
	chatTitle?: string;
	fcmToken: string;
	liveActivityToken: string;
}

export interface LiveActivityPushServiceContract {
	getIsEnabled(): boolean;
	onAssistantDelta(chatId: string, delta: string): void;
	onAssistantEvent(chatId: string, event: AssistantStreamEvent): void;
	onChatStarted(input: LiveActivityPushStartInput): void;
	onChatFinished(input: LiveActivityPushFinishInput): Promise<void>;
	upsertSubscription(input: LiveActivityPushSubscriptionInput): Promise<boolean>;
}
