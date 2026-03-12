/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import { parseDesktopMobileConnectQrPayload } from "@remotecode/contracts";

import {
	buildPrivateRegisterUrl,
	loginPrivateAccount,
	resolvePendingPrivateConnector,
} from "./private-account-section.model";

test("private account section flow logs in and resolves a scanned desktop connector", async () => {
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

test("private account section builds the browser registration URL with a native return target", () => {
	expect(buildPrivateRegisterUrl({
		backendUrl: "https://private.remotecode.dev",
		email: "founder@remotecode.io",
		platform: "android",
	})).toContain("returnUrl=remotecode%3A%2F%2Fauth%2Fcomplete");
});
