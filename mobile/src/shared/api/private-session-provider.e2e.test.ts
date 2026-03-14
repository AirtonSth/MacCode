/* eslint-disable import/no-unresolved */
import { expect, mock, test } from "bun:test";

import { refreshPrivateSessionRecord } from "./private-session-provider";

test("refreshPrivateSessionRecord rotates the private session through the shared contracts client", async () => {
	const refreshSpy = mock(async () => ({
		accessToken: "next-access-token",
		refreshToken: "next-refresh-token",
		user: {
			daysRemaing: 30,
			daysRemaining: 30,
			email: "dev@example.com",
			id: "usr_1",
			subscribed: true,
		},
	}));

	try {
		const result = await refreshPrivateSessionRecord({
			createClient: () => ({
				refresh: refreshSpy,
			}) as never,
			sessionRecord: {
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
			},
		});

		expect(result?.session.accessToken).toBe("next-access-token");
		expect(refreshSpy).toHaveBeenCalledTimes(1);
	} finally {
		// no-op
	}
});
