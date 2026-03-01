export type AssistantStreamItemType = "reasoning" | "tool" | "plan" | "assistant_message";

export type AssistantStreamDeltaTarget = "summary" | "body" | "output";

export type AssistantStreamItemState =
	| "running"
	| "preview"
	| "collapsed"
	| "completed"
	| "failed"
	| "cancelled";

export interface AssistantTurnStartedEvent {
	type: "turn_started";
	turnId: string;
}

export interface AssistantItemStartedEvent {
	type: "item_started";
	turnId: string;
	itemId: string;
	itemType: AssistantStreamItemType;
	state?: AssistantStreamItemState;
	summary?: string;
}

export interface AssistantItemDeltaEvent {
	type: "item_delta";
	turnId: string;
	itemId: string;
	target: AssistantStreamDeltaTarget;
	delta: string;
}

export interface AssistantItemStateEvent {
	type: "item_state";
	turnId: string;
	itemId: string;
	state: AssistantStreamItemState;
	summary?: string;
}

export interface AssistantItemCompletedEvent {
	type: "item_completed";
	turnId: string;
	itemId: string;
	state?: AssistantStreamItemState;
	summary?: string;
}

export interface AssistantTurnCompletedEvent {
	type: "turn_completed";
	turnId: string;
}

export type AssistantStreamEvent =
	| AssistantTurnStartedEvent
	| AssistantItemStartedEvent
	| AssistantItemDeltaEvent
	| AssistantItemStateEvent
	| AssistantItemCompletedEvent
	| AssistantTurnCompletedEvent;
