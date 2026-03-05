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
});
