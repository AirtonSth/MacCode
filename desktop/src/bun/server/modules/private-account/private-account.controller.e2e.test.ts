import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Elysia } from "elysia";
import { expect, test } from "bun:test";

import { createBackendServer } from "../../app";

const requirePort = (server: unknown): number => {
	if (!server || typeof server !== "object" || typeof (server as { port?: number }).port !== "number") {
		throw new Error("listener_port_unavailable");
	}

	return (server as { port: number }).port;
};

const readBearer = (value: string | null): string | null => {
	if (!value) {
		return null;
	}

	return value.startsWith("Bearer ") ? value.slice(7).trim() || null : value.trim() || null;
};

test("desktop private-account routes authenticate, expose QR state, and logout cleanly", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-private-account-controller-"));
	const databasePath = join(root, "remotecode.sqlite");
	const loginAccessToken = "access-token";
	const loginRefreshToken = "refresh-token";
	const registerAccessToken = "register-access-token";
	const registerRefreshToken = "register-refresh-token";
	let mobileConnectBootstrapCount = 0;
	const privateApp = new Elysia()
		.post("/v1/private/auth/login", ({ body }) => {
			expect(body).toEqual({
				email: "dev@example.com",
				password: "supersecret",
			});

			return {
				accessToken: loginAccessToken,
				refreshToken: loginRefreshToken,
				user: {
					daysRemaing: 30,
					daysRemaining: 30,
					email: "dev@example.com",
					id: "usr_1",
					subscribed: true,
				},
			};
		})
		.post("/v1/private/auth/register", ({ body }) => {
			expect(body).toEqual({
				email: "founder@example.com",
				password: "supersecret",
			});

			return {
				accessToken: registerAccessToken,
				refreshToken: registerRefreshToken,
				user: {
					daysRemaing: 30,
					daysRemaining: 30,
					email: "founder@example.com",
					id: "usr_2",
					subscribed: true,
				},
			};
		})
		.post("/v1/private/auth/refresh", ({ body }) => {
			expect(body).toEqual({
				refreshToken: loginRefreshToken,
			});

			return {
				accessToken: loginAccessToken,
				refreshToken: loginRefreshToken,
				user: {
					daysRemaing: 30,
					daysRemaining: 30,
					email: "dev@example.com",
					id: "usr_1",
					subscribed: true,
				},
			};
		})
		.post("/v1/private/auth/logout", ({ body, set }) => {
			expect(body).toEqual({
				refreshToken: loginRefreshToken,
			});
			set.status = 204;
			return null;
		})
		.get("/v1/private/me", ({ request }) => {
			expect(readBearer(request.headers.get("authorization"))).toBe(loginAccessToken);
			return {
				user: {
					daysRemaing: 30,
					daysRemaining: 30,
					email: "dev@example.com",
					id: "usr_1",
					subscribed: true,
				},
			};
		})
		.get("/v1/private/connectors", ({ request }) => {
			expect([loginAccessToken, registerAccessToken]).toContain(readBearer(request.headers.get("authorization")));
			return {
				connectors: [
					{
						claimedAt: new Date().toISOString(),
						hostname: "devbox.local",
						id: "con_1",
						isOnline: true,
						lastSeenAt: new Date().toISOString(),
						name: "Desktop Connector",
						relayCapabilitiesVersion: "1",
						relayVersion: "1.0.0",
						status: "online",
					},
				],
			};
		})
		.post("/v1/private/connectors/bootstrap", () => ({
			connector: {
				id: "con_1",
				name: "Desktop Connector",
			},
			expiresAt: new Date(Date.now() + 60_000).toISOString(),
			pairing: {
				code: "PAIR-123",
				id: "pair_1",
				pollToken: "poll_1",
				qrPayload: {
					backendUrl: "http://127.0.0.1:8787",
					pairingCode: "PAIR-123",
					pairingId: "pair_1",
					type: "remotecode_private_pairing",
					version: 1,
				},
			},
		}))
		.post("/v1/private/pairing/claim", ({ request }) => {
			expect([loginAccessToken, registerAccessToken]).toContain(readBearer(request.headers.get("authorization")));
			return {
				claimedAt: new Date().toISOString(),
				connectorId: "con_1",
				status: "claimed",
			};
		})
		.post("/v1/private/mobile-connect/bootstrap", ({ body, request }) => {
			expect([loginAccessToken, registerAccessToken]).toContain(readBearer(request.headers.get("authorization")));
			expect(body).toEqual({
				connectorId: "con_1",
			});
			mobileConnectBootstrapCount += 1;
			return {
				connector: {
					id: "con_1",
					name: "Desktop Connector",
				},
				expiresAt: new Date(Date.now() + 60_000).toISOString(),
				linkUrl: `https://qr.remotecode.dev/connect/mcs_${mobileConnectBootstrapCount}/secret_${mobileConnectBootstrapCount}`,
			};
		})
		.get("/v1/private/connectors/bootstrap/:pairingId/status", () => ({
			connector: {
				accessToken: "connector-token",
				id: "con_1",
			},
			expiresAt: new Date(Date.now() + 60_000).toISOString(),
			status: "claimed",
		}))
		.ws("/v1/private/connectors/socket", {
			open: (ws) => {
				ws.send(JSON.stringify({
					authenticated: true,
					connectorId: "con_1",
					type: "connector_auth",
				}));
			},
		});

	await privateApp.listen(0);
	const privatePort = requirePort(privateApp.server);

	let server:
		| Awaited<ReturnType<typeof createBackendServer>>
		| undefined;

	try {
		server = await createBackendServer({
			databasePath,
			disableLiveActivityPush: true,
			port: 0,
			privateMobileConnectRefreshIntervalMs: 5,
			privateBackendUrl: `http://127.0.0.1:${privatePort}`,
		});
		const baseUrl = `http://127.0.0.1:${requirePort(server.server)}`;

		const loginResponse = await fetch(`${baseUrl}/v1/private-account/login`, {
			body: JSON.stringify({
				email: "dev@example.com",
				password: "supersecret",
			}),
			headers: {
				authorization: "Bearer remotecode.io-token",
				"content-type": "application/json",
			},
			method: "POST",
		});

		expect(loginResponse.status).toBe(200);
		const loginPayload = await loginResponse.json() as {
			authenticated: boolean;
			qrPayload: {
				connectorId: string;
				linkUrl?: string | null;
				type: string;
			} | null;
			user: {
				email: string;
			} | null;
		};
		expect(loginPayload.authenticated).toBe(true);
		expect(loginPayload.user?.email).toBe("dev@example.com");
		expect(loginPayload.qrPayload?.connectorId).toBe("con_1");
		expect(loginPayload.qrPayload?.linkUrl).toContain("https://qr.remotecode.dev/connect/");
		expect(loginPayload.qrPayload?.type).toBe("remotecode_private_mobile_connect");

		await Bun.sleep(20);

		const stateResponse = await fetch(`${baseUrl}/v1/private-account/state`, {
			headers: {
				authorization: "Bearer remotecode.io-token",
			},
		});
		expect(stateResponse.status).toBe(200);
		const statePayload = await stateResponse.json() as {
			authenticated: boolean;
			connector: { id: string } | null;
			connectorRelayState: string;
			qrPayload: { linkUrl?: string | null } | null;
		};
		expect(statePayload.authenticated).toBe(true);
		expect(statePayload.connector?.id).toBe("con_1");
		expect(["connecting", "connected"]).toContain(statePayload.connectorRelayState);
		expect(statePayload.qrPayload?.linkUrl).toContain("mcs_2");

		const logoutResponse = await fetch(`${baseUrl}/v1/private-account/logout`, {
			headers: {
				authorization: "Bearer remotecode.io-token",
			},
			method: "POST",
		});
		expect(logoutResponse.status).toBe(200);
		const logoutPayload = await logoutResponse.json() as {
			authenticated: boolean;
			connector: { id: string } | null;
			qrPayload: { connectorId: string } | null;
			user: { email: string } | null;
		};
		expect(logoutPayload.authenticated).toBe(false);
		expect(logoutPayload.connector).toBeNull();
		expect(logoutPayload.qrPayload).toBeNull();
		expect(logoutPayload.user).toBeNull();

		const registerResponse = await fetch(`${baseUrl}/v1/private-account/register`, {
			body: JSON.stringify({
				email: "founder@example.com",
				password: "supersecret",
			}),
			headers: {
				authorization: "Bearer remotecode.io-token",
				"content-type": "application/json",
			},
			method: "POST",
		});
		expect(registerResponse.status).toBe(200);
		const registerPayload = await registerResponse.json() as {
			authenticated: boolean;
			qrPayload: { connectorId: string; linkUrl?: string | null; type: string } | null;
			user: { email: string } | null;
		};
		expect(registerPayload.authenticated).toBe(true);
		expect(registerPayload.user?.email).toBe("founder@example.com");
		expect(registerPayload.qrPayload?.connectorId).toBe("con_1");
		expect(registerPayload.qrPayload?.linkUrl).toContain("https://qr.remotecode.dev/connect/");
		expect(registerPayload.qrPayload?.type).toBe("remotecode_private_mobile_connect");
	} finally {
		if (server) {
			await server.app.stop(true);
			server.db.close();
		}
		await privateApp.stop(true);
		rmSync(root, { force: true, recursive: true });
	}
});

test("desktop private-account login returns 503 when the private backend is unreachable", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-private-account-controller-unreachable-"));
	const databasePath = join(root, "remotecode.sqlite");
	let server:
		| Awaited<ReturnType<typeof createBackendServer>>
		| undefined;

	try {
		server = await createBackendServer({
			databasePath,
			disableLiveActivityPush: true,
			port: 0,
			privateBackendUrl: "http://127.0.0.1:1",
		});
		const baseUrl = `http://127.0.0.1:${requirePort(server.server)}`;

		const loginResponse = await fetch(`${baseUrl}/v1/private-account/login`, {
			body: JSON.stringify({
				email: "dev@example.com",
				password: "supersecret",
			}),
			headers: {
				authorization: "Bearer remotecode.io-token",
				"content-type": "application/json",
			},
			method: "POST",
		});

		expect(loginResponse.status).toBe(503);
		expect(await loginResponse.json()).toEqual({
			code: "private_backend_unreachable",
			error: "Unable to connect. Is the computer able to access the url?",
		});
	} finally {
		if (server) {
			await server.app.stop(true);
			server.db.close();
		}
		rmSync(root, { force: true, recursive: true });
	}
});
