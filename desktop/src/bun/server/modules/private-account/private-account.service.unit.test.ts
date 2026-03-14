import { expect, test } from "bun:test";
import { Elysia } from "elysia";

import { PrivateAccountRepository } from "./private-account.repository";
import { PrivateAccountService } from "./private-account.service";
import type { RelayConnectorOptions } from "./relay-connector.client";

const createInMemoryRepository = (): PrivateAccountRepository => {
	const values = new Map<string, string>();
	return new PrivateAccountRepository({
		getValue: (key: string) => values.get(key) ?? null,
		setValue: (key: string, value: string) => {
			values.set(key, value);
		},
	} as never);
};

const createFakeRelayClientFactory = () => {
	let options: RelayConnectorOptions | null = null;
	const startCalls: Array<{
		connectorId: string;
		connectorToken: string;
		localServerBaseUrl: string;
		privateBackendUrl: string;
	}> = [];
	const client = {
		getState: () => "idle" as const,
		start: (input: {
			connectorId: string;
			connectorToken: string;
			localServerBaseUrl: string;
			privateBackendUrl: string;
		}) => {
			startCalls.push(input);
		},
		stop: () => undefined,
	};

	return {
		createRelayClient: (nextOptions: RelayConnectorOptions) => {
			options = nextOptions;
			return client;
		},
		emitError: (message: string) => {
			options?.onError?.(message);
		},
		emitState: (state: "idle" | "connecting" | "connected" | "disconnected" | "error") => {
			options?.onStateChange?.(state);
		},
		startCalls,
	};
};

test("PrivateAccountService returns an unauthenticated state by default", async () => {
	const service = new PrivateAccountService(createInMemoryRepository(), {
		backendUrl: "http://127.0.0.1:8787",
		localServerToken: "local-token",
	});

	const state = await service.getState();

	expect(state.authenticated).toBe(false);
	expect(state.user).toBeNull();
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

test("getState refreshes the subscription state from /v1/private/me before exposing state", async () => {
	const privateApp = new Elysia()
		.get("/v1/private/me", ({ request }) => {
			expect(request.headers.get("authorization")).toBe("Bearer access-token");
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
			expect(request.headers.get("authorization")).toBe("Bearer access-token");
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
		});

	await privateApp.listen(0);
	const privatePort = privateApp.server?.port;
	if (typeof privatePort !== "number") {
		throw new Error("listener_port_unavailable");
	}

	try {
		const repository = createInMemoryRepository();
		repository.saveSession({
			accessToken: "access-token",
			refreshToken: "refresh-token",
			user: {
				daysRemaing: 30,
				daysRemaining: 30,
				email: "Dev@Example.com",
				id: "usr_1",
				subscribed: false,
			},
		});
		repository.saveConnector({
			backendUrl: `http://127.0.0.1:${privatePort}`,
			connectorId: "con_1",
			connectorName: "Desktop Connector",
			connectorToken: "connector-token",
		});
		const service = new PrivateAccountService(repository, {
			backendUrl: `http://127.0.0.1:${privatePort}`,
			localServerToken: "local-token",
		});

		const state = await service.getState();

		expect(state.user?.subscribed).toBe(true);
		expect(state.connector?.id).toBe("con_1");
	} finally {
		await privateApp.stop();
	}
});

test("PrivateAccountService reconnects after relay errors and clears relay errors once connected again", async () => {
	const privateApp = new Elysia()
		.get("/v1/private/me", () => ({
			user: {
				daysRemaing: 30,
				daysRemaining: 30,
				email: "dev@example.com",
				id: "usr_1",
				subscribed: true,
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
		}));

	await privateApp.listen(0);
	const privatePort = privateApp.server?.port;
	if (typeof privatePort !== "number") {
		throw new Error("listener_port_unavailable");
	}

	try {
		const relay = createFakeRelayClientFactory();
		const repository = createInMemoryRepository();
		repository.saveSession({
			accessToken: "access-token",
			refreshToken: "refresh-token",
			user: {
				daysRemaing: 30,
				daysRemaining: 30,
				email: "dev@example.com",
				id: "usr_1",
				subscribed: true,
			},
		});
		repository.saveConnector({
			backendUrl: `http://127.0.0.1:${privatePort}`,
			connectorId: "con_1",
			connectorName: "Desktop Connector",
			connectorToken: "connector-token",
		});

		const service = new PrivateAccountService(repository, {
			backendUrl: `http://127.0.0.1:${privatePort}`,
			createRelayClient: relay.createRelayClient,
			localServerToken: "local-token",
			reconnectDelayMs: 5,
		});

		await service.attachRuntime({
			app: new Elysia() as never,
			baseUrl: "http://127.0.0.1:8835",
		});
		expect(relay.startCalls).toHaveLength(1);

		relay.emitError("private_relay_socket_error");
		relay.emitState("error");
		await Bun.sleep(20);
		expect(relay.startCalls).toHaveLength(2);

		relay.emitState("connected");
		const state = await service.getState();

		expect(state.connectorRelayState).toBe("connected");
		expect(state.errorMessage).toBeNull();
	} finally {
		await privateApp.stop();
	}
});

test("PrivateAccountService re-bootstraps a missing persisted connector before exposing state", async () => {
	let listConnectorsCallCount = 0;
	const privateApp = new Elysia()
		.get("/v1/private/me", () => ({
			user: {
				daysRemaing: 30,
				daysRemaining: 30,
				email: "dev@example.com",
				id: "usr_1",
				subscribed: false,
			},
		}))
		.get("/v1/private/connectors", () => {
			listConnectorsCallCount += 1;
			if (listConnectorsCallCount === 1) {
				return {
					connectors: [],
				};
			}

			return {
				connectors: [
					{
						claimedAt: new Date().toISOString(),
						hostname: "devbox.local",
						id: "con_recovered",
						isOnline: true,
						lastSeenAt: new Date().toISOString(),
						name: "Recovered Connector",
						relayCapabilitiesVersion: "1",
						relayVersion: "1.0.0",
						status: "online",
					},
				],
			};
		})
		.post("/v1/private/connectors/bootstrap", () => ({
			connector: {
				id: "con_recovered",
				name: "Recovered Connector",
			},
			expiresAt: new Date(Date.now() + 60_000).toISOString(),
			pairing: {
				code: "PAIR-RECOVER",
				id: "pair_recover",
				pollToken: "poll_recover",
			},
		}))
		.post("/v1/private/pairing/claim", () => ({
			claimedAt: new Date().toISOString(),
			connectorId: "con_recovered",
			status: "claimed",
		}))
		.get("/v1/private/connectors/bootstrap/:pairingId/status", () => ({
			connector: {
				accessToken: "connector-token-recovered",
				id: "con_recovered",
			},
			expiresAt: new Date(Date.now() + 60_000).toISOString(),
			status: "claimed",
		}));

	await privateApp.listen(0);
	const privatePort = privateApp.server?.port;
	if (typeof privatePort !== "number") {
		throw new Error("listener_port_unavailable");
	}

	try {
		const relay = createFakeRelayClientFactory();
		const repository = createInMemoryRepository();
		repository.saveSession({
			accessToken: "access-token",
			refreshToken: "refresh-token",
			user: {
				daysRemaing: 30,
				daysRemaining: 30,
				email: "dev@example.com",
				id: "usr_1",
				subscribed: false,
			},
		});
		repository.saveConnector({
			backendUrl: `http://127.0.0.1:${privatePort}`,
			connectorId: "con_stale",
			connectorName: "Stale Connector",
			connectorToken: "stale-token",
		});

		const service = new PrivateAccountService(repository, {
			backendUrl: `http://127.0.0.1:${privatePort}`,
			createRelayClient: relay.createRelayClient,
			localServerToken: "local-token",
		});

		await service.attachRuntime({
			app: new Elysia() as never,
			baseUrl: "http://127.0.0.1:8835",
		});

		const state = await service.getState();
		const persistedConnector = repository.readConnector();

		expect(state.connector?.id).toBe("con_recovered");
		expect(persistedConnector?.connectorId).toBe("con_recovered");
		expect(relay.startCalls.at(-1)?.connectorId).toBe("con_recovered");
	} finally {
		await privateApp.stop();
	}
});
