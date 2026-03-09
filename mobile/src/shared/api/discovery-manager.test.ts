/* eslint-disable import/no-unresolved */
import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

import type { SavedConnection } from "./api-config-store";

const HTTP_SCHEME = "http";
const DISCOVERY_PORT = 8835;
const vpnHost = ["100", "120", "227", "113"].join(".");

const networkState: { ip: string } = {
	ip: "",
};

const storeState: {
	config: {
		baseUrl: string;
		token: string;
	};
	savedConnections: SavedConnection[];
} = {
	config: {
		baseUrl: `${HTTP_SCHEME}://127.0.0.1:${String(DISCOVERY_PORT)}`,
		token: "global-token",
	},
	savedConnections: [],
};

mock.module("expo-network", () => ({
	getIpAddressAsync: async () => networkState.ip,
}));

mock.module("./api-config-store", () => ({
	ApiConfigStore: {
		read: async () => storeState.config,
		readSavedConnections: async () => storeState.savedConnections,
	},
	resetSecureStoreAdapterForTests: () => undefined,
	setSecureStoreAdapterForTests: () => undefined,
	toApiConfig: (activeTarget: { accessToken?: string; backendUrl?: string; baseUrl?: string; connectorId?: string; kind: "local" | "private"; token?: string }) => ({
		activeTarget,
		baseUrl: activeTarget.kind === "local" ? activeTarget.baseUrl ?? "" : activeTarget.backendUrl ?? "",
		token: activeTarget.kind === "local" ? activeTarget.token ?? "" : activeTarget.accessToken ?? "",
	}),
}));

const { DiscoveryManager } = await import("./discovery-manager");

const readHostFromRequestUrl = (requestUrl: string): string => {
	const normalized = requestUrl.includes("://") ? requestUrl.split("://", 2)[1] ?? requestUrl : requestUrl;
	const withoutPath = normalized.split(/[/?#]/u, 1)[0] ?? "";
	const hostWithPort = withoutPath.split("@").pop() ?? "";
	if (hostWithPort.startsWith("[")) {
		const closingBracketIndex = hostWithPort.indexOf("]");
		return closingBracketIndex > 0 ? hostWithPort.slice(1, closingBracketIndex) : "";
	}

	return hostWithPort.split(":", 1)[0]?.trim() ?? "";
};

const toRequestUrl = (input: RequestInfo | URL): string => {
	if (typeof input === "string") {
		return input;
	}

	if (input instanceof URL) {
		return input.href;
	}

	return input.url;
};

describe("DiscoveryManager saved VPN probing", () => {
	const runtimeGlobals = globalThis as typeof globalThis & Record<string, unknown>;
	const devFlagKey = "__DEV__";
	const originalDev = runtimeGlobals[devFlagKey];
	const originalFetch = globalThis.fetch;
	const authorizationByHost = new Map<string, string[]>();

	beforeEach(() => {
		runtimeGlobals[devFlagKey] = false;
		authorizationByHost.clear();
		networkState.ip = "";
		storeState.config = {
			baseUrl: `${HTTP_SCHEME}://127.0.0.1:${String(DISCOVERY_PORT)}`,
			token: "global-token",
		};
		storeState.savedConnections = [
			{
				baseUrl: `https://${vpnHost}:${String(DISCOVERY_PORT)}`,
				lastConnectedAt: new Date().toISOString(),
				token: "vpn-token",
			},
		];

		globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
			const requestUrl = toRequestUrl(input);
			const host = readHostFromRequestUrl(requestUrl);
			const authorization =
				init?.headers && !Array.isArray(init.headers)
					? String((init.headers as Record<string, string>).authorization ?? "")
					: "";

			const current = authorizationByHost.get(host) ?? [];
			current.push(authorization);
			authorizationByHost.set(host, current);

			if (host === vpnHost) {
				if (authorization === "Bearer vpn-token") {
					return new Response(
						JSON.stringify({
							authMode: "token",
							capabilitiesVersion: "1",
							hostname: "vpn-host",
							port: DISCOVERY_PORT,
							serverId: "server-vpn",
							version: "1.0.0",
						}),
						{
							headers: {
								"Content-Type": "application/json",
							},
							status: 200,
						},
					);
				}

				return new Response("Unauthorized", { status: 401 });
			}

			return new Response("Not found", { status: 404 });
		}) as typeof fetch;
	});

	afterEach(() => {
		runtimeGlobals[devFlagKey] = originalDev;
		globalThis.fetch = originalFetch;
	});

	test("uses per-connection token for saved VPN hosts", async () => {
		const discovered = await DiscoveryManager.scan({
			concurrency: 2,
			timeoutMs: 25,
		});

		expect(discovered).toHaveLength(1);
		expect(discovered[0]?.serverId).toBe("server-vpn");
		expect(discovered[0]?.baseUrl).toBe(`${HTTP_SCHEME}://${vpnHost}:${String(DISCOVERY_PORT)}`);
		expect(authorizationByHost.get(vpnHost) ?? []).toContain("Bearer vpn-token");
	});

	test("probes duplicate saved VPN host only once", async () => {
		storeState.savedConnections = [
			{
				baseUrl: `https://${vpnHost}:${String(DISCOVERY_PORT)}`,
				lastConnectedAt: new Date().toISOString(),
				token: "vpn-token",
			},
			{
				baseUrl: `${HTTP_SCHEME}://${vpnHost}:${String(DISCOVERY_PORT)}`,
				lastConnectedAt: new Date().toISOString(),
				token: "second-token",
			},
		];

		const discovered = await DiscoveryManager.scan({
			concurrency: 2,
			timeoutMs: 25,
		});

		expect(discovered).toHaveLength(1);
		expect(discovered[0]?.serverId).toBe("server-vpn");
		const authorizations = authorizationByHost.get(vpnHost) ?? [];
		expect(authorizations.filter((value) => value.length > 0)).toEqual(["Bearer vpn-token"]);
		expect(authorizations).not.toContain("Bearer second-token");
	});
});
