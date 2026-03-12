import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Elysia } from "elysia";

import { createBackendServer } from "../../../../bun/server/app";
import { createPrivateAccountApiClient } from "./private-account-api";

const toPort = (server: unknown): number => {
	if (!server || typeof server !== "object") {
		return 3001;
	}

	return (server as { port?: number }).port ?? 3001;
};

test("private-account api client completes desktop login and logout flow through the local backend", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-private-account-api-e2e-"));
	const databasePath = join(root, "remotecode.sqlite");
	const privateApp = new Elysia()
		.post("/v1/private/auth/login", () => ({
			accessToken: "access-token",
			refreshToken: "refresh-token",
			user: {
				daysRemaing: 30,
				daysRemaining: 30,
				email: "dev@example.com",
				id: "usr_1",
				subscribed: true,
			},
		}))
		.post("/v1/private/auth/refresh", () => ({
			accessToken: "access-token",
			refreshToken: "refresh-token",
			user: {
				daysRemaing: 30,
				daysRemaining: 30,
				email: "dev@example.com",
				id: "usr_1",
				subscribed: true,
			},
		}))
		.post("/v1/private/auth/logout", ({ set }) => {
			set.status = 204;
			return null;
		})
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
		.post("/v1/private/mobile-connect/bootstrap", () => ({
			connector: {
				id: "con_1",
				name: "Desktop Connector",
			},
			expiresAt: new Date(Date.now() + 60_000).toISOString(),
			linkUrl: "https://qr.remotecode.dev/connect/mcs_1/secret_1",
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

	let backend: Awaited<ReturnType<typeof createBackendServer>> | undefined;
	try {
		backend = await createBackendServer({
			databasePath,
			disableLiveActivityPush: true,
			port: 0,
			privateBackendUrl: `http://127.0.0.1:${(privateApp.server as { port?: number }).port ?? 8787}`,
		});
		const client = createPrivateAccountApiClient({
			baseUrl: `http://127.0.0.1:${toPort(backend.server)}`,
			token: "remotecode.io-token",
		});

		const loggedIn = await client.login({
			email: "dev@example.com",
			password: "supersecret",
		});
		expect(loggedIn.authenticated).toBe(true);
		expect(loggedIn.qrPayload?.type).toBe("remotecode_private_mobile_connect");

		const loggedOut = await client.logout();
		expect(loggedOut.authenticated).toBe(false);
		expect(loggedOut.qrPayload).toBeNull();
	} finally {
		if (backend) {
			await backend.app.stop(true);
			backend.db.close();
		}
		await privateApp.stop(true);
		rmSync(root, { force: true, recursive: true });
	}
});
