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
	endCalls: unknown[][];
	getId: () => string;
	getProps: () => { chatId: string } | null;
	getPushToken: () => Promise<string | null>;
	id: string;
	update: (props: unknown) => Promise<void>;
	updateCalls: unknown[];
}

const createMockActivity = (input?: { chatId?: string; id?: string }): MockActivity => {
	const state = {
		props: input?.chatId ? { chatId: input.chatId } : null,
	};

	return {
		addPushTokenListener: () => ({
			remove: () => undefined,
		}),
		async end(...args: unknown[]) {
			this.endCalls.push(args);
		},
		endCalls: [],
		getId() {
			return this.id;
		},
		getProps() {
			return state.props;
		},
		async getPushToken() {
			return null;
		},
		id: input?.id ?? `activity-${Math.random().toString(36).slice(2)}`,
		async update(props: unknown) {
			if (props && typeof props === "object" && "chatId" in props && typeof props.chatId === "string") {
				state.props = {
					chatId: props.chatId,
				};
			}
			this.updateCalls.push(props);
		},
		updateCalls: [],
	};
};

const widgetsState = {
	instances: [] as MockActivity[],
	startError: null as Error | null,
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
		start: (props: { chatId?: string }) => {
			if (widgetsState.startError) {
				throw widgetsState.startError;
			}
			const activity = createMockActivity({
				chatId: props.chatId,
			});
			widgetsState.instances.push(activity);
			return activity;
		},
	},
}));

const ACTIVE_STATE_KEY = "remotecode.live_activity.active_state";
const PUSH_TO_START_TOKEN_KEY = "remotecode.live_activity.push_to_start_token";

const {
	clearThreadLiveActivity,
	finishThreadLiveActivity,
	getThreadLiveActivityStateForBackgroundTask,
	hasActiveLiveActivityEntry,
	initializeThreadLiveActivityManager,
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
	widgetsState.instances = [];
	widgetsState.startError = null;
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

	test("removes placeholder state when the native activity fails to start", async () => {
		widgetsState.startError = new Error("activities-disabled");

		const started = await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: true,
		});

		expect(started).toBe(false);
		expect(hasActiveLiveActivityEntry("chat-1")).toBe(false);
		expect(secureStoreState.get(ACTIVE_STATE_KEY)).toBeUndefined();
	});

	test("recreates a dismissed activity when a new update arrives", async () => {
		const started = await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});

		expect(started).toBe(true);
		expect(widgetsState.instances).toHaveLength(1);

		const dismissedActivity = widgetsState.instances[0];
		widgetsState.instances = [];

		await updateThreadLiveActivity({
			chatId: "chat-1",
			force: true,
			preview: "New output after dismiss",
			statusLine: "Generating response",
		});
		await Bun.sleep(50);

		expect(widgetsState.instances).toHaveLength(1);
		expect(widgetsState.instances[0]).not.toBe(dismissedActivity);
		expect(widgetsState.instances[0]?.updateCalls).toHaveLength(1);
		expect(widgetsState.instances[0]?.updateCalls[0]).toMatchObject({
			chatId: "chat-1",
			preview: "New output after dismiss",
		});
	});

	test("keeps completed activities open until explicitly cleared", async () => {
		const started = await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});

		expect(started).toBe(true);
		const activity = widgetsState.instances[0];
		expect(activity).toBeDefined();

		await finishThreadLiveActivity({
			chatId: "chat-1",
			outcome: "completed",
		});

		await Bun.sleep(50);

		expect(activity?.endCalls).toHaveLength(0);
		expect(activity?.updateCalls.length ?? 0).toBeGreaterThanOrEqual(1);
		expect(activity?.updateCalls.at(-1)).toMatchObject({
			chatId: "chat-1",
			phase: "completed",
		});
		expect(widgetsState.instances).toHaveLength(1);
	});

	test("reuses the same activity when a completed chat starts again", async () => {
		const started = await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});

		expect(started).toBe(true);
		const activity = widgetsState.instances[0];
		expect(activity).toBeDefined();

		await finishThreadLiveActivity({
			chatId: "chat-1",
			outcome: "completed",
		});
		await Bun.sleep(50);

		const restarted = await startThreadLiveActivity({
			chatId: "chat-1",
			preview: "New output",
			remoteManaged: false,
			statusLine: "Generating response",
		});

		expect(restarted).toBe(true);
		await Bun.sleep(50);

		expect(widgetsState.instances).toHaveLength(1);
		expect(widgetsState.instances[0]).toBe(activity);
		expect(activity?.endCalls).toHaveLength(0);
		expect(activity?.updateCalls.length ?? 0).toBeGreaterThanOrEqual(2);
		expect(activity?.updateCalls.at(-1)).toMatchObject({
			chatId: "chat-1",
			phase: "running",
			preview: "New output",
			statusLine: "Generating response",
		});
	});

	test("reuses the already open activity when a different chat starts", async () => {
		const started = await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});

		expect(started).toBe(true);
		const activity = widgetsState.instances[0];
		expect(activity).toBeDefined();

		const startedSecondChat = await startThreadLiveActivity({
			chatId: "chat-2",
			preview: "New chat output",
			remoteManaged: false,
			statusLine: "Generating response",
		});

		expect(startedSecondChat).toBe(true);
		await Bun.sleep(50);

		expect(widgetsState.instances).toHaveLength(1);
		expect(widgetsState.instances[0]).toBe(activity);
		expect(activity?.endCalls).toHaveLength(0);
		expect(activity?.updateCalls.length ?? 0).toBeGreaterThanOrEqual(1);
		expect(activity?.updateCalls.at(-1)).toMatchObject({
			chatId: "chat-2",
			phase: "running",
			preview: "New chat output",
			statusLine: "Generating response",
		});
	});

	test("reuses the already open activity when a different chat finishes", async () => {
		const started = await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});

		expect(started).toBe(true);
		const activity = widgetsState.instances[0];
		expect(activity).toBeDefined();

		await finishThreadLiveActivity({
			chatId: "chat-2",
			outcome: "completed",
			preview: "Final answer",
		});
		await Bun.sleep(50);

		expect(widgetsState.instances).toHaveLength(1);
		expect(widgetsState.instances[0]).toBe(activity);
		expect(activity?.endCalls).toHaveLength(0);
		expect(activity?.updateCalls.length ?? 0).toBeGreaterThanOrEqual(1);
		expect(activity?.updateCalls.at(-1)).toMatchObject({
			chatId: "chat-2",
			phase: "completed",
			preview: "Final answer",
			statusLine: "Response is ready",
		});
	});

	test("recreates a dismissed activity when a completion arrives", async () => {
		const started = await startThreadLiveActivity({
			chatId: "chat-1",
			remoteManaged: false,
		});

		expect(started).toBe(true);
		widgetsState.instances = [];

		await clearThreadLiveActivity({
			chatId: "chat-1",
		});

		await finishThreadLiveActivity({
			chatId: "chat-1",
			outcome: "completed",
			preview: "Final answer after dismiss",
		});
		await Bun.sleep(50);

		expect(widgetsState.instances).toHaveLength(1);
		expect(widgetsState.instances[0]?.updateCalls).toHaveLength(1);
		expect(widgetsState.instances[0]?.updateCalls[0]).toMatchObject({
			chatId: "chat-1",
			phase: "completed",
			preview: "Final answer after dismiss",
			statusLine: "Response is ready",
		});
	});

	test("adopts restored activities by chat identity instead of instance order", async () => {
		const activityForChatB = createMockActivity({
			chatId: "chat-b",
			id: "activity-b",
		});
		const activityForChatA = createMockActivity({
			chatId: "chat-a",
			id: "activity-a",
		});
		widgetsState.instances = [activityForChatB, activityForChatA];
		secureStoreState.set(ACTIVE_STATE_KEY, JSON.stringify([
			{
				chatId: "chat-a",
				chatTitle: "Thread A",
				phase: "running",
				preview: "Waiting for updates...",
				remoteManaged: false,
				startedAtMs: 1_000,
				statusLine: "Generating response",
			},
			{
				chatId: "chat-b",
				chatTitle: "Thread B",
				phase: "running",
				preview: "Waiting for updates...",
				remoteManaged: false,
				startedAtMs: 1_000,
				statusLine: "Generating response",
			},
		]));

		Date.now = () => 10_000;
		await initializeThreadLiveActivityManager();
		await Bun.sleep(50);

		expect(activityForChatA.updateCalls[0]).toMatchObject({
			chatId: "chat-a",
		});
		expect(activityForChatB.updateCalls[0]).toMatchObject({
			chatId: "chat-b",
		});
	});
});
