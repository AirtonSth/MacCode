/* eslint-disable import/no-unresolved */
import { afterEach, beforeEach, describe, expect, test, mock } from "bun:test";

const platformState = {
	OS: "ios" as "ios" | "android",
	Version: "18.0",
};

const secureStoreState = new Map<string, string>();

const nativeBridgeState = {
	currentActivity: null as { id: string; props: Record<string, unknown>; updateCalls: Record<string, unknown>[] } | null,
	listeners: new Map<string, Set<(event: unknown) => void>>(),
};

const toNativeInfo = (): string | null => {
	if (!nativeBridgeState.currentActivity) {
		return null;
	}

	return JSON.stringify({
		activityId: nativeBridgeState.currentActivity.id,
		pushToken: null,
	});
};

	mock.module("react-native", () => {
		class MockNativeEventEmitter {
			public addListener(eventName: string, listener: (event: unknown) => void) {
				const listeners = nativeBridgeState.listeners.get(eventName) ?? new Set<(event: unknown) => void>();
				listeners.add(listener);
				nativeBridgeState.listeners.set(eventName, listeners);
				return {
				remove: () => {
					listeners.delete(listener);
				},
			};
		}
	}

	return {
		AppState: {
			addEventListener: () => ({
				remove: () => undefined,
			}),
			currentState: "active",
		},
		NativeEventEmitter: MockNativeEventEmitter,
		NativeModules: {
			RemoteCodeLiveActivityBridge: {
				addListener: (): undefined => undefined,
				async getCurrentLiveActivityInfo() {
					return toNativeInfo();
				},
				async getPushToStartToken() {
					return null;
				},
				async startLiveActivity(payloadJson: string) {
					const props = JSON.parse(payloadJson) as Record<string, unknown>;
					if (!nativeBridgeState.currentActivity) {
						nativeBridgeState.currentActivity = {
							id: `activity-${Math.random().toString(36).slice(2)}`,
							props,
							updateCalls: [],
						};
					} else {
						nativeBridgeState.currentActivity.props = props;
						nativeBridgeState.currentActivity.updateCalls.push(props);
					}
					return toNativeInfo();
				},
				async updateLiveActivity(payloadJson: string) {
					if (!nativeBridgeState.currentActivity) {
						return null;
					}
					const props = JSON.parse(payloadJson) as Record<string, unknown>;
					nativeBridgeState.currentActivity.props = props;
					nativeBridgeState.currentActivity.updateCalls.push(props);
					return toNativeInfo();
				},
				removeListeners: (): undefined => undefined,
			},
		},
		Platform: platformState,
	};
});

mock.module("expo-secure-store", () => ({
	deleteItemAsync: async (key: string) => {
		secureStoreState.delete(key);
	},
	getItemAsync: async (key: string) => secureStoreState.get(key) ?? null,
	setItemAsync: async (key: string, value: string) => {
		secureStoreState.set(key, value);
	},
}));

mock.module("../../../shared/live-activity/live-activity-shared-bridge", () => ({
	persistGlobalLiveActivitySharedSnapshot: async () => undefined,
}));

const {
	clearThreadLiveActivity,
	getTrackedThreadLiveActivityChatIds,
	resetThreadLiveActivityManagerForTests,
	startThreadLiveActivity,
	updateThreadLiveActivity,
} = await import("../../../shared/live-activity/thread-live-activity");
const {
	reconcileTrackedLiveActivityChats,
	resolveTrackedLiveActivityChats,
} = await import("./live-activity-tracking");

beforeEach(() => {
	platformState.OS = "ios";
	platformState.Version = "18.0";
	secureStoreState.clear();
	nativeBridgeState.currentActivity = null;
	nativeBridgeState.listeners.clear();
	resetThreadLiveActivityManagerForTests();
});

afterEach(() => {
	resetThreadLiveActivityManagerForTests();
});

describe("live activity tracking reconciliation e2e", () => {
	test("reconciles stale running chats down to the authoritative active thread count", async () => {
		await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});
		await startThreadLiveActivity({
			chatId: "chat-2",
			remoteManaged: false,
		});
		await startThreadLiveActivity({
			chatId: "chat-3",
			remoteManaged: false,
		});
		await startThreadLiveActivity({
			chatId: "chat-4",
			remoteManaged: false,
		});

		await updateThreadLiveActivity({
			chatId: "chat-4",
			force: true,
		});
		await Bun.sleep(25);
		expect(nativeBridgeState.currentActivity?.updateCalls.at(-1)).toMatchObject({
			chatId: "active-threads",
			statusLine: "4 threads active",
			preview: "RemoteCode is working on 4 active threads.",
		});

		const nextTrackedChats = resolveTrackedLiveActivityChats({
			activeThreads: [
				{
					id: "chat-1",
					projectId: "project-1",
					projectName: "Workspace",
					title: "Thread 1",
					updatedAt: "2026-03-18T01:56:00.000Z",
				},
			],
			selectedChat: null,
			selectedChatId: null,
		});
		const reconciliation = reconcileTrackedLiveActivityChats({
			nextTrackedChats,
			previousTrackedChatIds: new Set(["chat-1", "chat-2", "chat-3", "chat-4"]),
		});

		await Promise.all(reconciliation.removedChatIds.map(async (removedChatId) => { await clearThreadLiveActivity({
			chatId: removedChatId,
		}); }));

		await Bun.sleep(25);

		expect(reconciliation).toEqual({
			addedChatIds: [],
			removedChatIds: ["chat-2", "chat-3", "chat-4"],
		});
		expect(await getTrackedThreadLiveActivityChatIds()).toEqual(["chat-1"]);
		expect(nativeBridgeState.currentActivity?.updateCalls.at(-1)).toMatchObject({
			chatId: "active-threads",
			statusLine: "1 thread active",
			preview: "RemoteCode is working on 1 active thread.",
		});
	});
});
