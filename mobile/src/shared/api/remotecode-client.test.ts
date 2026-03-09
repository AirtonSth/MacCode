/* eslint-disable import/no-unresolved */
import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

import { createRemoteCodeClient, RemoteCodeRequestError } from "./remotecode-client";

const originalFetch = globalThis.fetch;

describe("createRemoteCodeClient live activity subscription contract", () => {
	beforeEach(() => {
		globalThis.fetch = originalFetch;
	});

	afterEach(() => {
		globalThis.fetch = originalFetch;
	});

	test("treats a generic 404 as a disabled live activity route for backward compatibility", async () => {
		globalThis.fetch = mock(async () => new Response(JSON.stringify({
			error: "not found",
		}), {
			headers: {
				"content-type": "application/json",
			},
			status: 404,
			statusText: "Not Found",
		})) as unknown as typeof fetch;

		const client = createRemoteCodeClient({
			baseUrl: "http://127.0.0.1:8835",
			token: "remotecode.io-token",
		});

		const result = await client.upsertChatLiveActivitySubscription("chat-1", {
			liveActivityToken: "activity-token",
			pushToken: "apns-token",
			pushTokenType: "apns",
		});

		expect(result).toEqual({
			enabled: false,
			subscribed: false,
		});
	});

	test("preserves a chat-not-found 404 instead of collapsing it into a disabled response", async () => {
		globalThis.fetch = mock(async () => new Response(JSON.stringify({
			error: "chat not found",
		}), {
			headers: {
				"content-type": "application/json",
			},
			status: 404,
			statusText: "Not Found",
		})) as unknown as typeof fetch;

		const client = createRemoteCodeClient({
			baseUrl: "http://127.0.0.1:8835",
			token: "remotecode.io-token",
		});

		let caughtError: unknown = null;
		try {
			await client.upsertChatLiveActivitySubscription("missing-chat", {
				liveActivityToken: "activity-token",
				pushToken: "apns-token",
				pushTokenType: "apns",
			});
		} catch (error) {
			caughtError = error;
		}

		expect(caughtError).toBeInstanceOf(RemoteCodeRequestError);
	});

	test("adds the connector header for private proxied requests", async () => {
		let connectorIdHeader = "";
		let authorizationHeader = "";

		globalThis.fetch = mock(async (input: RequestInfo | URL, init?: RequestInit) => {
			void input;
			const headers = new Headers(init?.headers);
			connectorIdHeader = headers.get("x-remotecode-connector-id") ?? "";
			authorizationHeader = headers.get("authorization") ?? "";
			return new Response(JSON.stringify({
				projects: [],
			}), {
				headers: {
					"content-type": "application/json",
				},
				status: 200,
			});
		}) as unknown as typeof fetch;

		const client = createRemoteCodeClient({
			activeTarget: {
				accessToken: "private-access-token",
				backendUrl: "https://private.remotecode.dev",
				connectorId: "con_1",
				kind: "private",
			},
			baseUrl: "https://private.remotecode.dev",
			token: "private-access-token",
		});

		await client.listProjects();

		expect(connectorIdHeader).toBe("con_1");
		expect(authorizationHeader).toBe("Bearer private-access-token");
	});

	test("retries once with a refreshed private access token after a 401", async () => {
		const seenAuthorizations: string[] = [];
		globalThis.fetch = mock(async (input: RequestInfo | URL, init?: RequestInit) => {
			void input;
			const headers = new Headers(init?.headers);
			seenAuthorizations.push(headers.get("authorization") ?? "");

			if (seenAuthorizations.length === 1) {
				return new Response(JSON.stringify({
					error: "expired",
				}), {
					headers: {
						"content-type": "application/json",
					},
					status: 401,
					statusText: "Unauthorized",
				});
			}

			return new Response(JSON.stringify({
				projects: [],
			}), {
				headers: {
					"content-type": "application/json",
				},
				status: 200,
			});
		}) as unknown as typeof fetch;

		const client = createRemoteCodeClient({
			activeTarget: {
				accessToken: "expired-access-token",
				backendUrl: "https://private.remotecode.dev",
				connectorId: "con_1",
				kind: "private",
			},
			baseUrl: "https://private.remotecode.dev",
			token: "expired-access-token",
		}, {
			refreshPrivateAccessToken: async () => "fresh-access-token",
		});

		await client.listProjects();

		expect(seenAuthorizations).toEqual([
			"Bearer expired-access-token",
			"Bearer fresh-access-token",
		]);
	});
});
