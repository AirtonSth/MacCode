/* eslint-disable import/no-unresolved */
import { expect, mock, test } from "bun:test";

import { completePrivateMobileConnect, parsePrivateConnectInput } from "./private-mobile-connect";

test("completePrivateMobileConnect claims the session, persists it, and activates the connector", async () => {
	const setSessionRecord = mock(async () => undefined);
	const activateConnector = mock(async () => undefined);
	const clearPendingQrPayload = mock(async () => undefined);
	const claimMobileConnect = mock(async () => ({
		backendUrl: "https://private.remotecode.dev",
		connector: {
			id: "con_1",
			name: "Studio MacBook",
		},
		session: {
			accessToken: "access-token",
			refreshToken: "refresh-token",
			user: {
				email: "dev@example.com",
				id: "usr_1",
			},
		},
	}));

	const intent = parsePrivateConnectInput(
		"https://qr.remotecode.dev/connect/sess_1/code_1",
	);
	if (intent.kind !== "claim") {
		throw new Error("claim_intent_expected");
	}

	const result = await completePrivateMobileConnect({
		activateConnector,
		clearPendingQrPayload,
		createClient: () => ({
			claimMobileConnect,
		}) as never,
		link: intent.claim,
		setSessionRecord,
	});

	expect(claimMobileConnect).toHaveBeenCalledWith({
		code: "code_1",
		sessionId: "sess_1",
	});
	expect(setSessionRecord).toHaveBeenCalledWith({
		backendUrl: "https://private.remotecode.dev",
		session: {
			accessToken: "access-token",
			refreshToken: "refresh-token",
			user: {
				email: "dev@example.com",
				id: "usr_1",
			},
		},
	});
	expect(activateConnector).toHaveBeenCalledWith({
		backendUrl: "https://private.remotecode.dev",
		connectorId: "con_1",
		sessionRecordOverride: {
			backendUrl: "https://private.remotecode.dev",
			session: {
				accessToken: "access-token",
				refreshToken: "refresh-token",
				user: {
					email: "dev@example.com",
					id: "usr_1",
				},
			},
		},
	});
	expect(clearPendingQrPayload).toHaveBeenCalledTimes(1);
	expect(result.connector.name).toBe("Studio MacBook");
});
