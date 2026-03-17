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

export type LiveActivityPushTokenType = "apns" | "fcm";

export interface LiveActivityPushSubscriptionInput {
	chatId: string;
	chatTitle?: string;
	pushToken: string;
	pushTokenType: LiveActivityPushTokenType;
	liveActivityToken: string;
}

export interface LiveActivityPushStoredSubscription extends LiveActivityPushSubscriptionInput {
	updatedAt: string;
}

export interface LiveActivityPushSubscriptionStoreContract {
	deleteByChatId(chatId: string): void;
	deleteExact(input: LiveActivityPushSubscriptionInput): void;
	listAll(): LiveActivityPushStoredSubscription[];
	upsert(input: LiveActivityPushSubscriptionInput): LiveActivityPushStoredSubscription;
}

export interface PushToStartTokenInput {
	pushToStartToken: string;
	pushToken: string;
	pushTokenType: LiveActivityPushTokenType;
}

export interface PushToStartTokenStored extends PushToStartTokenInput {
	updatedAt: string;
}

export interface PushToStartTokenStoreContract {
	listAll(): PushToStartTokenStored[];
	upsert(input: PushToStartTokenInput): PushToStartTokenStored;
	deleteByPushToken(pushToken: string, pushTokenType: LiveActivityPushTokenType): void;
}

export interface LiveActivityPushServiceContract {
	getIsEnabled(): boolean;
	getSupportedPushTokenTypes(): Promise<ReadonlySet<LiveActivityPushTokenType>>;
	onAssistantDelta(chatId: string, delta: string): void;
	onAssistantEvent(chatId: string, event: AssistantStreamEvent): void;
	onChatStarted(input: LiveActivityPushStartInput): void;
	onChatFinished(input: LiveActivityPushFinishInput): Promise<void>;
	upsertSubscription(input: LiveActivityPushSubscriptionInput): Promise<boolean>;
	registerPushToStartToken(input: PushToStartTokenInput): Promise<void>;
}
