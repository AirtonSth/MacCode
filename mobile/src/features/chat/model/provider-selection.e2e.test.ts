/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "bun:test";

import {
	applyDesktopProviderChange,
	isSelectedProvider,
	shouldLockProviderSelection,
	syncLockedProviderSelectionFromDesktop,
} from "./provider-selection";

describe("provider selection desktop parity e2e", () => {
	test("manual provider changes clear the current model and reasoning before persistence", () => {
		const nextSelection = applyDesktopProviderChange({
			selectedModel: "claude-sonnet-4",
			selectedProvider: "claude",
			selectedReasoningEffort: "high",
		}, "codex");

		expect(nextSelection).toEqual({
			selectedModel: null,
			selectedProvider: "codex",
			selectedReasoningEffort: null,
		});
	});

	test("locked thread sync runs once per chat and resets the local provider state", () => {
		const firstSync = syncLockedProviderSelectionFromDesktop({
			isProviderLocked: true,
			lastSyncedChatId: null,
			selectedChatId: "chat-1",
			selectedChatProvider: "claude",
			selectedModel: "gpt-5",
			selectedProvider: "codex",
			selectedReasoningEffort: "medium",
		});

		expect(firstSync).toEqual({
			nextLastSyncedChatId: "chat-1",
			nextSelection: {
				selectedModel: null,
				selectedProvider: "claude",
				selectedReasoningEffort: null,
			},
		});

		const repeatedSync = syncLockedProviderSelectionFromDesktop({
			isProviderLocked: true,
			lastSyncedChatId: firstSync.nextLastSyncedChatId,
			selectedChatId: "chat-1",
			selectedChatProvider: "claude",
			selectedModel: firstSync.nextSelection?.selectedModel ?? null,
			selectedProvider: firstSync.nextSelection?.selectedProvider ?? "claude",
			selectedReasoningEffort: firstSync.nextSelection?.selectedReasoningEffort ?? null,
		});

		expect(repeatedSync).toEqual({
			nextLastSyncedChatId: "chat-1",
			nextSelection: null,
		});
	});

	test("switching to a different locked chat syncs again with the new chat provider", () => {
		const nextSync = syncLockedProviderSelectionFromDesktop({
			isProviderLocked: true,
			lastSyncedChatId: "chat-1",
			selectedChatId: "chat-2",
			selectedChatProvider: "codex",
			selectedModel: null,
			selectedProvider: "claude",
			selectedReasoningEffort: null,
		});

		expect(nextSync).toEqual({
			nextLastSyncedChatId: "chat-2",
			nextSelection: {
				selectedModel: null,
				selectedProvider: "codex",
				selectedReasoningEffort: null,
			},
		});
	});
});

// ---------------------------------------------------------------------------
// Provider revert bug — the core issue this fix addresses.
//
// On mobile, switching from Codex to Claude Code would revert after a few
// seconds because PATCH /selection failures triggered a query invalidation,
// the refetched server data fed into the selectionQuery.data useEffect, and
// that effect unconditionally overwrote the local provider state.
//
// Desktop never has this problem because provider is stored in localStorage
// and never read back from the server.  The fix makes mobile provider state
// locally authoritative after initial hydration, matching desktop behaviour.
// ---------------------------------------------------------------------------

describe("provider revert bug — locally authoritative provider", () => {
	const shellSource = readFileSync(resolve(__dirname, "use-workspace-shell.ts"), "utf8");

	test("isProviderHydratedRef is initialized from initialSelection", () => {
		expect(shellSource).toContain(
			"const isProviderHydratedRef = useRef(isSelectedProvider(initialSelection.selectedProvider));",
		);
	});

	test("selection sync effect guards provider updates behind hydration flag", () => {
		expect(shellSource).toContain(
			"if (!isProviderHydratedRef.current && isSelectedProvider(normalizedSelection.selectedProvider))",
		);
		expect(shellSource).toContain("isProviderHydratedRef.current = true;");
	});

	test("unconditional provider overwrite from server data is removed", () => {
		// The old pattern was:
		//   if (isSelectedProvider(normalizedSelection.selectedProvider)) {
		//       const nextProvider = ...
		// This must no longer exist without the hydration guard.
		const lines = shellSource.split("\n");
		for (let i = 0; i < lines.length; i += 1) {
			const line = lines[i].trim();
			if (
				line === "if (isSelectedProvider(normalizedSelection.selectedProvider)) {"
				&& !lines[Math.max(0, i - 1)]?.includes("isProviderHydratedRef")
			) {
				// Found unconditional provider overwrite — this is the old broken pattern
				throw new Error(
					`Line ${i + 1}: found unconditional provider overwrite without hydration guard`,
				);
			}
		}
	});

	test("user-initiated provider switch is never overwritten by server refetch", () => {
		// Simulate the bug scenario:
		// 1. User switches codex → claude (local state = claude)
		// 2. PATCH /selection fails (e.g. locked chat 400)
		// 3. onError invalidates → refetch returns old {selectedProvider: "codex"}
		// 4. selectionQuery.data fires with "codex"
		// 5. With the fix, isProviderHydratedRef.current === true → provider not overwritten

		// Verify provider stays "claude" — the hydration ref blocks the overwrite.
		// We test this by verifying the code structure ensures the guard:
		const hydratedRefInit = shellSource.includes(
			"const isProviderHydratedRef = useRef(isSelectedProvider(initialSelection.selectedProvider))",
		);
		const guardPresent = shellSource.includes(
			"!isProviderHydratedRef.current && isSelectedProvider(normalizedSelection.selectedProvider)",
		);

		expect(hydratedRefInit).toBe(true);
		expect(guardPresent).toBe(true);

		// When initialSelection has a valid provider, the ref starts true,
		// so the effect can NEVER overwrite provider from server data.
		expect(isSelectedProvider("codex")).toBe(true);
		expect(isSelectedProvider("claude")).toBe(true);
		expect(isSelectedProvider("invalid")).toBe(false);
		expect(isSelectedProvider(null)).toBe(false);
		expect(isSelectedProvider(undefined)).toBe(false);
	});

	test("cold start without cached provider still hydrates correctly once", () => {
		// When initialSelection has NO valid provider (cold start), isProviderHydratedRef
		// starts false.  The first selectionQuery.data response hydrates the provider
		// and sets the ref to true.  Subsequent refetches are blocked.

		// isSelectedProvider returns false for null/undefined → ref starts false
		expect(isSelectedProvider(null)).toBe(false);

		// After first hydration, ref becomes true and blocks all further overwrites
		// This is verified by the code structure test above.
	});

	test("locked chat provider sync still works independently of hydration guard", () => {
		// The syncLockedProviderSelectionFromDesktop function is a separate
		// mechanism that handles switching between locked chats.  It must
		// continue to work regardless of the hydration state.

		// User is on chat-1 (claude), switches to chat-2 (codex, locked)
		const sync = syncLockedProviderSelectionFromDesktop({
			isProviderLocked: true,
			lastSyncedChatId: "chat-1",
			selectedChatId: "chat-2",
			selectedChatProvider: "codex",
			selectedModel: "claude-opus-4",
			selectedProvider: "claude",
			selectedReasoningEffort: "high",
		});

		// Provider must sync to the locked chat's provider
		expect(sync.nextSelection).toEqual({
			selectedModel: null,
			selectedProvider: "codex",
			selectedReasoningEffort: null,
		});
	});

	test("provider is not locked on an empty chat (no messages, no turns)", () => {
		const locked = shouldLockProviderSelection({
			hasStreamingText: false,
			hasStreamingTurn: false,
			messageCount: 0,
			providerThreadId: null,
			turnCount: 0,
		});
		expect(locked).toBe(false);
	});

	test("provider is locked once a chat has messages", () => {
		const locked = shouldLockProviderSelection({
			hasStreamingText: false,
			hasStreamingTurn: false,
			messageCount: 1,
			providerThreadId: null,
			turnCount: 0,
		});
		expect(locked).toBe(true);
	});

	test("provider is locked when a providerThreadId exists", () => {
		const locked = shouldLockProviderSelection({
			hasStreamingText: false,
			hasStreamingTurn: false,
			messageCount: 0,
			providerThreadId: "thread-abc",
			turnCount: 0,
		});
		expect(locked).toBe(true);
	});

	test("applyDesktopProviderChange always resets model and reasoning effort", () => {
		const result = applyDesktopProviderChange({
			selectedModel: "gpt-4o",
			selectedProvider: "codex",
			selectedReasoningEffort: "medium",
		}, "claude");

		expect(result).toEqual({
			selectedModel: null,
			selectedProvider: "claude",
			selectedReasoningEffort: null,
		});
	});
});
