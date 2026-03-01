import { expect, test } from "bun:test";

import { createTestServer } from "../../shared/core/test-server";
import { getCodexAvailability } from "./codex-test-gate";

const codexAvailability = getCodexAvailability();
const codexTest = test.skipIf(!codexAvailability.available);
const skipReasonSuffix = codexAvailability.available ? "" : ` (skip: ${codexAvailability.reason})`;

codexTest(
	`GET /v1/providers/codex/models returns codex model catalog${skipReasonSuffix}`,
	async () => {
		const { cleanup, client } = await createTestServer();

		try {
			const response = await client.v1.providers.codex.models.get();
			const payload = response.data as {
				models: Array<{
					id: string;
					isDefault: boolean;
					model: string;
					supportedReasoningEfforts: Array<{
						reasoningEffort: string;
					}>;
				}>;
				nextCursor: string | null;
			};

			expect(response.status).toBe(200);
			expect(Array.isArray(payload.models)).toBe(true);
			expect(payload.models.length).toBeGreaterThan(0);
			expect(payload.models[0]).toEqual(
				expect.objectContaining({
					id: expect.any(String),
					model: expect.any(String),
				}),
			);
			expect(payload.models.some((model) => model.isDefault)).toBe(true);
			expect(payload.models.some((model) => model.supportedReasoningEfforts.length > 0)).toBe(true);
			expect(payload.nextCursor).toBeNull();
		} finally {
			await cleanup();
		}
	},
	60_000,
);
