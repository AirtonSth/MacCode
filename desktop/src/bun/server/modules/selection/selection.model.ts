import type { CodexPermissionMode } from "../../../../shared/codex-permission-mode";
import type { CodexReasoningEffort } from "../../../../shared/codex-model-config";

export interface WorkspaceSelection {
	selectedChatId: string | null;
	selectedProjectId: string | null;
	permissionMode: CodexPermissionMode;
	selectedModel: string | null;
	selectedReasoningEffort: CodexReasoningEffort | null;
}

export interface WorkspaceSelectionInput {
	selectedChatId: string | null;
	selectedProjectId: string | null;
	permissionMode: CodexPermissionMode;
	selectedModel: string | null;
	selectedReasoningEffort: CodexReasoningEffort | null;
}
