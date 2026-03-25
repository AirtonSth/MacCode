import { createPrivateClient, type PrivateSubscriptionSnapshotDto } from "@remotecode/contracts";

import {
	hasActiveRevenueCatEntitlement,
	selectRevenueCatPackage,
	type RevenueCatCustomerInfoLike,
	type RevenueCatPackageLike,
} from "../../../shared/billing/revenuecat.model";
import type { RevenueCatPurchasesClient } from "../../../shared/billing/revenuecat";

export interface PrivateSubscriptionPurchaseResult {
	customerInfo: RevenueCatCustomerInfoLike;
	pkg: RevenueCatPackageLike;
	subscription: PrivateSubscriptionSnapshotDto;
}

const PRIVATE_SUBSCRIPTION_PACKAGE_UNAVAILABLE = "private_subscription_package_unavailable";

export const syncPrivateRevenueCatSubscription = async (input: {
	backendUrl: string;
	createClient?: typeof createPrivateClient;
	getAccessToken: () => string;
}): Promise<PrivateSubscriptionSnapshotDto> => {
	const client = (input.createClient ?? createPrivateClient)({
		baseUrl: input.backendUrl,
		getAccessToken: input.getAccessToken,
	});

	const response = await client.syncRevenueCatSubscription();
	return response.subscription;
};

export const purchasePrivateSubscription = async (input: {
	backendUrl: string;
	createClient?: typeof createPrivateClient;
	getAccessToken: () => string;
	purchasesClient: RevenueCatPurchasesClient;
	userId: string;
}): Promise<PrivateSubscriptionPurchaseResult> => {
	const configured = await input.purchasesClient.ensureConfigured(input.userId);
	if (!configured) {
		throw new Error("revenuecat_not_configured");
	}

	const offerings = await input.purchasesClient.getOfferings();
	const pkg = selectRevenueCatPackage(offerings);
	if (!pkg) {
		throw new Error(PRIVATE_SUBSCRIPTION_PACKAGE_UNAVAILABLE);
	}

	const { customerInfo } = await input.purchasesClient.purchasePackage(pkg);
	const subscription = await syncPrivateRevenueCatSubscription({
		backendUrl: input.backendUrl,
		createClient: input.createClient,
		getAccessToken: input.getAccessToken,
	});

	return {
		customerInfo,
		pkg,
		subscription,
	};
};

export const restorePrivateSubscriptionPurchases = async (input: {
	backendUrl: string;
	createClient?: typeof createPrivateClient;
	getAccessToken: () => string;
	purchasesClient: RevenueCatPurchasesClient;
	userId: string;
}): Promise<{
	customerInfo: RevenueCatCustomerInfoLike;
	subscription: PrivateSubscriptionSnapshotDto;
}> => {
	const configured = await input.purchasesClient.ensureConfigured(input.userId);
	if (!configured) {
		throw new Error("revenuecat_not_configured");
	}

	const customerInfo = await input.purchasesClient.restorePurchases();
	const subscription = await syncPrivateRevenueCatSubscription({
		backendUrl: input.backendUrl,
		createClient: input.createClient,
		getAccessToken: input.getAccessToken,
	});

	return {
		customerInfo,
		subscription,
	};
};

export const didRevenueCatUnlockPrivateAccess = (
	customerInfo: RevenueCatCustomerInfoLike,
): boolean => hasActiveRevenueCatEntitlement(customerInfo);
