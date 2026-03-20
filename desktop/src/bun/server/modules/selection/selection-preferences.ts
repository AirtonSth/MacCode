import {
	DEFAULT_CODEX_PERMISSION_MODE,
	parseCodexPermissionMode,
	type CodexPermissionMode,
} from "../../../../shared/codex-permission-mode";
import { parseCodexReasoningEffort, type CodexReasoningEffort } from "../../../../shared/codex-model-config";
import type { ChatProvider } from "../../shared/core/server.types";
import type { WorkspaceSelection } from "./selection.model";

const VALID_PROVIDERS = new Set<ChatProvider>(["codex", "claude"]);

const parseSelectedProvider = (value: unknown): ChatProvider | null => {
	if (typeof value !== "string") {
		return null;
	}

	return VALID_PROVIDERS.has(value as ChatProvider) ? (value as ChatProvider) : null;
};

const readSelectedModel = (value: unknown): string | null => {
	if (typeof value !== "string") {
		return null;
	}

	const trimmed = value.trim();
	return trimmed.length > 0 ? trimmed : null;
};

export interface WorkspaceSelectionPatchPayload {
	permissionMode?: unknown;
	selectedModel?: unknown;
	selectedProvider?: unknown;
	selectedReasoningEffort?: unknown;
}

export interface NormalizedSelectionPreferences {
	permissionMode: CodexPermissionMode;
	selectedModel: string | null;
	selectedProvider: ChatProvider | null;
	selectedReasoningEffort: CodexReasoningEffort | null;
}

type NormalizeSelectionPreferencesResult =
	| { ok: true; value: NormalizedSelectionPreferences }
	| { error: string; ok: false };

export const normalizeSelectionPreferences = (input: {
	current: WorkspaceSelection;
	lockedProvider?: ChatProvider | null;
	payload: WorkspaceSelectionPatchPayload;
}): NormalizeSelectionPreferencesResult => {
	const { current, lockedProvider = null, payload } = input;

	const permissionMode =
		payload.permissionMode === undefined
			? current.permissionMode
			: parseCodexPermissionMode(payload.permissionMode);
	if (permissionMode === null) {
		return { error: "invalid permissionMode", ok: false };
	}

	if (
		payload.selectedProvider !== undefined
		&& payload.selectedProvider !== null
		&& parseSelectedProvider(payload.selectedProvider) === null
	) {
		return { error: "invalid selectedProvider", ok: false };
	}

	const explicitProvider =
		payload.selectedProvider === undefined
			? current.selectedProvider
			: payload.selectedProvider === null
				? null
				: parseSelectedProvider(payload.selectedProvider);
	const selectedProvider = lockedProvider ?? explicitProvider ?? null;

	const explicitModelProvided = payload.selectedModel !== undefined;
	const explicitModel =
		payload.selectedModel === undefined
			? current.selectedModel
			: payload.selectedModel === null
				? null
				: readSelectedModel(payload.selectedModel);
	if (payload.selectedModel !== undefined && payload.selectedModel !== null && explicitModel === null) {
		return { error: "invalid selectedModel", ok: false };
	}

	const explicitReasoningEffortProvided = payload.selectedReasoningEffort !== undefined;
	const explicitReasoningEffort =
		payload.selectedReasoningEffort === undefined
			? current.selectedReasoningEffort
			: payload.selectedReasoningEffort === null || payload.selectedReasoningEffort === ""
				? null
				: parseCodexReasoningEffort(payload.selectedReasoningEffort);
	if (
		payload.selectedReasoningEffort !== undefined
		&& payload.selectedReasoningEffort !== null
		&& payload.selectedReasoningEffort !== ""
		&& explicitReasoningEffort === null
	) {
		return { error: "invalid selectedReasoningEffort", ok: false };
	}

	let selectedModel = explicitModel;
	let selectedReasoningEffort = explicitReasoningEffort;
	const providerChanged = selectedProvider !== current.selectedProvider;
	const providerExplicitlyCleared = payload.selectedProvider === null;

	if (selectedProvider === null && (providerChanged || providerExplicitlyCleared)) {
		selectedModel = null;
		selectedReasoningEffort = null;
	} else if (providerChanged) {
		if (!explicitModelProvided || selectedModel === current.selectedModel) {
			selectedModel = null;
		}
		if (!explicitReasoningEffortProvided || selectedModel === null) {
			selectedReasoningEffort = null;
		}
	}

	if (selectedModel === null) {
		selectedReasoningEffort = null;
	}

	if (explicitModelProvided && selectedModel !== current.selectedModel && !explicitReasoningEffortProvided) {
		selectedReasoningEffort = null;
	}

	return {
		ok: true,
		value: {
			permissionMode: permissionMode ?? DEFAULT_CODEX_PERMISSION_MODE,
			selectedModel,
			selectedProvider,
			selectedReasoningEffort,
		},
	};
};
