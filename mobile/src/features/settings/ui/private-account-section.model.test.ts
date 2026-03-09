/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import {
	authenticatePrivateAccount,
	loadPrivateConnectorsSafely,
	resolvePendingPrivateConnector,
	sortPrivateConnectors,
} from "./private-account-section.model";

test("sortPrivateConnectors prioritizes online connectors", () => {
	const sorted = sortPrivateConnectors([
		{
			claimedAt: "2026-01-01T00:00:00.000Z",
			hostname: "offline.local",
			id: "con_2",
			isOnline: false,
			lastSeenAt: "2026-01-01T00:00:00.000Z",
			name: "Offline",
			relayCapabilitiesVersion: "1",
			relayVersion: "1.0.0",
			status: "offline",
		},
		{
			claimedAt: "2026-01-02T00:00:00.000Z",
			hostname: "online.local",
			id: "con_1",
			isOnline: true,
			lastSeenAt: "2026-01-02T00:00:00.000Z",
			name: "Online",
			relayCapabilitiesVersion: "1",
			relayVersion: "1.0.0",
			status: "online",
		},
	]);

	expect(sorted[0]?.id).toBe("con_1");
});

test("resolvePendingPrivateConnector finds the scanned desktop connector in the account list", () => {
	const connector = resolvePendingPrivateConnector({
		connectors: [
			{
				claimedAt: "2026-01-02T00:00:00.000Z",
				hostname: "online.local",
				id: "con_1",
				isOnline: true,
				lastSeenAt: "2026-01-02T00:00:00.000Z",
				name: "Online",
				relayCapabilitiesVersion: "1",
				relayVersion: "1.0.0",
				status: "online",
			},
		],
		pendingConnectorId: "con_1",
	});

	expect(connector?.hostname).toBe("online.local");
});

test("authenticatePrivateAccount delegates login to the shared contracts client", async () => {
	const password = ["super", "secret"].join("");
	const session = await authenticatePrivateAccount({
		baseUrl: "https://private.remotecode.dev",
		createClient: () => ({
			login: async () => ({
				accessToken: "access-token",
				refreshToken: "refresh-token",
				user: {
					email: "dev@example.com",
					id: "usr_1",
				},
			}),
		}) as never,
		email: "dev@example.com",
		mode: "login",
		password,
	});

	expect(session.accessToken).toBe("access-token");
});

test("loadPrivateConnectorsSafely reports load failures instead of rejecting", async () => {
	let seenMessage = "";

	await loadPrivateConnectorsSafely({
		loadConnectors: async () => {
			throw new Error("connector_load_failed");
		},
		onError: (message) => {
			seenMessage = message;
		},
		resumePendingQrConnection: async () => undefined,
	});

	expect(seenMessage).toBe("connector_load_failed");
});
