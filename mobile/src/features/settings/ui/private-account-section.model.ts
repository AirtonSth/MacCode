import {
	createPrivateClient,
	PrivateApiError,
	type PrivateConnectorDto,
	type PrivateSignupIntentDto,
	type PrivateSessionDto,
	type PrivateSubscriptionSnapshotDto,
} from "@remotecode/contracts";

import type { PersistedPrivateSessionRecord } from "../../../shared/api/private-session-store";
import { ApiConfigStore } from "../../../shared/api/api-config-store";
import {
	getNativeSubscriptionManagementUrl,
	selectRevenueCatPackage,
	type RevenueCatCustomerInfoLike,
	type RevenueCatPackageLike,
	type RevenueCatPlatform,
} from "../../../shared/billing/revenuecat.model";
import type { RevenueCatPurchasesClient } from "../../../shared/billing/revenuecat";
import {
	PrivateSignupIntentStore,
	type PersistedPrivateSignupIntentRecord,
} from "../../../shared/api/private-signup-intent-store";

const REMOTECODE_WEB_URL = "https://remotecode.io";
const REMOTECODE_PRIVACY_POLICY_URL = `${REMOTECODE_WEB_URL}/privacy`;
const REMOTECODE_TERMS_OF_USE_URL = `${REMOTECODE_WEB_URL}/terms`;
const MOBILE_SIGNUP_RETURN_URL = "remotecode-mobile://auth/complete";
const PRIVATE_TRIAL_OFFERINGS_TIMEOUT_MS = 15_000;
const PRIVATE_TRIAL_ACTIVATION_POLL_INTERVAL_MS = 1_500;
const PRIVATE_TRIAL_ACTIVATION_TIMEOUT_MS = 20_000;
const PRIVATE_TRIAL_ACTIVATION_POST_RESTORE_TIMEOUT_MS = 20_000;
const PRIVATE_TRIAL_PURCHASE_TIMEOUT_MS = 30_000;
const PRIVATE_TRIAL_PURCHASE_TIMEOUT_MESSAGE =
	"Timed out while starting the in-app trial. If you're testing on the iOS Simulator, run the app from Xcode with a StoreKit configuration file or test on a physical device.";
const PRIVATE_TRIAL_ACTIVATION_TIMEOUT_MESSAGE =
	"Purchase completed, but account activation is still pending. Try again in a moment or use Restore purchases.";

const trimBaseUrl = (value: string): string => value.trim().replace(/\/+$/u, "");
const isObject = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null;
const isSignupCheckoutIncomplete = (error: unknown): boolean =>
	error instanceof PrivateApiError
	&& (
		(isObject(error.payload) && error.payload.code === "signup_checkout_incomplete")
		|| error.message.toLowerCase().includes("complete the checkout")
	);
const isPendingSignupIntentError = (error: unknown): boolean =>
	error instanceof PrivateApiError
	&& (
		(isObject(error.payload) && typeof error.payload.code === "string" && error.payload.code.includes("pending"))
		|| error.message.toLowerCase().includes("pending signup already exists")
	);
const extractSignupIntentId = (payload: unknown): string | null => {
	if (!isObject(payload)) {
		return null;
	}

	if (typeof payload.signupIntentId === "string" && payload.signupIntentId.trim().length > 0) {
		return payload.signupIntentId.trim();
	}

	if (
		isObject(payload.signupIntent)
		&& typeof payload.signupIntent.id === "string"
		&& payload.signupIntent.id.trim().length > 0
	) {
		return payload.signupIntent.id.trim();
	}

	return null;
};
const withTimeout = async <T>(
	promise: Promise<T>,
	timeoutMs: number,
	timeoutMessage: string,
): Promise<T> => {
	let timeoutId: ReturnType<typeof setTimeout> | null = null;

	try {
		return await Promise.race([
			promise,
			// eslint-disable-next-line promise/avoid-new -- Timeout needs a deferred rejection promise.
			new Promise<T>((resolve, reject) => {
				void resolve;
				timeoutId = setTimeout(() => {
					reject(new Error(timeoutMessage));
				}, timeoutMs);
			}),
		]);
	} finally {
		if (timeoutId) {
			clearTimeout(timeoutId);
		}
	}
};

const wait = async (delayMs: number): Promise<void> => {
	// eslint-disable-next-line promise/avoid-new -- Small delay helper used for RevenueCat propagation retries.
	await new Promise<void>((resolve) => {
		setTimeout(resolve, delayMs);
	});
};

const waitForSignupIntentActivation = async (input: {
	activationPollIntervalMs?: number;
	activationPostRestoreTimeoutMs?: number;
	activationTimeoutMs?: number;
	client: Pick<ReturnType<typeof createPrivateClient>, "getSignupIntent" | "login">;
	email: string;
	password: string;
	purchasesClient: Pick<RevenueCatPurchasesClient, "restorePurchases">;
	signupIntentId: string;
}) => {
	const pollIntervalMs = input.activationPollIntervalMs ?? PRIVATE_TRIAL_ACTIVATION_POLL_INTERVAL_MS;
	const activationDeadline = Date.now() + (input.activationTimeoutMs ?? PRIVATE_TRIAL_ACTIVATION_TIMEOUT_MS);
	let restoreDeadline = 0;
	let didRestorePurchases = false;

	/* eslint-disable no-await-in-loop -- Polling must observe sequential backend state transitions. */
	for (;;) {
		const signupIntentResponse = await input.client.getSignupIntent(input.signupIntentId);
		const currentSignupIntent = signupIntentResponse.signupIntent;

		if (currentSignupIntent.status === "completed") {
			return {
				session: await input.client.login({
					email: input.email,
					password: input.password,
				}),
				signupIntent: currentSignupIntent,
			};
		}

		if (currentSignupIntent.status === "canceled" || currentSignupIntent.status === "expired") {
			throw new Error("This signup session is no longer valid. Start the trial again.");
		}

		const now = Date.now();
		if (!didRestorePurchases && now >= activationDeadline) {
			await input.purchasesClient.restorePurchases();
			didRestorePurchases = true;
			restoreDeadline = now + (input.activationPostRestoreTimeoutMs ?? PRIVATE_TRIAL_ACTIVATION_POST_RESTORE_TIMEOUT_MS);
			continue;
		}

		if (didRestorePurchases && now >= restoreDeadline) {
			throw new Error(PRIVATE_TRIAL_ACTIVATION_TIMEOUT_MESSAGE);
		}

		await wait(pollIntervalMs);
	}
	/* eslint-enable no-await-in-loop */
};

export const buildNativeManageSubscriptionUrl = (platform: RevenueCatPlatform): string =>
	getNativeSubscriptionManagementUrl(platform);

export const buildPrivacyPolicyUrl = (): string => REMOTECODE_PRIVACY_POLICY_URL;

export const buildTermsOfUseUrl = (): string => REMOTECODE_TERMS_OF_USE_URL;

export const deletePrivateAccount = async (input: {
	backendUrl: string;
	createClient?: typeof createPrivateClient;
	getAccessToken: () => string;
}): Promise<void> => {
	const client = (input.createClient ?? createPrivateClient)({
		baseUrl: input.backendUrl,
		getAccessToken: input.getAccessToken,
	});
	await client.deleteAccount();
};

export const getPrivateSubscriptionSnapshot = (
	session: PrivateSessionDto | null | undefined,
): {
	daysRemaining: number;
	isSubscribed: boolean;
} => ({
	daysRemaining: session?.user.daysRemaining ?? session?.user.daysRemaing ?? 0,
	isSubscribed: Boolean(session?.user.subscribed),
});

export const sortPrivateConnectors = (connectors: PrivateConnectorDto[]): PrivateConnectorDto[] =>
	Array.from(connectors).sort((left, right) => {
		if (left.status === right.status) {
			return (right.lastSeenAt ?? "").localeCompare(left.lastSeenAt ?? "");
		}

		return left.status === "online" ? -1 : 1;
	});

export const loginPrivateAccount = async (input: {
	baseUrl: string;
	createClient?: typeof createPrivateClient;
	email: string;
	password: string;
}): Promise<PrivateSessionDto> => {
	const client = (input.createClient ?? createPrivateClient)({
		baseUrl: input.baseUrl,
	});

	return await client.login({
		email: input.email,
		password: input.password,
	});
};

export const registerPrivateAccount = async (input: {
	baseUrl: string;
	createClient?: typeof createPrivateClient;
	email: string;
	password: string;
}): Promise<PrivateSessionDto> => {
	const client = (input.createClient ?? createPrivateClient)({
		baseUrl: input.baseUrl,
	});

	return await client.register({
		email: input.email,
		password: input.password,
	});
};

export const registerPrivateAccountWithTrial = async (input: {
	activationPollIntervalMs?: number;
	activationPostRestoreTimeoutMs?: number;
	activationTimeoutMs?: number;
	baseUrl: string;
	clearPendingSignupIntentRecord?: () => Promise<void>;
	createClient?: typeof createPrivateClient;
	email: string;
	offeringsTimeoutMs?: number;
	password: string;
	platform: RevenueCatPlatform;
	purchaseTimeoutMs?: number;
	purchasesClient: RevenueCatPurchasesClient;
	readPendingSignupIntentRecord?: () => Promise<PersistedPrivateSignupIntentRecord | null>;
	savePendingSignupIntentRecord?: (
		record: PersistedPrivateSignupIntentRecord,
	) => Promise<PersistedPrivateSignupIntentRecord>;
}): Promise<{
	customerInfo: RevenueCatCustomerInfoLike | null;
	pkg: RevenueCatPackageLike | null;
	session: PrivateSessionDto;
	signupIntent: PrivateSignupIntentDto;
}> => {
	const client = (input.createClient ?? createPrivateClient)({
		baseUrl: input.baseUrl,
	});
	const clearPendingSignupIntentRecord =
		input.clearPendingSignupIntentRecord ?? (async () => {
			await PrivateSignupIntentStore.clear();
		});
	const readPendingSignupIntentRecord =
		input.readPendingSignupIntentRecord ?? (async () => {
			return await PrivateSignupIntentStore.read();
		});
	const savePendingSignupIntentRecord =
		input.savePendingSignupIntentRecord ?? (async (record) => {
			return await PrivateSignupIntentStore.save(record);
		});
	const normalizedBackendUrl = trimBaseUrl(input.baseUrl);
	const normalizedEmail = input.email.trim().toLowerCase();
		const signupIntent = await (async () => {
			try {
				const createdSignupIntentResponse = await client.createSignupIntent({
					email: input.email,
					password: input.password,
					platform: input.platform,
					returnUrl: MOBILE_SIGNUP_RETURN_URL,
					target: "mobile",
				});
				const createdSignupIntent = createdSignupIntentResponse.signupIntent;
				await savePendingSignupIntentRecord({
					backendUrl: normalizedBackendUrl,
					email: normalizedEmail,
					platform: input.platform,
				signupIntentId: createdSignupIntent.id,
			});
			return createdSignupIntent;
		} catch (error) {
			if (!isPendingSignupIntentError(error)) {
				throw error;
			}

			const payloadSignupIntentId = error instanceof PrivateApiError ? extractSignupIntentId(error.payload) : null;
				if (payloadSignupIntentId) {
					await savePendingSignupIntentRecord({
						backendUrl: normalizedBackendUrl,
						email: normalizedEmail,
						platform: input.platform,
						signupIntentId: payloadSignupIntentId,
					});
					const signupIntentResponse = await client.getSignupIntent(payloadSignupIntentId);
					return signupIntentResponse.signupIntent;
				}

			const persistedRecord = await readPendingSignupIntentRecord();
				if (
					persistedRecord
					&& persistedRecord.backendUrl === normalizedBackendUrl
					&& persistedRecord.email === normalizedEmail
					&& persistedRecord.platform === input.platform
				) {
					const signupIntentResponse = await client.getSignupIntent(persistedRecord.signupIntentId);
					return signupIntentResponse.signupIntent;
				}

			throw error;
		}
	})();

	try {
		const completion = await client.completeSignupIntent(signupIntent.id);
		await clearPendingSignupIntentRecord();
		return {
			customerInfo: null,
			pkg: null,
			session: completion.session,
			signupIntent: completion.signupIntent,
		};
	} catch (error) {
		if (!isSignupCheckoutIncomplete(error)) {
			throw error;
		}
	}

	const configured = await input.purchasesClient.ensureConfigured(signupIntent.id);
	if (!configured) {
		throw new Error("revenuecat_not_configured");
	}

	const offerings = await withTimeout(
		input.purchasesClient.getOfferings(),
		input.offeringsTimeoutMs ?? PRIVATE_TRIAL_OFFERINGS_TIMEOUT_MS,
		"Timed out while loading the in-app trial options. Try again in a moment.",
	);
	const pkg = selectRevenueCatPackage(offerings);
	if (!pkg) {
		throw new Error("private_subscription_package_unavailable");
	}

	const { customerInfo } = await withTimeout(
		input.purchasesClient.purchasePackage(pkg),
		input.purchaseTimeoutMs ?? PRIVATE_TRIAL_PURCHASE_TIMEOUT_MS,
		PRIVATE_TRIAL_PURCHASE_TIMEOUT_MESSAGE,
	);
	const completion = await waitForSignupIntentActivation({
		activationPollIntervalMs: input.activationPollIntervalMs,
		activationPostRestoreTimeoutMs: input.activationPostRestoreTimeoutMs,
		activationTimeoutMs: input.activationTimeoutMs,
		client,
		email: input.email,
		password: input.password,
		purchasesClient: input.purchasesClient,
		signupIntentId: signupIntent.id,
	});
	await clearPendingSignupIntentRecord();
	return {
		customerInfo,
		pkg,
		session: completion.session,
		signupIntent: completion.signupIntent,
	};
};

export const requestPrivatePasswordReset = async (input: {
	baseUrl: string;
	createClient?: typeof createPrivateClient;
	email: string;
}): Promise<void> => {
	const client = (input.createClient ?? createPrivateClient)({
		baseUrl: input.baseUrl,
	});

	await client.requestPasswordReset({
		email: input.email,
	});
};

export const syncPrivateRevenueCatSubscriptionStatus = async (input: {
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

type PrivateClientWithMeOnly = Pick<ReturnType<typeof createPrivateClient>, "me">;

export const refreshPrivateAccountSessionRecord = async (input: {
	createClient?: (config: Parameters<typeof createPrivateClient>[0]) => PrivateClientWithMeOnly;
	refreshSession?: () => Promise<PrivateSessionDto | null>;
	sessionRecord: PersistedPrivateSessionRecord | null;
}): Promise<PersistedPrivateSessionRecord | null> => {
	if (!input.sessionRecord) {
		return null;
	}

	const sessionRecord = input.sessionRecord;
	const createBackendClient = (accessToken: string) => (input.createClient ?? createPrivateClient)({
		baseUrl: sessionRecord.backendUrl,
		getAccessToken: () => accessToken,
	});

	try {
		const backendClient = createBackendClient(sessionRecord.session.accessToken);
		const response = await backendClient.me();
		return {
			backendUrl: sessionRecord.backendUrl,
			session: {
				...sessionRecord.session,
				user: response.user,
			},
		};
	} catch (error) {
		if (!(error instanceof PrivateApiError) || error.status !== 401) {
			throw error;
		}

		if (!input.refreshSession) {
			return null;
		}

		const refreshedSession = await input.refreshSession();
		if (!refreshedSession) {
			return null;
		}

		const refreshedResponse = await createBackendClient(refreshedSession.accessToken).me();
		return {
			backendUrl: input.sessionRecord.backendUrl,
			session: {
				...refreshedSession,
				user: refreshedResponse.user,
			},
		};
	}
};

export const persistSavedPrivateConnection = async (input: {
	backendUrl: string;
	connector: Pick<PrivateConnectorDto, "id" | "name">;
	saveSavedConnection?: typeof ApiConfigStore.saveSavedConnection;
}): Promise<void> => {
	await (input.saveSavedConnection ?? ApiConfigStore.saveSavedConnection)({
		backendUrl: trimBaseUrl(input.backendUrl),
		connectorId: input.connector.id,
		connectorName: input.connector.name,
		kind: "private",
	});
};

export const loadPrivateConnectorsSafely = async (input: {
	loadConnectors: () => Promise<PrivateConnectorDto[]>;
	onError: (message: string) => void;
}): Promise<void> => {
	try {
		await input.loadConnectors();
	} catch (error) {
		input.onError(error instanceof Error ? error.message : "Unable to load private connectors.");
	}
};
