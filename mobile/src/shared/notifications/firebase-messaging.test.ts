/* eslint-disable import/no-unresolved */
import { beforeEach, describe, expect, test, mock } from "bun:test";

const appState = {
	currentState: "active" as "active" | "background" | "inactive",
};

const notificationsState = {
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

const messagingState = {
	getTokenResponses: [] as unknown[],
	getTokenCalls: 0,
	isDeviceRegisteredForRemoteMessages: false,
	onTokenRefreshListener: null as ((token: string) => void) | null,
	registerDeviceForRemoteMessagesCalls: 0,
};

const resetNotificationsState = () => {
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

const resetMessagingState = () => {
	messagingState.getTokenResponses = [];
	messagingState.getTokenCalls = 0;
	messagingState.isDeviceRegisteredForRemoteMessages = false;
	messagingState.onTokenRefreshListener = null;
	messagingState.registerDeviceForRemoteMessagesCalls = 0;
};

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
		get isDeviceRegisteredForRemoteMessages() {
			return messagingState.isDeviceRegisteredForRemoteMessages;
		},
		getToken: async () => {
			messagingState.getTokenCalls += 1;
			return messagingState.getTokenResponses.shift() ?? null;
		},
		onTokenRefresh: (listener: (token: string) => void) => {
			messagingState.onTokenRefreshListener = listener;
			return () => {
				if (messagingState.onTokenRefreshListener === listener) {
					messagingState.onTokenRefreshListener = null;
				}
			};
		},
		registerDeviceForRemoteMessages: async () => {
			messagingState.registerDeviceForRemoteMessagesCalls += 1;
			messagingState.isDeviceRegisteredForRemoteMessages = true;
		},
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
	resetMessagingState();
	resetPushDeliveryTokenForTests();
});

describe("push delivery token resolution", () => {
	test("returns the FCM token without requesting notification permission when direct token access already works", async () => {
		messagingState.getTokenResponses = ["fcm-token-direct"];

		const token = await ensurePushDeliveryToken();

		expect(token).toEqual({
			token: "fcm-token-direct",
			type: "fcm",
		});
		expect(notificationsState.requestPermissionsCalls).toBe(0);
		expect(messagingState.registerDeviceForRemoteMessagesCalls).toBe(1);
	});

	test("retries the FCM token read immediately after permission is granted", async () => {
		messagingState.getTokenResponses = [
			null,
			"fcm-token-after-permission",
		];
		notificationsState.requestPermissionsResponse = {
			granted: true,
			ios: {
				status: 0,
			},
		};

		const token = await ensurePushDeliveryToken();

		expect(token).toEqual({
			token: "fcm-token-after-permission",
			type: "fcm",
		});
		expect(notificationsState.requestPermissionsCalls).toBe(1);
		expect(messagingState.getTokenCalls).toBe(2);
	});

	test("publishes token refresh updates as FCM", () => {
		const refreshedTokens: { token: string; type: string }[] = [];
		const unsubscribe = subscribePushDeliveryTokenRefresh((token) => {
			refreshedTokens.push(token);
		});

		messagingState.onTokenRefreshListener?.("fcm-token-refresh");
		unsubscribe();

		expect(refreshedTokens).toEqual([{
			token: "fcm-token-refresh",
			type: "fcm",
		}]);
	});
});
