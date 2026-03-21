import { expect, test } from "bun:test";

import { createTestServer } from "../../shared/core/test-server";

test("GET /v1/discovery returns public server metadata without auth", async () => {
	const { baseUrl, cleanup } = await createTestServer();

	try {
		const response = await fetch(`${baseUrl}/v1/discovery`);
		const payload = await response.json() as {
			authMode: string;
			capabilitiesVersion: string;
			hostname: string;
			port: number;
			serverId: string;
			version: string;
		};

		expect(response.status).toBe(200);
		expect(payload.serverId).toBeTruthy();
		expect(payload.hostname).toBeTruthy();
		expect(payload.port).toBeGreaterThanOrEqual(0);
		expect(payload.version).toBeTruthy();
		expect(payload.authMode).toBe("token_lan");
		expect(payload.capabilitiesVersion).toBeTruthy();
	} finally {
		await cleanup();
	}
});
