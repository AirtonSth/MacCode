import * as SecureStore from "expo-secure-store";
import { addPushToStartTokenListener, type LiveActivity } from "expo-widgets";
import { Platform, type AppStateStatus } from "react-native";

import {
	threadLiveActivityFactory,
	type ThreadLiveActivityPhase,
	type ThreadLiveActivityProps,
} from "./thread-live-activity.widget";

const ACTIVE_STATE_KEY = "remotecode.live_activity.active_state";
const PUSH_TOKEN_KEY = "remotecode.live_activity.push_token";
const PUSH_TO_START_TOKEN_KEY = "remotecode.live_activity.push_to_start_token";
const UPDATE_THROTTLE_MS = 1_200;
const ELAPSED_TICK_INTERVAL_MS = 1_000;
const MIN_IOS_LIVE_ACTIVITIES_MAJOR = 16;
const MIN_IOS_LIVE_ACTIVITIES_MINOR = 1;

interface Subscription {
	remove: () => void;
}

interface PersistedLiveActivityState {
	chatId: string;
	chatTitle: string;
	phase: ThreadLiveActivityPhase;
	preview: string;
	startedAtMs: number;
	statusLine: string;
}

interface LiveActivityStartInput {
	chatId: string;
	chatTitle?: string;
	preview?: string;
	startedAtMs?: number;
	statusLine?: string;
	restart?: boolean;
}

interface LiveActivityUpdateInput {
	chatId: string;
	chatTitle?: string;
	phase?: ThreadLiveActivityPhase;
	preview?: string;
	statusLine?: string;
	force?: boolean;
}

interface LiveActivityFinishInput {
	chatId: string;
	chatTitle?: string;
	outcome: "completed" | "failed" | "error";
	preview?: string;
	statusLine?: string;
}

let initialized = false;
let activeState: PersistedLiveActivityState | null = null;
let activeActivity: LiveActivity<ThreadLiveActivityProps> | null = null;
let activityPushTokenSubscription: Subscription | null = null;
let pushToStartTokenSubscription: Subscription | null = null;
let lastContentUpdateAt = 0;
let elapsedTickInterval: ReturnType<typeof setInterval> | null = null;
let finishingChatId: string | null = null;
let liveActivitiesUnavailable = false;

const isSupportedIosVersion = (): boolean => {
	if (Platform.OS !== "ios") {
		return false;
	}

	const rawVersion = Platform.Version;
	const normalized = typeof rawVersion === "string" ? rawVersion : String(rawVersion);
	const [majorPart = "0", minorPart = "0"] = normalized.split(".");
	const major = Number.parseInt(majorPart, 10);
	const minor = Number.parseInt(minorPart, 10);
	if (Number.isNaN(major) || Number.isNaN(minor)) {
		return false;
	}

	if (major > MIN_IOS_LIVE_ACTIVITIES_MAJOR) {
		return true;
	}

	return major === MIN_IOS_LIVE_ACTIVITIES_MAJOR && minor >= MIN_IOS_LIVE_ACTIVITIES_MINOR;
};

const canUseLiveActivities = (): boolean => !liveActivitiesUnavailable && isSupportedIosVersion();

const nowMs = (): number => Date.now();

const withDefault = (value: string | undefined, fallback: string): string => {
	const trimmed = value?.trim();
	return trimmed && trimmed.length > 0 ? trimmed : fallback;
};

const toElapsedSeconds = (startedAtMs: number): number => {
	const started = Number.isFinite(startedAtMs) && startedAtMs > 0 ? startedAtMs : nowMs();
	const deltaMs = Math.max(0, nowMs() - started);
	return Math.floor(deltaMs / 1000);
};

const toProps = (state: PersistedLiveActivityState): ThreadLiveActivityProps => ({
	chatId: state.chatId,
	chatTitle: state.chatTitle,
	elapsedSeconds: toElapsedSeconds(state.startedAtMs),
	phase: state.phase,
	preview: state.preview,
	statusLine: state.statusLine,
});

const isTerminalPhase = (phase: ThreadLiveActivityPhase): boolean =>
	phase === "completed" || phase === "failed" || phase === "error";

const persistActiveState = async (): Promise<void> => {
	if (!activeState) {
		await SecureStore.deleteItemAsync(ACTIVE_STATE_KEY);
		return;
	}

	await SecureStore.setItemAsync(ACTIVE_STATE_KEY, JSON.stringify(activeState));
};

const hydratePersistedState = async (): Promise<void> => {
	const raw = await SecureStore.getItemAsync(ACTIVE_STATE_KEY);
	if (!raw) {
		return;
	}

	try {
		const parsed = JSON.parse(raw) as Partial<PersistedLiveActivityState> | null;
		if (!parsed || typeof parsed !== "object") {
			return;
		}

		const chatId = withDefault(parsed.chatId, "");
		if (chatId.length === 0) {
			return;
		}

		activeState = {
			chatId,
			chatTitle: withDefault(parsed.chatTitle, "Thread"),
			phase: parsed.phase ?? "running",
			preview: withDefault(parsed.preview, "Waiting for updates..."),
			startedAtMs:
				typeof parsed.startedAtMs === "number" && Number.isFinite(parsed.startedAtMs) && parsed.startedAtMs > 0
					? Math.floor(parsed.startedAtMs)
					: nowMs(),
			statusLine: withDefault(parsed.statusLine, "Running"),
		};
	} catch {
		// Ignore malformed state and continue.
	}
};

const clearElapsedTick = (): void => {
	if (!elapsedTickInterval) {
		return;
	}

	clearInterval(elapsedTickInterval);
	elapsedTickInterval = null;
};

const detachActivityPushTokenSubscription = (): void => {
	if (!activityPushTokenSubscription) {
		return;
	}

	activityPushTokenSubscription.remove();
	activityPushTokenSubscription = null;
};

const attachActivityPushTokenSubscription = (activity: LiveActivity<ThreadLiveActivityProps>): void => {
	detachActivityPushTokenSubscription();
	activityPushTokenSubscription = activity.addPushTokenListener((event) => {
		void SecureStore.setItemAsync(PUSH_TOKEN_KEY, event.pushToken);
	});
};

async function normalizeActivityInstance(): Promise<LiveActivity<ThreadLiveActivityProps> | null> {
	if (activeActivity) {
		return activeActivity;
	}

	const instances = threadLiveActivityFactory.getInstances();
	if (instances.length === 0) {
		return null;
	}

	activeActivity = instances[0];
	attachActivityPushTokenSubscription(activeActivity);

	if (instances.length > 1) {
		await Promise.all(
			instances.slice(1).map(async (instance) => {
				try {
					await instance.end("immediate");
				} catch {
					// Ignore duplicate cleanup failures.
				}
			}),
		);
	}

	return activeActivity;
}

const pushElapsedTickUpdate = async (): Promise<void> => {
	if (!activeState || isTerminalPhase(activeState.phase)) {
		return;
	}

	const activity = await normalizeActivityInstance();
	if (!activity) {
		return;
	}

	try {
		await activity.update(toProps(activeState));
	} catch {
		// Ignore elapsed tick update failures.
	}
};

const ensureElapsedTick = (): void => {
	if (elapsedTickInterval || !activeState || isTerminalPhase(activeState.phase)) {
		return;
	}

	elapsedTickInterval = setInterval(() => {
		void pushElapsedTickUpdate();
	}, ELAPSED_TICK_INTERVAL_MS);
};

const shouldSkipThrottledUpdate = (force = false): boolean =>
	!force && nowMs() - lastContentUpdateAt < UPDATE_THROTTLE_MS;

export const initializeThreadLiveActivityManager = async (): Promise<void> => {
	if (!canUseLiveActivities() || initialized) {
		return;
	}

	try {
		initialized = true;
		await hydratePersistedState();
		await normalizeActivityInstance();

		if (activeState && !isTerminalPhase(activeState.phase)) {
			ensureElapsedTick();
		}

		pushToStartTokenSubscription ||= addPushToStartTokenListener((event) => {
			void SecureStore.setItemAsync(PUSH_TO_START_TOKEN_KEY, event.activityPushToStartToken);
		});
	} catch {
		liveActivitiesUnavailable = true;
		clearElapsedTick();
		detachActivityPushTokenSubscription();
		activeActivity = null;
		activeState = null;
		lastContentUpdateAt = 0;
		// eslint-disable-next-line require-atomic-updates
		initialized = false;
	}
};

export const startThreadLiveActivity = async (input: LiveActivityStartInput): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	if (input.restart && activeState) {
		await clearThreadLiveActivity({
			chatId: activeState.chatId,
		});
	}

	let startedAtMs = nowMs();
	const hasExplicitStartTime =
		typeof input.startedAtMs === "number" && Number.isFinite(input.startedAtMs) && input.startedAtMs > 0;
	if (hasExplicitStartTime) {
		startedAtMs = Math.floor(input.startedAtMs ?? nowMs());
	}
	if (!hasExplicitStartTime && !input.restart && activeState?.chatId === input.chatId) {
		startedAtMs = activeState.startedAtMs;
	}

	const nextState: PersistedLiveActivityState = {
		chatId: input.chatId,
		chatTitle: withDefault(input.chatTitle, activeState?.chatId === input.chatId ? activeState.chatTitle : "Thread"),
		phase: "running",
		preview: withDefault(input.preview, "Waiting for updates..."),
		startedAtMs,
		statusLine: withDefault(input.statusLine, "Running"),
	};

	if (activeState && activeState.chatId !== input.chatId) {
		await clearThreadLiveActivity({
			chatId: activeState.chatId,
		});
	}

	// eslint-disable-next-line require-atomic-updates
	activeState = nextState;
	await persistActiveState();
	ensureElapsedTick();

	const existing = await normalizeActivityInstance();
	if (existing) {
		try {
			await existing.update(toProps(nextState));
			lastContentUpdateAt = nowMs();
			return;
		} catch {
			activeActivity = null;
		}
	}

	try {
		activeActivity = threadLiveActivityFactory.start(toProps(nextState), `remotecode-mobile://chat?chatId=${encodeURIComponent(nextState.chatId)}`);
		attachActivityPushTokenSubscription(activeActivity);
		lastContentUpdateAt = nowMs();
	} catch {
		// Ignore Live Activity startup failures.
	}
};

export const updateThreadLiveActivity = async (input: LiveActivityUpdateInput): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	if (!activeState || activeState.chatId !== input.chatId || shouldSkipThrottledUpdate(input.force)) {
		return;
	}

	activeState = {
		...activeState,
		chatTitle: withDefault(input.chatTitle, activeState.chatTitle),
		phase: input.phase ?? activeState.phase,
		preview: withDefault(input.preview, activeState.preview),
		statusLine: withDefault(input.statusLine, activeState.statusLine),
	};
	await persistActiveState();

	const activity = await normalizeActivityInstance();
	if (!activity) {
		return;
	}

	try {
		await activity.update(toProps(activeState));
		lastContentUpdateAt = nowMs();
	} catch {
		// Ignore runtime update failures.
	}
};

export const finishThreadLiveActivity = async (input: LiveActivityFinishInput): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	if (!activeState) {
		return;
	}

	if (finishingChatId === input.chatId) {
		return;
	}

	if (activeState.chatId !== input.chatId) {
		return;
	}

	finishingChatId = input.chatId;

	const outcomePhase: ThreadLiveActivityPhase = (() => {
		switch (input.outcome) {
			case "completed": {
				return "completed";
			}
			case "error": {
				return "error";
			}
			case "failed": {
				return "failed";
			}
			default: {
				return "error";
			}
		}
	})();
	const defaultStatusLine = (() => {
		switch (outcomePhase) {
			case "completed": {
				return "Response is ready";
			}
			case "error": {
				return "Thread ended with an error";
			}
			case "failed": {
				return "Thread failed";
			}
			default: {
				return "Thread ended with an error";
			}
		}
	})();
	const finalState: PersistedLiveActivityState = {
		chatId: input.chatId,
		chatTitle: withDefault(input.chatTitle, activeState?.chatTitle ?? "Thread"),
		phase: outcomePhase,
		preview: withDefault(input.preview, activeState?.preview ?? "Done"),
		startedAtMs: activeState?.startedAtMs ?? nowMs(),
		statusLine: withDefault(input.statusLine, defaultStatusLine),
	};

	try {
		activeState = finalState;
		await persistActiveState();
		clearElapsedTick();

		const activity = await normalizeActivityInstance();
		if (!activity) {
			activeActivity = null;
			// eslint-disable-next-line require-atomic-updates
			activeState = null;
			await persistActiveState();
			return;
		}

		try {
			await activity.update(toProps(finalState));
			await activity.end("default", toProps(finalState));
		} catch {
			// Ignore completion failures.
		} finally {
			detachActivityPushTokenSubscription();
			activeActivity = null;
			// eslint-disable-next-line require-atomic-updates
			activeState = null;
			lastContentUpdateAt = 0;
			await persistActiveState();
		}
	} finally {
		if (finishingChatId === input.chatId) {
			finishingChatId = null;
		}
	}
};

export const clearThreadLiveActivity = async (input: { chatId: string }): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	if (!activeState) {
		return;
	}

	if (activeState.chatId !== input.chatId) {
		return;
	}

	clearElapsedTick();
	const activity = await normalizeActivityInstance();
	if (activity) {
		try {
			await activity.end("immediate");
		} catch {
			// Ignore cleanup failures.
		}
	}

	detachActivityPushTokenSubscription();
	activeActivity = null;
	// eslint-disable-next-line require-atomic-updates
	activeState = null;
	lastContentUpdateAt = 0;
	await persistActiveState();
};

export const onThreadLiveActivityAppStateChanged = async (nextState: AppStateStatus): Promise<void> => {
	if (!canUseLiveActivities() || !activeState) {
		return;
	}

	if (isTerminalPhase(activeState.phase)) {
		return;
	}

	if (nextState === "background" || nextState === "inactive") {
		await updateThreadLiveActivity({
			chatId: activeState.chatId,
			phase: "background",
			statusLine: "Running in background",
			force: true,
		});
		return;
	}

	if (nextState === "active") {
		await updateThreadLiveActivity({
			chatId: activeState.chatId,
			phase: "running",
			statusLine: "Running",
			force: true,
		});
	}
};

export const isThreadLiveActivityEnabled = (): boolean => canUseLiveActivities();

export const getThreadLiveActivityStateForBackgroundTask = (): PersistedLiveActivityState | null => activeState;
