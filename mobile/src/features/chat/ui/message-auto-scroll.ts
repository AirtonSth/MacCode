export interface ResolveMessageAutoScrollInput {
	isViewingOlderMessages: boolean;
	nextLastMessageId: string | null;
	previousLastMessageId: string | null;
	streamingText: string;
	hasStreamingTurn: boolean;
	userScrolledUp: boolean;
}

export interface ResolveMessageAutoScrollResult {
	nextLastMessageId: string | null;
	shouldPinToBottom: boolean;
	shouldRequestScroll: boolean;
}

export const resolveMessageAutoScroll = (
	input: ResolveMessageAutoScrollInput,
): ResolveMessageAutoScrollResult => {
	const hasNewTailMessage = input.nextLastMessageId !== null && input.nextLastMessageId !== input.previousLastMessageId;
	const hasStreaming = input.streamingText.trim().length > 0 || input.hasStreamingTurn;

	if (input.isViewingOlderMessages) {
		return {
			nextLastMessageId: input.nextLastMessageId,
			shouldPinToBottom: false,
			shouldRequestScroll: false,
		};
	}

	if (input.userScrolledUp) {
		return {
			nextLastMessageId: input.nextLastMessageId,
			shouldPinToBottom: false,
			shouldRequestScroll: false,
		};
	}

	return {
		nextLastMessageId: input.nextLastMessageId,
		shouldPinToBottom: hasStreaming,
		shouldRequestScroll: hasNewTailMessage || hasStreaming,
	};
};

export const shouldScrollOnMessageContentSizeChange = (input: {
	hasPendingScroll: boolean;
	isViewingOlderMessages: boolean;
	shouldPinToBottom: boolean;
	userScrolledUp: boolean;
}): boolean => {
	if (input.isViewingOlderMessages || input.userScrolledUp) {
		return false;
	}

	return input.hasPendingScroll || input.shouldPinToBottom;
};
