export type RevenueCatPlatform = "android" | "ios";

export const PRIVATE_SUBSCRIPTION_PRICE_USD = 4.99;
export const REVENUECAT_ENTITLEMENT_ID = "private_connectors";
export const REVENUECAT_OFFERING_ID = "default";
export const REVENUECAT_IOS_API_KEY = "appl_dummy_ios_public_sdk_key";
export const REVENUECAT_ANDROID_API_KEY = "goog_dummy_android_public_sdk_key";
export const REVENUECAT_APPLE_MANAGE_SUBSCRIPTION_URL = "https://apps.apple.com/account/subscriptions";
export const REVENUECAT_PLAY_MANAGE_SUBSCRIPTION_URL = "https://play.google.com/store/account/subscriptions";

export interface RevenueCatPackageLike {
	identifier: string;
	packageType?: string | null;
	product: {
		priceString?: string | null;
	};
}

export interface RevenueCatOfferingLike {
	availablePackages: RevenueCatPackageLike[];
	identifier: string;
	monthly?: RevenueCatPackageLike | null;
}

export interface RevenueCatOfferingsLike {
	all?: Record<string, RevenueCatOfferingLike | undefined>;
	current: RevenueCatOfferingLike | null;
}

export interface RevenueCatCustomerInfoLike {
	entitlements: {
		active: Record<string, unknown>;
	};
}

const PLACEHOLDER_KEY_MARKERS = ["dummy", "placeholder"];

export const getRevenueCatApiKey = (platform: RevenueCatPlatform): string =>
	platform === "android" ? REVENUECAT_ANDROID_API_KEY : REVENUECAT_IOS_API_KEY;

export const isRevenueCatPlaceholderKey = (value: string): boolean => {
	const normalized = value.trim().toLowerCase();
	return normalized.length === 0 || PLACEHOLDER_KEY_MARKERS.some((marker) => normalized.includes(marker));
};

export const isRevenueCatConfigured = (platform: RevenueCatPlatform): boolean =>
	!isRevenueCatPlaceholderKey(getRevenueCatApiKey(platform));

export const getNativeSubscriptionManagementUrl = (platform: RevenueCatPlatform): string =>
	platform === "android"
		? REVENUECAT_PLAY_MANAGE_SUBSCRIPTION_URL
		: REVENUECAT_APPLE_MANAGE_SUBSCRIPTION_URL;

export const selectRevenueCatOffering = (
	offerings: RevenueCatOfferingsLike,
	offeringId = REVENUECAT_OFFERING_ID,
): RevenueCatOfferingLike | null =>
	offerings.all?.[offeringId] ?? offerings.current;

export const selectRevenueCatPackage = (
	offerings: RevenueCatOfferingsLike,
	offeringId = REVENUECAT_OFFERING_ID,
): RevenueCatPackageLike | null => {
	const offering = selectRevenueCatOffering(offerings, offeringId);
	if (!offering) {
		return null;
	}

	return (
		offering.monthly
		?? offering.availablePackages.find((pkg) => pkg.packageType?.toUpperCase() === "MONTHLY")
		?? offering.availablePackages[0]
		?? null
	);
};

export const hasActiveRevenueCatEntitlement = (
	customerInfo: RevenueCatCustomerInfoLike,
	entitlementId = REVENUECAT_ENTITLEMENT_ID,
): boolean => Boolean(customerInfo.entitlements.active[entitlementId]);

export const formatPrivateSubscriptionPriceLabel = (pkg?: RevenueCatPackageLike | null): string =>
	pkg?.product.priceString?.trim() || `$${PRIVATE_SUBSCRIPTION_PRICE_USD.toFixed(2)}/month`;
