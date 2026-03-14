import { expect, test } from "bun:test";

import {
	loadPrivateAccountState,
	runPrivateAccountLoginAction,
} from "./private-account-sidebar-footer";

test("private account sidebar helpers hydrate state and authenticate", async () => {
	const client = {
		getState: async () => ({
			authenticated: false,
			connector: null,
			connectorRelayState: "idle" as const,
			errorMessage: null,
			user: null,
		}),
		login: async () => ({
			authenticated: true,
			connector: {
				claimedAt: new Date().toISOString(),
				hostname: "devbox.local",
				id: "con_1",
				isOnline: true,
				lastSeenAt: new Date().toISOString(),
				name: "Desktop Connector",
				relayCapabilitiesVersion: "1",
				relayVersion: "1.0.0",
				status: "online" as const,
			},
			connectorRelayState: "connected" as const,
			errorMessage: null,
			user: {
				daysRemaing: 30,
				daysRemaining: 30,
				email: "dev@example.com",
				id: "usr_1",
				subscribed: true,
			},
		}),
		logout: async () => ({
			authenticated: false,
			connector: null,
			connectorRelayState: "idle" as const,
			errorMessage: null,
			user: null,
		}),
		browserForgotPassword: async () => ({ url: "https://remotecode.io/forgot-password" }),
		browserManageSubscription: async () => ({ url: "https://remotecode.io/app" }),
		browserRegister: async () => ({ url: "https://remotecode.io/register" }),
	};

	const initialState = await loadPrivateAccountState(client);
	expect(initialState.authenticated).toBe(false);

	const loggedInState = await runPrivateAccountLoginAction({
		client,
		email: "dev@example.com",
		password: "supersecret",
	});
	expect(loggedInState.user?.email).toBe("dev@example.com");
	expect(loggedInState.connector?.name).toBe("Desktop Connector");
});

