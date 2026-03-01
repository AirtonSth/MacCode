export const CODEX_PERMISSION_MODES = ["plan", "default", "full"] as const;

export type CodexPermissionMode = (typeof CODEX_PERMISSION_MODES)[number];

export const DEFAULT_CODEX_PERMISSION_MODE: CodexPermissionMode = "default";

export const isCodexPermissionMode = (value: unknown): value is CodexPermissionMode => {
	return typeof value === "string" && (CODEX_PERMISSION_MODES as readonly string[]).includes(value);
};

export const parseCodexPermissionMode = (value: unknown): CodexPermissionMode | null => {
	return isCodexPermissionMode(value) ? value : null;
};
