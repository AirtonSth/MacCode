export interface ProviderSelectionLockState {
	providerThreadId: string | null;
	messageCount: number;
	turnCount: number;
	hasStreamingText: boolean;
	hasStreamingTurn: boolean;
	threadTitle?: string | null;
}

const isPlaceholderThreadTitle = (title: string | null | undefined): boolean => {
	if (typeof title !== "string") {
		return false;
	}

	const normalized = title.trim().toLowerCase();
	return normalized === "new thread" || normalized === "new chat";
};

export const shouldLockProviderSelection = (state: ProviderSelectionLockState): boolean => {
	return Boolean(
		state.providerThreadId
		|| state.messageCount > 0
		|| state.turnCount > 0
		|| state.hasStreamingText
		|| state.hasStreamingTurn
		|| (
			typeof state.threadTitle === "string"
			&& state.threadTitle.trim().length > 0
			&& !isPlaceholderThreadTitle(state.threadTitle)
		)
	);
};
