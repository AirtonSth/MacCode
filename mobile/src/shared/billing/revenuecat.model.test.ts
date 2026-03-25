/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import {
	REVENUECAT_ANDROID_API_KEY,
	REVENUECAT_APPLE_MANAGE_SUBSCRIPTION_URL,
	REVENUECAT_IOS_API_KEY,
	formatPrivateSubscriptionPriceLabel,
	getNativeSubscriptionManagementUrl,
	getRevenueCatApiKey,
	hasActiveRevenueCatEntitlement,
	isRevenueCatConfigured,
	isRevenueCatPlaceholderKey,
	selectRevenueCatPackage,
} from "./revenuecat.model";

test("getRevenueCatApiKey returns the iOS and Android placeholder keys", () => {
	expect(getRevenueCatApiKey("ios")).toBe(REVENUECAT_IOS_API_KEY);
	expect(getRevenueCatApiKey("android")).toBe(REVENUECAT_ANDROID_API_KEY);
});

test("isRevenueCatPlaceholderKey identifies dummy keys", () => {
	expect(isRevenueCatPlaceholderKey("appl_dummy_key")).toBe(true);
	expect(isRevenueCatPlaceholderKey("real_key_value")).toBe(false);
});

test("isRevenueCatConfigured is false while dummy keys are still in place", () => {
	expect(isRevenueCatConfigured("ios")).toBe(false);
	expect(isRevenueCatConfigured("android")).toBe(false);
});

test("getNativeSubscriptionManagementUrl returns the native App Store management url on iOS", () => {
	expect(getNativeSubscriptionManagementUrl("ios")).toBe(REVENUECAT_APPLE_MANAGE_SUBSCRIPTION_URL);
});

test("selectRevenueCatPackage prefers the monthly package from the current offering", () => {
	expect(
		selectRevenueCatPackage({
			all: {
				default: {
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
			},
			current: null,
		})?.identifier,
	).toBe("$rc_monthly");
});

test("selectRevenueCatPackage falls back to the first available package when monthly is missing", () => {
	expect(
		selectRevenueCatPackage({
			current: {
				availablePackages: [
					{
						identifier: "custom_package",
						packageType: "CUSTOM",
						product: {
							priceString: "$4.99",
						},
					},
				],
				identifier: "default",
				monthly: null,
			},
		})?.identifier,
	).toBe("custom_package");
});

test("hasActiveRevenueCatEntitlement checks the configured entitlement id", () => {
	expect(
		hasActiveRevenueCatEntitlement({
			entitlements: {
				active: {
					"private_connectors": {},
				},
			},
		}),
	).toBe(true);
});

test("formatPrivateSubscriptionPriceLabel uses the package price string when available", () => {
	expect(
		formatPrivateSubscriptionPriceLabel({
			identifier: "$rc_monthly",
			product: {
				priceString: "US$4.99",
			},
		}),
	).toBe("US$4.99");
});
