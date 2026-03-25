/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import {
	didRevenueCatUnlockPrivateAccess,
	purchasePrivateSubscription,
	restorePrivateSubscriptionPurchases,
	syncPrivateRevenueCatSubscription,
} from "./private-subscription.model";

const createPurchasesClient = () => ({
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
						"private_connectors": {},
					},
				},
			},
		}),
	restorePurchases: async () => ({
		entitlements: {
			active: {
				"private_connectors": {},
			},
		},
	}),
});

test("syncPrivateRevenueCatSubscription delegates the backend sync to the contracts client", async () => {
	const subscription = await syncPrivateRevenueCatSubscription({
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
});

test("purchasePrivateSubscription selects a RevenueCat package and syncs the backend subscription", async () => {
	const result = await purchasePrivateSubscription({
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
		purchasesClient: createPurchasesClient(),
		userId: "usr_1",
	});

	expect(result.pkg.identifier).toBe("$rc_monthly");
	expect(result.subscription.subscribed).toBe(true);
	expect(didRevenueCatUnlockPrivateAccess(result.customerInfo)).toBe(true);
});

test("restorePrivateSubscriptionPurchases syncs the restored entitlement with the backend", async () => {
	const result = await restorePrivateSubscriptionPurchases({
		backendUrl: "https://private.remotecode.io:8787",
		createClient: () => ({
			syncRevenueCatSubscription: async () => ({
				subscription: {
					daysRemaing: 7,
					daysRemaining: 7,
					email: "dev@example.com",
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
		purchasesClient: createPurchasesClient(),
		userId: "usr_1",
	});

	expect(result.subscription.status).toBe("trialing");
	expect(didRevenueCatUnlockPrivateAccess(result.customerInfo)).toBe(true);
});

test("purchasePrivateSubscription still returns active access when the backend sync is active before the local entitlement snapshot updates", async () => {
	const result = await purchasePrivateSubscription({
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
		purchasesClient: {
			...createPurchasesClient(),
			purchasePackage: async () => ({
				customerInfo: {
					entitlements: {
						active: {},
					},
				},
			}),
		},
		userId: "usr_1",
	});

	expect(result.subscription.subscribed).toBe(true);
	expect(didRevenueCatUnlockPrivateAccess(result.customerInfo)).toBe(false);
});

test("restorePrivateSubscriptionPurchases still trusts the backend sync when the local RevenueCat snapshot is stale", async () => {
	const result = await restorePrivateSubscriptionPurchases({
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
		purchasesClient: {
			...createPurchasesClient(),
			restorePurchases: async () => ({
				entitlements: {
					active: {},
				},
			}),
		},
		userId: "usr_1",
	});

	expect(result.subscription.subscribed).toBe(true);
	expect(didRevenueCatUnlockPrivateAccess(result.customerInfo)).toBe(false);
});
