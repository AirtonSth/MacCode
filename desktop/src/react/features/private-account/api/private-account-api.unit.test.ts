import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

import { createPrivateAccountApiClient, PrivateAccountApiError } from "./private-account-api";

const originalFetch = globalThis.fetch;

describe("createPrivateAccountApiClient", () => {
	beforeEach(() => {
		globalThis.fetch = originalFetch;
	});

	afterEach(() => {
		globalThis.fetch = originalFetch;
	});

	test("requests private account state from the local desktop server", async () => {
		let requestedUrl = "";
		let requestedMethod = "";
		let requestedAuthorization = "";

		globalThis.fetch = mock(async (input: RequestInfo | URL, init?: RequestInit) => {
			requestedUrl = String(input);
			requestedMethod = init?.method ?? "GET";
			requestedAuthorization = new Headers(init?.headers).get("authorization") ?? "";
			return new Response(JSON.stringify({
				authenticated: false,
				connector: null,
				connectorRelayState: "idle",
				errorMessage: null,
				user: null,
			}), {
				headers: {
					"content-type": "application/json",
				},
				status: 200,
			});
		}) as unknown as typeof fetch;

		const client = createPrivateAccountApiClient({
			baseUrl: "http://127.0.0.1:3001/",
			token: "desktop-token",
		});
		const state = await client.getState();

		expect(requestedUrl).toBe("http://127.0.0.1:3001/v1/private-account/state");
		expect(requestedMethod).toBe("GET");
		expect(requestedAuthorization).toBe("Bearer desktop-token");
		expect(state.authenticated).toBe(false);
	});

	test("posts login payload to the local desktop server", async () => {
		let requestedBody = "";

		globalThis.fetch = mock(async (_input: RequestInfo | URL, init?: RequestInit) => {
			requestedBody = String(init?.body ?? "");
			return new Response(JSON.stringify({
				authenticated: true,
				connector: {
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
				connectorRelayState: "connected",
				errorMessage: null,
				user: {
					daysRemaing: 30,
					daysRemaining: 30,
					email: "dev@example.com",
					id: "usr_1",
					subscribed: true,
				},
			}), {
				headers: {
					"content-type": "application/json",
				},
				status: 200,
			});
		}) as unknown as typeof fetch;

		const client = createPrivateAccountApiClient();
		const state = await client.login({
			email: "dev@example.com",
			password: "supersecret",
		});

		expect(JSON.parse(requestedBody)).toEqual({
			email: "dev@example.com",
			password: "supersecret",
		});
		expect(state.user?.email).toBe("dev@example.com");
	});

	test("throws PrivateAccountApiError on request failure", async () => {
		globalThis.fetch = mock(async () => new Response(JSON.stringify({
			code: "unauthorized",
			error: "You are not authorized to access this desktop server.",
		}), {
			headers: {
				"content-type": "application/json",
			},
			status: 401,
			statusText: "Unauthorized",
		})) as unknown as typeof fetch;

		const client = createPrivateAccountApiClient();

		await expect(client.getState()).rejects.toMatchObject({
			message: "You are not authorized to access this desktop server.",
			status: 401,
		} satisfies Partial<PrivateAccountApiError>);
	});

	test("uses plain-text server errors when the response is not JSON", async () => {
		globalThis.fetch = mock(async () => new Response("Password must be at least 8 characters long.", {
			status: 400,
			statusText: "Bad Request",
		})) as unknown as typeof fetch;

		const client = createPrivateAccountApiClient();

		await expect(client.browserRegister({
			email: "dev@example.com",
		})).rejects.toMatchObject({
			message: "Password must be at least 8 characters long.",
			status: 400,
		} satisfies Partial<PrivateAccountApiError>);
	});

	test("requests the browser subscription management url from the local desktop server", async () => {
		let requestedUrl = "";

		globalThis.fetch = mock(async (input: RequestInfo | URL) => {
			requestedUrl = String(input);
			return new Response(JSON.stringify({
				url: "https://remotecode.io/app",
			}), {
				headers: {
					"content-type": "application/json",
				},
				status: 200,
			});
		}) as unknown as typeof fetch;

		const client = createPrivateAccountApiClient();
		const response = await client.browserManageSubscription();

		expect(requestedUrl).toBe("http://127.0.0.1:8835/v1/private-account/browser/manage-subscription");
		expect(response.url).toBe("https://remotecode.io/app");
	});
});
