/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import {
	buildPrivateForgotPasswordUrl,
	buildPrivateManageSubscriptionUrl,
	buildPrivateRegisterUrl,
	getPrivateSubscriptionSnapshot,
	loginPrivateAccount,
	loadPrivateConnectorsSafely,
	persistSavedPrivateConnection,
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

test("loginPrivateAccount delegates login to the shared contracts client", async () => {
	const password = ["super", "secret"].join("");
	const session = await loginPrivateAccount({
		baseUrl: "https://private.remotecode.dev",
		createClient: () => ({
			login: async () => ({
				accessToken: "access-token",
				refreshToken: "refresh-token",
				user: {
					daysRemaing: 30,
					daysRemaining: 30,
					email: "dev@example.com",
					id: "usr_1",
					subscribed: true,
				},
			}),
		}) as never,
		email: "dev@example.com",
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

test("persistSavedPrivateConnection stores a reconnectable private saved connection", async () => {
	let persistedBackendUrl = "";
	let persistedConnectorId = "";
	let persistedConnectorName = "";
	let persistedKind = "";

	await persistSavedPrivateConnection({
		backendUrl: "https://private.remotecode.dev/",
		connector: {
			id: "con_1",
			name: "Desktop Connector",
		},
		saveSavedConnection: async (input) => {
			if (input.kind === "private") {
				persistedBackendUrl = input.backendUrl;
				persistedConnectorId = input.connectorId;
				persistedConnectorName = input.connectorName;
				persistedKind = input.kind;
			}
			return [];
		},
	});

	expect(persistedBackendUrl).toBe("https://private.remotecode.dev");
	expect(persistedConnectorId).toBe("con_1");
	expect(persistedConnectorName).toBe("Desktop Connector");
	expect(persistedKind).toBe("private");
});

test("buildPrivateRegisterUrl sends mobile users to the browser registration flow", () => {
	expect(buildPrivateRegisterUrl({
		backendUrl: "https://private.remotecode.dev/",
		email: "dev@example.com",
		platform: "ios",
	})).toBe(
		"https://remotecode.io/register?backendUrl=https%3A%2F%2Fprivate.remotecode.dev&email=dev%40example.com&platform=ios&returnUrl=remotecode%3A%2F%2Fauth%2Fcomplete&target=mobile",
	);
});

test("buildPrivateForgotPasswordUrl preserves the backend and optional email", () => {
	expect(buildPrivateForgotPasswordUrl({
		backendUrl: "https://private.remotecode.dev/",
		email: "dev@example.com",
	})).toBe(
		"https://remotecode.io/forgot-password?backendUrl=https%3A%2F%2Fprivate.remotecode.dev&email=dev%40example.com",
	);
});

test("buildPrivateManageSubscriptionUrl points to the private web app", () => {
	expect(buildPrivateManageSubscriptionUrl()).toBe("https://remotecode.io/app");
});

test("getPrivateSubscriptionSnapshot reads the subscription flags from the session", () => {
	expect(getPrivateSubscriptionSnapshot({
		accessToken: "access-token",
		refreshToken: "refresh-token",
		user: {
			daysRemaing: 30,
			daysRemaining: 30,
			email: "dev@example.com",
			id: "usr_1",
			subscribed: false,
		},
	})).toEqual({
		daysRemaining: 30,
		isSubscribed: false,
	});
});
