/* eslint-disable import/no-unresolved */
import { beforeEach, describe, expect, test, mock } from "bun:test";

const platformState: { OS: "android" | "ios" } = { OS: "ios" };

const notificationsState = {
	androidChannels: [] as { channelId: string; options: unknown }[],
	getPermissionsResponse: {
		granted: false,
		ios: {
			status: 0,
		},
	},
	notificationHandlers: [] as unknown[],
	requestPermissionsCalls: 0,
	requestPermissionsResponse: {
		granted: false,
		ios: {
			status: 0,
		},
	},
	scheduledNotifications: [] as unknown[],
};

const resetNotificationsState = () => {
	notificationsState.androidChannels = [];
	notificationsState.getPermissionsResponse = {
		granted: false,
		ios: {
			status: 0,
		},
	};
	notificationsState.notificationHandlers = [];
	notificationsState.requestPermissionsCalls = 0;
	notificationsState.requestPermissionsResponse = {
		granted: false,
		ios: {
			status: 0,
		},
	};
	notificationsState.scheduledNotifications = [];
};

mock.module("react-native", () => ({
	Platform: platformState,
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
	scheduleNotificationAsync: async (request: unknown) => {
		notificationsState.scheduledNotifications.push(request);
		return "notification-id";
	},
	setNotificationChannelAsync: async (channelId: string, options: unknown) => {
		notificationsState.androidChannels.push({ channelId, options });
	},
	setNotificationHandler: (handler: unknown) => {
		notificationsState.notificationHandlers.push(handler);
	},
}));

const notificationsModule = await import("./local-notifications");
const {
	resetLocalNotificationsForTests,
	ensureLocalNotificationPermission,
	initializeLocalNotifications,
	sendThreadCompletionNotification,
} = notificationsModule;

beforeEach(() => {
	platformState.OS = "ios";
	resetNotificationsState();
	resetLocalNotificationsForTests();
});

describe("local notifications", () => {
	test("initializeLocalNotifications is idempotent and sets Android channel on Android", async () => {
		platformState.OS = "android";

		await initializeLocalNotifications();
		await initializeLocalNotifications();

		expect(notificationsState.notificationHandlers.length).toBe(1);
		expect(notificationsState.androidChannels.length).toBe(1);
		expect(notificationsState.androidChannels[0]?.channelId).toBe("thread-updates");
	});

	test("ensureLocalNotificationPermission returns granted without requesting again", async () => {
		notificationsState.getPermissionsResponse = {
			granted: true,
			ios: {
				status: 0,
			},
		};

		const granted = await ensureLocalNotificationPermission();

		expect(granted).toBe(true);
		expect(notificationsState.requestPermissionsCalls).toBe(0);
	});

	test("ensureLocalNotificationPermission caches granted permission after request", async () => {
		notificationsState.getPermissionsResponse = {
			granted: false,
			ios: {
				status: 0,
			},
		};
		notificationsState.requestPermissionsResponse = {
			granted: true,
			ios: {
				status: 0,
			},
		};

		const first = await ensureLocalNotificationPermission();
		const second = await ensureLocalNotificationPermission();

		expect(first).toBe(true);
		expect(second).toBe(true);
		expect(notificationsState.requestPermissionsCalls).toBe(1);
	});

	test("ensureLocalNotificationPermission does not re-request after denied in same session", async () => {
		notificationsState.getPermissionsResponse = {
			granted: false,
			ios: {
				status: 0,
			},
		};
		notificationsState.requestPermissionsResponse = {
			granted: false,
			ios: {
				status: 0,
			},
		};

		const first = await ensureLocalNotificationPermission();
		const second = await ensureLocalNotificationPermission();

		expect(first).toBe(false);
		expect(second).toBe(false);
		expect(notificationsState.requestPermissionsCalls).toBe(1);
	});

	test("sendThreadCompletionNotification does not schedule when permission is denied", async () => {
		notificationsState.getPermissionsResponse = {
			granted: false,
			ios: {
				status: 0,
			},
		};
		notificationsState.requestPermissionsResponse = {
			granted: false,
			ios: {
				status: 0,
			},
		};

		const scheduled = await sendThreadCompletionNotification({
			chatId: "chat-1",
			chatTitle: "Build Thread",
			outcome: "completed",
		});

		expect(scheduled).toBe(false);
		expect(notificationsState.scheduledNotifications.length).toBe(0);
	});

	test("sendThreadCompletionNotification schedules completion notification payload", async () => {
		notificationsState.getPermissionsResponse = {
			granted: true,
			ios: {
				status: 0,
			},
		};

		const scheduled = await sendThreadCompletionNotification({
			chatId: "chat-42",
			chatTitle: "Build Thread",
			outcome: "completed",
		});

		expect(scheduled).toBe(true);
		expect(notificationsState.scheduledNotifications.length).toBe(1);

		const request = notificationsState.scheduledNotifications[0] as {
			content: {
				body: string;
				data: { chatId: string; outcome: string };
				title: string;
			};
			trigger: null;
		};
		expect(request.content.title).toBe("Thread finished");
		expect(request.content.body).toBe("Build Thread response is ready.");
		expect(request.content.data).toEqual({
			chatId: "chat-42",
			outcome: "completed",
		});
		expect(request.trigger).toBeNull();
	});
});
