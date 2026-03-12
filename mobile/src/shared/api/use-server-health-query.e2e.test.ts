/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import { fetchPrivateTargetHealth } from "./use-server-health-query";

test("fetchPrivateTargetHealth returns ok when the private connector is online", async () => {
	const result = await fetchPrivateTargetHealth({
		createClient: () => ({
			listConnectors: async () => ({
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
			}),
			me: async () => ({
				user: {
					daysRemaing: 30,
					daysRemaining: 30,
					email: "dev@example.com",
					id: "usr_1",
					subscribed: true,
				},
			}),
		}) as never,
		target: {
			accessToken: "token",
			backendUrl: "https://private.remotecode.dev",
			connectorId: "con_1",
			kind: "private",
		},
	});

	expect(result.ok).toBe(true);
	expect(result.connector.id).toBe("con_1");
});
