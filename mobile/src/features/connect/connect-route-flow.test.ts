/* eslint-disable import/no-unresolved */
import { expect, mock, test } from "bun:test";

import { runConnectRouteFlow } from "./connect-route-flow";

test("runConnectRouteFlow claims the private session and routes to workspaces", async () => {
	const activateConnector = mock(async () => undefined);
	const clearPendingQrPayload = mock(async () => undefined);
	const saveSavedPrivateConnection = mock(async () => undefined);
	const setPendingQrPayload = mock(async () => undefined);
	const setSessionRecord = mock(async () => undefined);
	const onStatusMessage = mock(() => undefined);

	const result = await runConnectRouteFlow({
		activateConnector,
		clearPendingQrPayload,
		completeConnect: async () => ({
			connector: {
				id: "con_1",
				name: "Studio MacBook",
			},
			sessionRecord: {
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
			},
		}),
		onStatusMessage,
		parseInput: () => ({
			claim: {
				backendUrl: "https://private.remotecode.dev",
				code: "secret",
				sessionId: "mcs_1",
			},
			kind: "claim",
			rawValue: "https://qr.remotecode.dev/connect/mcs_1/secret",
		}),
		rawUrl: "https://qr.remotecode.dev/connect/mcs_1/secret",
		saveSavedPrivateConnection,
		sessionRecord: null,
		setPendingQrPayload,
		setSessionRecord,
	});

	expect(result).toEqual({
		pathname: "/workspaces",
		statusMessage: "Connected to Studio MacBook.",
	});
	expect(onStatusMessage).toHaveBeenCalledWith("Claiming private connection.");
	expect(onStatusMessage).toHaveBeenCalledWith("Connected to Studio MacBook.");
	expect(saveSavedPrivateConnection).toHaveBeenCalledWith({
		backendUrl: "https://private.remotecode.dev",
		connectorId: "con_1",
		connectorName: "Studio MacBook",
	});
	expect(setPendingQrPayload).toHaveBeenCalledTimes(0);
});

test("runConnectRouteFlow surfaces claim failures back to settings", async () => {
	const result = await runConnectRouteFlow({
		activateConnector: async () => undefined,
		clearPendingQrPayload: async () => undefined,
		completeConnect: async () => {
			throw new Error("Link expired.");
		},
		parseInput: () => ({
			claim: {
				backendUrl: "https://private.remotecode.dev",
				code: "secret",
				sessionId: "mcs_1",
			},
			kind: "claim",
			rawValue: "https://qr.remotecode.dev/connect/mcs_1/secret",
		}),
		rawUrl: "https://qr.remotecode.dev/connect/mcs_1/secret",
		sessionRecord: null,
		setPendingQrPayload: async () => undefined,
		setSessionRecord: async () => undefined,
	});

	expect(result).toEqual({
		errorMessage: "Link expired.",
		pathname: "/settings",
		privateConnectError: "Link expired.",
	});
});

test("runConnectRouteFlow stores legacy QR payloads and reuses an active private session", async () => {
	const activateConnector = mock(async () => undefined);
	const clearPendingQrPayload = mock(async () => undefined);
	const saveSavedPrivateConnection = mock(async () => undefined);
	const setPendingQrPayload = mock(async () => undefined);
	const onStatusMessage = mock(() => undefined);

	const result = await runConnectRouteFlow({
		activateConnector,
		clearPendingQrPayload,
		onStatusMessage,
		parseInput: () => ({
			kind: "legacy_qr",
			payload: {
				backendUrl: "https://private.remotecode.dev",
				connectorId: "con_1",
				connectorName: "Desktop Connector",
				type: "remotecode_private_mobile_connect",
				version: 1,
			},
			rawValue: "{\"connectorId\":\"con_1\"}",
		}),
		rawUrl: "{\"connectorId\":\"con_1\"}",
		saveSavedPrivateConnection,
		sessionRecord: {
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
		},
		setPendingQrPayload,
		setSessionRecord: async () => undefined,
	});

	expect(result).toEqual({
		pathname: "/workspaces",
		statusMessage: "Connecting to Desktop Connector.",
	});
	expect(setPendingQrPayload).toHaveBeenCalledTimes(1);
	expect(activateConnector).toHaveBeenCalledWith({
		backendUrl: "https://private.remotecode.dev",
		connectorId: "con_1",
	});
	expect(saveSavedPrivateConnection).toHaveBeenCalledWith({
		backendUrl: "https://private.remotecode.dev",
		connectorId: "con_1",
		connectorName: "Desktop Connector",
	});
	expect(clearPendingQrPayload).toHaveBeenCalledTimes(1);
});
