import type { ChatDTO } from "../features/workspace/model/useWorkspaceStore";

const buildNotificationContent = (chat: Pick<ChatDTO, "status" | "title">): { body: string; title: string } => {
	const normalizedTitle = chat.title.trim() || "Thread";
	if (chat.status === "completed") {
		return {
			title: "Thread finished",
			body: `${normalizedTitle} response is ready.`,
		};
	}

	return {
		title: "Thread failed",
		body: `${normalizedTitle} ended with an error.`,
	};
};

export const requestDesktopNotificationPermission = async (): Promise<boolean> => {
	if (typeof Notification === "undefined") {
		return false;
	}

	if (Notification.permission === "granted") {
		return true;
	}
	if (Notification.permission === "denied") {
		return false;
	}

	return await Notification.requestPermission() === "granted";
};

export const showThreadCompletionDesktopNotification = async (
	chat: Pick<ChatDTO, "status" | "title">,
): Promise<boolean> => {
	if (chat.status !== "completed" && chat.status !== "failed") {
		return false;
	}

	const granted = await requestDesktopNotificationPermission();
	if (!granted || typeof Notification === "undefined") {
		return false;
	}

	const content = buildNotificationContent(chat);
	new Notification(content.title, {
		body: content.body,
	});
	return true;
};
