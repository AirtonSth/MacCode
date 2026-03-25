/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import {
	purchasePrivateSubscription,
	restorePrivateSubscriptionPurchases,
} from "./private-subscription.model";

test("private subscription purchase flow fails fast when RevenueCat is not configured", async () => {
	expect(
		purchasePrivateSubscription({
			backendUrl: "https://private.remotecode.io:8787",
			getAccessToken: () => "access-token",
			purchasesClient: {
				ensureConfigured: async () => false,
				getManagementUrl: () => "https://apps.apple.com/account/subscriptions",
				getOfferings: async () => ({
					current: null,
				}),
				isPurchaseCancelled: () => false,
				purchasePackage: async () => ({
					customerInfo: {
						entitlements: {
							active: {},
						},
					},
				}),
				restorePurchases: async () => ({
					entitlements: {
						active: {},
					},
				}),
			},
			userId: "usr_1",
		}),
	).rejects.toThrow("revenuecat_not_configured");
});

test("private subscription restore flow also fails fast when RevenueCat is not configured", async () => {
	expect(
		restorePrivateSubscriptionPurchases({
			backendUrl: "https://private.remotecode.io:8787",
			getAccessToken: () => "access-token",
			purchasesClient: {
				ensureConfigured: async () => false,
				getManagementUrl: () => "https://apps.apple.com/account/subscriptions",
				getOfferings: async () => ({
					current: null,
				}),
				isPurchaseCancelled: () => false,
				purchasePackage: async () => ({
					customerInfo: {
						entitlements: {
							active: {},
						},
					},
				}),
				restorePurchases: async () => ({
					entitlements: {
						active: {},
					},
				}),
			},
			userId: "usr_1",
		}),
	).rejects.toThrow("revenuecat_not_configured");
});
