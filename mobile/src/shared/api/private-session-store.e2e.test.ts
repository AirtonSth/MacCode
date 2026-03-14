/* eslint-disable import/no-unresolved */
import { afterEach, describe, expect, test } from "bun:test";

import {
	PrivateSessionStore,
	resetPrivateSessionSecureStoreForTests,
	setPrivateSessionSecureStoreForTests,
} from "./private-session-store";

const createMemoryStore = () => {
	const values = new Map<string, string>();
	return {
		deleteItemAsync: async (key: string) => {
			values.delete(key);
		},
		getItemAsync: async (key: string) => values.get(key) ?? null,
		setItemAsync: async (key: string, value: string) => {
			values.set(key, value);
		},
	};
};

describe("PrivateSessionStore integration flow", () => {
	afterEach(() => {
		resetPrivateSessionSecureStoreForTests();
	});

	test("persists and reads private session records", async () => {
		setPrivateSessionSecureStoreForTests(createMemoryStore());

		await PrivateSessionStore.saveSessionRecord({
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

		const populated = await PrivateSessionStore.read();
		expect(populated.sessionRecord?.session.accessToken).toBe("access-token");
		expect(populated.sessionRecord?.session.user.id).toBe("usr_1");
	});
});
