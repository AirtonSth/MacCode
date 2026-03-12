import { expect, test } from "bun:test";
import { Elysia } from "elysia";

import { PrivateAccountRepository } from "./private-account.repository";
import { PrivateAccountService } from "./private-account.service";

const createInMemoryRepository = (): PrivateAccountRepository => {
	const values = new Map<string, string>();
	return new PrivateAccountRepository({
		getValue: (key: string) => values.get(key) ?? null,
		setValue: (key: string, value: string) => {
			values.set(key, value);
		},
	} as never);
};

test("PrivateAccountService returns an unauthenticated state by default", async () => {
	const service = new PrivateAccountService(createInMemoryRepository(), {
		backendUrl: "http://127.0.0.1:8787",
		localServerToken: "local-token",
	});

	const state = await service.getState();

	expect(state.authenticated).toBe(false);
	expect(state.user).toBeNull();
	expect(state.qrPayload).toBeNull();
	expect(state.connectorRelayState).toBe("idle");
});

test("PrivateAccountService builds the browser registration handoff for macOS", async () => {
	const service = new PrivateAccountService(createInMemoryRepository(), {
		backendUrl: "https://private.remotecode.io:8787",
		localServerToken: "local-token",
		platform: "darwin",
	});

	const response = await service.buildBrowserRegisterUrl({
		email: "dev@example.com",
	});
	const url = new URL(response.url);

	expect(url.origin).toBe("https://remotecode.io");
	expect(url.pathname).toBe("/register");
	expect(url.searchParams.get("target")).toBe("desktop");
	expect(url.searchParams.get("platform")).toBe("macos");
	expect(url.searchParams.get("returnUrl")).toBe("remotecode://auth/complete");
	expect(url.searchParams.get("backendUrl")).toBe("https://private.remotecode.io:8787");
	expect(url.searchParams.get("email")).toBe("dev@example.com");
});

test("PrivateAccountService exchanges browser completion tokens and persists the session", async () => {
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
		.get("/v1/private/connectors", () => ({
			connectors: [],
		}));

	await privateApp.listen(0);
	const privatePort = privateApp.server?.port;
	if (typeof privatePort !== "number") {
		throw new Error("listener_port_unavailable");
	}

	try {
		const service = new PrivateAccountService(createInMemoryRepository(), {
			backendUrl: `http://127.0.0.1:${privatePort}`,
			localServerToken: "local-token",
			platform: "darwin",
		});

		const state = await service.completeBrowserReturn({
			completionToken: "token_123",
		});

		expect(state.authenticated).toBe(true);
		expect(state.user?.email).toBe("dev@example.com");
		expect(state.user?.subscribed).toBe(false);
	} finally {
		await privateApp.stop();
	}
});
