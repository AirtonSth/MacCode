/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const source = readFileSync(resolve(__dirname, "use-workspace-shell.ts"), "utf8");

describe("[M-41] provider change follows desktop parity", () => {
	it("clears model and reasoning immediately in setSelectedProviderWithSync", () => {
		expect(source).toContain("const setSelectedProviderWithSync = useCallback(");
		expect(source).toContain("const nextSelection = applyDesktopProviderChange({");
		expect(source).toContain("setSelectedModel(nextSelection.selectedModel);");
		expect(source).toContain("setSelectedReasoningEffort(nextSelection.selectedReasoningEffort);");
		expect(source).toContain("selectedModel: nextSelection.selectedModel");
		expect(source).toContain("selectedReasoningEffort: nextSelection.selectedReasoningEffort");
	});

	it("persists a replacement selection only after the new model list resolves", () => {
		const modelsEffectBlock = /useEffect\(\(\) => \{[\s\S]*?defaultModelDescriptor[\s\S]*?persistSelection\(\{[\s\S]*?selectedModel: defaultModelDescriptor\.model[\s\S]*?\}\);[\s\S]*?\}, \[modelsQuery\.data\?\.models[\s\S]*?\]\);/.exec(
			source,
		);
		expect(modelsEffectBlock).not.toBeNull();
	});

	it("locks provider changes once the selected thread already has content", () => {
		expect(source).toContain("const selectedChatProviderThreadId = useMemo(");
		expect(source).toContain("const isProviderLocked = useMemo(");
		expect(source).toContain("shouldLockProviderSelection({");
		expect(source).toContain("const lastProviderSyncChatIdRef = useRef<string | null>(null);");
		expect(source).toContain("syncLockedProviderSelectionFromDesktop({");
		expect(source).toContain("provider: selectedProvider ?? undefined");
	});

	it("provider is locally authoritative after initial hydration — server refetches never overwrite", () => {
		// The hydration ref must exist and be initialized from initialSelection
		expect(source).toContain("const isProviderHydratedRef = useRef(isSelectedProvider(initialSelection.selectedProvider));");

		// The selection sync effect must guard provider updates behind the hydration flag
		expect(source).toContain("if (!isProviderHydratedRef.current && isSelectedProvider(normalizedSelection.selectedProvider))");
		expect(source).toContain("isProviderHydratedRef.current = true;");

		// The old pattern (unconditionally overwriting provider from server) must be gone
		const unconditionalProviderSync = /if \(isSelectedProvider\(normalizedSelection\.selectedProvider\)\) \{[\t\v\f\r \u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]*\n\s*const nextProvider/.exec(source);
		expect(unconditionalProviderSync).toBeNull();
	});

	it("preserves explicit null clears and skips stale server model sync across providers", () => {
		expect(source).toContain("mergePersistedSelectionPatch({");
		expect(source).toContain("const shouldSyncProviderScopedSelection = shouldSyncProviderScopedSelectionFromServer({");
		expect(source).toContain("if (shouldSyncProviderScopedSelection) {");
	});
});
