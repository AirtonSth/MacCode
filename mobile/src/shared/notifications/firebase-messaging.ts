import * as Notifications from "expo-notifications";
import messaging from "@react-native-firebase/messaging";
import { AppState, Platform, type AppStateStatus } from "react-native";

export type PushDeliveryTokenType = "fcm";

export interface PushDeliveryToken {
	token: string;
	type: PushDeliveryTokenType;
}

const LOG_PREFIX = "[push-delivery-token]";
const TOKEN_RETRY_INTERVAL_MS = 1_000;
const TOKEN_RESOLUTION_TIMEOUT_MS = 20_000;

const toTokenPreview = (token: string): string => (
	token.length <= 16
		? token
		: `${token.slice(0, 8)}...${token.slice(-4)}`
);

const log = (message: string, meta?: Record<string, unknown>): void => {
	if (meta) {
		console.log(LOG_PREFIX, message, meta);
		return;
	}

	console.log(LOG_PREFIX, message);
};

const hasGrantedPermission = (status: Notifications.NotificationPermissionsStatus): boolean => {
	if (status.granted) {
		return true;
	}

	return status.ios?.status === Notifications.IosAuthorizationStatus.PROVISIONAL;
};

const isActiveAppState = (status: AppStateStatus): boolean => status === "active";

const wait = async (durationMs: number): Promise<void> => {
	// eslint-disable-next-line promise/avoid-new -- setTimeout is callback-based in React Native.
	await new Promise((resolve) => {
		setTimeout(resolve, durationMs);
	});
};

const waitForActiveAppState = async (timeoutMs: number): Promise<boolean> => {
	if (isActiveAppState(AppState.currentState)) {
		return true;
	}

	// eslint-disable-next-line promise/avoid-new -- AppState subscriptions are callback-based in React Native.
	return await new Promise((resolve) => {
		let settled = false;
		const subscription = AppState.addEventListener("change", (nextState) => {
			if (!isActiveAppState(nextState) || settled) {
				return;
			}

			settled = true;
			subscription.remove();
			resolve(true);
		});

		setTimeout(() => {
			if (settled) {
				return;
			}

			settled = true;
			subscription.remove();
			resolve(isActiveAppState(AppState.currentState));
		}, timeoutMs);
	});
};

const normalizeToken = (value: unknown): string | null => {
	if (typeof value !== "string") {
		return null;
	}

	const normalized = value.trim();
	return normalized.length > 0 ? normalized : null;
};

const ensurePushPermission = async (): Promise<boolean> => {
	const currentPermissions = await Notifications.getPermissionsAsync();
	if (hasGrantedPermission(currentPermissions)) {
		return true;
	}

	const requestedPermissions = await Notifications.requestPermissionsAsync({
		ios: {
			allowAlert: true,
			allowBadge: false,
			allowSound: true,
		},
	});
	return hasGrantedPermission(requestedPermissions);
};

let cachedPushDeliveryToken: PushDeliveryToken | null = null;
let inflightPushDeliveryTokenPromise: Promise<PushDeliveryToken | null> | null = null;

const storeResolvedPushDeliveryToken = (token: PushDeliveryToken): PushDeliveryToken => {
	cachedPushDeliveryToken = token;
	log("token obtained", {
		token: toTokenPreview(token.token),
		type: token.type,
	});
	return token;
};

interface ResolvePushDeliveryTokenOptions {
	attempt: number;
	requestedPermission: boolean;
	startedAtMs: number;
}

const readPushDeliveryToken = async (): Promise<PushDeliveryToken | null> => {
	const service = messaging();
	if (Platform.OS === "ios" && !service.isDeviceRegisteredForRemoteMessages) {
		await service.registerDeviceForRemoteMessages();
	}

	const token = normalizeToken(await service.getToken());
	if (!token) {
		log("failed to resolve fcm token");
		return null;
	}

	return {
		token,
		type: "fcm",
	};
};

const resolvePushDeliveryTokenWithRetry = async (
	options: ResolvePushDeliveryTokenOptions,
): Promise<PushDeliveryToken | null> => {
	const attempt = options.attempt + 1;
	const directToken = await readPushDeliveryToken();
	if (directToken) {
		return storeResolvedPushDeliveryToken(directToken);
	}

	let requestedPermission = options.requestedPermission;
	let hasPermission = hasGrantedPermission(await Notifications.getPermissionsAsync());
	const shouldRequestPermission = !requestedPermission && isActiveAppState(AppState.currentState);
	if (!hasPermission && shouldRequestPermission) {
		requestedPermission = true;
		hasPermission = await ensurePushPermission();
		if (hasPermission) {
			const tokenAfterPermission = await readPushDeliveryToken();
			if (tokenAfterPermission) {
				return storeResolvedPushDeliveryToken(tokenAfterPermission);
			}
		}
	}

	if (!hasPermission) {
		if (requestedPermission) {
			log("permission still unavailable; retrying", {
				appState: AppState.currentState,
				attempt,
			});
		} else {
			log("permission not granted; retrying direct token read", {
				appState: AppState.currentState,
				attempt,
			});
		}
	} else {
		log("token unavailable; retrying", {
			appState: AppState.currentState,
			attempt,
		});
	}

	const remainingMs = TOKEN_RESOLUTION_TIMEOUT_MS - (Date.now() - options.startedAtMs);
	if (remainingMs <= 0) {
		log("token resolution timed out", {
			appState: AppState.currentState,
			attempts: attempt,
		});
		return null;
	}

	if (!isActiveAppState(AppState.currentState)) {
		log("waiting for active app state before retry", {
			appState: AppState.currentState,
			attempt,
		});
		await waitForActiveAppState(Math.min(remainingMs, TOKEN_RETRY_INTERVAL_MS * 4));
	} else {
		await wait(Math.min(remainingMs, TOKEN_RETRY_INTERVAL_MS));
	}

	return await resolvePushDeliveryTokenWithRetry({
		attempt,
		requestedPermission,
		startedAtMs: options.startedAtMs,
	});
};

export const ensurePushDeliveryToken = async (): Promise<PushDeliveryToken | null> => {
	if (cachedPushDeliveryToken) {
		log("using cached token", {
			token: toTokenPreview(cachedPushDeliveryToken.token),
			type: cachedPushDeliveryToken.type,
		});
		return cachedPushDeliveryToken;
	}

	if (inflightPushDeliveryTokenPromise) {
		return await inflightPushDeliveryTokenPromise;
	}

	inflightPushDeliveryTokenPromise = (async () => {
		try {
			return await resolvePushDeliveryTokenWithRetry({
				attempt: 0,
				requestedPermission: false,
				startedAtMs: Date.now(),
			});
		} catch (error) {
			log("token request failed", {
				error: error instanceof Error ? error.message : "unknown",
			});
			return null;
		} finally {
			inflightPushDeliveryTokenPromise = null;
		}
	})();

	return await inflightPushDeliveryTokenPromise;
};

export const subscribePushDeliveryTokenRefresh = (
	listener: (token: PushDeliveryToken) => void,
): (() => void) => {
	return messaging().onTokenRefresh((nextToken) => {
		const normalizedToken = normalizeToken(nextToken);
		if (!normalizedToken) {
			log("token refresh event ignored");
			return;
		}

		const token: PushDeliveryToken = {
			token: normalizedToken,
			type: "fcm",
		};
		cachedPushDeliveryToken = token;
		log("token refreshed", {
			token: toTokenPreview(token.token),
			type: token.type,
		});
		listener(token);
	});
};

export const ensureFirebaseMessagingToken = ensurePushDeliveryToken;
export const subscribeFirebaseMessagingTokenRefresh = subscribePushDeliveryTokenRefresh;

export const resetPushDeliveryTokenForTests = (): void => {
	cachedPushDeliveryToken = null;
	inflightPushDeliveryTokenPromise = null;
};
