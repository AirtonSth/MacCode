/* eslint-disable import/no-unresolved */
import { expect, mock, test } from "bun:test";

import { PrivateApiError } from "@remotecode/contracts";

import {
	buildPrivacyPolicyUrl,
	buildPrivateForgotPasswordUrl,
	buildPrivateManageSubscriptionUrl,
	buildPrivateRegisterUrl,
	buildTermsOfUseUrl,
	deletePrivateAccount,
	getPrivateSubscriptionSnapshot,
	refreshPrivateAccountSessionRecord,
	loginPrivateAccount,
	loadPrivateConnectorsSafely,
	persistSavedPrivateConnection,
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

test("loginPrivateAccount delegates login to the shared contracts client", async () => {
	const password = ["super", "secret"].join("");
	const session = await loginPrivateAccount({
		baseUrl: "https://private.remotecode.io:8787",
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
	});

	expect(seenMessage).toBe("connector_load_failed");
});

test("persistSavedPrivateConnection stores a reconnectable private saved connection", async () => {
	let persistedBackendUrl = "";
	let persistedConnectorId = "";
	let persistedConnectorName = "";
	let persistedKind = "";

	await persistSavedPrivateConnection({
		backendUrl: "https://private.remotecode.io:8787/",
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

	expect(persistedBackendUrl).toBe("https://private.remotecode.io:8787");
	expect(persistedConnectorId).toBe("con_1");
	expect(persistedConnectorName).toBe("Desktop Connector");
	expect(persistedKind).toBe("private");
});

test("buildPrivateRegisterUrl sends mobile users to the browser registration flow", () => {
	expect(buildPrivateRegisterUrl({
		backendUrl: "https://private.remotecode.io:8787/",
		email: "dev@example.com",
		platform: "ios",
	})).toBe(
		"https://remotecode.io/register?backendUrl=https%3A%2F%2Fprivate.remotecode.io%3A8787&email=dev%40example.com&platform=ios&returnUrl=remotecode%3A%2F%2Fauth%2Fcomplete&target=mobile",
	);
});

test("buildPrivateForgotPasswordUrl preserves the backend and optional email", () => {
	expect(buildPrivateForgotPasswordUrl({
		backendUrl: "https://private.remotecode.io:8787/",
		email: "dev@example.com",
	})).toBe(
		"https://remotecode.io/forgot-password?backendUrl=https%3A%2F%2Fprivate.remotecode.io%3A8787&email=dev%40example.com",
	);
});

test("buildPrivateManageSubscriptionUrl points to the private web app", () => {
	expect(buildPrivateManageSubscriptionUrl()).toBe("https://remotecode.io/app");
});

test("refreshPrivateAccountSessionRecord updates subscription state from private account /me response", async () => {
	const createClient = mock(() => ({
		me: async () => ({
			user: {
				daysRemaing: 10,
				daysRemaining: 10,
				email: "dev@example.com",
				id: "usr_1",
				subscribed: true,
			},
		}),
	}));

	const refreshed = await refreshPrivateAccountSessionRecord({
		createClient,
		sessionRecord: {
			backendUrl: "https://private.remotecode.io:8787",
			session: {
				accessToken: "access-token",
				refreshToken: "refresh-token",
				user: {
					daysRemaing: 10,
					daysRemaining: 10,
					email: "dev@example.com",
					id: "usr_1",
					subscribed: false,
				},
			},
		},
	});

	expect(refreshed?.session.user.subscribed).toBe(true);
	expect(createClient).toHaveBeenCalledTimes(1);
});

test("refreshPrivateAccountSessionRecord refreshes tokens when /me returns unauthorized", async () => {
	let meCalls = 0;
	const unauthorized = new PrivateApiError(401, null, "private_session_expired");
	const createClient = mock(() => ({
		me: async () => {
			meCalls += 1;
			if (meCalls === 1) {
				throw unauthorized;
			}

			return {
				user: {
					daysRemaing: 10,
					daysRemaining: 10,
					email: "dev@example.com",
					id: "usr_1",
					subscribed: true,
				},
			};
		},
	}));
	const refreshSession = mock(async () => ({
		accessToken: "next-access-token",
		refreshToken: "next-refresh-token",
		user: {
			daysRemaing: 10,
			daysRemaining: 10,
			email: "dev@example.com",
			id: "usr_1",
			subscribed: false,
		},
	}));

	const refreshed = await refreshPrivateAccountSessionRecord({
		createClient,
		refreshSession,
		sessionRecord: {
			backendUrl: "https://private.remotecode.io:8787",
			session: {
				accessToken: "expired-token",
				refreshToken: "refresh-token",
				user: {
					daysRemaing: 10,
					daysRemaining: 10,
					email: "dev@example.com",
					id: "usr_1",
					subscribed: false,
				},
			},
		},
	});

	expect(refreshed?.session.accessToken).toBe("next-access-token");
	expect(refreshed?.session.user.subscribed).toBe(true);
	expect(refreshSession).toHaveBeenCalledTimes(1);
	expect(meCalls).toBe(2);
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

test("buildPrivacyPolicyUrl returns the privacy policy page", () => {
	expect(buildPrivacyPolicyUrl()).toBe("https://remotecode.io/privacy");
});

test("buildTermsOfUseUrl returns the terms of use page", () => {
	expect(buildTermsOfUseUrl()).toBe("https://remotecode.io/terms");
});

test("deletePrivateAccount delegates deletion to the shared contracts client", async () => {
	// eslint-disable-next-line @typescript-eslint/no-empty-function
	const deleteAccount = mock(async () => {});
	await deletePrivateAccount({
		backendUrl: "https://private.remotecode.io:8787",
		createClient: () => ({
			deleteAccount,
		}) as never,
		getAccessToken: () => "access-token",
	});

	expect(deleteAccount).toHaveBeenCalledTimes(1);
});
