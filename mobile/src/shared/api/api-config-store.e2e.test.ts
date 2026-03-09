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
	};
};

describe("ApiConfigStore integration flow", () => {
	afterEach(() => {
		resetSecureStoreAdapterForTests();
	});

	test("switches from local to private and back while keeping saved LAN connections intact", async () => {
		const memoryStore = createMemoryStore();
		setSecureStoreAdapterForTests(memoryStore);

		await ApiConfigStore.saveServerConnection({
			baseUrl: "https://192.168.1.21:8835",
			serverId: "srv_1",
			token: "lan-token",
		});
		await ApiConfigStore.saveSavedConnection({
			baseUrl: "https://192.168.1.21:8835",
			token: "lan-token",
		});
		await ApiConfigStore.save(toApiConfig({
			accessToken: "private-token",
			backendUrl: "https://private.remotecode.dev",
			connectorId: "con_9",
			kind: "private",
		}));

		const privateConfig = await ApiConfigStore.read();
		const savedConnections = await ApiConfigStore.readSavedConnections();

		expect(privateConfig.activeTarget.kind).toBe("private");
		expect(savedConnections).toHaveLength(1);

		const localConfig = await ApiConfigStore.saveServerConnection({
			baseUrl: "https://192.168.1.21:8835",
			serverId: "srv_1",
			token: "lan-token",
		});
		expect(localConfig.activeTarget.kind).toBe("local");
	});
});
