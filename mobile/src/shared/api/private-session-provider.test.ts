/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import { refreshPrivateSessionRecord, toPrivateApiConfig } from "./private-session-provider";

test("toPrivateApiConfig converts a private session and connector into the active private target", () => {
	const config = toPrivateApiConfig({
		backendUrl: "https://private.remotecode.dev",
		connectorId: "con_1",
		session: {
			accessToken: "access-token",
			refreshToken: "refresh-token",
			user: {
				email: "dev@example.com",
				id: "usr_1",
			},
		},
	});

	expect(config.activeTarget.kind).toBe("private");
	expect(config.token).toBe("access-token");
});

test("refreshPrivateSessionRecord returns null when there is no private session", async () => {
	const result = await refreshPrivateSessionRecord({
		sessionRecord: null,
	});

	expect(result).toBeNull();
});
