export type SelectedProvider = "codex" | "claude";

export interface ProviderSelectionLockState {
	providerThreadId: string | null;
	messageCount: number;
	turnCount: number;
	hasStreamingText: boolean;
	hasStreamingTurn: boolean;
}

export interface ProviderSelectionState {
	selectedModel: string | null;
	selectedProvider: SelectedProvider;
	selectedReasoningEffort: string | null;
}

export interface PersistedSelectionState extends ProviderSelectionState {
	permissionMode: string;
	selectedChatId: string | null;
	selectedProjectId: string | null;
}

export interface PersistedSelectionPatch {
	permissionMode?: string;
	selectedChatId: string | null;
	selectedModel?: string | null;
	selectedProjectId: string | null;
	selectedProvider?: SelectedProvider;
	selectedReasoningEffort?: string | null;
}

export interface LockedProviderSyncInput extends ProviderSelectionState {
	isProviderLocked: boolean;
	lastSyncedChatId: string | null;
	selectedChatId: string | null;
	selectedChatProvider: SelectedProvider | null;
}

export interface LockedProviderSyncResult {
	nextLastSyncedChatId: string | null;
	nextSelection: ProviderSelectionState | null;
}

export const isSelectedProvider = (value: string | null | undefined): value is SelectedProvider =>
	value === "codex" || value === "claude";

export const applyDesktopProviderChange = (
	state: ProviderSelectionState,
	nextProvider: SelectedProvider,
): ProviderSelectionState => ({
	selectedModel: null,
	selectedProvider: nextProvider,
	selectedReasoningEffort: null,
});

export const mergePersistedSelectionPatch = (
	current: PersistedSelectionState,
	patch: PersistedSelectionPatch,
): PersistedSelectionState => ({
	permissionMode: patch.permissionMode === undefined ? current.permissionMode : patch.permissionMode,
	selectedChatId: patch.selectedChatId,
	selectedModel: patch.selectedModel === undefined ? current.selectedModel : patch.selectedModel,
	selectedProjectId: patch.selectedProjectId,
	selectedProvider: patch.selectedProvider === undefined ? current.selectedProvider : patch.selectedProvider,
	selectedReasoningEffort:
		patch.selectedReasoningEffort === undefined ? current.selectedReasoningEffort : patch.selectedReasoningEffort,
});

export const shouldSyncProviderScopedSelectionFromServer = (input: {
	isProviderHydrated: boolean;
	localSelectedProvider: SelectedProvider;
	serverSelectedProvider: SelectedProvider | null;
}): boolean => {
	if (!input.isProviderHydrated) {
		return true;
	}

	return input.serverSelectedProvider === input.localSelectedProvider;
};

export const syncLockedProviderSelectionFromDesktop = (
	input: LockedProviderSyncInput,
): LockedProviderSyncResult => {
	if (!input.isProviderLocked || !input.selectedChatProvider) {
		return {
			nextLastSyncedChatId: input.lastSyncedChatId,
			nextSelection: null,
		};
	}

	if (input.lastSyncedChatId === input.selectedChatId) {
		return {
			nextLastSyncedChatId: input.lastSyncedChatId,
			nextSelection: null,
		};
	}

	const nextLastSyncedChatId = input.selectedChatId ?? input.lastSyncedChatId;
	if (input.selectedProvider === input.selectedChatProvider) {
		return {
			nextLastSyncedChatId,
			nextSelection: null,
		};
	}

	return {
		nextLastSyncedChatId,
		nextSelection: applyDesktopProviderChange(input, input.selectedChatProvider),
	};
};

export const shouldLockProviderSelection = (state: ProviderSelectionLockState): boolean => {
	return Boolean(
		state.providerThreadId
		|| state.messageCount > 0
		|| state.turnCount > 0
		|| state.hasStreamingText
		|| state.hasStreamingTurn
	);
};
