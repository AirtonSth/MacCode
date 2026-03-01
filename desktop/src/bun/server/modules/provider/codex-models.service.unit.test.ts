import { expect, test } from "bun:test";

import { CodexModelsService } from "./codex-models.service";

const buildStdoutPayload = (result: unknown): string => {
	return [
		JSON.stringify({
			id: 1,
			result: { userAgent: "Codex Desktop" },
		}),
		JSON.stringify({
			id: 2,
			result,
		}),
		"",
	].join("\n");
};

test("CodexModelsService parses model/list response", async () => {
	const service = new CodexModelsService(
		async () => ({
			exitCode: 0,
			stderr: "",
			stdout: buildStdoutPayload({
				data: [
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
		}),
	);

	const catalog = await service.getModelsCatalog();

	expect(catalog).toEqual({
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

test("CodexModelsService caches successful catalog for ttl", async () => {
	let callCount = 0;
	let nowMs = 1_000;
	const service = new CodexModelsService(
		async () => {
			callCount += 1;
			return {
				exitCode: 0,
				stderr: "",
				stdout: buildStdoutPayload({
					data: [
						{
							defaultReasoningEffort: "high",
							description: "Ultra-fast coding model.",
							displayName: "GPT-5.3-Codex-Spark",
							id: "gpt-5.3-codex-spark",
							isDefault: false,
							model: "gpt-5.3-codex-spark",
							supportedReasoningEfforts: [{ description: "High", reasoningEffort: "high" }],
						},
					],
					nextCursor: null,
				}),
			};
		},
		60_000,
		20_000,
		() => nowMs,
	);

	const first = await service.getModelsCatalog();
	nowMs += 10_000;
	const second = await service.getModelsCatalog();

	expect(callCount).toBe(1);
	expect(second).toEqual(first);
});

test("CodexModelsService returns stale cache when refresh fails", async () => {
	let callCount = 0;
	let nowMs = 1_000;
	const service = new CodexModelsService(
		async () => {
			callCount += 1;
			if (callCount === 1) {
				return {
					exitCode: 0,
					stderr: "",
					stdout: buildStdoutPayload({
						data: [
							{
								defaultReasoningEffort: "low",
								description: "Model",
								displayName: "Model",
								id: "model",
								isDefault: true,
								model: "model",
								supportedReasoningEfforts: [{ description: "Low", reasoningEffort: "low" }],
							},
						],
						nextCursor: null,
					}),
				};
			}

			throw new Error("spawn failed");
		},
		50,
		20_000,
		() => nowMs,
	);

	const first = await service.getModelsCatalog();
	nowMs += 100;
	const second = await service.getModelsCatalog();

	expect(callCount).toBe(2);
	expect(second).toEqual(first);
});

test("CodexModelsService throws 503 when no cache is available on failure", async () => {
	const service = new CodexModelsService(async () => {
		return {
			exitCode: 1,
			stderr: "codex unavailable",
			stdout: "",
		};
	});

	await expect(service.getModelsCatalog()).rejects.toEqual(
		expect.objectContaining({
			message: "codex unavailable",
			name: "CodexModelsServiceError",
			statusCode: 503,
		}),
	);
});
