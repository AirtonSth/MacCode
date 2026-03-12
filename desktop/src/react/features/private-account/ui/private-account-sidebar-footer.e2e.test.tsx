import { expect, test } from "bun:test";

import {
	buildPrivateAccountQrDataUrl,
	loadPrivateAccountState,
	runPrivateAccountAuthAction,
} from "./private-account-sidebar-footer";

test("private account sidebar helpers hydrate state, authenticate, and build the QR payload", async () => {
	const client = {
		getState: async () => ({
			authenticated: false,
			connector: null,
			connectorRelayState: "idle" as const,
			errorMessage: null,
			qrPayload: null,
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
			qrPayload: {
				backendUrl: "http://127.0.0.1:8787",
				connectorId: "con_1",
				connectorName: "Desktop Connector",
				linkUrl: "https://qr.remotecode.dev/connect/mcs_1/secret",
				type: "remotecode_private_mobile_connect" as const,
				version: 1 as const,
			},
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
			qrPayload: null,
			user: null,
		}),
		register: async () => ({
			authenticated: true,
			connector: null,
			connectorRelayState: "connecting" as const,
			errorMessage: null,
			qrPayload: {
				backendUrl: "http://127.0.0.1:8787",
				connectorId: "con_2",
				connectorName: "Desktop Connector",
				linkUrl: "https://qr.remotecode.dev/connect/mcs_2/secret",
				type: "remotecode_private_mobile_connect" as const,
				version: 1 as const,
			},
			user: {
				daysRemaing: 30,
				daysRemaining: 30,
				email: "new@example.com",
				id: "usr_2",
				subscribed: true,
			},
		}),
	};

	const initialState = await loadPrivateAccountState(client);
	expect(initialState.authenticated).toBe(false);

	const loggedInState = await runPrivateAccountAuthAction({
		client,
		email: "dev@example.com",
		mode: "login",
		password: "supersecret",
	});
	expect(loggedInState.user?.email).toBe("dev@example.com");

	const qrDataUrl = await buildPrivateAccountQrDataUrl({
		createQrDataUrl: async (value) => `data:image/png;base64,${Buffer.from(value).toString("base64")}`,
		state: loggedInState,
	});
	expect(qrDataUrl).toContain("data:image/png;base64,");
	expect(Buffer.from(qrDataUrl!.split(",", 2)[1] ?? "", "base64").toString("utf8")).toContain(
		"https://qr.remotecode.dev/connect/mcs_1/secret",
	);
});
