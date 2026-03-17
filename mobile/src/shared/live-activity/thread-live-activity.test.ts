/* eslint-disable import/no-unresolved */
import { afterEach, beforeEach, describe, expect, test, mock } from "bun:test";

const platformState = {
	OS: "ios" as "ios" | "android",
	Version: "18.0",
};

const secureStoreState = new Map<string, string>();

interface MockActivity {
	addPushTokenListener: (listener: (event: { pushToken: string }) => void) => { remove: () => void };
	end: (...args: unknown[]) => Promise<void>;
	getPushToken: () => Promise<string | null>;
	update: (props: unknown) => Promise<void>;
	updateCalls: unknown[];
}

const createMockActivity = (): MockActivity => ({
	addPushTokenListener: () => ({
		remove: () => undefined,
	}),
	end: async () => undefined,
	async getPushToken() {
		return null;
	},
	async update(props: unknown) {
		this.updateCalls.push(props);
	},
	updateCalls: [],
});

const widgetsState = {
	instances: [] as MockActivity[],
};

mock.module("react-native", () => ({
	AppState: {
		addEventListener: () => ({
			remove: () => undefined,
		}),
		currentState: "active",
	},
	Platform: platformState,
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

mock.module("expo-widgets", () => ({
	addPushToStartTokenListener: () => ({
		remove: () => undefined,
	}),
}));

mock.module("./thread-live-activity.widget", () => ({
	threadLiveActivityFactory: {
		getInstances: () => widgetsState.instances,
		start: () => {
			const activity = createMockActivity();
			widgetsState.instances.push(activity);
			return activity;
		},
	},
}));

const ACTIVE_STATE_KEY = "remotecode.live_activity.active_state";
const PUSH_TO_START_TOKEN_KEY = "remotecode.live_activity.push_to_start_token";

const {
	clearThreadLiveActivity,
	getThreadLiveActivityStateForBackgroundTask,
	initializeThreadLiveActivityManager,
	onThreadLiveActivityAppStateChanged,
	resetThreadLiveActivityManagerForTests,
	startThreadLiveActivity,
} = await import("./thread-live-activity");

const realDateNow = Date.now;

beforeEach(() => {
	platformState.OS = "ios";
	platformState.Version = "18.0";
	secureStoreState.clear();
	widgetsState.instances = [];
	resetThreadLiveActivityManagerForTests();
	Date.now = realDateNow;
});

afterEach(() => {
	Date.now = realDateNow;
});

describe("thread live activity manager", () => {
	test("does not create placeholder state for remotely started unowned instances", async () => {
		widgetsState.instances = [createMockActivity()];

		await initializeThreadLiveActivityManager();

		expect(getThreadLiveActivityStateForBackgroundTask()).toBeNull();
	});

	test("falls back to local writes after the authoritative sync grace period expires", async () => {
		const activity = createMockActivity();
		widgetsState.instances = [activity];
		secureStoreState.set(ACTIVE_STATE_KEY, JSON.stringify([
			{
				chatId: "chat-1",
				chatTitle: "Thread",
				phase: "running",
				preview: "Waiting for updates...",
				remoteManaged: true,
				startedAtMs: 1_000,
				statusLine: "Generating response",
			},
		]));

		Date.now = () => 10_000;
		await initializeThreadLiveActivityManager();
		expect(activity.updateCalls).toHaveLength(0);

		Date.now = () => 45_000;
		await onThreadLiveActivityAppStateChanged("background");
		await Bun.sleep(50);

		expect(activity.updateCalls).toHaveLength(1);
		expect(activity.updateCalls[0]).toMatchObject({
			chatId: "chat-1",
			phase: "background",
		});
	});

	test("keeps the push-to-start token persisted after clearing the last local entry", async () => {
		secureStoreState.set(PUSH_TO_START_TOKEN_KEY, "push-to-start-token");

		await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: true,
		});
		await clearThreadLiveActivity({
			chatId: "chat-1",
		});

		expect(secureStoreState.get(PUSH_TO_START_TOKEN_KEY)).toBe("push-to-start-token");
	});
});
