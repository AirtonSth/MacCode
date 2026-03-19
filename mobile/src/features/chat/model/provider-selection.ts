export interface ProviderSelectionLockState {
	providerThreadId: string | null;
	messageCount: number;
	turnCount: number;
	hasStreamingText: boolean;
	hasStreamingTurn: boolean;
}

export const shouldLockProviderSelection = (state: ProviderSelectionLockState): boolean => {
	return Boolean(
		state.providerThreadId
		|| state.messageCount > 0
		|| state.turnCount > 0
		|| state.hasStreamingText
		|| state.hasStreamingTurn,
	);
};
