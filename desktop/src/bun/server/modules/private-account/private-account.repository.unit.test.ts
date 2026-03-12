import { expect, test } from "bun:test";

import { ServerMetadataRepository } from "../server-metadata/server-metadata.repository";
import { createPrivateAccountRepository } from "./private-account.repository";

const createFakeServerMetadataRepository = (): ServerMetadataRepository => {
	const values = new Map<string, string>();

	return {
		getValue: (key: string) => values.get(key) ?? null,
		setValue: (key: string, value: string) => {
			values.set(key, value);
		},
	} as unknown as ServerMetadataRepository;
};

test("PrivateAccountRepository persists and clears session and connector state", () => {
	const repository = createPrivateAccountRepository(createFakeServerMetadataRepository());

	repository.saveSession({
		accessToken: "access",
		refreshToken: "refresh",
		user: {
			daysRemaing: 30,
			daysRemaining: 30,
			email: "dev@example.com",
			id: "usr_1",
			subscribed: true,
		},
	});
	repository.saveConnector({
		backendUrl: "https://private.remotecode.io:8787",
		connectorId: "con_1",
		connectorName: "Studio MacBook",
		connectorToken: "connector-token",
	});

	expect(repository.readSession()?.user.id).toBe("usr_1");
	expect(repository.readConnector()?.connectorId).toBe("con_1");

	repository.clearSession();
	repository.clearConnector();

	expect(repository.readSession()).toBeNull();
	expect(repository.readConnector()).toBeNull();
});
