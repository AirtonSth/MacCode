import type { CodexModelDescriptor, CodexModelsCatalog, CodexReasoningEffort } from "../../shared/codex-model-config";

export type SelectedProvider = "codex" | "claude";

export interface ProviderChangeCallbacks {
	setAvailableModels: (models: CodexModelDescriptor[]) => void;
	setHasLoadedCodexModels: (loaded: boolean) => void;
	setSelectedModel: (model: string | null) => void;
	setSelectedReasoningEffort: (effort: CodexReasoningEffort | null) => void;
}

export interface ProviderChangeApi {
	listClaudeModels: () => Promise<CodexModelsCatalog>;
	listCodexModels: () => Promise<CodexModelsCatalog>;
}

export interface ProviderSelectionLockState {
	providerThreadId: string | null;
	messageCount: number;
	turnCount: number;
	hasStreamingText: boolean;
	hasStreamingTurn: boolean;
}

export const listModelsForProvider = async (
	provider: SelectedProvider,
	api: ProviderChangeApi,
): Promise<CodexModelsCatalog> => {
	return provider === "claude"
		? await api.listClaudeModels()
		: await api.listCodexModels();
};

/**
 * Fetches models for a provider and updates state only once the fetch resolves.
 * Previous provider's models stay visible until new ones arrive (D-14).
 */
export const fetchModelsForProvider = async (
	provider: SelectedProvider,
	api: ProviderChangeApi,
	callbacks: ProviderChangeCallbacks,
): Promise<void> => {
	callbacks.setHasLoadedCodexModels(false);
	try {
		const catalog = await listModelsForProvider(provider, api);
		callbacks.setAvailableModels(catalog.models);
		const defaultModel = catalog.models.find((m) => m.isDefault) ?? catalog.models[0];
		if (defaultModel) {
			callbacks.setSelectedModel(defaultModel.model);
			callbacks.setSelectedReasoningEffort(defaultModel.defaultReasoningEffort);
		} else {
			callbacks.setSelectedModel(null);
			callbacks.setSelectedReasoningEffort(null);
		}
	} catch {
		callbacks.setAvailableModels([]);
		callbacks.setSelectedModel(null);
		callbacks.setSelectedReasoningEffort(null);
	} finally {
		callbacks.setHasLoadedCodexModels(true);
	}
};

export const shouldLockProviderSelection = (state: ProviderSelectionLockState): boolean => {
	return Boolean(
		state.providerThreadId
		|| state.messageCount > 0
		|| state.turnCount > 0
		|| state.hasStreamingText
		|| state.hasStreamingTurn,
	);
};
