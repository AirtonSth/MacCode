/* eslint-disable import/no-unresolved */
import { afterEach, beforeEach, describe, expect, test, mock } from "bun:test";

const platformState = {
	OS: "ios" as "ios" | "android",
	Version: "18.0",
};

const secureStoreState = new Map<string, string>();

interface MockNativeActivity {
	endCalls: (Record<string, unknown> | null)[];
	id: string;
	props: Record<string, unknown>;
	updateCalls: Record<string, unknown>[];
}

const nativeBridgeState = {
	currentActivity: null as MockNativeActivity | null,
	listeners: new Map<string, Set<(event: unknown) => void>>(),
	pushToStartToken: null as string | null,
	pushToken: null as string | null,
	startDeepLinks: [] as string[],
	startError: null as Error | null,
};

const sharedSnapshotWrites: (Record<string, unknown> | null)[] = [];

const emitNativeEvent = (eventName: string, event: unknown): void => {
	for (const listener of nativeBridgeState.listeners.get(eventName) ?? []) {
		listener(event);
	}
};

const toNativeInfo = (): string | null => {
	if (!nativeBridgeState.currentActivity) {
		return null;
	}

	return JSON.stringify({
		activityId: nativeBridgeState.currentActivity.id,
		pushToken: nativeBridgeState.pushToken,
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
				async endLiveActivity(payloadJson: string | null) {
					const payload = payloadJson ? JSON.parse(payloadJson) as Record<string, unknown> : null;
					if (nativeBridgeState.currentActivity) {
						nativeBridgeState.currentActivity.endCalls.push(payload);
					}
					nativeBridgeState.currentActivity = null;
				},
				async getCurrentLiveActivityInfo() {
					return toNativeInfo();
				},
				async getPushToStartToken() {
					return nativeBridgeState.pushToStartToken;
				},
				async startLiveActivity(payloadJson: string, deepLink: string) {
					if (nativeBridgeState.startError) {
						throw nativeBridgeState.startError;
					}

					const payload = JSON.parse(payloadJson) as Record<string, unknown>;
					nativeBridgeState.startDeepLinks.push(deepLink);
					if (nativeBridgeState.currentActivity) {
						nativeBridgeState.currentActivity.props = payload;
						nativeBridgeState.currentActivity.updateCalls.push(payload);
					} else {
						nativeBridgeState.currentActivity = {
							endCalls: [],
							id: `activity-${Math.random().toString(36).slice(2)}`,
							props: payload,
							updateCalls: [],
						};
					}
					return toNativeInfo();
				},
				async updateLiveActivity(payloadJson: string) {
					if (!nativeBridgeState.currentActivity) {
						return null;
					}

					const payload = JSON.parse(payloadJson) as Record<string, unknown>;
					nativeBridgeState.currentActivity.props = payload;
					nativeBridgeState.currentActivity.updateCalls.push(payload);
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
	persistGlobalLiveActivitySharedSnapshot: async (snapshot: Record<string, unknown> | null) => {
		sharedSnapshotWrites.push(snapshot);
	},
}));

const ACTIVE_STATE_KEY = "remotecode.live_activity.active_state";
const PUSH_TO_START_TOKEN_KEY = "remotecode.live_activity.push_to_start_token";

const {
	clearThreadLiveActivity,
	finishThreadLiveActivity,
	getThreadLiveActivityStateForBackgroundTask,
	onThreadLiveActivityAppStateChanged,
	resetThreadLiveActivityManagerForTests,
	startThreadLiveActivity,
	updateThreadLiveActivity,
} = await import("./thread-live-activity");

const realDateNow = Date.now;

const expectCurrentActivity = (): MockNativeActivity => {
	expect(nativeBridgeState.currentActivity).toBeDefined();
	return nativeBridgeState.currentActivity!;
};

const expectLatestUpdate = (): Record<string, unknown> => {
	const latest = expectCurrentActivity().updateCalls.at(-1);
	expect(latest).toBeDefined();
	return latest!;
};

beforeEach(() => {
	platformState.OS = "ios";
	platformState.Version = "18.0";
	secureStoreState.clear();
	nativeBridgeState.currentActivity = null;
	nativeBridgeState.listeners.clear();
	nativeBridgeState.pushToStartToken = null;
	nativeBridgeState.pushToken = null;
	nativeBridgeState.startDeepLinks = [];
	nativeBridgeState.startError = null;
	sharedSnapshotWrites.length = 0;
	resetThreadLiveActivityManagerForTests();
	Date.now = realDateNow;
});

afterEach(() => {
	Date.now = realDateNow;
});

describe("thread live activity manager", () => {
	test("starts a single global live activity session from zero", async () => {
		Date.now = () => 1_000;

		const started = await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});

		expect(started).toBe(true);
		expect(expectCurrentActivity().props).toMatchObject({
			chatId: "active-threads",
			chatTitle: "Active Threads",
			elapsedSeconds: 0,
			phase: "running",
			preview: "RemoteCode is working on 1 active thread.",
			statusLine: "1 thread active",
		});
		expect(nativeBridgeState.startDeepLinks).toEqual(["remotecode-mobile://active-threads"]);
		expect(sharedSnapshotWrites.at(-1)).toMatchObject({
			activeThreadCount: 1,
			chatId: "active-threads",
			deepLink: "remotecode-mobile://active-threads",
			phase: "running",
		});
	});

	test("finishing the only active thread freezes elapsed time and shows terminal summary", async () => {
		Date.now = () => 1_000;
		await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});

		const activity = expectCurrentActivity();
		Date.now = () => 11_000;
		await finishThreadLiveActivity({
			chatId: "chat-1",
			outcome: "completed",
		});
		await Bun.sleep(25);

		expect(activity.endCalls).toHaveLength(0);
		expect(expectLatestUpdate()).toMatchObject({
			chatId: "active-threads",
			elapsedSeconds: 10,
			phase: "completed",
			preview: "No active threads right now.",
			statusLine: "All threads completed",
		});
		expect(getThreadLiveActivityStateForBackgroundTask()).toMatchObject({
			chatId: "active-threads",
			phase: "completed",
		});
		expect(sharedSnapshotWrites.at(-1)).toMatchObject({
			activeThreadCount: 0,
			phase: "completed",
			statusLine: "All threads completed",
		});
	});

	test("starting a new session after all threads finished resets the timer to zero", async () => {
		Date.now = () => 1_000;
		await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});
		Date.now = () => 6_000;
		await finishThreadLiveActivity({
			chatId: "chat-1",
			outcome: "error",
		});

		Date.now = () => 9_000;
		await startThreadLiveActivity({
			chatId: "chat-2",
			remoteManaged: false,
		});
		await Bun.sleep(25);

		expect(expectLatestUpdate()).toMatchObject({
			chatId: "active-threads",
			elapsedSeconds: 0,
			phase: "running",
			preview: "RemoteCode is working on 1 active thread.",
			statusLine: "1 thread active",
		});
	});

	test("overlapping threads keep one continuous timer until the last thread finishes", async () => {
		Date.now = () => 1_000;
		await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});

		Date.now = () => 4_000;
		await startThreadLiveActivity({
			chatId: "chat-2",
			remoteManaged: false,
		});
		await Bun.sleep(25);
		expect(expectLatestUpdate()).toMatchObject({
			elapsedSeconds: 3,
			phase: "running",
			statusLine: "2 threads active",
			preview: "RemoteCode is working on 2 active threads.",
		});

		Date.now = () => 9_000;
		await updateThreadLiveActivity({
			chatId: "chat-2",
			force: true,
		});
		await Bun.sleep(25);
		expect(expectLatestUpdate()).toMatchObject({
			elapsedSeconds: 8,
			phase: "running",
			statusLine: "2 threads active",
		});

		Date.now = () => 11_000;
		await finishThreadLiveActivity({
			chatId: "chat-1",
			outcome: "completed",
		});
		await Bun.sleep(25);
		expect(expectLatestUpdate()).toMatchObject({
			elapsedSeconds: 10,
			phase: "running",
			statusLine: "1 thread active",
			preview: "RemoteCode is working on 1 active thread.",
		});

		Date.now = () => 13_000;
		await finishThreadLiveActivity({
			chatId: "chat-2",
			outcome: "failed",
		});
		await Bun.sleep(25);
		expect(expectLatestUpdate()).toMatchObject({
			elapsedSeconds: 12,
			phase: "failed",
			preview: "No active threads right now.",
			statusLine: "At least one thread failed",
		});
	});

	test("background transitions preserve the global session and use background phase", async () => {
		Date.now = () => 1_000;
		await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});

		Date.now = () => 4_000;
		await onThreadLiveActivityAppStateChanged("background");
		await Bun.sleep(25);

		expect(expectLatestUpdate()).toMatchObject({
			chatId: "active-threads",
			elapsedSeconds: 3,
			phase: "background",
			statusLine: "1 thread active",
			preview: "RemoteCode is working on 1 active thread.",
		});
	});

	test("recreates a dismissed activity on the next active-session event", async () => {
		await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});

		const previousActivityId = expectCurrentActivity().id;
		nativeBridgeState.currentActivity = null;

		await updateThreadLiveActivity({
			chatId: "chat-1",
			force: true,
		});
		await Bun.sleep(25);

		expect(expectCurrentActivity().id).not.toBe(previousActivityId);
		expect(expectCurrentActivity().props).toMatchObject({
			chatId: "active-threads",
			chatTitle: "Active Threads",
		});
	});

	test("does not recreate a dismissed terminal activity until a new session starts", async () => {
		await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});
		await finishThreadLiveActivity({
			chatId: "chat-1",
			outcome: "completed",
		});
		await Bun.sleep(25);

		nativeBridgeState.currentActivity = null;
		await onThreadLiveActivityAppStateChanged("active");
		await Bun.sleep(25);
		expect(nativeBridgeState.currentActivity).toBeNull();

		await startThreadLiveActivity({
			chatId: "chat-2",
			remoteManaged: false,
		});
		await Bun.sleep(25);
		expect(expectCurrentActivity().props).toMatchObject({
			chatId: "active-threads",
			phase: "running",
		});
	});

	test("clearThreadLiveActivity removes a tracked chat and recomputes the global summary", async () => {
		await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});
		await startThreadLiveActivity({
			chatId: "chat-2",
			remoteManaged: false,
		});

		await clearThreadLiveActivity({
			chatId: "chat-1",
		});
		await Bun.sleep(25);
		expect(expectLatestUpdate()).toMatchObject({
			phase: "running",
			statusLine: "1 thread active",
		});

		await clearThreadLiveActivity({
			chatId: "chat-2",
		});
		await Bun.sleep(25);
		expect(expectLatestUpdate()).toMatchObject({
			phase: "completed",
			statusLine: "All threads completed",
			preview: "No active threads right now.",
		});
	});

	test("preserves the worst session outcome after clearing a finished chat while another thread keeps running", async () => {
		Date.now = () => 1_000;
		await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});
		await startThreadLiveActivity({
			chatId: "chat-2",
			remoteManaged: false,
		});

		Date.now = () => 6_000;
		await finishThreadLiveActivity({
			chatId: "chat-1",
			outcome: "failed",
		});
		await clearThreadLiveActivity({
			chatId: "chat-1",
		});

		Date.now = () => 11_000;
		await finishThreadLiveActivity({
			chatId: "chat-2",
			outcome: "completed",
		});
		await Bun.sleep(25);

		expect(expectLatestUpdate()).toMatchObject({
			chatId: "active-threads",
			elapsedSeconds: 10,
			phase: "failed",
			preview: "No active threads right now.",
			statusLine: "At least one thread failed",
		});
	});

	test("keeps the push-to-start token persisted after clearing the last tracked chat", async () => {
		secureStoreState.set(PUSH_TO_START_TOKEN_KEY, "push-to-start-token");

		await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});
		await clearThreadLiveActivity({
			chatId: "chat-1",
		});

		expect(secureStoreState.get(PUSH_TO_START_TOKEN_KEY)).toBe("push-to-start-token");
		expect(JSON.parse(secureStoreState.get(ACTIVE_STATE_KEY) ?? "{}")).toMatchObject({
			renderedState: {
				chatId: "active-threads",
				phase: "completed",
			},
		});
	});

	test("keeps remote-managed placeholder state when native start fails so the next event can retry", async () => {
		nativeBridgeState.startError = new Error("activities-disabled");
		Date.now = () => 1_000;

		const started = await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: true,
		});

		expect(started).toBe(false);
		expect(JSON.parse(secureStoreState.get(ACTIVE_STATE_KEY) ?? "{}")).toMatchObject({
			renderedState: {
				chatId: "active-threads",
				phase: "running",
				subscriptionChatId: "chat-1",
			},
			trackedChats: [
				{
					chatId: "chat-1",
					phase: "running",
				},
			],
		});

		nativeBridgeState.startError = null;
		Date.now = () => 45_000;
		await updateThreadLiveActivity({
			chatId: "chat-1",
			force: true,
		});
		await Bun.sleep(25);
		expect(expectCurrentActivity().props).toMatchObject({
			chatId: "active-threads",
			phase: "running",
		});
	});

	test("writes locally after authoritative sync is received for a remote-managed activity", async () => {
		Date.now = () => 1_000;
		await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: true,
		});
		await Bun.sleep(25);

		const activity = expectCurrentActivity();
		const initialUpdateCount = activity.updateCalls.length;

		Date.now = () => 21_000;
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

		expect(activity.updateCalls.length).toBeGreaterThan(initialUpdateCount);
		expect(activity.props).toMatchObject({
			phase: "completed",
			preview: "No active threads right now.",
			statusLine: "All threads completed",
		});
	});

	test("propagates native push token events to the current subscription chat", async () => {
		await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});

		nativeBridgeState.pushToken = "push-token-1";
		emitNativeEvent("RemoteCodeLiveActivityPushToken", {
			activityId: expectCurrentActivity().id,
			pushToken: "push-token-1",
		});
		await Bun.sleep(25);

		expect(secureStoreState.get("remotecode.live_activity.push_token")).toBe("push-token-1");
	});
});
