/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import { exchangePrivateAuthCompletion } from "./private-auth-completion";

test("exchangePrivateAuthCompletion stores the session returned by the completion token exchange", async () => {
	const sessionRecord = await exchangePrivateAuthCompletion({
		completion: {
			backendUrl: "https://private.remotecode.io:8787",
			completionToken: "token_123",
		},
		createClient: () => ({
			exchangeCompletionToken: async () => ({
				accessToken: "access-token",
				refreshToken: "refresh-token",
				user: {
					daysRemaing: 30,
					daysRemaining: 30,
					email: "dev@example.com",
					id: "usr_1",
					subscribed: true,
				},
			}),
		}) as never,
	});

	expect(sessionRecord).toEqual({
		backendUrl: "https://private.remotecode.io:8787",
		session: {
			accessToken: "access-token",
			refreshToken: "refresh-token",
			user: {
				daysRemaing: 30,
				daysRemaining: 30,
				email: "dev@example.com",
				id: "usr_1",
				subscribed: true,
			},
		},
	});
});
