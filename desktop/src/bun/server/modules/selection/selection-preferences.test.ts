import { expect, test } from "bun:test";

import type { WorkspaceSelection } from "./selection.model";
import { normalizeSelectionPreferences } from "./selection-preferences";

const createSelection = (overrides: Partial<WorkspaceSelection> = {}): WorkspaceSelection => ({
	selectedChatId: null,
	selectedModel: "gpt-5.3-codex",
	selectedProjectId: "project-1",
	selectedProvider: "codex",
	selectedReasoningEffort: "high",
	permissionMode: "plan",
	...overrides,
});

test("normalizeSelectionPreferences clears stale model and reasoning when provider changes", () => {
	const result = normalizeSelectionPreferences({
		current: createSelection(),
		payload: {
			selectedProvider: "claude",
		},
	});

	expect(result).toEqual({
		ok: true,
		value: {
			permissionMode: "plan",
			selectedModel: null,
			selectedProvider: "claude",
			selectedReasoningEffort: null,
		},
	});
});

test("normalizeSelectionPreferences clears stale model when locked provider differs from current selection", () => {
	const result = normalizeSelectionPreferences({
		current: createSelection(),
		lockedProvider: "claude",
		payload: {},
	});

	expect(result).toEqual({
		ok: true,
		value: {
			permissionMode: "plan",
			selectedModel: null,
			selectedProvider: "claude",
			selectedReasoningEffort: null,
		},
	});
});

test("normalizeSelectionPreferences keeps an explicit replacement model when provider changes", () => {
	const result = normalizeSelectionPreferences({
		current: createSelection(),
		payload: {
			selectedModel: "sonnet",
			selectedProvider: "claude",
		},
	});

	expect(result).toEqual({
		ok: true,
		value: {
			permissionMode: "plan",
			selectedModel: "sonnet",
			selectedProvider: "claude",
			selectedReasoningEffort: null,
		},
	});
});

test("normalizeSelectionPreferences rejects invalid selectedProvider values", () => {
	const result = normalizeSelectionPreferences({
		current: createSelection(),
		payload: {
			selectedProvider: "cursor",
		},
	});

	expect(result).toEqual({
		error: "invalid selectedProvider",
		ok: false,
	});
});

test("normalizeSelectionPreferences keeps the model when provider is still unset", () => {
	const result = normalizeSelectionPreferences({
		current: createSelection({
			selectedProvider: null,
		}),
		payload: {
			selectedModel: "gpt-5.3-codex",
			selectedReasoningEffort: "medium",
		},
	});

	expect(result).toEqual({
		ok: true,
		value: {
			permissionMode: "plan",
			selectedModel: "gpt-5.3-codex",
			selectedProvider: null,
			selectedReasoningEffort: "medium",
		},
	});
});
