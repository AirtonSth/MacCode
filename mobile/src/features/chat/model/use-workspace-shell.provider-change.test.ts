/* eslint-disable import/no-unresolved */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "bun:test";

const source = readFileSync(resolve(__dirname, "use-workspace-shell.ts"), "utf8");

describe("[M-41] provider change preserves the selected model until new models resolve", () => {
	it("does not clear the selected model immediately in setSelectedProviderWithSync", () => {
		const providerChangeBlock = /const setSelectedProviderWithSync = useCallback\([\s\S]*?\);/.exec(
			source,
		);
		expect(providerChangeBlock).not.toBeNull();
		expect(providerChangeBlock![0]).not.toContain("setSelectedModel(null)");
		expect(providerChangeBlock![0]).not.toContain("selectedModel: null");
	});

	it("persists a replacement selection only after the new model list resolves", () => {
		const modelsEffectBlock = /useEffect\(\(\) => \{[\s\S]*?defaultModelDescriptor[\s\S]*?persistSelection\(\{[\s\S]*?selectedModel: defaultModelDescriptor\.model[\s\S]*?\}\);[\s\S]*?\}, \[modelsQuery\.data\?\.models[\s\S]*?\]\);/.exec(
			source,
		);
		expect(modelsEffectBlock).not.toBeNull();
	});

	it("locks provider changes only after the selected thread has a provider thread id", () => {
		expect(source).toContain("const selectedChatProviderThreadId = useMemo(");
		expect(source).toContain("const isProviderLocked = selectedChatProviderThreadId !== null;");
		expect(source).toContain("if (selectedChatProviderThreadId) {");
		expect(source).toContain("const effectiveProvider = selectedChatProviderThreadId");
		expect(source).toContain("? selectedChatProvider ?? undefined");
		expect(source).toContain(": selectedProvider ?? undefined;");
	});
});
