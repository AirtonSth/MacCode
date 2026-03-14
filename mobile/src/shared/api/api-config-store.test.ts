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
			backendUrl: "https://private.remotecode.io:8787/",
			connectorId: "con_1",
			kind: "private",
		}));
		const hydrated = await ApiConfigStore.read();

		expect(saved.baseUrl).toBe("https://private.remotecode.io:8787");
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

	test("parses legacy saved local connections without a kind discriminator", async () => {
		const memoryStore = createMemoryStore();
		setSecureStoreAdapterForTests(memoryStore);
		await memoryStore.setItemAsync("remotecode.saved_connections", JSON.stringify([
			{
				baseUrl: "https://192.168.1.20:8835",
				lastConnectedAt: "2026-03-13T10:00:00.000Z",
				token: "token-1",
			},
		]));

		const saved = await ApiConfigStore.readSavedConnections();

		expect(saved).toEqual([
			{
				baseUrl: "https://192.168.1.20:8835",
				kind: "local",
				lastConnectedAt: "2026-03-13T10:00:00.000Z",
				token: "token-1",
			},
		]);
	});

	test("saves and reads mixed local and private saved connections", async () => {
		const memoryStore = createMemoryStore();
		setSecureStoreAdapterForTests(memoryStore);

		await ApiConfigStore.saveSavedConnection({
			baseUrl: "https://192.168.1.20:8835",
			kind: "local",
			token: "token-1",
		});
		await ApiConfigStore.saveSavedConnection({
			backendUrl: "https://private.remotecode.io:8787",
			connectorId: "con_1",
			connectorName: "Desktop Connector",
			kind: "private",
		});

		const saved = await ApiConfigStore.readSavedConnections();

		expect(saved).toHaveLength(2);
		expect(saved.some((item) => item.kind === "local" && item.baseUrl === "https://192.168.1.20:8835")).toBe(true);
		expect(saved.some((item) => item.kind === "private" && item.connectorId === "con_1")).toBe(true);
	});

	test("dedupes local entries by baseUrl and private entries by backendUrl plus connectorId", async () => {
		const memoryStore = createMemoryStore();
		setSecureStoreAdapterForTests(memoryStore);

		await ApiConfigStore.saveSavedConnection({
			baseUrl: "https://192.168.1.20:8835",
			kind: "local",
			token: "token-1",
		});
		await ApiConfigStore.saveSavedConnection({
			baseUrl: "https://192.168.1.20:8835",
			kind: "local",
			token: "token-2",
		});
		await ApiConfigStore.saveSavedConnection({
			backendUrl: "https://private.remotecode.io:8787",
			connectorId: "con_1",
			connectorName: "Desktop A",
			kind: "private",
		});
		await ApiConfigStore.saveSavedConnection({
			backendUrl: "https://private.remotecode.io:8787",
			connectorId: "con_1",
			connectorName: "Desktop B",
			kind: "private",
		});

		const saved = await ApiConfigStore.readSavedConnections();
		const locals = saved.filter((item) => item.kind === "local");
		const privates = saved.filter((item) => item.kind === "private");

		expect(locals).toHaveLength(1);
		expect(locals[0]?.token).toBe("token-2");
		expect(privates).toHaveLength(1);
		expect(privates[0]?.connectorName).toBe("Desktop B");
	});

	test("deletes local and private saved entries independently", async () => {
		const memoryStore = createMemoryStore();
		setSecureStoreAdapterForTests(memoryStore);

		await ApiConfigStore.saveSavedConnection({
			baseUrl: "https://192.168.1.20:8835",
			kind: "local",
			token: "token-1",
		});
		await ApiConfigStore.saveSavedConnection({
			backendUrl: "https://private.remotecode.io:8787",
			connectorId: "con_1",
			connectorName: "Desktop Connector",
			kind: "private",
		});

		await ApiConfigStore.deleteSavedConnection({
			baseUrl: "https://192.168.1.20:8835",
			kind: "local",
			lastConnectedAt: new Date(0).toISOString(),
			token: "token-1",
		});
		let saved = await ApiConfigStore.readSavedConnections();
		expect(saved).toHaveLength(1);
		expect(saved[0]?.kind).toBe("private");

		await ApiConfigStore.deleteSavedConnection({
			backendUrl: "https://private.remotecode.io:8787",
			connectorId: "con_1",
			connectorName: "Desktop Connector",
			kind: "private",
			lastConnectedAt: new Date(0).toISOString(),
		});
		saved = await ApiConfigStore.readSavedConnections();
		expect(saved).toHaveLength(0);
	});

	test("does not silently replace an empty private access token with the local default token", async () => {
		const memoryStore = createMemoryStore();
		setSecureStoreAdapterForTests(memoryStore);

		const saved = await ApiConfigStore.save(toApiConfig({
			accessToken: "",
			backendUrl: "https://private.remotecode.io:8787",
			connectorId: "con_2",
			kind: "private",
		}));

		expect(saved.token).toBe("");
	});
});
