/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import {
	buildNativeManageSubscriptionUrl,
	buildPrivacyPolicyUrl,
	buildTermsOfUseUrl,
	deletePrivateAccount,
	loginPrivateAccount,
	persistSavedPrivateConnection,
	registerPrivateAccountWithTrial,
	requestPrivatePasswordReset,
	syncPrivateRevenueCatSubscriptionStatus,
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

test("private account section flow starts the in-app trial and completes the mobile signup intent without a browser redirect", async () => {
	const password = ["super", "secret", "123"].join("");
	const {session} = await registerPrivateAccountWithTrial({
		baseUrl: "https://private.remotecode.io:8787",
		createClient: () => ({
			completeSignupIntent: async () => ({
				redirectUrl: "remotecode-mobile://auth/complete?completionToken=test",
				session: {
					accessToken: "register-token",
					refreshToken: "refresh-token",
					user: {
						daysRemaing: 7,
						daysRemaining: 7,
						email: "founder@remotecode.io",
						id: "usr_2",
						subscribed: true,
					},
				},
				signupIntent: {
					email: "founder@remotecode.io",
					id: "signup_456",
					platform: "ios",
					returnUrl: "remotecode-mobile://auth/complete",
					status: "completed",
					subscriptionStatus: "trialing",
					target: "mobile",
					trialEndsAt: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(),
				},
			}),
			createSignupIntent: async () => ({
				signupIntent: {
					email: "founder@remotecode.io",
					id: "signup_456",
					platform: "ios",
					returnUrl: "remotecode-mobile://auth/complete",
					status: "pending_checkout",
					subscriptionStatus: "inactive",
					target: "mobile",
					trialEndsAt: null,
				},
			}),
		}) as never,
		clearPendingSignupIntentRecord: async () => undefined,
		email: "founder@remotecode.io",
		platform: "ios",
		password,
		purchasesClient: {
			ensureConfigured: async () => true,
			getManagementUrl: () => "https://apps.apple.com/account/subscriptions",
			getOfferings: async () => ({
				current: {
					availablePackages: [],
					identifier: "default",
					monthly: {
						identifier: "$rc_monthly",
						packageType: "MONTHLY",
						product: {
							priceString: "$4.99",
						},
					},
				},
			}),
			isPurchaseCancelled: () => false,
			purchasePackage: async () => ({
				customerInfo: {
					entitlements: {
						active: {
							"PS Tech Pro": {},
						},
					},
				},
			}),
			restorePurchases: async () => ({
				entitlements: {
					active: {},
				},
			}),
		},
		readPendingSignupIntentRecord: async () => null,
		savePendingSignupIntentRecord: async (record) => record,
	});

	expect(session.user.email).toBe("founder@remotecode.io");
	expect(session.user.subscribed).toBe(true);
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

test("private account section sends password reset requests in-app", async () => {
	let requestedEmail = "";

	await requestPrivatePasswordReset({
		baseUrl: "https://private.remotecode.io:8787",
		createClient: () => ({
			requestPasswordReset: async (input: { email: string }) => {
				requestedEmail = input.email;
				return { sent: true };
			},
		}) as never,
		email: "reset@remotecode.io",
	});

	expect(requestedEmail).toBe("reset@remotecode.io");
});

test("private account section syncs RevenueCat subscription status through the backend", async () => {
	const subscription = await syncPrivateRevenueCatSubscriptionStatus({
		backendUrl: "https://private.remotecode.io:8787",
		createClient: () => ({
			syncRevenueCatSubscription: async () => ({
				subscription: {
					daysRemaing: 7,
					daysRemaining: 7,
					email: "founder@remotecode.io",
					endsAt: null,
					portalUrl: "https://apps.apple.com/account/subscriptions",
					renewsAt: null,
					status: "trialing",
					subscribed: true,
					trialEndsAt: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(),
				},
			}),
		}) as never,
		getAccessToken: () => "access-token",
	});

	expect(subscription.subscribed).toBe(true);
	expect(subscription.status).toBe("trialing");
});

test("privacy policy URL points to remotecode.io/privacy", () => {
	expect(buildPrivacyPolicyUrl()).toBe("https://remotecode.io/privacy");
});

test("terms of use URL points to remotecode.io/terms", () => {
	expect(buildTermsOfUseUrl()).toBe("https://remotecode.io/terms");
});

test("subscription management URL points to the native iOS subscriptions screen", () => {
	expect(buildNativeManageSubscriptionUrl("ios")).toBe("https://apps.apple.com/account/subscriptions");
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
