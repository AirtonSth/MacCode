/* eslint-disable import/no-unresolved */
import { afterEach, expect, test } from "bun:test";

import {
	PrivateSignupIntentStore,
	resetPrivateSignupIntentSecureStoreForTests,
	setPrivateSignupIntentSecureStoreForTests,
} from "./private-signup-intent-store";

const createMemoryStore = () => {
	const data = new Map<string, string>();

	return {
		deleteItemAsync: async (key: string) => {
			data.delete(key);
		},
		getItemAsync: async (key: string) => data.get(key) ?? null,
		setItemAsync: async (key: string, value: string) => {
			data.set(key, value);
		},
	};
};

afterEach(() => {
	resetPrivateSignupIntentSecureStoreForTests();
});

test("PrivateSignupIntentStore persists and reads a normalized signup intent record", async () => {
	setPrivateSignupIntentSecureStoreForTests(createMemoryStore());

	await PrivateSignupIntentStore.save({
		backendUrl: "https://private.remotecode.io:8787/",
		email: " Founder@RemoteCode.io ",
		platform: "ios",
		signupIntentId: " signup_123 ",
	});

	const persistedRecord = await PrivateSignupIntentStore.read();
	expect(persistedRecord).toEqual({
		backendUrl: "https://private.remotecode.io:8787",
		email: "founder@remotecode.io",
		platform: "ios",
		signupIntentId: "signup_123",
	});
});

test("PrivateSignupIntentStore clears a persisted signup intent record", async () => {
	setPrivateSignupIntentSecureStoreForTests(createMemoryStore());

	await PrivateSignupIntentStore.save({
		backendUrl: "https://private.remotecode.io:8787",
		email: "founder@remotecode.io",
		platform: "ios",
		signupIntentId: "signup_123",
	});

	await PrivateSignupIntentStore.clear();

	const clearedRecord = await PrivateSignupIntentStore.read();
	expect(clearedRecord).toBeNull();
});
