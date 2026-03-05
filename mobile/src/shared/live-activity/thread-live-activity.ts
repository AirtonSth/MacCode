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
const LOCAL_UPDATE_MIN_INTERVAL_MS = 5_000;
const LOCAL_HEARTBEAT_INTERVAL_MS = 5_000;
const LOCAL_ELAPSED_BUCKET_SECONDS = 5;
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
	remoteManaged: boolean;
}

interface LiveActivityStartInput {
	chatId: string;
	chatTitle?: string;
	preview?: string;
	startedAtMs?: number;
	statusLine?: string;
	remoteManaged?: boolean;
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

interface LiveActivityPushTokenUpdate {
	chatId: string;
	pushToken: string;
}

let initialized = false;
let liveActivitiesUnavailable = false;
let activeState: PersistedLiveActivityState | null = null;
let activeActivity: LiveActivity<ThreadLiveActivityProps> | null = null;
let activityPushTokenSubscription: Subscription | null = null;
let pushToStartTokenSubscription: Subscription | null = null;
let finishingChatId: string | null = null;
let flushTimeout: ReturnType<typeof setTimeout> | null = null;
let heartbeatInterval: ReturnType<typeof setInterval> | null = null;
let writeInFlight = false;
let writeAgain = false;
let pendingForceWrite = false;
let lastContentSignature = "";
let lastContentUpdateAtMs = 0;
let lastStatePersistAtMs = 0;
let currentAppState: AppStateStatus = "active";
const pushTokenListeners = new Set<(event: LiveActivityPushTokenUpdate) => void>();

const nowMs = (): number => Date.now();

const withDefault = (value: string | undefined, fallback: string): string => {
	const trimmed = value?.trim();
	return trimmed && trimmed.length > 0 ? trimmed : fallback;
};

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

const toElapsedSeconds = (startedAtMs: number): number => {
	const started = Number.isFinite(startedAtMs) && startedAtMs > 0 ? startedAtMs : nowMs();
	const deltaMs = Math.max(0, nowMs() - started);
	return Math.floor(deltaMs / 1_000);
};

const toElapsedBucket = (startedAtMs: number): number =>
	Math.floor(toElapsedSeconds(startedAtMs) / LOCAL_ELAPSED_BUCKET_SECONDS);

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

const toContentSignature = (state: PersistedLiveActivityState): string =>
	[
		state.chatId,
		state.chatTitle,
		state.phase,
		state.statusLine,
		state.preview,
		String(toElapsedBucket(state.startedAtMs)),
	].join("\u0001");

const persistActiveState = async (): Promise<void> => {
	if (!activeState) {
		await SecureStore.deleteItemAsync(ACTIVE_STATE_KEY);
		lastStatePersistAtMs = 0;
		return;
	}

	await SecureStore.setItemAsync(ACTIVE_STATE_KEY, JSON.stringify(activeState));
	lastStatePersistAtMs = nowMs();
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
				remoteManaged: Boolean(parsed.remoteManaged),
			};
	} catch {
		// Ignore malformed persisted state.
	}
};

const detachActivityPushTokenSubscription = (): void => {
	if (!activityPushTokenSubscription) {
		return;
	}

	activityPushTokenSubscription.remove();
	activityPushTokenSubscription = null;
};

const emitPushToken = (chatId: string, pushToken: string): void => {
	for (const listener of pushTokenListeners) {
		try {
			listener({
				chatId,
				pushToken,
			});
		} catch {
			// Keep listeners isolated from one another.
		}
	}
};

const attachActivityPushTokenSubscription = (activity: LiveActivity<ThreadLiveActivityProps>): void => {
	detachActivityPushTokenSubscription();
	activityPushTokenSubscription = activity.addPushTokenListener((event) => {
		const chatId = activeState?.chatId;
		if (!chatId) {
			return;
		}

		const normalizedPushToken = withDefault(event.pushToken, "");
		if (normalizedPushToken.length === 0) {
			return;
		}

		void SecureStore.setItemAsync(PUSH_TOKEN_KEY, normalizedPushToken);
		emitPushToken(chatId, normalizedPushToken);
	});
};

const syncCurrentActivityPushToken = async (): Promise<void> => {
	const chatId = activeState?.chatId;
	if (!chatId || !activeActivity) {
		return;
	}

	try {
		const pushToken = withDefault(await activeActivity.getPushToken() ?? "", "");
		if (pushToken.length === 0) {
			return;
		}

		await SecureStore.setItemAsync(PUSH_TOKEN_KEY, pushToken);
		emitPushToken(chatId, pushToken);
	} catch {
		// Ignore push-token synchronization failures.
	}
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
					// Ignore duplicate activity cleanup failures.
				}
			}),
		);
	}

	return activeActivity;
}

const clearScheduledFlush = (): void => {
	if (!flushTimeout) {
		return;
	}

	clearTimeout(flushTimeout);
	flushTimeout = null;
};

const clearHeartbeat = (): void => {
	if (!heartbeatInterval) {
		return;
	}

	clearInterval(heartbeatInterval);
	heartbeatInterval = null;
};

const ensureHeartbeat = (): void => {
	if (
		heartbeatInterval
		|| !activeState
		|| activeState.remoteManaged
		|| isTerminalPhase(activeState.phase)
		|| currentAppState !== "active"
	) {
		return;
	}

	heartbeatInterval = setInterval(() => {
		void queueStateUpdate();
	}, LOCAL_HEARTBEAT_INTERVAL_MS);
};

const flushStateUpdate = async (input?: { force?: boolean }): Promise<void> => {
	if (!activeState || activeState.remoteManaged || isTerminalPhase(activeState.phase)) {
		return;
	}

	if (writeInFlight) {
		if (input?.force) {
			pendingForceWrite = true;
		}
		writeAgain = true;
		return;
	}

	writeInFlight = true;
	const activity = await normalizeActivityInstance();
	if (!activity || !activeState || isTerminalPhase(activeState.phase)) {
		// eslint-disable-next-line require-atomic-updates
		writeInFlight = false;
		if (writeAgain || pendingForceWrite) {
			writeAgain = false;
			void queueStateUpdate({
				force: pendingForceWrite,
			});
		}
		return;
	}

	const force = (input?.force ?? false) || pendingForceWrite;
	const elapsedSinceLastUpdate = nowMs() - lastContentUpdateAtMs;
	if (!force && lastContentUpdateAtMs > 0 && elapsedSinceLastUpdate < LOCAL_UPDATE_MIN_INTERVAL_MS) {
		// eslint-disable-next-line require-atomic-updates
		writeInFlight = false;
		void queueStateUpdate();
		return;
	}

	const signature = toContentSignature(activeState);
	if (!force && signature === lastContentSignature) {
		// eslint-disable-next-line require-atomic-updates
		writeInFlight = false;
		return;
	}

	pendingForceWrite = false;
	try {
		await activity.update(toProps(activeState));
		// eslint-disable-next-line require-atomic-updates
		lastContentSignature = signature;
		// eslint-disable-next-line require-atomic-updates
		lastContentUpdateAtMs = nowMs();
	} catch {
		// Ignore runtime update failures.
	} finally {
		// eslint-disable-next-line require-atomic-updates
		writeInFlight = false;
		if (writeAgain) {
			writeAgain = false;
			void queueStateUpdate({
				force: pendingForceWrite,
			});
		}
	}
};

async function queueStateUpdate(input?: { immediate?: boolean; force?: boolean }): Promise<void> {
	if (!activeState || activeState.remoteManaged || isTerminalPhase(activeState.phase)) {
		return;
	}

	if (input?.force) {
		pendingForceWrite = true;
	}

	if (input?.immediate) {
		clearScheduledFlush();
		await flushStateUpdate({
			force: true,
		});
		return;
	}

	if (flushTimeout) {
		return;
	}

	const elapsedSinceLastUpdate = nowMs() - lastContentUpdateAtMs;
	const delayMs = lastContentUpdateAtMs <= 0
		? 0
		: Math.max(0, LOCAL_UPDATE_MIN_INTERVAL_MS - elapsedSinceLastUpdate);

	flushTimeout = setTimeout(() => {
		flushTimeout = null;
		void flushStateUpdate();
	}, delayMs);
}

const resetRuntimeState = async (): Promise<void> => {
	clearScheduledFlush();
	clearHeartbeat();
	detachActivityPushTokenSubscription();
	activeActivity = null;
	activeState = null;
	writeInFlight = false;
	writeAgain = false;
	pendingForceWrite = false;
	lastContentSignature = "";
	lastContentUpdateAtMs = 0;
	lastStatePersistAtMs = 0;
	await persistActiveState();
};

export const initializeThreadLiveActivityManager = async (): Promise<void> => {
	if (!canUseLiveActivities() || initialized) {
		return;
	}

	try {
		initialized = true;
		await hydratePersistedState();
		await normalizeActivityInstance();
		await syncCurrentActivityPushToken();

		if (activeState && !isTerminalPhase(activeState.phase)) {
			if (activeState.remoteManaged) {
				clearHeartbeat();
				clearScheduledFlush();
			} else {
				ensureHeartbeat();
				await queueStateUpdate({
					immediate: true,
					force: true,
				});
			}
		}

		pushToStartTokenSubscription ||= addPushToStartTokenListener((event) => {
			void SecureStore.setItemAsync(PUSH_TO_START_TOKEN_KEY, event.activityPushToStartToken);
		});
	} catch {
		liveActivitiesUnavailable = true;
		await resetRuntimeState();
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

	if (activeState && activeState.chatId !== input.chatId) {
		await clearThreadLiveActivity({
			chatId: activeState.chatId,
		});
	}

	const hasExplicitStartTime =
		typeof input.startedAtMs === "number" && Number.isFinite(input.startedAtMs) && input.startedAtMs > 0;
	let startedAtMs = nowMs();
	if (hasExplicitStartTime) {
		startedAtMs = Math.floor(input.startedAtMs ?? startedAtMs);
	} else if (activeState?.chatId === input.chatId && !input.restart) {
		startedAtMs = activeState.startedAtMs;
	} else {
		startedAtMs = nowMs();
	}

	activeState = {
		chatId: input.chatId,
		chatTitle: withDefault(input.chatTitle, activeState?.chatId === input.chatId ? activeState.chatTitle : "Thread"),
		phase: "running",
		preview: withDefault(input.preview, "Waiting for updates..."),
		startedAtMs,
		statusLine: withDefault(input.statusLine, "Running"),
		remoteManaged: Boolean(input.remoteManaged),
	};
	await persistActiveState();
	if (activeState.remoteManaged) {
		clearHeartbeat();
		clearScheduledFlush();
	} else {
		ensureHeartbeat();
	}

	const existing = await normalizeActivityInstance();
	if (existing) {
		if (!activeState.remoteManaged) {
			await queueStateUpdate({
				immediate: true,
				force: true,
			});
		}
		await syncCurrentActivityPushToken();
		return;
	}

	try {
		activeActivity = threadLiveActivityFactory.start(
			toProps(activeState),
			`remotecode-mobile://chat?chatId=${encodeURIComponent(activeState.chatId)}`,
		);
		attachActivityPushTokenSubscription(activeActivity);
		lastContentSignature = toContentSignature(activeState);
		lastContentUpdateAtMs = nowMs();
		await syncCurrentActivityPushToken();
	} catch {
		// Ignore startup failures to keep app flow resilient.
	}
};

export const updateThreadLiveActivity = async (input: LiveActivityUpdateInput): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	if (!activeState || activeState.chatId !== input.chatId) {
		return;
	}
	if (activeState.remoteManaged) {
		return;
	}

	const nextState: PersistedLiveActivityState = {
		...activeState,
		chatTitle: withDefault(input.chatTitle, activeState.chatTitle),
		phase: input.phase ?? activeState.phase,
		preview: withDefault(input.preview, activeState.preview),
		statusLine: withDefault(input.statusLine, activeState.statusLine),
	};
	const shouldPersistState =
		Boolean(input.force)
		|| nextState.chatTitle !== activeState.chatTitle
		|| nextState.phase !== activeState.phase
		|| nextState.statusLine !== activeState.statusLine
		|| nowMs() - lastStatePersistAtMs >= LOCAL_UPDATE_MIN_INTERVAL_MS;
	activeState = nextState;
	if (shouldPersistState) {
		await persistActiveState();
	}
	if (isTerminalPhase(nextState.phase)) {
		clearHeartbeat();
		clearScheduledFlush();
	} else {
		ensureHeartbeat();
	}
	await queueStateUpdate({
		force: input.force,
		immediate: false,
	});
};

export const finishThreadLiveActivity = async (input: LiveActivityFinishInput): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	if (!activeState || activeState.chatId !== input.chatId) {
		return;
	}

	if (finishingChatId === input.chatId) {
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
		chatTitle: withDefault(input.chatTitle, activeState.chatTitle),
		phase: outcomePhase,
		preview: withDefault(input.preview, activeState.preview),
		startedAtMs: activeState.startedAtMs,
		statusLine: withDefault(input.statusLine, defaultStatusLine),
		remoteManaged: activeState.remoteManaged,
	};

	try {
		clearHeartbeat();
		clearScheduledFlush();
		activeState = finalState;
		await persistActiveState();

		const activity = await normalizeActivityInstance();
		if (activity) {
			try {
				await activity.update(toProps(finalState));
			} catch {
				// Ignore final update failures.
			}

			try {
				await activity.end("default", toProps(finalState));
			} catch {
				// Ignore completion failures.
			}
		}
	} finally {
		await resetRuntimeState();
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
	if (!activeState || activeState.chatId !== input.chatId) {
		return;
	}

	clearHeartbeat();
	clearScheduledFlush();
	const activity = await normalizeActivityInstance();
	if (activity) {
		try {
			await activity.end("immediate");
		} catch {
			// Ignore cleanup failures.
		}
	}

	await resetRuntimeState();
};

export const onThreadLiveActivityAppStateChanged = async (nextState: AppStateStatus): Promise<void> => {
	currentAppState = nextState;

	if (!canUseLiveActivities() || !activeState) {
		return;
	}

	if (isTerminalPhase(activeState.phase)) {
		return;
	}
	if (activeState.remoteManaged) {
		clearHeartbeat();
		clearScheduledFlush();
		return;
	}

	if (nextState === "background" || nextState === "inactive") {
		clearHeartbeat();
		await updateThreadLiveActivity({
			chatId: activeState.chatId,
			phase: "background",
			statusLine: "Running in background",
			force: false,
		});
		return;
	}

	if (nextState === "active") {
		ensureHeartbeat();
		await updateThreadLiveActivity({
			chatId: activeState.chatId,
			phase: "running",
			statusLine: "Running",
			force: false,
		});
	}
};

export const isThreadLiveActivityEnabled = (): boolean => canUseLiveActivities();

export const setThreadLiveActivityRemoteManaged = async (input: {
	chatId: string;
	remoteManaged: boolean;
}): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	if (!activeState || activeState.chatId !== input.chatId) {
		return;
	}

	if (activeState.remoteManaged === input.remoteManaged) {
		return;
	}

	activeState = {
		...activeState,
		remoteManaged: input.remoteManaged,
	};
	await persistActiveState();

	if (input.remoteManaged) {
		clearHeartbeat();
		clearScheduledFlush();
		return;
	}

	ensureHeartbeat();
	await queueStateUpdate({
		immediate: true,
		force: true,
	});
};

export const subscribeThreadLiveActivityPushToken = (
	listener: (event: LiveActivityPushTokenUpdate) => void,
): (() => void) => {
	pushTokenListeners.add(listener);
	return () => {
		pushTokenListeners.delete(listener);
	};
};

export const getThreadLiveActivityStateForBackgroundTask = (): PersistedLiveActivityState | null => activeState;
