import { expect, test } from "bun:test";
import { Elysia } from "elysia";

import { ProviderController } from "./provider.controller";
import { CodexModelsServiceError, type CodexModelsService } from "./codex-models.service";

test("ProviderController returns codex model catalog", async () => {
	const app = new Elysia().group("/v1", (group) =>
		group.use(
			ProviderController.build(
				{
					getModelsCatalog: async () => ({
						models: [
							{
								defaultReasoningEffort: "medium",
								description: "Latest frontier agentic coding model.",
								displayName: "gpt-5.3-codex",
								id: "gpt-5.3-codex",
								isDefault: true,
								model: "gpt-5.3-codex",
								supportedReasoningEfforts: [
									{ description: "Medium", reasoningEffort: "medium" },
									{ description: "High", reasoningEffort: "high" },
								],
							},
						],
						nextCursor: null,
					}),
				} as unknown as CodexModelsService,
				{
					getModelsCatalog: async () => ({
						models: [],
						nextCursor: null,
					}),
				} as unknown as any,
			),
		),
	);

	const response = await app.handle(
		new Request("http://localhost/v1/providers/codex/models", {
			headers: { authorization: "Bearer local-dev-token" },
			method: "GET",
		}),
	);
	const payload = await response.json();

	expect(response.status).toBe(200);
	expect(payload).toEqual({
		models: [
			{
				defaultReasoningEffort: "medium",
				description: "Latest frontier agentic coding model.",
				displayName: "gpt-5.3-codex",
				id: "gpt-5.3-codex",
				isDefault: true,
				model: "gpt-5.3-codex",
				supportedReasoningEfforts: [
					{ description: "Medium", reasoningEffort: "medium" },
					{ description: "High", reasoningEffort: "high" },
				],
			},
		],
		nextCursor: null,
	});
});

test("ProviderController returns 503 when codex models cannot be loaded", async () => {
	const app = new Elysia().group("/v1", (group) =>
		group.use(
			ProviderController.build(
				{
					getModelsCatalog: async () => {
						throw new CodexModelsServiceError("codex unavailable", 503);
					},
				} as unknown as CodexModelsService,
				{
					getModelsCatalog: async () => ({
						models: [],
						nextCursor: null,
					}),
				} as unknown as any,
			),
		),
	);

	const response = await app.handle(
		new Request("http://localhost/v1/providers/codex/models", {
			headers: { authorization: "Bearer local-dev-token" },
			method: "GET",
		}),
	);
	const payload = await response.json();

	expect(response.status).toBe(503);
	expect(payload).toEqual({
		error: "codex unavailable",
	});
});
