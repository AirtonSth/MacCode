import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Elysia } from "elysia";
import { expect, test } from "bun:test";

import { createBackendServer } from "../../app";

const toPort = (server: unknown): number => {
	if (!server || typeof server !== "object") {
		return 3001;
	}

	return (server as { port?: number }).port ?? 3001;
};

test("desktop private-account routes authenticate and expose QR state", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-private-account-controller-"));
	const databasePath = join(root, "remotecode.sqlite");
	const privateApp = new Elysia()
		.post("/v1/private/auth/login", () => ({
			accessToken: "access-token",
			refreshToken: "refresh-token",
			user: {
				email: "dev@example.com",
				id: "usr_1",
			},
		}))
		.post("/v1/private/auth/refresh", () => ({
			accessToken: "access-token",
			refreshToken: "refresh-token",
			user: {
				email: "dev@example.com",
				id: "usr_1",
			},
		}))
		.post("/v1/private/auth/logout", ({ set }) => {
			set.status = 204;
			return null;
		})
		.get("/v1/private/me", () => ({
			user: {
				email: "dev@example.com",
				id: "usr_1",
			},
		}))
		.get("/v1/private/connectors", () => ({
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
		}))
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
		.post("/v1/private/pairing/claim", () => ({
			claimedAt: new Date().toISOString(),
			connectorId: "con_1",
			status: "claimed",
		}))
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
	const privatePort = (privateApp.server as { port?: number }).port ?? 8787;

	let server:
		| Awaited<ReturnType<typeof createBackendServer>>
		| undefined;

	try {
		server = await createBackendServer({
			databasePath,
			disableLiveActivityPush: true,
			port: 0,
			privateBackendUrl: `http://127.0.0.1:${privatePort}`,
		});
		const baseUrl = `http://127.0.0.1:${toPort(server.server)}`;

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
				type: string;
			} | null;
			user: {
				email: string;
			} | null;
		};
		expect(loginPayload.authenticated).toBe(true);
		expect(loginPayload.user?.email).toBe("dev@example.com");
		expect(loginPayload.qrPayload?.connectorId).toBe("con_1");
		expect(loginPayload.qrPayload?.type).toBe("remotecode_private_mobile_connect");

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
		};
		expect(statePayload.authenticated).toBe(true);
		expect(statePayload.connector?.id).toBe("con_1");
		expect(["connecting", "connected"]).toContain(statePayload.connectorRelayState);
	} finally {
		if (server) {
			await server.app.stop(true);
			server.db.close();
		}
		await privateApp.stop(true);
		rmSync(root, { force: true, recursive: true });
	}
});
