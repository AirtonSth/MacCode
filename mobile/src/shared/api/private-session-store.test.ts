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

describe("PrivateSessionStore", () => {
	afterEach(() => {
		resetPrivateSessionSecureStoreForTests();
	});

	test("persists a private session record", async () => {
		setPrivateSessionSecureStoreForTests(createMemoryStore());

		await PrivateSessionStore.saveSessionRecord({
			backendUrl: "https://private.remotecode.dev/",
			session: {
				accessToken: "access-token",
				refreshToken: "refresh-token",
				user: {
					email: "dev@example.com",
					id: "usr_1",
				},
			},
		});

		const state = await PrivateSessionStore.read();
		expect(state.sessionRecord?.backendUrl).toBe("https://private.remotecode.dev");
		expect(state.sessionRecord?.session.user.email).toBe("dev@example.com");
	});
});
