import type { CodexModelsCatalog } from "../../../../shared/codex-model-config";

export class ClaudeModelsService {
	async getModelsCatalog(): Promise<CodexModelsCatalog> {
		return {
			models: [
				{
					defaultReasoningEffort: "medium",
					description: "Fast, intelligent, and versatile",
					displayName: "Claude Sonnet",
					id: "claude-sonnet",
					isDefault: true,
					model: "sonnet",
					supportedReasoningEfforts: [
						{ description: "Faster responses", reasoningEffort: "low" },
						{ description: "Balanced", reasoningEffort: "medium" },
						{ description: "Deeper reasoning", reasoningEffort: "high" },
					],
				},
				{
					defaultReasoningEffort: "medium",
					description: "Most capable for complex tasks",
					displayName: "Claude Opus",
					id: "claude-opus",
					isDefault: false,
					model: "opus",
					supportedReasoningEfforts: [
						{ description: "Faster responses", reasoningEffort: "low" },
						{ description: "Balanced", reasoningEffort: "medium" },
						{ description: "Deeper reasoning", reasoningEffort: "high" },
					],
				},
				{
					defaultReasoningEffort: "low",
					description: "Fastest responses",
					displayName: "Claude Haiku",
					id: "claude-haiku",
					isDefault: false,
					model: "haiku",
					supportedReasoningEfforts: [
						{ description: "Faster responses", reasoningEffort: "low" },
						{ description: "Balanced", reasoningEffort: "medium" },
					],
				},
			],
			nextCursor: null,
		};
	}
}
