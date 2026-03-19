/* eslint-disable import/no-unresolved */
import { beforeEach, describe, expect, test, mock } from "bun:test";

const appState = {
	currentState: "active" as "active" | "background" | "inactive",
};

const notificationsState = {
	pushTokenListener: null as ((event: unknown) => void) | null,
	devicePushTokenCalls: 0,
	devicePushTokenResponses: [] as unknown[],
	getPermissionsResponse: {
		granted: false,
		ios: {
			status: 0,
		},
	},
	requestPermissionsCalls: 0,
	requestPermissionsResponse: {
		granted: false,
		ios: {
			status: 0,
		},
	},
};

const resetNotificationsState = () => {
	notificationsState.pushTokenListener = null;
	notificationsState.devicePushTokenCalls = 0;
	notificationsState.devicePushTokenResponses = [];
	notificationsState.getPermissionsResponse = {
		granted: false,
		ios: {
			status: 0,
		},
	};
	notificationsState.requestPermissionsCalls = 0;
	notificationsState.requestPermissionsResponse = {
		granted: false,
		ios: {
			status: 0,
		},
	};
};

const noopUnsubscribe = () => undefined;

mock.module("react-native", () => ({
	AppState: {
		addEventListener: () => ({
			remove: () => undefined,
		}),
		get currentState() {
			return appState.currentState;
		},
	},
	Platform: {
		OS: "ios",
	},
}));

mock.module("expo-notifications", () => ({
	AndroidImportance: {
		DEFAULT: 3,
	},
	IosAuthorizationStatus: {
		PROVISIONAL: 3,
	},
	addPushTokenListener: (callback: (event: unknown) => void) => {
		notificationsState.pushTokenListener = callback;
		return {
			remove: () => {
				if (notificationsState.pushTokenListener === callback) {
					notificationsState.pushTokenListener = null;
				}
			},
		};
	},
	getDevicePushTokenAsync: async () => {
		notificationsState.devicePushTokenCalls += 1;
		return notificationsState.devicePushTokenResponses.shift() ?? null;
	},
	getPermissionsAsync: async () => notificationsState.getPermissionsResponse,
	requestPermissionsAsync: async () => {
		notificationsState.requestPermissionsCalls += 1;
		return notificationsState.requestPermissionsResponse;
	},
	scheduleNotificationAsync: async () => "notification-id",
	setNotificationChannelAsync: async () => undefined,
	setNotificationHandler: () => undefined,
}));

mock.module("@react-native-firebase/messaging", () => ({
	default: () => ({
		getAPNSToken: async () => null,
		getToken: async () => null,
		onTokenRefresh: () => noopUnsubscribe,
		registerDeviceForRemoteMessages: async () => undefined,
	}),
}));

const {
	ensurePushDeliveryToken,
	resetPushDeliveryTokenForTests,
	subscribePushDeliveryTokenRefresh,
} = await import("./firebase-messaging");

beforeEach(() => {
	appState.currentState = "active";
	resetNotificationsState();
	resetPushDeliveryTokenForTests();
});

describe("push delivery token resolution", () => {
	test("returns the APNS token without requesting notification permission when direct token access already works", async () => {
		notificationsState.devicePushTokenResponses = [{
			data: "apns-token-direct",
			type: "ios",
		}];

		const token = await ensurePushDeliveryToken();

		expect(token).toEqual({
			token: "apns-token-direct",
			type: "apns",
		});
		expect(notificationsState.requestPermissionsCalls).toBe(0);
	});

	test("retries the device token read immediately after permission is granted", async () => {
		notificationsState.devicePushTokenResponses = [
			null,
			{
				data: "apns-token-after-permission",
				type: "ios",
			},
		];
		notificationsState.requestPermissionsResponse = {
			granted: true,
			ios: {
				status: 0,
			},
		};

		const token = await ensurePushDeliveryToken();

		expect(token).toEqual({
			token: "apns-token-after-permission",
			type: "apns",
		});
		expect(notificationsState.requestPermissionsCalls).toBe(1);
		expect(notificationsState.devicePushTokenCalls).toBe(2);
	});

	test("publishes token refresh updates as APNS", () => {
		const refreshedTokens: { token: string; type: string }[] = [];
		const unsubscribe = subscribePushDeliveryTokenRefresh((token) => {
			refreshedTokens.push(token);
		});

		notificationsState.pushTokenListener?.({
			data: {
				token: "apns-token-refresh",
				type: "ios",
			},
		});
		unsubscribe();

		expect(refreshedTokens).toEqual([{
			token: "apns-token-refresh",
			type: "apns",
		}]);
	});
});
