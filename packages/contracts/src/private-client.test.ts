/* eslint-disable import/no-unresolved, compat/compat */
/* eslint-disable functional/immutable-data, @typescript-eslint/require-await */
/* eslint-disable no-underscore-dangle, @typescript-eslint/naming-convention */
/* eslint-disable sonarjs/no-hardcoded-passwords */
/* eslint-disable functional/no-let */
import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

import { createPrivateClient, PrivateApiError } from "./private-client";

const originalFetch = globalThis.fetch;

describe("createPrivateClient", () => {
	beforeEach(() => {
		globalThis.fetch = originalFetch;
	});

	afterEach(() => {
		globalThis.fetch = originalFetch;
	});

	test("sends bearer auth for authenticated requests", async () => {
		const seenAuthorization: string[] = [];

		globalThis.fetch = mock(async (input: string | URL | Request, init?: RequestInit) => {
			void input;
			seenAuthorization.push(String(new Headers(init?.headers).get("authorization") ?? ""));

			return new Response(JSON.stringify({ user: { email: "dev@example.com", id: "usr_1" } }), {
				headers: { "content-type": "application/json" },
				status: 200,
			});
		}) as unknown as typeof fetch;

		const client = createPrivateClient({
			baseUrl: "http://127.0.0.1:8787",
			getAccessToken: () => "access-token",
		});

		const me = await client.me();

		expect(me.user.id).toBe("usr_1");
		expect(seenAuthorization).toEqual(["Bearer access-token"]);
	});

	test("does not require auth for login and register", async () => {
		const seenAuthorization: (string | null)[] = [];

		globalThis.fetch = mock(async (_input: string | URL | Request, init?: RequestInit) => {
			seenAuthorization.push(new Headers(init?.headers).get("authorization"));

			return new Response(JSON.stringify({
				accessToken: "access",
				refreshToken: "refresh",
				user: { email: "dev@example.com", id: "usr_1" },
			}), {
				headers: { "content-type": "application/json" },
				status: 200,
			});
		}) as unknown as typeof fetch;

		const client = createPrivateClient({
			baseUrl: "http://127.0.0.1:8787",
		});

		await client.login({ email: "dev@example.com", password: "supersecret" });
		await client.register({ email: "dev@example.com", password: "supersecret" });
		expect(seenAuthorization).toEqual([null, null]);
	});

	test("calls onUnauthorized and throws PrivateApiError on 401", async () => {
		let unauthorizedCalls = 0;

		globalThis.fetch = mock(async () => new Response(JSON.stringify({ error: "unauthorized" }), {
			headers: { "content-type": "application/json" },
			status: 401,
		})) as unknown as typeof fetch;

		const client = createPrivateClient({
			baseUrl: "http://127.0.0.1:8787",
			getAccessToken: () => "expired-token",

			onUnauthorized: () => {
				unauthorizedCalls += 1;
			},
		});

		let caughtError: unknown = null;

		try {
			await client.me();
		} catch (error) {
			caughtError = error;
		}

		expect(unauthorizedCalls).toBe(1);
		expect(caughtError).toBeInstanceOf(PrivateApiError);
		expect((caughtError as PrivateApiError).status).toBe(401);
	});
});
