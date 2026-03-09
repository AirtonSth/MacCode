import { expect, test } from "bun:test";

import { PrivateAccountRepository } from "./private-account.repository";
import { PrivateAccountService } from "./private-account.service";

const createInMemoryRepository = (): PrivateAccountRepository => {
	const values = new Map<string, string>();
	return new PrivateAccountRepository({
		getValue: (key: string) => values.get(key) ?? null,
		setValue: (key: string, value: string) => {
			values.set(key, value);
		},
	} as never);
};

test("PrivateAccountService returns an unauthenticated state by default", async () => {
	const service = new PrivateAccountService(createInMemoryRepository(), {
		backendUrl: "http://127.0.0.1:8787",
		localServerToken: "local-token",
	});

	const state = await service.getState();

	expect(state.authenticated).toBe(false);
	expect(state.user).toBeNull();
	expect(state.qrPayload).toBeNull();
	expect(state.connectorRelayState).toBe("idle");
});

