import * as Notifications from "expo-notifications";

const hasGrantedPermission = (status: Notifications.NotificationPermissionsStatus): boolean => {
	if (status.granted) {
		return true;
	}

	return status.ios?.status === Notifications.IosAuthorizationStatus.PROVISIONAL;
};

const normalizeToken = (value: unknown): string | null => {
	if (typeof value !== "string") {
		return null;
	}

	const normalized = value.trim();
	return normalized.length > 0 ? normalized : null;
};

const extractToken = (value: unknown): string | null => {
	const directToken = normalizeToken(value);
	if (directToken) {
		return directToken;
	}

	if (typeof value !== "object" || value === null) {
		return null;
	}

	const withData = value as { data?: unknown; token?: unknown };
	const directDataToken = normalizeToken(withData.data);
	if (directDataToken) {
		return directDataToken;
	}

	if (typeof withData.data === "object" && withData.data !== null) {
		const nestedDataToken = normalizeToken((withData.data as { token?: unknown }).token);
		if (nestedDataToken) {
			return nestedDataToken;
		}
	}

	return normalizeToken(withData.token);
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

let cachedMessagingToken: string | null = null;

export const ensureFirebaseMessagingToken = async (): Promise<string | null> => {
	if (cachedMessagingToken) {
		return cachedMessagingToken;
	}

	try {
		const hasPermission = await ensurePushPermission();
		if (!hasPermission) {
			return null;
		}

		const getDevicePushTokenAsync = (Notifications as unknown as {
			getDevicePushTokenAsync?: () => Promise<unknown>;
		}).getDevicePushTokenAsync;
		if (typeof getDevicePushTokenAsync !== "function") {
			return null;
		}

		const token = extractToken(await getDevicePushTokenAsync());
		if (!token) {
			return null;
		}

		// eslint-disable-next-line require-atomic-updates
		cachedMessagingToken = token;
		return token;
	} catch {
		return null;
	}
};

export const subscribeFirebaseMessagingTokenRefresh = (
	listener: (token: string) => void,
): (() => void) => {
	const addPushTokenListener = (Notifications as unknown as {
		addPushTokenListener?: (callback: (event: unknown) => void) => { remove: () => void };
	}).addPushTokenListener;

	if (typeof addPushTokenListener !== "function") {
		return () => undefined;
	}

	const subscription = addPushTokenListener((event) => {
		const token = extractToken(event);
		if (!token) {
			return;
		}

		cachedMessagingToken = token;
		listener(token);
	});

	return () => {
		subscription.remove();
	};
};
