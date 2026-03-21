import { expect, test } from "bun:test";

import { serverConfig } from "../../config";
import { createTestServer } from "../../shared/core/test-server";

test("POST /v1/auth/verify accepts body token and returns server metadata", async () => {
	const { baseUrl, cleanup } = await createTestServer();

	try {
		const response = await fetch(`${baseUrl}/v1/auth/verify`, {
			body: JSON.stringify({ token: serverConfig.token }),
			headers: {
				"content-type": "application/json",
			},
			method: "POST",
		});

		const payload = await response.json() as {
			ok: boolean;
			server: {
				authMode: string;
				capabilitiesVersion: string;
				hostname: string;
				port: number;
				serverId: string;
				version: string;
			};
		};

		expect(response.status).toBe(200);
		expect(payload.ok).toBe(true);
		expect(payload.server.serverId).toBeTruthy();
		expect(payload.server.port).toBeGreaterThanOrEqual(0);
		expect(payload.server.authMode).toBe("token_lan");
		expect(payload.server.capabilitiesVersion).toBeTruthy();
	} finally {
		await cleanup();
	}
});

test("POST /v1/auth/verify accepts bearer token from the authorization header", async () => {
	const { baseUrl, cleanup } = await createTestServer();

	try {
		const response = await fetch(`${baseUrl}/v1/auth/verify`, {
			headers: {
				authorization: `Bearer ${serverConfig.token}`,
				"content-type": "application/json",
			},
			method: "POST",
		});

		const payload = await response.json() as { ok: boolean };

		expect(response.status).toBe(200);
		expect(payload.ok).toBe(true);
	} finally {
		await cleanup();
	}
});

test("POST /v1/auth/verify rejects invalid tokens", async () => {
	const { baseUrl, cleanup } = await createTestServer();

	try {
		const response = await fetch(`${baseUrl}/v1/auth/verify`, {
			body: JSON.stringify({ token: "invalid-token" }),
			headers: {
				"content-type": "application/json",
			},
			method: "POST",
		});

		const payload = await response.json() as { error: string };

		expect(response.status).toBe(401);
		expect(payload.error).toBe("unauthorized");
	} finally {
		await cleanup();
	}
});
