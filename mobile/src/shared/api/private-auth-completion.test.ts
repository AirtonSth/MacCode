/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import { parsePrivateAuthCompletionInput } from "./private-auth-completion";

test("parsePrivateAuthCompletionInput reads the auth completion deeplink", () => {
	expect(
		parsePrivateAuthCompletionInput(
			"remotecode://auth/complete?backendUrl=https%3A%2F%2Fprivate.remotecode.io%3A8787&completionToken=token_123",
		),
	).toEqual({
		backendUrl: "https://private.remotecode.io:8787",
		completionToken: "token_123",
	});
});

test("parsePrivateAuthCompletionInput rejects unrelated private links", () => {
	expect(() => parsePrivateAuthCompletionInput("remotecode://connect/mcs_1/secret")).toThrow(
		"invalid_private_auth_completion_url",
	);
});
