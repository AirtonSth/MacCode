import Purchases, { PURCHASES_ERROR_CODE, type PurchasesPackage } from "react-native-purchases";
import { Platform } from "react-native";

import {
	getNativeSubscriptionManagementUrl,
	getRevenueCatApiKey,
	isRevenueCatConfigured,
	type RevenueCatCustomerInfoLike,
	type RevenueCatOfferingsLike,
	type RevenueCatPackageLike,
	type RevenueCatPlatform,
} from "./revenuecat.model";

export interface RevenueCatPurchasesClient {
	ensureConfigured: (userId: string) => Promise<boolean>;
	getManagementUrl: () => string;
	getOfferings: () => Promise<RevenueCatOfferingsLike>;
	isPurchaseCancelled: (error: unknown) => boolean;
	purchasePackage: (pkg: RevenueCatPackageLike) => Promise<{ customerInfo: RevenueCatCustomerInfoLike }>;
	restorePurchases: () => Promise<RevenueCatCustomerInfoLike>;
}

let configuredUserId: string | null = null;
let isConfigured = false;

const getSupportedPlatform = (): RevenueCatPlatform | null => {
	switch (Platform.OS) {
		case "android": {
			return "android";
		}
		case "ios": {
			return "ios";
		}
		default: {
			return null;
		}
	}
};

const ensureConfigured = async (userId: string): Promise<boolean> => {
	const platform = getSupportedPlatform();
	if (!platform || !isRevenueCatConfigured(platform)) {
		return false;
	}

	await Purchases.setLogLevel(Purchases.LOG_LEVEL.WARN);
	if (!isConfigured) {
		Purchases.configure({
			apiKey: getRevenueCatApiKey(platform),
			appUserID: userId,
		});
		configuredUserId = userId;
		isConfigured = true;
		return true;
	}

	if (configuredUserId !== userId) {
		configuredUserId = userId;
		await Purchases.logIn(userId);
	}

	return true;
};

export const revenueCatPurchasesClient: RevenueCatPurchasesClient = {
	ensureConfigured,
	getManagementUrl: () => getNativeSubscriptionManagementUrl(getSupportedPlatform() ?? "ios"),
	getOfferings: async () => await Purchases.getOfferings(),
	isPurchaseCancelled: (error) =>
		Boolean(
			error
			&& typeof error === "object"
			&& "code" in error
			&& error.code === PURCHASES_ERROR_CODE.PURCHASE_CANCELLED_ERROR,
		),
	purchasePackage: async (pkg) => {
		const result = await Purchases.purchasePackage(pkg as PurchasesPackage);
		return { customerInfo: result.customerInfo };
	},
	restorePurchases: async () => await Purchases.restorePurchases(),
};
