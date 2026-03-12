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

	test("keeps pending QR payload while session is created and clears it independently", async () => {
		setPrivateSessionSecureStoreForTests(createMemoryStore());

		await PrivateSessionStore.savePendingQrPayload({
			backendUrl: "https://private.remotecode.dev",
			connectorId: "con_1",
			connectorName: "Desktop Connector",
			type: "remotecode_private_mobile_connect",
			version: 1,
		});
		await PrivateSessionStore.saveSessionRecord({
			backendUrl: "https://private.remotecode.dev",
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
		expect(populated.pendingQrPayload?.connectorId).toBe("con_1");
		expect(populated.pendingQrPayload?.backendUrl).toBe("https://private.remotecode.dev");
		expect(populated.sessionRecord?.session.accessToken).toBe("access-token");

		await PrivateSessionStore.clearPendingQrPayload();
		const cleared = await PrivateSessionStore.read();
		expect(cleared.pendingQrPayload).toBeNull();
		expect(cleared.sessionRecord?.backendUrl).toBe("https://private.remotecode.dev");
	});
});
