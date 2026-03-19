/* eslint-disable import/no-unresolved */
import { describe, expect, test } from "bun:test";

import type { CodexModelDescriptor, CodexModelsCatalog } from "../../shared/codex-model-config";
import { fetchModelsForProvider } from "./provider-change";

const makeModel = (overrides: Partial<CodexModelDescriptor> = {}): CodexModelDescriptor => ({
	defaultReasoningEffort: "medium",
	description: "Test model",
	displayName: "Test Model",
	id: "model-1",
	isDefault: false,
	model: "test-model-v1",
	supportedReasoningEfforts: [],
	...overrides,
});

const makeCatalog = (models: CodexModelDescriptor[]): CodexModelsCatalog => ({
	models,
	nextCursor: null,
});

const createCallbackCollector = () => {
	const calls: { fn: string; arg: unknown }[] = [];
	return {
		calls,
		callbacks: {
			setAvailableModels: (models: CodexModelDescriptor[]) => {
				calls.push({ fn: "setAvailableModels", arg: models });
			},
			setHasLoadedCodexModels: (loaded: boolean) => {
				calls.push({ fn: "setHasLoadedCodexModels", arg: loaded });
			},
			setSelectedModel: (model: string | null) => {
				calls.push({ fn: "setSelectedModel", arg: model });
			},
			setSelectedReasoningEffort: (effort: unknown) => {
				calls.push({ fn: "setSelectedReasoningEffort", arg: effort });
			},
		},
	};
};

describe("fetchModelsForProvider (D-14: no flash of empty models)", () => {
	test("does NOT call setAvailableModels([]) or setSelectedModel(null) before fetch resolves", async () => {
		const { calls, callbacks } = createCallbackCollector();

		const catalog = makeCatalog([makeModel({ isDefault: true, model: "new-model" })]);
		const api = {
			listClaudeModels: async () => catalog,
			listCodexModels: async () => catalog,
		};

		await fetchModelsForProvider("codex", api, callbacks);

		// The first call should be setHasLoadedCodexModels(false), not clearing models.
		expect(calls[0]).toEqual({ fn: "setHasLoadedCodexModels", arg: false });

		// Verify that setAvailableModels was never called with an empty array
		// before being called with the actual models.
		const setModelsCalls = calls.filter((c) => c.fn === "setAvailableModels");
		expect(setModelsCalls.length).toBe(1);
		expect((setModelsCalls[0].arg as CodexModelDescriptor[]).length).toBeGreaterThan(0);
	});

	test("sets models from catalog on successful fetch", async () => {
		const { calls, callbacks } = createCallbackCollector();

		const model = makeModel({ isDefault: true, model: "gpt-5", defaultReasoningEffort: "high" });
		const api = {
			listClaudeModels: async () => makeCatalog([model]),
			listCodexModels: async () => makeCatalog([model]),
		};

		await fetchModelsForProvider("codex", api, callbacks);

		const modelSetCall = calls.find((c) => c.fn === "setSelectedModel" && c.arg !== null);
		expect(modelSetCall).toBeDefined();
		expect(modelSetCall!.arg).toBe("gpt-5");
	});

	test("calls listClaudeModels when provider is claude", async () => {
		const { callbacks } = createCallbackCollector();

		let claudeCalled = false;
		let codexCalled = false;
		const api = {
			listClaudeModels: async () => {
				claudeCalled = true;
				return makeCatalog([makeModel({ isDefault: true })]);
			},
			listCodexModels: async () => {
				codexCalled = true;
				return makeCatalog([]);
			},
		};

		await fetchModelsForProvider("claude", api, callbacks);

		expect(claudeCalled).toBe(true);
		expect(codexCalled).toBe(false);
	});

	test("clears models on fetch error", async () => {
		const { calls, callbacks } = createCallbackCollector();

		const api = {
			listClaudeModels: async (): Promise<CodexModelsCatalog> => {
				throw new Error("network error");
			},
			listCodexModels: async (): Promise<CodexModelsCatalog> => {
				throw new Error("network error");
			},
		};

		await fetchModelsForProvider("codex", api, callbacks);

		const setModelsCalls = calls.filter((c) => c.fn === "setAvailableModels");
		expect(setModelsCalls.length).toBe(1);
		expect(setModelsCalls[0].arg).toEqual([]);
	});

	test("sets hasLoadedCodexModels to true in finally block", async () => {
		const { calls, callbacks } = createCallbackCollector();

		const api = {
			listClaudeModels: async (): Promise<CodexModelsCatalog> => {
				throw new Error("network error");
			},
			listCodexModels: async (): Promise<CodexModelsCatalog> => {
				throw new Error("network error");
			},
		};

		await fetchModelsForProvider("codex", api, callbacks);

		const lastCall = calls[calls.length - 1];
		expect(lastCall).toEqual({ fn: "setHasLoadedCodexModels", arg: true });
	});

	test("handles empty catalog without error", async () => {
		const { calls, callbacks } = createCallbackCollector();

		const api = {
			listClaudeModels: async () => makeCatalog([]),
			listCodexModels: async () => makeCatalog([]),
		};

		await fetchModelsForProvider("codex", api, callbacks);

		const selectedModelCall = calls.find((c) => c.fn === "setSelectedModel");
		expect(selectedModelCall).toBeDefined();
		expect(selectedModelCall!.arg).toBeNull();
	});
});
