import * as BackgroundTask from "expo-background-task";
import * as TaskManager from "expo-task-manager";
import { Platform } from "react-native";

import { ApiConfigStore } from "../api/api-config-store";
import { createRemoteCodeClient } from "../api/remotecode-client";
import {
	finishThreadLiveActivity,
	getThreadLiveActivityStateForBackgroundTask,
	initializeThreadLiveActivityManager,
	updateThreadLiveActivity,
} from "./thread-live-activity";

const THREAD_MONITOR_TASK_NAME = "remotecode.thread-live-activity.monitor";
const MINIMUM_INTERVAL_MINUTES = 15;
let expirationListenerAttached = false;

if (!TaskManager.isTaskDefined(THREAD_MONITOR_TASK_NAME)) {
	TaskManager.defineTask(THREAD_MONITOR_TASK_NAME, async () => {
		if (Platform.OS !== "ios") {
			return BackgroundTask.BackgroundTaskResult.Success;
		}

		await initializeThreadLiveActivityManager();
		const state = getThreadLiveActivityStateForBackgroundTask();
		if (!state) {
			return BackgroundTask.BackgroundTaskResult.Success;
		}

		try {
			const config = await ApiConfigStore.read();
			const client = createRemoteCodeClient(config);
			const selection = await client.getSelection();
			if (!selection.selectedProjectId) {
				return BackgroundTask.BackgroundTaskResult.Success;
			}

			const chats = await client.listChats(selection.selectedProjectId);
			const chat = chats.find((entry) => entry.id === state.chatId);
			if (!chat) {
				return BackgroundTask.BackgroundTaskResult.Success;
			}

			if (chat.status === "running" || chat.status === "pending") {
				await updateThreadLiveActivity({
					chatId: chat.id,
					chatTitle: chat.title,
					phase: "background",
					statusLine: "Running in background",
					force: true,
				});
				return BackgroundTask.BackgroundTaskResult.Success;
			}

			if (chat.status === "completed" || chat.status === "failed") {
				await finishThreadLiveActivity({
					chatId: chat.id,
					chatTitle: chat.title,
					outcome: chat.status === "completed" ? "completed" : "failed",
					statusLine: chat.status === "completed" ? "Response is ready" : "Thread failed",
				});
			}

			return BackgroundTask.BackgroundTaskResult.Success;
		} catch {
			return BackgroundTask.BackgroundTaskResult.Failed;
		}
	});
}

export const registerThreadLiveActivityBackgroundTask = async (): Promise<void> => {
	if (Platform.OS !== "ios") {
		return;
	}

	try {
		const status = await BackgroundTask.getStatusAsync();
		if (status !== BackgroundTask.BackgroundTaskStatus.Available) {
			return;
		}

		if (!expirationListenerAttached) {
			BackgroundTask.addExpirationListener(() => {
				const state = getThreadLiveActivityStateForBackgroundTask();
				if (!state) {
					return;
				}

				void updateThreadLiveActivity({
					chatId: state.chatId,
					phase: "background",
					statusLine: "iOS paused background execution",
					force: true,
				});
			});
			expirationListenerAttached = true;
		}

		await BackgroundTask.registerTaskAsync(THREAD_MONITOR_TASK_NAME, {
			minimumInterval: MINIMUM_INTERVAL_MINUTES,
		});
	} catch {
		// Ignore background-task registration failures on devices without required capabilities.
	}
};
