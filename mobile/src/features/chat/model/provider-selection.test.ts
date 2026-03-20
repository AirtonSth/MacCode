/* eslint-disable import/no-unresolved */
import { describe, expect, it } from "bun:test";

import {
	applyDesktopProviderChange,
	isSelectedProvider,
	mergePersistedSelectionPatch,
	shouldLockProviderSelection,
	shouldSyncProviderScopedSelectionFromServer,
} from "./provider-selection";

describe("shouldLockProviderSelection", () => {
	it("does not lock the provider for title-only threads", () => {
		expect(shouldLockProviderSelection({
			hasStreamingText: false,
			hasStreamingTurn: false,
			messageCount: 0,
			providerThreadId: null,
			turnCount: 0,
		})).toBe(false);
	});

	it("locks the provider once the selected thread already has messages", () => {
		expect(shouldLockProviderSelection({
			hasStreamingText: false,
			hasStreamingTurn: false,
			messageCount: 1,
			providerThreadId: null,
			turnCount: 0,
		})).toBe(true);
	});

	it("locks the provider while a streamed response is visible", () => {
		expect(shouldLockProviderSelection({
			hasStreamingText: true,
			hasStreamingTurn: false,
			messageCount: 0,
			providerThreadId: null,
			turnCount: 0,
		})).toBe(true);
	});

	it("locks the provider for hydrated threads with a provider thread id", () => {
		expect(shouldLockProviderSelection({
			hasStreamingText: false,
			hasStreamingTurn: false,
			messageCount: 0,
			providerThreadId: "thread-42",
			turnCount: 0,
		})).toBe(true);
	});

	it("keeps the provider editable for empty draft threads", () => {
		expect(shouldLockProviderSelection({
			hasStreamingText: false,
			hasStreamingTurn: false,
			messageCount: 0,
			providerThreadId: null,
			turnCount: 0,
		})).toBe(false);
	});
});

describe("provider-selection helpers", () => {
	it("validates the supported providers", () => {
		expect(isSelectedProvider("codex")).toBe(true);
		expect(isSelectedProvider("claude")).toBe(true);
		expect(isSelectedProvider("grok")).toBe(false);
	});

	it("matches desktop provider changes by clearing model and reasoning", () => {
		expect(applyDesktopProviderChange({
			selectedModel: "claude-sonnet-4",
			selectedProvider: "claude",
			selectedReasoningEffort: "high",
		}, "codex")).toEqual({
			selectedModel: null,
			selectedProvider: "codex",
			selectedReasoningEffort: null,
		});
	});

	it("preserves explicit nulls when merging a persisted provider change patch", () => {
		expect(mergePersistedSelectionPatch({
			permissionMode: "plan",
			selectedChatId: "chat-1",
			selectedModel: "gpt-5",
			selectedProjectId: "project-1",
			selectedProvider: "codex",
			selectedReasoningEffort: "medium",
		}, {
			selectedChatId: "chat-1",
			selectedModel: null,
			selectedProjectId: "project-1",
			selectedProvider: "claude",
			selectedReasoningEffort: null,
		})).toEqual({
			permissionMode: "plan",
			selectedChatId: "chat-1",
			selectedModel: null,
			selectedProjectId: "project-1",
			selectedProvider: "claude",
			selectedReasoningEffort: null,
		});
	});

	it("ignores stale server model and reasoning when provider hydration already diverged", () => {
		expect(shouldSyncProviderScopedSelectionFromServer({
			isProviderHydrated: true,
			localSelectedProvider: "claude",
			serverSelectedProvider: "codex",
		})).toBe(false);
	});

	it("hydrates provider-scoped selection from the server before local provider is locked in", () => {
		expect(shouldSyncProviderScopedSelectionFromServer({
			isProviderHydrated: false,
			localSelectedProvider: "codex",
			serverSelectedProvider: "claude",
		})).toBe(true);
	});
});
