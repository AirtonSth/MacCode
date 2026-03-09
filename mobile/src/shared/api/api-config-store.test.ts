/* eslint-disable import/no-unresolved */
import { afterEach, describe, expect, test } from "bun:test";

import {
	ApiConfigStore,
	resetSecureStoreAdapterForTests,
	setSecureStoreAdapterForTests,
	toApiConfig,
} from "./api-config-store";

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
		values,
	};
};

describe("ApiConfigStore", () => {
	afterEach(() => {
		resetSecureStoreAdapterForTests();
	});

	test("persists and hydrates a private active target while preserving legacy baseUrl/token fields", async () => {
		const memoryStore = createMemoryStore();
		setSecureStoreAdapterForTests(memoryStore);

		const saved = await ApiConfigStore.save(toApiConfig({
			accessToken: "private-access-token",
			backendUrl: "https://private.remotecode.dev/",
			connectorId: "con_1",
			kind: "private",
		}));
		const hydrated = await ApiConfigStore.read();

		expect(saved.baseUrl).toBe("https://private.remotecode.dev");
		expect(saved.token).toBe("private-access-token");
		expect(hydrated.activeTarget.kind).toBe("private");
		expect(hydrated.activeTarget.kind === "private" ? hydrated.activeTarget.connectorId : null).toBe("con_1");
	});

	test("saveServerConnection switches the active target back to local mode", async () => {
		const memoryStore = createMemoryStore();
		setSecureStoreAdapterForTests(memoryStore);

		const saved = await ApiConfigStore.saveServerConnection({
			baseUrl: "https://192.168.1.20:8835",
			serverId: "srv_1",
			token: "token-1",
		});

		expect(saved.activeTarget.kind).toBe("local");
		expect(saved.baseUrl).toBe("https://192.168.1.20:8835");
		expect(saved.token).toBe("token-1");
	});

	test("does not silently replace an empty private access token with the local default token", async () => {
		const memoryStore = createMemoryStore();
		setSecureStoreAdapterForTests(memoryStore);

		const saved = await ApiConfigStore.save(toApiConfig({
			accessToken: "",
			backendUrl: "https://private.remotecode.dev",
			connectorId: "con_2",
			kind: "private",
		}));

		expect(saved.token).toBe("");
	});
});
