/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import { parseDesktopMobileConnectQrPayload } from "@remotecode/contracts";

import {
	authenticatePrivateAccount,
	resolvePendingPrivateConnector,
} from "./private-account-section.model";

test("private account section flow authenticates and resolves a scanned desktop connector", async () => {
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
	const payload = parseDesktopMobileConnectQrPayload(JSON.stringify({
		backendUrl: "https://private.remotecode.dev",
		connectorId: "con_1",
		connectorName: "Desktop Connector",
		type: "remotecode_private_mobile_connect",
		version: 1,
	}));
	const connector = resolvePendingPrivateConnector({
		connectors: [
			{
				claimedAt: new Date().toISOString(),
				hostname: "devbox.local",
				id: "con_1",
				isOnline: true,
				lastSeenAt: new Date().toISOString(),
				name: "Desktop Connector",
				relayCapabilitiesVersion: "1",
				relayVersion: "1.0.0",
				status: "online",
			},
		],
		pendingConnectorId: payload.connectorId,
	});

	expect(session.user.email).toBe("dev@example.com");
	expect(connector?.id).toBe("con_1");
});
