/* eslint-disable import/no-unresolved */
import { beforeEach, describe, expect, test, mock } from "bun:test";

const appState = {
	currentState: "active" as "active" | "background" | "inactive",
};

const notificationsState = {
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
	addPushTokenListener: () => ({
		remove: () => undefined,
	}),
	getDevicePushTokenAsync: async () => notificationsState.devicePushTokenResponses.shift() ?? null,
	getPermissionsAsync: async () => notificationsState.getPermissionsResponse,
	requestPermissionsAsync: async () => {
		notificationsState.requestPermissionsCalls += 1;
		return notificationsState.requestPermissionsResponse;
	},
	scheduleNotificationAsync: async () => "notification-id",
	setNotificationChannelAsync: async () => undefined,
	setNotificationHandler: () => undefined,
}));

const {
	ensurePushDeliveryToken,
	resetPushDeliveryTokenForTests,
} = await import("./firebase-messaging");

beforeEach(() => {
	appState.currentState = "active";
	resetNotificationsState();
	resetPushDeliveryTokenForTests();
});

describe("push delivery token resolution", () => {
	test("returns the APNS token without requesting notification permission when direct token access already works", async () => {
		notificationsState.devicePushTokenResponses = [
			{
				data: "apns-token-direct",
				type: "ios",
			},
		];

		const token = await ensurePushDeliveryToken();

		expect(token).toEqual({
			token: "apns-token-direct",
			type: "apns",
		});
		expect(notificationsState.requestPermissionsCalls).toBe(0);
	});

	test("retries the direct token read immediately after permission is granted", async () => {
		notificationsState.devicePushTokenResponses = [
			null,
			{
				data: "apns-token-after-permission",
				type: "apns",
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
	});
});
