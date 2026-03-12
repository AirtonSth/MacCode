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

const resolveExpectedDesktopPlatform = (): "linux" | "macos" | "windows" => {
	switch (process.platform) {
		case "darwin":
			return "macos";
		case "win32":
			return "windows";
		default:
			return "linux";
	}
};

test("desktop private-account browser routes hand off to the web flow and localhost callback completes auth", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-private-account-browser-"));
	const databasePath = join(root, "remotecode.sqlite");
	const expectedDesktopPlatform = resolveExpectedDesktopPlatform();
	const privateApp = new Elysia()
		.post("/v1/private/auth/completion/exchange", ({ body }) => {
			expect(body).toEqual({
				completionToken: "token_123",
			});

			return {
				accessToken: "access-token",
				refreshToken: "refresh-token",
				user: {
					daysRemaing: 30,
					daysRemaining: 30,
					email: "dev@example.com",
					id: "usr_1",
					subscribed: false,
				},
			};
		})
		.get("/v1/private/connectors", ({ request }) => {
			expect(readBearer(request.headers.get("authorization"))).toBe("access-token");
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
			expect(readBearer(request.headers.get("authorization"))).toBe("access-token");
			return {
				claimedAt: new Date().toISOString(),
				connectorId: "con_1",
				status: "claimed",
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
	let backendHandle: Awaited<ReturnType<typeof createBackendServer>> | undefined;

	try {
		const privatePort = requirePort(privateApp.server);
		backendHandle = await createBackendServer({
			databasePath,
			disableLiveActivityPush: true,
			port: 0,
			privateBackendUrl: `http://127.0.0.1:${privatePort}`,
		});
		const baseUrl = `http://127.0.0.1:${requirePort(backendHandle.server)}`;

		const registerResponse = await fetch(`${baseUrl}/v1/private-account/browser/register`, {
			body: JSON.stringify({
				email: "dev@example.com",
			}),
			headers: {
				authorization: "Bearer remotecode.io-token",
				"content-type": "application/json",
			},
			method: "POST",
		});
		expect(registerResponse.status).toBe(200);
		const registerPayload = await registerResponse.json() as { url: string };
		const registerUrl = new URL(registerPayload.url);
		expect(registerUrl.origin).toBe("https://remotecode.io");
		expect(registerUrl.pathname).toBe("/register");
		expect(registerUrl.searchParams.get("target")).toBe("desktop");
		expect(registerUrl.searchParams.get("platform")).toBe(expectedDesktopPlatform);
		expect(registerUrl.searchParams.get("email")).toBe("dev@example.com");

		const forgotResponse = await fetch(`${baseUrl}/v1/private-account/browser/forgot-password`, {
			body: JSON.stringify({
				email: "dev@example.com",
			}),
			headers: {
				authorization: "Bearer remotecode.io-token",
				"content-type": "application/json",
			},
			method: "POST",
		});
		expect(forgotResponse.status).toBe(200);
		const forgotPayload = await forgotResponse.json() as { url: string };
		expect(forgotPayload.url).toContain("https://remotecode.io/forgot-password");
		expect(forgotPayload.url).toContain("email=dev%40example.com");

		const manageResponse = await fetch(`${baseUrl}/v1/private-account/browser/manage-subscription`, {
			headers: {
				authorization: "Bearer remotecode.io-token",
			},
		});
		expect(manageResponse.status).toBe(200);
		const managePayload = await manageResponse.json() as { url: string };
		expect(managePayload.url).toBe("https://remotecode.io/app");

		const callbackResponse = await fetch(
			`${baseUrl}/v1/private-account/browser-return?backendUrl=http%3A%2F%2F127.0.0.1%3A${privatePort}&completionToken=token_123`,
		);
		expect(callbackResponse.status).toBe(200);
		expect(await callbackResponse.text()).toContain("RemoteCode desktop is ready");

		const stateResponse = await fetch(`${baseUrl}/v1/private-account/state`, {
			headers: {
				authorization: "Bearer remotecode.io-token",
			},
		});
		expect(stateResponse.status).toBe(200);
		const statePayload = await stateResponse.json() as {
			authenticated: boolean;
			user: {
				email: string;
				subscribed: boolean;
			} | null;
		};
		expect(statePayload.authenticated).toBe(true);
		expect(statePayload.user?.email).toBe("dev@example.com");
		expect(statePayload.user?.subscribed).toBe(false);
	} finally {
		if (backendHandle) {
			await backendHandle.privateAccountService.logout();
			await backendHandle.app.stop(true);
			backendHandle.db.close();
		}
		await privateApp.stop(true);
		rmSync(root, { force: true, recursive: true });
	}
});
