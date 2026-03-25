/* eslint-disable import/no-unresolved */
import { expect, mock, test } from "bun:test";

import { PrivateApiError } from "@remotecode/contracts";

import {
	buildNativeManageSubscriptionUrl,
	buildPrivacyPolicyUrl,
	buildTermsOfUseUrl,
	deletePrivateAccount,
	getPrivateSubscriptionSnapshot,
	loadPrivateConnectorsSafely,
	loginPrivateAccount,
	persistSavedPrivateConnection,
	refreshPrivateAccountSessionRecord,
	registerPrivateAccountWithTrial,
	requestPrivatePasswordReset,
	sortPrivateConnectors,
	syncPrivateRevenueCatSubscriptionStatus,
} from "./private-account-section.model";

test("sortPrivateConnectors prioritizes online connectors", () => {
	const sorted = sortPrivateConnectors([
		{
			claimedAt: "2026-01-01T00:00:00.000Z",
			hostname: "offline.local",
			id: "con_2",
			isOnline: false,
			lastSeenAt: "2026-01-01T00:00:00.000Z",
			name: "Offline",
			relayCapabilitiesVersion: "1",
			relayVersion: "1.0.0",
			status: "offline",
		},
		{
			claimedAt: "2026-01-02T00:00:00.000Z",
			hostname: "online.local",
			id: "con_1",
			isOnline: true,
			lastSeenAt: "2026-01-02T00:00:00.000Z",
			name: "Online",
			relayCapabilitiesVersion: "1",
			relayVersion: "1.0.0",
			status: "online",
		},
	]);

	expect(sorted[0]?.id).toBe("con_1");
});

test("loginPrivateAccount delegates login to the shared contracts client", async () => {
	const password = ["super", "secret"].join("");
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

	expect(session.accessToken).toBe("access-token");
});

test("registerPrivateAccountWithTrial creates a mobile signup intent, purchases the package, and completes the account", async () => {
	const password = ["super", "safe", "123"].join("");
	let configuredUserId = "";
	let purchaseCount = 0;

	const result = await registerPrivateAccountWithTrial({
		baseUrl: "https://private.remotecode.io:8787",
		createClient: () => ({
			completeSignupIntent: async () => {
				if (purchaseCount === 0) {
					throw new PrivateApiError(
						409,
						{ code: "signup_checkout_incomplete" },
						"Complete the checkout to activate your account.",
					);
				}

				return {
					redirectUrl: "remotecode-mobile://auth/complete?completionToken=test",
					session: {
						accessToken: "register-token",
						refreshToken: "refresh-token",
						user: {
							daysRemaing: 7,
							daysRemaining: 7,
							email: "new@example.com",
							id: "usr_new",
							subscribed: true,
						},
					},
					signupIntent: {
						email: "new@example.com",
						id: "signup_123",
						platform: "ios",
						returnUrl: "remotecode-mobile://auth/complete",
						status: "completed",
						subscriptionStatus: "trialing",
						target: "mobile",
						trialEndsAt: "2026-04-01T00:00:00.000Z",
					},
				};
			},
			createSignupIntent: async () => ({
				signupIntent: {
					email: "new@example.com",
					id: "signup_123",
					platform: "ios",
					returnUrl: "remotecode-mobile://auth/complete",
					status: "pending_checkout",
					subscriptionStatus: "inactive",
					target: "mobile",
					trialEndsAt: null,
				},
			}),
			getSignupIntent: async () => ({
				signupIntent: {
					email: "new@example.com",
					id: "signup_123",
					platform: "ios",
					returnUrl: "remotecode-mobile://auth/complete",
					status: "completed",
					subscriptionStatus: "trialing",
					target: "mobile",
					trialEndsAt: "2026-04-01T00:00:00.000Z",
				},
			}),
			login: async () => ({
				accessToken: "register-token",
				refreshToken: "refresh-token",
				user: {
					daysRemaing: 7,
					daysRemaining: 7,
					email: "new@example.com",
					id: "usr_new",
					subscribed: true,
				},
			}),
		}) as never,
		clearPendingSignupIntentRecord: async () => undefined,
		email: "new@example.com",
		platform: "ios",
		password,
		purchasesClient: {
			ensureConfigured: async (userId) => {
				configuredUserId = userId;
				return true;
			},
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
			purchasePackage: async (pkg) => {
				purchaseCount += 1;
				return {
					customerInfo: {
						entitlements: {
							active: {
								"PS Tech Pro": {
									pkg,
								},
							},
						},
					},
				};
			},
			restorePurchases: async () => ({
				entitlements: {
					active: {},
				},
			}),
		},
		readPendingSignupIntentRecord: async () => null,
		savePendingSignupIntentRecord: async (record) => record,
	});

	expect(configuredUserId).toBe("signup_123");
	expect(purchaseCount).toBe(1);
	expect(result.session.user.email).toBe("new@example.com");
	expect(result.session.accessToken).toBe("register-token");
	expect(result.pkg?.identifier).toBe("$rc_monthly");
});

test("registerPrivateAccountWithTrial resumes an existing mobile signup intent without repurchasing when the trial is already active", async () => {
	const password = ["resume", "secret", "123"].join("");
	let purchaseCount = 0;

	const result = await registerPrivateAccountWithTrial({
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
						email: "resume@example.com",
						id: "usr_resume",
						subscribed: true,
					},
				},
				signupIntent: {
					email: "resume@example.com",
					id: "signup_resume",
					platform: "ios",
					returnUrl: "remotecode-mobile://auth/complete",
					status: "completed",
					subscriptionStatus: "trialing",
					target: "mobile",
					trialEndsAt: "2026-04-01T00:00:00.000Z",
				},
			}),
			createSignupIntent: async () => ({
				signupIntent: {
					email: "resume@example.com",
					id: "signup_resume",
					platform: "ios",
					returnUrl: "remotecode-mobile://auth/complete",
					status: "billing_active",
					subscriptionStatus: "trialing",
					target: "mobile",
					trialEndsAt: "2026-04-01T00:00:00.000Z",
				},
			}),
		}) as never,
		clearPendingSignupIntentRecord: async () => undefined,
		email: "resume@example.com",
		platform: "ios",
		password,
		purchasesClient: {
			ensureConfigured: async () => true,
			getManagementUrl: () => "https://apps.apple.com/account/subscriptions",
			getOfferings: async () => ({ current: null }),
			isPurchaseCancelled: () => false,
			purchasePackage: async () => {
				purchaseCount += 1;
				return {
					customerInfo: {
						entitlements: {
							active: {},
						},
					},
				};
			},
			restorePurchases: async () => ({
				entitlements: {
					active: {},
				},
			}),
		},
		readPendingSignupIntentRecord: async () => null,
		savePendingSignupIntentRecord: async (record) => record,
	});

	expect(purchaseCount).toBe(0);
	expect(result.session.user.email).toBe("resume@example.com");
});

test("registerPrivateAccountWithTrial continues to the native purchase flow when checkout incomplete is returned as a plain message", async () => {
	const password = ["plain", "message", "123"].join("");
	let purchaseCount = 0;

	const result = await registerPrivateAccountWithTrial({
		baseUrl: "https://private.remotecode.io:8787",
		createClient: () => ({
			completeSignupIntent: async () => {
				if (purchaseCount === 0) {
					throw new PrivateApiError(
						409,
						{ error: "Complete the checkout to activate your account." },
						"Complete the checkout to activate your account.",
					);
				}

				return {
					redirectUrl: "remotecode-mobile://auth/complete?completionToken=test",
					session: {
						accessToken: "register-token",
						refreshToken: "refresh-token",
						user: {
							daysRemaing: 7,
							daysRemaining: 7,
							email: "plain@example.com",
							id: "usr_plain",
							subscribed: true,
						},
					},
					signupIntent: {
						email: "plain@example.com",
						id: "signup_plain",
						platform: "ios",
						returnUrl: "remotecode-mobile://auth/complete",
						status: "completed",
						subscriptionStatus: "trialing",
						target: "mobile",
						trialEndsAt: "2026-04-01T00:00:00.000Z",
					},
				};
			},
			createSignupIntent: async () => ({
				signupIntent: {
					email: "plain@example.com",
					id: "signup_plain",
					platform: "ios",
					returnUrl: "remotecode-mobile://auth/complete",
					status: "pending_checkout",
					subscriptionStatus: "inactive",
					target: "mobile",
					trialEndsAt: null,
				},
			}),
			getSignupIntent: async () => {
				return {
					signupIntent: {
						email: "plain@example.com",
						id: "signup_plain",
						platform: "ios",
						returnUrl: "remotecode-mobile://auth/complete",
						status: "completed",
						subscriptionStatus: "trialing",
						target: "mobile",
						trialEndsAt: "2026-04-01T00:00:00.000Z",
					},
				};
			},
			login: async () => ({
				accessToken: "register-token",
				refreshToken: "refresh-token",
				user: {
					daysRemaing: 7,
					daysRemaining: 7,
					email: "plain@example.com",
					id: "usr_plain",
					subscribed: true,
				},
			}),
		}) as never,
		clearPendingSignupIntentRecord: async () => undefined,
		email: "plain@example.com",
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
			purchasePackage: async () => {
				purchaseCount += 1;
				return {
					customerInfo: {
						entitlements: {
							active: {
								"PS Tech Pro": {},
							},
						},
					},
				};
			},
			restorePurchases: async () => ({
				entitlements: {
					active: {},
				},
			}),
		},
		readPendingSignupIntentRecord: async () => null,
		savePendingSignupIntentRecord: async (record) => record,
	});

	expect(purchaseCount).toBe(1);
	expect(result.session.user.email).toBe("plain@example.com");
});

test("registerPrivateAccountWithTrial restores purchases and retries completion when activation lags after purchase", async () => {
	const password = ["recover", "after", "purchase"].join("");
	let activationPollCount = 0;
	let restoreCount = 0;

	const result = await registerPrivateAccountWithTrial({
		baseUrl: "https://private.remotecode.io:8787",
		activationPollIntervalMs: 0,
		activationPostRestoreTimeoutMs: 0,
		activationTimeoutMs: 0,
		createClient: () => ({
			completeSignupIntent: async () => {
				throw new PrivateApiError(
					409,
					{ code: "signup_checkout_incomplete" },
					"Complete the checkout to activate your account.",
				);
			},
			createSignupIntent: async () => ({
				signupIntent: {
					email: "recover-after-purchase@example.com",
					id: "signup_recover_after_purchase",
					platform: "ios",
					returnUrl: "remotecode-mobile://auth/complete",
					status: "pending_checkout",
					subscriptionStatus: "inactive",
					target: "mobile",
					trialEndsAt: null,
				},
			}),
			getSignupIntent: async () => {
				activationPollCount += 1;
				return {
					signupIntent: {
						email: "recover-after-purchase@example.com",
						id: "signup_recover_after_purchase",
						platform: "ios",
						returnUrl: "remotecode-mobile://auth/complete",
						status: activationPollCount >= 2 ? "completed" : "pending_checkout",
						subscriptionStatus: activationPollCount >= 2 ? "trialing" : "inactive",
						target: "mobile",
						trialEndsAt: activationPollCount >= 2 ? "2026-04-01T00:00:00.000Z" : null,
					},
				};
			},
			login: async () => ({
				accessToken: "register-token",
				refreshToken: "refresh-token",
				user: {
					daysRemaing: 7,
					daysRemaining: 7,
					email: "recover-after-purchase@example.com",
					id: "usr_recover_after_purchase",
					subscribed: true,
				},
			}),
		}) as never,
		clearPendingSignupIntentRecord: async () => undefined,
		email: "recover-after-purchase@example.com",
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
			restorePurchases: async () => {
				restoreCount += 1;
				return {
					entitlements: {
						active: {
							"PS Tech Pro": {},
						},
					},
				};
			},
		},
		readPendingSignupIntentRecord: async () => null,
		savePendingSignupIntentRecord: async (record) => record,
	});

	expect(activationPollCount).toBe(2);
	expect(restoreCount).toBe(1);
	expect(result.session.user.email).toBe("recover-after-purchase@example.com");
});

test("registerPrivateAccountWithTrial resumes a pending signup intent from local storage when the backend rejects duplicate signup creation", async () => {
	const password = ["recover", "secret", "123"].join("");
	let lookedUpSignupIntentId = "";
	let purchaseCount = 0;
	let clearedPendingRecordCount = 0;
	let signupIntentStatusLookupCount = 0;

	const result = await registerPrivateAccountWithTrial({
		baseUrl: "https://private.remotecode.io:8787",
		clearPendingSignupIntentRecord: async () => {
			clearedPendingRecordCount += 1;
		},
		createClient: () => ({
			completeSignupIntent: async () => {
				if (purchaseCount === 0) {
					throw new PrivateApiError(
						409,
						{ code: "signup_checkout_incomplete" },
						"Complete the checkout to activate your account.",
					);
				}

				return {
					redirectUrl: "remotecode-mobile://auth/complete?completionToken=test",
					session: {
						accessToken: "register-token",
						refreshToken: "refresh-token",
						user: {
							daysRemaing: 7,
							daysRemaining: 7,
							email: "recover@example.com",
							id: "usr_recover",
							subscribed: true,
						},
					},
					signupIntent: {
						email: "recover@example.com",
						id: "signup_cached",
						platform: "ios",
						returnUrl: "remotecode-mobile://auth/complete",
						status: "completed",
						subscriptionStatus: "trialing",
						target: "mobile",
						trialEndsAt: "2026-04-01T00:00:00.000Z",
					},
				};
			},
			createSignupIntent: async () => {
				throw new PrivateApiError(
					409,
					{ error: "A pending signup already exists for this email." },
					"A pending signup already exists for this email.",
				);
			},
			getSignupIntent: async (signupIntentId: string) => {
				lookedUpSignupIntentId = signupIntentId;
				signupIntentStatusLookupCount += 1;
				return {
					signupIntent: {
						email: "recover@example.com",
						id: "signup_cached",
						platform: "ios",
						returnUrl: "remotecode-mobile://auth/complete",
						status: signupIntentStatusLookupCount >= 2 ? "completed" : "pending_checkout",
						subscriptionStatus: signupIntentStatusLookupCount >= 2 ? "trialing" : "inactive",
						target: "mobile",
						trialEndsAt: signupIntentStatusLookupCount >= 2 ? "2026-04-01T00:00:00.000Z" : null,
					},
				};
			},
			login: async () => ({
				accessToken: "register-token",
				refreshToken: "refresh-token",
				user: {
					daysRemaing: 7,
					daysRemaining: 7,
					email: "recover@example.com",
					id: "usr_recover",
					subscribed: true,
				},
			}),
		}) as never,
		email: "recover@example.com",
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
			purchasePackage: async () => {
				purchaseCount += 1;
				return {
					customerInfo: {
						entitlements: {
							active: {
								"PS Tech Pro": {},
							},
						},
					},
				};
			},
			restorePurchases: async () => ({
				entitlements: {
					active: {},
				},
			}),
		},
		readPendingSignupIntentRecord: async () => ({
			backendUrl: "https://private.remotecode.io:8787",
			email: "recover@example.com",
			platform: "ios",
			signupIntentId: "signup_cached",
		}),
		savePendingSignupIntentRecord: async (record) => record,
	});

	expect(lookedUpSignupIntentId).toBe("signup_cached");
	expect(purchaseCount).toBe(1);
	expect(signupIntentStatusLookupCount).toBe(2);
	expect(clearedPendingRecordCount).toBe(1);
	expect(result.session.user.email).toBe("recover@example.com");
});

test("registerPrivateAccountWithTrial surfaces a clear timeout error when the purchase never resolves", async () => {
	const password = ["timeout", "secret", "123"].join("");

	const timeoutErrorPromise = registerPrivateAccountWithTrial({
		baseUrl: "https://private.remotecode.io:8787",
		createClient: () => ({
			completeSignupIntent: async () => {
				throw new PrivateApiError(
					409,
					{ code: "signup_checkout_incomplete" },
					"Complete the checkout to activate your account.",
				);
			},
			createSignupIntent: async () => ({
				signupIntent: {
					email: "timeout@example.com",
					id: "signup_timeout",
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
		email: "timeout@example.com",
		platform: "ios",
		password,
		purchaseTimeoutMs: 1,
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
				// eslint-disable-next-line promise/avoid-new -- This test needs a permanently pending purchase promise.
				purchasePackage: async () => await new Promise<never>((resolve) => {
					void resolve;
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
	try {
		await timeoutErrorPromise;
		throw new Error("Expected the registration flow to time out.");
	} catch (error) {
		expect(error).toBeInstanceOf(Error);
		expect((error as Error).message).toBe(
			"Timed out while starting the in-app trial. If you're testing on the iOS Simulator, run the app from Xcode with a StoreKit configuration file or test on a physical device.",
		);
	}
});

test("requestPrivatePasswordReset delegates the reset email request to the shared contracts client", async () => {
	let seenEmail = "";

	await requestPrivatePasswordReset({
		baseUrl: "https://private.remotecode.io:8787",
		createClient: () => ({
			requestPasswordReset: async (input: { email: string }) => {
				seenEmail = input.email;
				return { sent: true };
			},
		}) as never,
		email: "reset@example.com",
	});

	expect(seenEmail).toBe("reset@example.com");
});

test("syncPrivateRevenueCatSubscriptionStatus returns the backend subscription snapshot", async () => {
	const subscription = await syncPrivateRevenueCatSubscriptionStatus({
		backendUrl: "https://private.remotecode.io:8787",
		createClient: () => ({
			syncRevenueCatSubscription: async () => ({
				subscription: {
					daysRemaing: 30,
					daysRemaining: 30,
					email: "dev@example.com",
					endsAt: null,
					portalUrl: "https://apps.apple.com/account/subscriptions",
					renewsAt: null,
					status: "active",
					subscribed: true,
					trialEndsAt: null,
				},
			}),
		}) as never,
		getAccessToken: () => "access-token",
	});

	expect(subscription.subscribed).toBe(true);
	expect(subscription.portalUrl).toBe("https://apps.apple.com/account/subscriptions");
});

test("loadPrivateConnectorsSafely reports load failures instead of rejecting", async () => {
	let seenMessage = "";

	await loadPrivateConnectorsSafely({
		loadConnectors: async () => {
			throw new Error("connector_load_failed");
		},
		onError: (message) => {
			seenMessage = message;
		},
	});

	expect(seenMessage).toBe("connector_load_failed");
});

test("persistSavedPrivateConnection stores a reconnectable private saved connection", async () => {
	let persistedBackendUrl = "";
	let persistedConnectorId = "";
	let persistedConnectorName = "";
	let persistedKind = "";

	await persistSavedPrivateConnection({
		backendUrl: "https://private.remotecode.io:8787/",
		connector: {
			id: "con_1",
			name: "Desktop Connector",
		},
		saveSavedConnection: async (input) => {
			if (input.kind === "private") {
				persistedBackendUrl = input.backendUrl;
				persistedConnectorId = input.connectorId;
				persistedConnectorName = input.connectorName;
				persistedKind = input.kind;
			}
			return [];
		},
	});

	expect(persistedBackendUrl).toBe("https://private.remotecode.io:8787");
	expect(persistedConnectorId).toBe("con_1");
	expect(persistedConnectorName).toBe("Desktop Connector");
	expect(persistedKind).toBe("private");
});

test("buildNativeManageSubscriptionUrl points iOS users to native subscription management", () => {
	expect(buildNativeManageSubscriptionUrl("ios")).toBe("https://apps.apple.com/account/subscriptions");
});

test("buildPrivacyPolicyUrl returns the privacy policy page", () => {
	expect(buildPrivacyPolicyUrl()).toBe("https://remotecode.io/privacy");
});

test("buildTermsOfUseUrl returns the terms of use page", () => {
	expect(buildTermsOfUseUrl()).toBe("https://remotecode.io/terms");
});

test("refreshPrivateAccountSessionRecord updates subscription state from private account /me response", async () => {
	const createClient = mock(() => ({
		me: async () => ({
			user: {
				daysRemaing: 10,
				daysRemaining: 10,
				email: "dev@example.com",
				id: "usr_1",
				subscribed: true,
			},
		}),
	}));

	const refreshed = await refreshPrivateAccountSessionRecord({
		createClient,
		sessionRecord: {
			backendUrl: "https://private.remotecode.io:8787",
			session: {
				accessToken: "access-token",
				refreshToken: "refresh-token",
				user: {
					daysRemaing: 10,
					daysRemaining: 10,
					email: "dev@example.com",
					id: "usr_1",
					subscribed: false,
				},
			},
		},
	});

	expect(refreshed?.session.user.subscribed).toBe(true);
	expect(createClient).toHaveBeenCalledTimes(1);
});

test("refreshPrivateAccountSessionRecord refreshes tokens when /me returns unauthorized", async () => {
	let meCalls = 0;
	const unauthorized = new PrivateApiError(401, null, "private_session_expired");
	const createClient = mock(() => ({
		me: async () => {
			meCalls += 1;
			if (meCalls === 1) {
				throw unauthorized;
			}

			return {
				user: {
					daysRemaing: 10,
					daysRemaining: 10,
					email: "dev@example.com",
					id: "usr_1",
					subscribed: true,
				},
			};
		},
	}));
	const refreshSession = mock(async () => ({
		accessToken: "next-access-token",
		refreshToken: "next-refresh-token",
		user: {
			daysRemaing: 10,
			daysRemaining: 10,
			email: "dev@example.com",
			id: "usr_1",
			subscribed: false,
		},
	}));

	const refreshed = await refreshPrivateAccountSessionRecord({
		createClient,
		refreshSession,
		sessionRecord: {
			backendUrl: "https://private.remotecode.io:8787",
			session: {
				accessToken: "expired-token",
				refreshToken: "refresh-token",
				user: {
					daysRemaing: 10,
					daysRemaining: 10,
					email: "dev@example.com",
					id: "usr_1",
					subscribed: false,
				},
			},
		},
	});

	expect(refreshed?.session.accessToken).toBe("next-access-token");
	expect(refreshed?.session.user.subscribed).toBe(true);
	expect(refreshSession).toHaveBeenCalledTimes(1);
	expect(meCalls).toBe(2);
});

test("getPrivateSubscriptionSnapshot reads the subscription flags from the session", () => {
	expect(getPrivateSubscriptionSnapshot({
		accessToken: "access-token",
		refreshToken: "refresh-token",
		user: {
			daysRemaing: 30,
			daysRemaining: 30,
			email: "dev@example.com",
			id: "usr_1",
			subscribed: false,
		},
	})).toEqual({
		daysRemaining: 30,
		isSubscribed: false,
	});
});

test("deletePrivateAccount delegates deletion to the shared contracts client", async () => {
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
