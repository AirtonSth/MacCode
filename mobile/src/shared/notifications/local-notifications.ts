import * as Notifications from "expo-notifications";
import { Platform } from "react-native";

const THREAD_UPDATES_CHANNEL_ID = "thread-updates";

type NotificationOutcome = "completed" | "error" | "failed";

let runtimeInitialized = false;
let permissionStatus: "unknown" | "granted" | "denied" = "unknown";

const hasGrantedPermission = (status: Notifications.NotificationPermissionsStatus): boolean => {
	if (status.granted) {
		return true;
	}

	return status.ios?.status === Notifications.IosAuthorizationStatus.PROVISIONAL;
};

const configureNotificationHandler = () => {
	Notifications.setNotificationHandler({
		handleNotification: async () => ({
			shouldPlaySound: true,
			shouldSetBadge: false,
			shouldShowBanner: true,
			shouldShowList: true,
		}),
	});
};

const ensureAndroidChannel = async () => {
	if (Platform.OS !== "android") {
		return;
	}

	await Notifications.setNotificationChannelAsync(THREAD_UPDATES_CHANNEL_ID, {
		name: "Thread updates",
		importance: Notifications.AndroidImportance.DEFAULT,
		sound: "default",
		vibrationPattern: [0, 220, 120, 220],
	});
};

export const initializeLocalNotifications = async (): Promise<void> => {
	if (runtimeInitialized) {
		return;
	}

	configureNotificationHandler();
	await ensureAndroidChannel();
	// eslint-disable-next-line require-atomic-updates
	runtimeInitialized = true;
};

export const ensureLocalNotificationPermission = async (): Promise<boolean> => {
	await initializeLocalNotifications();

	if (permissionStatus === "granted") {
		return true;
	}
	if (permissionStatus === "denied") {
		return false;
	}

	const currentPermissions = await Notifications.getPermissionsAsync();
	if (hasGrantedPermission(currentPermissions)) {
		// eslint-disable-next-line require-atomic-updates
		permissionStatus = "granted";
		return true;
	}

	const requestedPermissions = await Notifications.requestPermissionsAsync({
		ios: {
			allowAlert: true,
			allowBadge: false,
			allowSound: true,
		},
	});
	const granted = hasGrantedPermission(requestedPermissions);
	// eslint-disable-next-line require-atomic-updates
	permissionStatus = granted ? "granted" : "denied";
	return granted;
};

const buildNotificationContent = (
	chatTitle: string | undefined,
	outcome: NotificationOutcome,
): { body: string; title: string } => {
	const normalizedTitle = chatTitle?.trim() || "Thread";

	if (outcome === "completed") {
		return {
			title: "Thread finished",
			body: `${normalizedTitle} response is ready.`,
		};
	}

	if (outcome === "failed") {
		return {
			title: "Thread failed",
			body: `${normalizedTitle} ended with an error.`,
		};
	}

	return {
		title: "Thread update",
		body: `${normalizedTitle} has a new status.`,
	};
};

export const sendThreadCompletionNotification = async (input: {
	chatId: string;
	chatTitle?: string;
	outcome: NotificationOutcome;
}): Promise<boolean> => {
	const canNotify = await ensureLocalNotificationPermission();
	if (!canNotify) {
		return false;
	}

	const content = buildNotificationContent(input.chatTitle, input.outcome);

	await Notifications.scheduleNotificationAsync({
		content: {
			title: content.title,
			body: content.body,
			sound: "default",
			data: {
				chatId: input.chatId,
				outcome: input.outcome,
			},
		},
		trigger: null,
	});

	return true;
};

export const resetLocalNotificationsForTests = (): void => {
	runtimeInitialized = false;
	permissionStatus = "unknown";
};
