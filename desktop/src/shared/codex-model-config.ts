export const CODEX_REASONING_EFFORTS = ["none", "minimal", "low", "medium", "high", "xhigh"] as const;

export type CodexReasoningEffort = (typeof CODEX_REASONING_EFFORTS)[number];

export interface CodexReasoningEffortOption {
	description: string;
	reasoningEffort: CodexReasoningEffort;
}

export interface CodexModelDescriptor {
	defaultReasoningEffort: CodexReasoningEffort;
	description: string;
	displayName: string;
	id: string;
	isDefault: boolean;
	model: string;
	supportedReasoningEfforts: CodexReasoningEffortOption[];
}

export interface CodexModelsCatalog {
	models: CodexModelDescriptor[];
	nextCursor: string | null;
}

export const isCodexReasoningEffort = (value: unknown): value is CodexReasoningEffort => {
	return typeof value === "string" && (CODEX_REASONING_EFFORTS as readonly string[]).includes(value);
};

export const parseCodexReasoningEffort = (value: unknown): CodexReasoningEffort | null => {
	return isCodexReasoningEffort(value) ? value : null;
};

export const formatCodexReasoningEffortLabel = (value: CodexReasoningEffort): string => {
	return value === "xhigh" ? "extra high" : value;
};
