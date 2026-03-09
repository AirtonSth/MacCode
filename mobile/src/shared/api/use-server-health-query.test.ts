/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import { fetchPrivateTargetHealth } from "./use-server-health-query";

test("fetchPrivateTargetHealth rejects when the selected connector is missing", async () => {
	let caughtError: unknown = null;

	try {
		await fetchPrivateTargetHealth({
			createClient: () => ({
				listConnectors: async () => ({
					connectors: [],
				}),
				me: async () => ({
					user: {
						email: "dev@example.com",
						id: "usr_1",
					},
				}),
			}) as never,
			target: {
				accessToken: "token",
				backendUrl: "https://private.remotecode.dev",
				connectorId: "missing",
				kind: "private",
			},
		});
	} catch (error) {
		caughtError = error;
	}

	expect(caughtError).toBeInstanceOf(Error);
});
