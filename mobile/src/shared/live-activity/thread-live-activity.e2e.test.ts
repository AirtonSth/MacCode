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
	startDeepLinks: [] as string[],
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
				async startLiveActivity(payloadJson: string, deepLink: string) {
					const props = JSON.parse(payloadJson) as Record<string, unknown>;
					nativeBridgeState.startDeepLinks.push(deepLink);
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

mock.module("expo-haptics", () => ({
	ImpactFeedbackStyle: { Light: "light", Medium: "medium", Heavy: "heavy" },
	NotificationFeedbackType: { Success: "success", Warning: "warning", Error: "error" },
	impactAsync: async () => undefined,
	notificationAsync: async () => undefined,
}));

mock.module("expo-secure-store", () => ({
	deleteItemAsync: async (key: string) => {
		secureStoreState.delete(key);
	},
	getItemAsync: async (key: string) => secureStoreState.get(key) ?? null,
	setItemAsync: async (key: string, value: string) => {
		secureStoreState.set(key, value);
	},
}));

mock.module("./live-activity-shared-bridge", () => ({
	persistGlobalLiveActivitySharedSnapshot: async () => undefined,
}));

const {
	finishThreadLiveActivity,
	onThreadLiveActivityAppStateChanged,
	resetThreadLiveActivityManagerForTests,
	startThreadLiveActivity,
	updateThreadLiveActivity,
} = await import("./thread-live-activity");

const realDateNow = Date.now;

beforeEach(() => {
	platformState.OS = "ios";
	platformState.Version = "18.0";
	secureStoreState.clear();
	nativeBridgeState.currentActivity = null;
	nativeBridgeState.listeners.clear();
	nativeBridgeState.startDeepLinks = [];
	resetThreadLiveActivityManagerForTests();
	Date.now = realDateNow;
});

afterEach(() => {
	Date.now = realDateNow;
	resetThreadLiveActivityManagerForTests();
});

describe("thread live activity native bridge e2e", () => {
	test("runs one full global session, freezes terminal state, then restarts from zero", async () => {
		Date.now = () => 1_000;
		const started = await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});

		expect(started).toBe(true);
		expect(nativeBridgeState.startDeepLinks).toEqual(["remotecode-mobile://active-threads"]);
		expect(nativeBridgeState.currentActivity?.props).toMatchObject({
			chatId: "active-threads",
			phase: "running",
			statusLine: "1 thread active",
		});

		Date.now = () => 8_000;
		await updateThreadLiveActivity({
			chatId: "chat-1",
			force: true,
		});
		await Bun.sleep(25);
		expect(nativeBridgeState.currentActivity?.updateCalls.at(-1)).toMatchObject({
			elapsedSeconds: 7,
			phase: "running",
		});

		Date.now = () => 13_000;
		await finishThreadLiveActivity({
			chatId: "chat-1",
			outcome: "completed",
		});
		await Bun.sleep(25);
		expect(nativeBridgeState.currentActivity?.updateCalls.at(-1)).toMatchObject({
			elapsedSeconds: 12,
			phase: "completed",
			statusLine: "All threads completed",
		});

		Date.now = () => 20_000;
		await startThreadLiveActivity({
			chatId: "chat-2",
			remoteManaged: false,
		});
		await Bun.sleep(25);
		expect(nativeBridgeState.currentActivity?.updateCalls.at(-1)).toMatchObject({
			elapsedSeconds: 0,
			phase: "running",
			statusLine: "1 thread active",
		});
	});

	test("does not reapply stale local running state over a remote-managed terminal activity", async () => {
		Date.now = () => 1_000;
		const started = await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: true,
		});

		expect(started).toBe(true);
		expect(nativeBridgeState.currentActivity?.props).toMatchObject({
			chatId: "active-threads",
			phase: "running",
			statusLine: "1 thread active",
		});
		const initialUpdateCount = nativeBridgeState.currentActivity?.updateCalls.length ?? 0;

		nativeBridgeState.currentActivity!.props = {
			chatId: "active-threads",
			chatTitle: "Active Threads",
			elapsedSeconds: 18,
			phase: "completed",
			preview: "No active threads right now.",
			statusLine: "All threads completed",
		};

		Date.now = () => 20_000;
		await onThreadLiveActivityAppStateChanged("background");
		await updateThreadLiveActivity({
			authoritative: true,
			chatId: "chat-1",
			force: true,
			phase: "background",
			preview: "RemoteCode is working on 1 active thread.",
			statusLine: "Running in background",
		});
		await finishThreadLiveActivity({
			chatId: "chat-1",
			outcome: "completed",
		});
		await Bun.sleep(25);

		expect(nativeBridgeState.currentActivity!.updateCalls.length).toBeGreaterThan(initialUpdateCount);
		expect(nativeBridgeState.currentActivity?.props).toMatchObject({
			phase: "completed",
			preview: "No active threads right now.",
			statusLine: "All threads completed",
		});
	});
});
