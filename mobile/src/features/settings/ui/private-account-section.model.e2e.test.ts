/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import {
	buildPrivacyPolicyUrl,
	buildPrivateRegisterUrl,
	buildTermsOfUseUrl,
	deletePrivateAccount,
	loginPrivateAccount,
	persistSavedPrivateConnection,
} from "./private-account-section.model";

test("private account section flow logs in with valid credentials", async () => {
	const password = ["s", "uper", "secret"].join("");
	const session = await loginPrivateAccount({
		baseUrl: "https://private.remotecode.io:8787",
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

	expect(session.user.email).toBe("dev@example.com");
	expect(session.accessToken).toBe("access-token");
});

test("private account section persistence helper writes the claimed connector as a saved private connection", async () => {
	let persistedConnectorId = "";

	await persistSavedPrivateConnection({
		backendUrl: "https://private.remotecode.io:8787",
		connector: {
			id: "con_42",
			name: "Studio MacBook",
		},
		saveSavedConnection: async (input) => {
			persistedConnectorId = input.kind === "private" ? input.connectorId : "";
			return [];
		},
	});

	expect(persistedConnectorId).toBe("con_42");
});


test("private account section builds the browser registration URL with a native return target", () => {
	expect(buildPrivateRegisterUrl({
		backendUrl: "https://private.remotecode.io:8787",
		email: "founder@remotecode.io",
		platform: "android",
	})).toContain("returnUrl=remotecode%3A%2F%2Fauth%2Fcomplete");
});

test("privacy policy URL points to remotecode.io/privacy", () => {
	expect(buildPrivacyPolicyUrl()).toBe("https://remotecode.io/privacy");
});

test("terms of use URL points to remotecode.io/terms", () => {
	expect(buildTermsOfUseUrl()).toBe("https://remotecode.io/terms");
});

test("deletePrivateAccount calls the deleteAccount method on the private client", async () => {
	let deleteCalled = false;
	await deletePrivateAccount({
		backendUrl: "https://private.remotecode.io:8787",
		createClient: () => ({
			deleteAccount: async () => {
				deleteCalled = true;
			},
		}) as never,
		getAccessToken: () => "access-token",
	});

	expect(deleteCalled).toBe(true);
});
