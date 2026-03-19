import * as SecureStore from "expo-secure-store";
import * as Haptics from "expo-haptics";
import { Platform, type AppStateStatus } from "react-native";

import {
	endNativeLiveActivity,
	getCurrentNativeLiveActivityInfo,
	getNativePushToStartToken,
	isNativeLiveActivityBridgeAvailable,
	startNativeLiveActivity,
	subscribeNativeLiveActivityPushToken,
	subscribeNativePushToStartToken,
	updateNativeLiveActivity,
} from "./live-activity-native-bridge";
import { persistGlobalLiveActivitySharedSnapshot } from "./live-activity-shared-bridge";
import { toLiveActivitySharedSnapshot } from "./live-activity-shared-snapshot";
import type {
	ThreadLiveActivityPhase,
	ThreadLiveActivityProps,
} from "./thread-live-activity.types";

const LOG_PREFIX = "[thread-live-activity]";
const ACTIVE_STATE_KEY = "remotecode.live_activity.active_state";
const PUSH_TOKEN_KEY = "remotecode.live_activity.push_token";
const PUSH_TO_START_TOKEN_KEY = "remotecode.live_activity.push_to_start_token";
const GLOBAL_ACTIVITY_CHAT_ID = "active-threads";
const GLOBAL_ACTIVITY_TITLE = "Active Threads";
const GLOBAL_ACTIVITY_DEEP_LINK = "remotecode-mobile://active-threads";
const LOCAL_CONTENT_UPDATE_MIN_INTERVAL_MS = 1_000;
const LOCAL_HEARTBEAT_INTERVAL_MS = 5_000;
const LOCAL_STATE_PERSIST_MIN_INTERVAL_MS = 5_000;
const PREVIEW_LIMIT = 140;
const TITLE_LIMIT = 80;
const STATUS_LIMIT = 80;
const PREVIEW_ELLIPSIS = "...";
const MIN_IOS_LIVE_ACTIVITIES_MAJOR = 16;
const MIN_IOS_LIVE_ACTIVITIES_MINOR = 1;
const AUTHORITATIVE_SYNC_GRACE_PERIOD_MS = 1_000;
const PERSISTED_STATE_VERSION = 2;
const MARKDOWN_CODE_FENCE_PATTERN = /```[\s\S]*?```/gu;
const INLINE_CODE_PATTERN = /`[^`]*`/gu;
const STRUCTURAL_CODE_CHARACTER_PATTERN = /[<>{}[\]\\|=]/gu;
const PREVIEW_ALLOWED_PATTERN = /[^\p{Letter}\p{Number}\p{Space_Separator}'.,;:!?@#%&+\-_/()]/gu;
const TITLE_STATUS_ALLOWED_PATTERN = /[^\p{Letter}\p{Number}\p{Space_Separator}'.,;:!?@#%&+\-_/()]/gu;

interface Subscription {
	remove: () => void;
}

interface PersistedLiveActivityState {
	activityId?: string | null;
	chatId: string;
	chatTitle: string;
	phase: ThreadLiveActivityPhase;
	preview: string;
	startedAtMs: number;
	elapsedSecondsSnapshot?: number | null;
	statusLine: string;
	remoteManaged: boolean;
	subscriptionChatId?: string | null;
}

type TrackedChatPhase = Exclude<ThreadLiveActivityPhase, "background">;
type TerminalOutcome = Extract<TrackedChatPhase, "completed" | "failed" | "error">;

interface TrackedChatState {
	chatId: string;
	phase: TrackedChatPhase;
	remoteManaged: boolean;
	sequence: number;
}

interface PersistedManagerState {
	version: number;
	renderedState: PersistedLiveActivityState | null;
	sessionWorstOutcome?: TerminalOutcome | null;
	trackedChats: TrackedChatState[];
	nextTrackedChatSequence: number;
}

interface ActivityEntry {
	state: PersistedLiveActivityState;
	lastContentSignature: string;
	lastContentUpdateAtMs: number;
	lastStatePersistAtMs: number;
	writeInFlight: boolean;
	writeAgain: boolean;
	pendingForceWrite: boolean;
	flushTimeout: ReturnType<typeof setTimeout> | null;
	awaitingAuthoritativeSync: boolean;
	awaitingAuthoritativeSyncStartedAtMs: number;
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
	authoritative?: boolean;
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
let pushToStartTokenSubscription: Subscription | null = null;
let pushTokenSubscription: Subscription | null = null;
let heartbeatInterval: ReturnType<typeof setInterval> | null = null;
let currentAppState: AppStateStatus = "active";
let renderedEntry: ActivityEntry | null = null;
let nextTrackedChatSequence = 1;
let sessionWorstOutcome: TerminalOutcome | null = null;
const trackedChats = new Map<string, TrackedChatState>();
const pushTokenListeners = new Set<(event: LiveActivityPushTokenUpdate) => void>();
const pushToStartTokenListeners = new Set<(token: string) => void>();

const nowMs = (): number => Date.now();

const toTokenPreview = (token: string): string => (
	token.length <= 16
		? token
		: `${token.slice(0, 8)}...${token.slice(-4)}`
);

const log = (message: string, meta?: Record<string, unknown>): void => {
	if (meta) {
		console.log(LOG_PREFIX, message, meta);
		return;
	}

	console.log(LOG_PREFIX, message);
};

const withDefault = (value: string | undefined, fallback: string): string => {
	const trimmed = value?.trim();
	return trimmed && trimmed.length > 0 ? trimmed : fallback;
};

const withOptionalValue = (value: string | null | undefined): string | null => {
	const trimmed = value?.trim();
	return trimmed && trimmed.length > 0 ? trimmed : null;
};

type LiveActivityTextField = "preview" | "status" | "title";

const toCodePointHead = (value: string, maxLength: number): string => {
	if (maxLength <= 0) {
		return "";
	}

	let count = 0;
	let result = "";
	for (const point of value) {
		if (count >= maxLength) {
			break;
		}

		result += point;
		count += 1;
	}

	return result;
};

const toNormalizedWhitespace = (value: string): string => value.replaceAll(/\s+/gu, " ").trim();

const toFieldAllowPattern = (field: LiveActivityTextField): RegExp =>
	field === "preview" ? PREVIEW_ALLOWED_PATTERN : TITLE_STATUS_ALLOWED_PATTERN;

const withOptionalEllipsis = (value: string, maxLength: number, field: LiveActivityTextField): string => {
	if (field !== "preview") {
		return toCodePointHead(value, maxLength);
	}

	let pointCount = 0;
	for (const ignore of value) {
		void ignore;
		pointCount += 1;
	}

	if (pointCount <= maxLength) {
		return value;
	}
	if (maxLength <= PREVIEW_ELLIPSIS.length) {
		return PREVIEW_ELLIPSIS.slice(0, maxLength);
	}

	return `${toCodePointHead(value, maxLength - PREVIEW_ELLIPSIS.length)}${PREVIEW_ELLIPSIS}`;
};

const stripAnsiSequences = (value: string): string => {
	let result = "";
	for (let index = 0; index < value.length; index += 1) {
		const current = value.codePointAt(index);
		if (current !== 27) {
			result += value[index] ?? "";
			continue;
		}

		if ((value[index + 1] ?? "") !== "[") {
			result += " ";
			continue;
		}

		index += 2;
		while (index < value.length) {
			const next = value.codePointAt(index);
			if (next === undefined) {
				break;
			}
			if ((next >= 65 && next <= 90) || (next >= 97 && next <= 122)) {
				break;
			}
			index += 1;
		}

		result += " ";
	}

	return result;
};

const stripUnsafeCharacters = (value: string): string => {
	let result = "";
	for (const point of value) {
		const codePoint = point.codePointAt(0);
		if (codePoint === undefined) {
			continue;
		}

		const isControl =
			(codePoint >= 0x00 && codePoint <= 0x08)
			|| (codePoint >= 0x0B && codePoint <= 0x1F)
			|| codePoint === 0x7F;
		const isInvisibleFormat =
			(codePoint >= 0x200B && codePoint <= 0x200F)
			|| (codePoint >= 0x202A && codePoint <= 0x202E)
			|| (codePoint >= 0x2060 && codePoint <= 0x206F)
			|| codePoint === 0xFEFF;
		const isBrokenSurrogate = codePoint >= 0xD800 && codePoint <= 0xDFFF;

		result += isControl || isInvisibleFormat || isBrokenSurrogate ? " " : point;
	}

	return result;
};

const toSafeLiveActivityText = (value: string | undefined, maxLength: number, field: LiveActivityTextField): string => {
	if (maxLength <= 0) {
		return "";
	}

	const normalizedValue = String(value ?? "").normalize("NFKC");
	const withoutAnsi = stripAnsiSequences(normalizedValue);
	const withoutControlChars = stripUnsafeCharacters(withoutAnsi);
	const withoutCodeFrames = withoutControlChars
		.replaceAll(MARKDOWN_CODE_FENCE_PATTERN, " ")
		.replaceAll(INLINE_CODE_PATTERN, " ")
		.replaceAll(STRUCTURAL_CODE_CHARACTER_PATTERN, " ");
	const asciiSafeQuotes = withoutCodeFrames
		.replaceAll(/[\u2018\u2019]/gu, "'")
		.replaceAll(/[\u201C\u201D]/gu, "\"");
	const fieldOnlyAllowed = asciiSafeQuotes.replaceAll(toFieldAllowPattern(field), " ");
	const collapsedWhitespace = toNormalizedWhitespace(fieldOnlyAllowed);
	if (collapsedWhitespace.length === 0) {
		return "";
	}

	return toNormalizedWhitespace(withOptionalEllipsis(collapsedWhitespace, maxLength, field));
};

const sanitizeTitle = (value: string | undefined, fallback: string): string =>
	withDefault(toSafeLiveActivityText(value, TITLE_LIMIT, "title"), fallback);

const sanitizeStatusLine = (value: string | undefined, fallback: string): string =>
	withDefault(toSafeLiveActivityText(value, STATUS_LIMIT, "status"), fallback);

const sanitizePreview = (value: string | undefined, fallback: string): string =>
	withDefault(toSafeLiveActivityText(value, PREVIEW_LIMIT, "preview"), fallback);

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

const canUseLiveActivities = (): boolean =>
	!liveActivitiesUnavailable
	&& isSupportedIosVersion()
	&& isNativeLiveActivityBridgeAvailable();

const hasAuthoritativeSyncTimedOut = (entry: ActivityEntry): boolean => (
	entry.awaitingAuthoritativeSync
	&& entry.awaitingAuthoritativeSyncStartedAtMs > 0
	&& (nowMs() - entry.awaitingAuthoritativeSyncStartedAtMs) >= AUTHORITATIVE_SYNC_GRACE_PERIOD_MS
);

const hasEntryBinding = (): boolean =>
	Boolean(withOptionalValue(renderedEntry?.state.activityId));

const isTerminalPhase = (phase: ThreadLiveActivityPhase): boolean =>
	phase === "completed" || phase === "failed" || phase === "error";

const isTrackedTerminalPhase = (phase: TrackedChatPhase): phase is TerminalOutcome =>
	phase === "completed" || phase === "failed" || phase === "error";

const toElapsedSeconds = (startedAtMs: number): number => {
	const started = Number.isFinite(startedAtMs) && startedAtMs > 0 ? startedAtMs : nowMs();
	const deltaMs = Math.max(0, nowMs() - started);
	return Math.floor(deltaMs / 1_000);
};

const toElapsedSecondsForState = (state: PersistedLiveActivityState): number => {
	if (isTerminalPhase(state.phase) && typeof state.elapsedSecondsSnapshot === "number" && state.elapsedSecondsSnapshot >= 0) {
		return Math.floor(state.elapsedSecondsSnapshot);
	}

	return toElapsedSeconds(state.startedAtMs);
};

const toProps = (state: PersistedLiveActivityState): ThreadLiveActivityProps => ({
	chatId: state.chatId,
	chatTitle: sanitizeTitle(state.chatTitle, GLOBAL_ACTIVITY_TITLE),
	elapsedSeconds: toElapsedSecondsForState(state),
	phase: state.phase,
	preview: sanitizePreview(state.preview, "Waiting for updates..."),
	statusLine: sanitizeStatusLine(state.statusLine, "Generating response"),
});

const toContentSignature = (state: PersistedLiveActivityState): string => {
	const props = toProps(state);
	return [
		props.chatId,
		props.chatTitle,
		String(props.elapsedSeconds),
		props.phase,
		props.statusLine,
		props.preview,
		withOptionalValue(state.subscriptionChatId) ?? "",
	].join("\u0001");
};

const toTrackedPhase = (phase: ThreadLiveActivityPhase | undefined): TrackedChatPhase => {
	if (
		phase === "completed"
		|| phase === "error"
		|| phase === "failed"
		|| phase === "finalizing"
	) {
		return phase;
	}

	return "running";
};

const toTerminalOutcomeSeverity = (outcome: TerminalOutcome | null): number => {
	if (outcome === "completed") {
		return 1;
	}
	if (outcome === "error") {
		return 3;
	}
	if (outcome === "failed") {
		return 2;
	}

	return 0;
};

const toWorstOutcome = (left: TerminalOutcome | null, right: TerminalOutcome | null): TerminalOutcome | null => (
	toTerminalOutcomeSeverity(right) > toTerminalOutcomeSeverity(left)
		? right
		: left
);

const toTrackedChatsSorted = (): TrackedChatState[] => Array.from(trackedChats.values()).sort((left, right) => left.sequence - right.sequence);

const selectSubscriptionChatId = (preferredChatId: string | null): string | null => {
	if (preferredChatId && trackedChats.has(preferredChatId)) {
		return preferredChatId;
	}

	return toTrackedChatsSorted()[0]?.chatId ?? null;
};

const toRunningStatusLine = (count: number): string =>
	count === 1 ? "1 thread active" : `${String(count)} threads active`;

const toRunningPreview = (count: number): string =>
	count === 1
		? "RemoteCode is working on 1 active thread."
		: `RemoteCode is working on ${String(count)} active threads.`;

const toFinalizingStatusLine = (count: number): string =>
	count === 1 ? "Finalizing 1 thread" : `Finalizing ${String(count)} threads`;

const toFinalizingPreview = (count: number): string =>
	count === 1
		? "RemoteCode is wrapping up the remaining thread."
		: `RemoteCode is wrapping up the remaining threads.`;

const toTerminalStatusLine = (outcome: TerminalOutcome): string => {
	if (outcome === "error") {
		return "At least one thread ended with an error";
	}
	if (outcome === "failed") {
		return "At least one thread failed";
	}

	return "All threads completed";
};

const toTrackedCounts = (): {
	activeCount: number;
	finalizingCount: number;
	runningCount: number;
} => {
	let runningCount = 0;
	let finalizingCount = 0;

	for (const trackedChat of trackedChats.values()) {
		if (trackedChat.phase === "running") {
			runningCount += 1;
		}
		if (trackedChat.phase === "finalizing") {
			finalizingCount += 1;
		}
	}

	return {
		activeCount: runningCount + finalizingCount,
		finalizingCount,
		runningCount,
	};
};

const createEntry = (state: PersistedLiveActivityState): ActivityEntry => ({
	state,
	lastContentSignature: "",
	lastContentUpdateAtMs: 0,
	lastStatePersistAtMs: 0,
	writeInFlight: false,
	writeAgain: false,
	pendingForceWrite: false,
	flushTimeout: null,
	awaitingAuthoritativeSync: state.remoteManaged && !isTerminalPhase(state.phase),
	awaitingAuthoritativeSyncStartedAtMs: state.remoteManaged && !isTerminalPhase(state.phase) ? nowMs() : 0,
});

const resetInitializationFailureState = (): void => {
	renderedEntry = null;
	trackedChats.clear();
	nextTrackedChatSequence = 1;
	initialized = false;
};

const syncSharedSnapshot = async (state: PersistedLiveActivityState | null): Promise<void> => {
	if (!state) {
		await persistGlobalLiveActivitySharedSnapshot(null);
		return;
	}

	const counts = toTrackedCounts();
	await persistGlobalLiveActivitySharedSnapshot(
		toLiveActivitySharedSnapshot({
			counts: {
				activeCount: counts.activeCount,
				finalizingCount: counts.finalizingCount,
				runningCount: counts.runningCount,
			},
			deepLink: GLOBAL_ACTIVITY_DEEP_LINK,
			nowMs: nowMs(),
			state,
		}),
	);
};

const getCurrentSubscriptionChatId = (): string | null =>
	withOptionalValue(renderedEntry?.state.subscriptionChatId);

const emitPushToken = (pushToken: string): void => {
	const chatId = getCurrentSubscriptionChatId();
	if (!chatId) {
		return;
	}

	log("push token emitted", {
		chatId,
		pushToken: toTokenPreview(pushToken),
	});
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

const emitPersistedPushTokenIfAvailable = async (): Promise<void> => {
	try {
		const pushToken = withDefault(await SecureStore.getItemAsync(PUSH_TOKEN_KEY) ?? "", "");
		if (pushToken.length === 0) {
			return;
		}

		log("reusing persisted activity push token", {
			chatId: getCurrentSubscriptionChatId(),
			pushToken: toTokenPreview(pushToken),
		});
		emitPushToken(pushToken);
	} catch {
		// Ignore persisted push-token reuse failures.
	}
};

const detachPushTokenSubscription = (): void => {
	if (!pushTokenSubscription) {
		return;
	}

	pushTokenSubscription.remove();
	pushTokenSubscription = null;
};

const syncNativePushToken = async (pushToken: string | null | undefined): Promise<void> => {
	const normalizedPushToken = withDefault(pushToken ?? "", "");
	if (normalizedPushToken.length === 0) {
		return;
	}

	await SecureStore.setItemAsync(PUSH_TOKEN_KEY, normalizedPushToken);
	log("activity push token synchronized", {
		chatId: getCurrentSubscriptionChatId(),
		pushToken: toTokenPreview(normalizedPushToken),
	});
	emitPushToken(normalizedPushToken);
};

const persistManagerState = async (): Promise<void> => {
	const stateToPersist = renderedEntry?.state ?? null;
	if (!stateToPersist && trackedChats.size === 0) {
		await SecureStore.deleteItemAsync(ACTIVE_STATE_KEY);
		await syncSharedSnapshot(null);
		return;
	}

	const payload: PersistedManagerState = {
		version: PERSISTED_STATE_VERSION,
		renderedState: stateToPersist,
		sessionWorstOutcome,
		trackedChats: toTrackedChatsSorted(),
		nextTrackedChatSequence,
	};
	await SecureStore.setItemAsync(ACTIVE_STATE_KEY, JSON.stringify(payload));
	if (renderedEntry) {
		renderedEntry.lastStatePersistAtMs = nowMs();
	}
	await syncSharedSnapshot(stateToPersist);
};

const sanitizeTrackedChatState = (value: Partial<TrackedChatState>, sequence: number): TrackedChatState | null => {
	const chatId = withDefault(value.chatId, "");
	if (chatId.length === 0) {
		return null;
	}

	return {
		chatId,
		phase: toTrackedPhase(value.phase),
		remoteManaged: value.remoteManaged !== false,
		sequence: typeof value.sequence === "number" && Number.isFinite(value.sequence) && value.sequence > 0
			? Math.floor(value.sequence)
			: sequence,
	};
};

const sanitizeRenderedState = (value: Partial<PersistedLiveActivityState> | null | undefined): PersistedLiveActivityState | null => {
	if (!value) {
		return null;
	}

	const phase = value.phase ?? "running";
	return {
		activityId: withOptionalValue(value.activityId),
		chatId: GLOBAL_ACTIVITY_CHAT_ID,
		chatTitle: GLOBAL_ACTIVITY_TITLE,
		phase,
		preview: sanitizePreview(value.preview, "Waiting for updates..."),
		startedAtMs:
			typeof value.startedAtMs === "number" && Number.isFinite(value.startedAtMs) && value.startedAtMs > 0
				? Math.floor(value.startedAtMs)
				: nowMs(),
		elapsedSecondsSnapshot:
			typeof value.elapsedSecondsSnapshot === "number" && Number.isFinite(value.elapsedSecondsSnapshot) && value.elapsedSecondsSnapshot >= 0
				? Math.floor(value.elapsedSecondsSnapshot)
				: null,
		statusLine: sanitizeStatusLine(value.statusLine, "Generating response"),
		remoteManaged: value.remoteManaged !== false,
		subscriptionChatId: withOptionalValue(value.subscriptionChatId),
	};
};

const hydratePersistedState = async (): Promise<void> => {
	const raw = await SecureStore.getItemAsync(ACTIVE_STATE_KEY);
	if (!raw) {
		return;
	}

	try {
		const parsed = JSON.parse(raw) as unknown;
		if (Array.isArray(parsed)) {
			sessionWorstOutcome = null;
			let sequence = 1;
			for (const item of parsed) {
				if (!item || typeof item !== "object") {
					continue;
				}
				const trackedChat = sanitizeTrackedChatState(item as Partial<TrackedChatState>, sequence);
				if (!trackedChat || trackedChat.chatId === GLOBAL_ACTIVITY_CHAT_ID) {
					continue;
				}
				trackedChats.set(trackedChat.chatId, trackedChat);
				sequence = Math.max(sequence, trackedChat.sequence + 1);
			}
			nextTrackedChatSequence = sequence;
			return;
		}

		if (!parsed || typeof parsed !== "object") {
			return;
		}

		const persisted = parsed as Partial<PersistedManagerState>;
		const tracked = Array.isArray(persisted.trackedChats) ? persisted.trackedChats : [];
		let nextSequence = 1;
		for (const item of tracked) {
			const trackedChat = sanitizeTrackedChatState(item, nextSequence);
			if (!trackedChat) {
				continue;
			}
			trackedChats.set(trackedChat.chatId, trackedChat);
			nextSequence = Math.max(nextSequence, trackedChat.sequence + 1);
		}
		nextTrackedChatSequence =
			typeof persisted.nextTrackedChatSequence === "number"
			&& Number.isFinite(persisted.nextTrackedChatSequence)
			&& persisted.nextTrackedChatSequence > 0
				? Math.max(nextSequence, Math.floor(persisted.nextTrackedChatSequence))
				: nextSequence;
		const persistedSessionWorstOutcome = persisted.sessionWorstOutcome;
		sessionWorstOutcome =
			persistedSessionWorstOutcome === "completed"
			|| persistedSessionWorstOutcome === "failed"
			|| persistedSessionWorstOutcome === "error"
				? persistedSessionWorstOutcome
				: null;

		const sanitizedState = sanitizeRenderedState(persisted.renderedState);
		if (sanitizedState) {
			renderedEntry = createEntry(sanitizedState);
		}
	} catch {
		// Ignore malformed persisted state.
	}
};

const syncCurrentNativeActivity = async (): Promise<boolean> => {
	const entry = renderedEntry;
	if (!entry) {
		return false;
	}

	const nativeInfo = await getCurrentNativeLiveActivityInfo();
	if (!nativeInfo?.activityId) {
		if (entry.state.activityId) {
			log("bound activity instance missing; clearing binding", {
				chatId: GLOBAL_ACTIVITY_CHAT_ID,
			});
		}
		entry.state = {
			...entry.state,
			activityId: null,
		};
		await persistManagerState();
		return false;
	}

	entry.state = {
		...entry.state,
		activityId: nativeInfo.activityId,
	};
	await persistManagerState();
	await syncNativePushToken(nativeInfo.pushToken);
	return true;
};

const startActivityInstance = async (): Promise<boolean> => {
	if (!renderedEntry) {
		return false;
	}

	try {
		const nativeInfo = await startNativeLiveActivity(
			toProps(renderedEntry.state),
			GLOBAL_ACTIVITY_DEEP_LINK,
		);
		renderedEntry.state = {
			...renderedEntry.state,
			activityId: nativeInfo?.activityId ?? null,
		};
		log("activity instance started", { chatId: GLOBAL_ACTIVITY_CHAT_ID });
		renderedEntry.lastContentSignature = toContentSignature(renderedEntry.state);
		renderedEntry.lastContentUpdateAtMs = nowMs();
		await persistManagerState();
		await syncNativePushToken(nativeInfo?.pushToken);
		return Boolean(nativeInfo?.activityId);
	} catch {
		log("activity instance start failed", { chatId: GLOBAL_ACTIVITY_CHAT_ID });
		if (renderedEntry) {
			renderedEntry.state = {
				...renderedEntry.state,
				activityId: null,
			};
			await persistManagerState();
		}
		return false;
	}
};

const acquireActivityInstance = async (
	input?: { allowCreate?: boolean },
): Promise<boolean> => {
	if (!renderedEntry) {
		return false;
	}

	const resolved = await syncCurrentNativeActivity();
	if (resolved) {
		return resolved;
	}

	if (input?.allowCreate === false) {
		return false;
	}

	return await startActivityInstance();
};

const clearEntryFlush = (): void => {
	if (!renderedEntry?.flushTimeout) {
		return;
	}

	clearTimeout(renderedEntry.flushTimeout);
	renderedEntry.flushTimeout = null;
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
		|| !renderedEntry
		|| isTerminalPhase(renderedEntry.state.phase)
		|| !hasEntryBinding()
	) {
		return;
	}

	heartbeatInterval = setInterval(() => {
		void queueEntryStateUpdate();
	}, LOCAL_HEARTBEAT_INTERVAL_MS);
};

const flushEntryStateUpdate = async (input?: { force?: boolean }): Promise<void> => {
	const entry = renderedEntry;
	if (!entry) {
		return;
	}

	if (entry.writeInFlight) {
		if (input?.force) {
			entry.pendingForceWrite = true;
		}
		entry.writeAgain = true;
		return;
	}

	entry.writeInFlight = true;
	const hadBindingBeforeAcquire = hasEntryBinding();
	const allowCreate = !isTerminalPhase(entry.state.phase);
	const hasActivity = await acquireActivityInstance({ allowCreate });
	const currentEntry = renderedEntry;
	if (!currentEntry) {
		return;
	}

	if (!hasActivity) {
		currentEntry.writeInFlight = false;
		if (currentEntry.writeAgain || currentEntry.pendingForceWrite) {
			currentEntry.writeAgain = false;
			void queueEntryStateUpdate({
				force: currentEntry.pendingForceWrite,
			});
		}
		return;
	}

	const shouldWriteContentLocally =
		!currentEntry.state.remoteManaged
		|| !hadBindingBeforeAcquire
		|| !currentEntry.awaitingAuthoritativeSync
		|| hasAuthoritativeSyncTimedOut(currentEntry);
	if (!shouldWriteContentLocally) {
		currentEntry.pendingForceWrite = false;
		currentEntry.writeInFlight = false;
		if (currentEntry.writeAgain) {
			currentEntry.writeAgain = false;
			void queueEntryStateUpdate({
				force: currentEntry.pendingForceWrite,
			});
		}
		return;
	}

	const force = (input?.force ?? false) || currentEntry.pendingForceWrite;
	const elapsedSinceLastUpdate = nowMs() - currentEntry.lastContentUpdateAtMs;
	if (!force && currentEntry.lastContentUpdateAtMs > 0 && elapsedSinceLastUpdate < LOCAL_CONTENT_UPDATE_MIN_INTERVAL_MS) {
		currentEntry.writeInFlight = false;
		void queueEntryStateUpdate();
		return;
	}

	const signature = toContentSignature(currentEntry.state);
	if (!force && signature === currentEntry.lastContentSignature) {
		currentEntry.writeInFlight = false;
		return;
	}

	currentEntry.pendingForceWrite = false;
	try {
		const nativeInfo = await updateNativeLiveActivity(toProps(currentEntry.state));
		const activityId = nativeInfo?.activityId ?? null;
		if (!activityId) {
			currentEntry.state = {
				...currentEntry.state,
				activityId: null,
			};
			await persistManagerState();
		}
		if (activityId && activityId !== currentEntry.state.activityId) {
			currentEntry.state = {
				...currentEntry.state,
				activityId,
			};
			await persistManagerState();
		}
		await syncNativePushToken(nativeInfo?.pushToken);
		currentEntry.lastContentSignature = signature;
		currentEntry.lastContentUpdateAtMs = nowMs();
	} catch {
		// Ignore runtime update failures.
	} finally {
		currentEntry.writeInFlight = false;
		if (currentEntry.writeAgain) {
			currentEntry.writeAgain = false;
			void queueEntryStateUpdate({
				force: currentEntry.pendingForceWrite,
			});
		}
	}
};

async function queueEntryStateUpdate(input?: { immediate?: boolean; force?: boolean }): Promise<void> {
	const entry = renderedEntry;
	if (!entry) {
		return;
	}

	if (input?.force) {
		entry.pendingForceWrite = true;
	}

	if (input?.immediate) {
		clearEntryFlush();
		await flushEntryStateUpdate({
			force: true,
		});
		return;
	}

	if (entry.flushTimeout) {
		return;
	}

	const elapsedSinceLastUpdate = nowMs() - entry.lastContentUpdateAtMs;
	const delayMs = entry.lastContentUpdateAtMs <= 0
		? 0
		: Math.max(0, LOCAL_CONTENT_UPDATE_MIN_INTERVAL_MS - elapsedSinceLastUpdate);

	entry.flushTimeout = setTimeout(() => {
		if (renderedEntry) {
			renderedEntry.flushTimeout = null;
		}
		void flushEntryStateUpdate();
	}, delayMs);
}

const upsertTrackedChatState = (input: {
	chatId: string;
	phase: TrackedChatPhase;
	remoteManaged: boolean;
	resetSession?: boolean;
}): void => {
	if (input.resetSession) {
		trackedChats.clear();
		nextTrackedChatSequence = 1;
		sessionWorstOutcome = null;
	}

	const previous = trackedChats.get(input.chatId);
	const sequence = previous?.sequence ?? nextTrackedChatSequence;
	if (!previous) {
		nextTrackedChatSequence += 1;
	}
	trackedChats.set(input.chatId, {
		chatId: input.chatId,
		phase: input.phase,
		remoteManaged: input.remoteManaged,
		sequence,
	});
};

const computeNextRenderedState = (input?: {
	preferredStartedAtMs?: number;
}): PersistedLiveActivityState | null => {
	const previousState = renderedEntry?.state ?? null;
	const { activeCount, finalizingCount, runningCount } = toTrackedCounts();

	if (trackedChats.size === 0) {
		if (!previousState) {
			return null;
		}

		if (isTerminalPhase(previousState.phase)) {
			return previousState;
		}

		return {
			...previousState,
			activityId: previousState.activityId ?? null,
			chatId: GLOBAL_ACTIVITY_CHAT_ID,
			chatTitle: GLOBAL_ACTIVITY_TITLE,
			phase: "completed",
			preview: "No active threads right now.",
			elapsedSecondsSnapshot: toElapsedSecondsForState(previousState),
			statusLine: "All threads completed",
		};
	}

	const subscriptionChatId = selectSubscriptionChatId(withOptionalValue(previousState?.subscriptionChatId));
	const remoteManaged = subscriptionChatId
		? trackedChats.get(subscriptionChatId)?.remoteManaged ?? previousState?.remoteManaged ?? true
		: previousState?.remoteManaged ?? true;
	const startingNewSession = activeCount > 0 && (!previousState || isTerminalPhase(previousState.phase));
	const startedAtMs = (() => {
		if (startingNewSession) {
			return Math.floor(input?.preferredStartedAtMs ?? nowMs());
		}
		if (typeof previousState?.startedAtMs === "number" && previousState.startedAtMs > 0) {
			return previousState.startedAtMs;
		}
		return Math.floor(input?.preferredStartedAtMs ?? nowMs());
	})();

	if (activeCount > 0) {
		const isRunning = runningCount > 0;
		const phase: ThreadLiveActivityPhase = (() => {
			if (!isRunning) {
				return "finalizing";
			}
			if (currentAppState === "background" || currentAppState === "inactive") {
				return "background";
			}
			return "running";
		})();
		const statusLine = isRunning
			? toRunningStatusLine(activeCount)
			: toFinalizingStatusLine(finalizingCount);
		const preview = isRunning
			? toRunningPreview(activeCount)
			: toFinalizingPreview(finalizingCount);

		return {
			activityId: previousState?.activityId ?? null,
			chatId: GLOBAL_ACTIVITY_CHAT_ID,
			chatTitle: GLOBAL_ACTIVITY_TITLE,
			phase,
			preview,
			startedAtMs,
			elapsedSecondsSnapshot: null,
			statusLine,
			remoteManaged,
			subscriptionChatId,
		};
	}

	const terminalOutcome = sessionWorstOutcome ?? "completed";
	const elapsedSecondsSnapshot = (() => {
		if (isTerminalPhase(previousState?.phase ?? "running")) {
			return previousState?.elapsedSecondsSnapshot ?? 0;
		}
		if (previousState) {
			return toElapsedSecondsForState(previousState);
		}
		return 0;
	})();

	return {
		activityId: previousState?.activityId ?? null,
		chatId: GLOBAL_ACTIVITY_CHAT_ID,
		chatTitle: GLOBAL_ACTIVITY_TITLE,
		phase: terminalOutcome,
		preview: "No active threads right now.",
		startedAtMs,
		elapsedSecondsSnapshot,
		statusLine: toTerminalStatusLine(terminalOutcome),
		remoteManaged,
		subscriptionChatId,
	};
};

const reconcileRenderedState = async (input?: {
	authoritative?: boolean;
	force?: boolean;
	preferredStartedAtMs?: number;
}): Promise<void> => {
	const previousState = renderedEntry?.state ?? null;
	const nextState = computeNextRenderedState({
		preferredStartedAtMs: input?.preferredStartedAtMs,
	});
	if (!nextState) {
		await persistManagerState();
		return;
	}

	const previousSubscriptionChatId = withOptionalValue(previousState?.subscriptionChatId);
	if (!renderedEntry) {
		renderedEntry = createEntry(nextState);
	} else {
		renderedEntry.state = nextState;
	}

	if (input?.authoritative || !nextState.remoteManaged || isTerminalPhase(nextState.phase)) {
		renderedEntry.awaitingAuthoritativeSync = false;
		renderedEntry.awaitingAuthoritativeSyncStartedAtMs = 0;
	}

	const shouldPersist =
		Boolean(input?.force)
		|| !previousState
		|| previousState.phase !== nextState.phase
		|| previousState.statusLine !== nextState.statusLine
		|| previousState.preview !== nextState.preview
		|| previousState.startedAtMs !== nextState.startedAtMs
		|| previousState.elapsedSecondsSnapshot !== nextState.elapsedSecondsSnapshot
		|| previousState.remoteManaged !== nextState.remoteManaged
		|| previousState.subscriptionChatId !== nextState.subscriptionChatId
		|| nowMs() - renderedEntry.lastStatePersistAtMs >= LOCAL_STATE_PERSIST_MIN_INTERVAL_MS;
	if (shouldPersist) {
		await persistManagerState();
	}

	if (previousSubscriptionChatId !== nextState.subscriptionChatId) {
		await emitPersistedPushTokenIfAvailable();
	}

	if (isTerminalPhase(nextState.phase)) {
		clearHeartbeat();
	} else {
		ensureHeartbeat();
	}

	await queueEntryStateUpdate({
		force: input?.force,
		immediate: Boolean(input?.force),
	});
};

export const initializeThreadLiveActivityManager = async (): Promise<void> => {
	if (!canUseLiveActivities() || initialized) {
		return;
	}

	try {
		initialized = true;
		await hydratePersistedState();

		if (renderedEntry) {
			await syncCurrentNativeActivity();
			if (!isTerminalPhase(renderedEntry.state.phase) && hasEntryBinding()) {
				ensureHeartbeat();
				await queueEntryStateUpdate({
					immediate: true,
					force: true,
				});
			}
		}

		pushTokenSubscription ||= {
			remove: subscribeNativeLiveActivityPushToken((event) => {
				void syncNativePushToken(event.pushToken);
			}),
		};
		pushToStartTokenSubscription ||= {
			remove: subscribeNativePushToStartToken((pushToStartToken) => {
				log("push-to-start token received", {
					pushToken: toTokenPreview(pushToStartToken),
				});
				void SecureStore.setItemAsync(PUSH_TO_START_TOKEN_KEY, pushToStartToken);
				for (const listener of pushToStartTokenListeners) {
					try {
						listener(pushToStartToken);
					} catch {
						// Keep listeners isolated.
					}
				}
			}),
		};

		const pushToStartToken = await getNativePushToStartToken();
		if (pushToStartToken) {
			log("push-to-start token received", {
				pushToken: toTokenPreview(pushToStartToken),
			});
			await SecureStore.setItemAsync(PUSH_TO_START_TOKEN_KEY, pushToStartToken);
			for (const listener of pushToStartTokenListeners) {
				try {
					listener(pushToStartToken);
				} catch {
					// Keep listeners isolated.
				}
			}
		}
	} catch {
		liveActivitiesUnavailable = true;
		resetInitializationFailureState();
	}
};

export const startThreadLiveActivity = async (input: LiveActivityStartInput): Promise<boolean> => {
	if (!canUseLiveActivities()) {
		return false;
	}

	await initializeThreadLiveActivityManager();
	const chatId = withDefault(input.chatId, "");
	if (chatId.length === 0) {
		return false;
	}

	const countsBefore = toTrackedCounts();
	const resetSession = Boolean(input.restart) || countsBefore.activeCount === 0;
	upsertTrackedChatState({
		chatId,
		phase: "running",
		remoteManaged: input.remoteManaged ?? true,
		resetSession,
	});

	await reconcileRenderedState({
		force: true,
		preferredStartedAtMs:
			typeof input.startedAtMs === "number" && Number.isFinite(input.startedAtMs) && input.startedAtMs > 0
				? Math.floor(input.startedAtMs)
				: undefined,
	});

	return hasEntryBinding();
};

export const updateThreadLiveActivity = async (input: LiveActivityUpdateInput): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	const chatId = withDefault(input.chatId, "");
	if (chatId.length === 0) {
		return;
	}

	const existing = trackedChats.get(chatId);
	if (!existing) {
		await startThreadLiveActivity({
			chatId,
			remoteManaged: true,
		});
	}

	const snapshot = trackedChats.get(chatId);
	if (!snapshot) {
		return;
	}

	trackedChats.set(chatId, {
		...snapshot,
		phase: toTrackedPhase(input.phase ?? snapshot.phase),
	});
	await reconcileRenderedState({
		authoritative: input.authoritative,
		force: input.force,
	});
};

export const finishThreadLiveActivity = async (input: LiveActivityFinishInput): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	const chatId = withDefault(input.chatId, "");
	if (chatId.length === 0) {
		return;
	}

	upsertTrackedChatState({
		chatId,
		phase: input.outcome,
		remoteManaged: trackedChats.get(chatId)?.remoteManaged ?? renderedEntry?.state.remoteManaged ?? true,
	});
	sessionWorstOutcome = toWorstOutcome(sessionWorstOutcome, input.outcome);
	await reconcileRenderedState({
		force: true,
	});

	try {
		await Haptics.notificationAsync(
			input.outcome === "completed"
				? Haptics.NotificationFeedbackType.Success
				: Haptics.NotificationFeedbackType.Error,
		);
	} catch {
		// Haptic feedback is best-effort.
	}
};

export const clearThreadLiveActivity = async (input: { chatId: string }): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	const chatId = withDefault(input.chatId, "");
	if (chatId.length === 0) {
		return;
	}

	trackedChats.delete(chatId);
	await reconcileRenderedState({
		force: true,
	});
};

export const dismissTerminalLiveActivity = async (): Promise<void> => {
	if (!canUseLiveActivities() || !renderedEntry) {
		return;
	}

	if (!isTerminalPhase(renderedEntry.state.phase)) {
		return;
	}

	clearEntryFlush();
	clearHeartbeat();
	renderedEntry = null;
	try {
		await endNativeLiveActivity(null);
	} catch {
		// Best-effort dismissal.
	}
	trackedChats.clear();
	nextTrackedChatSequence = 1;
	sessionWorstOutcome = null;
	await persistManagerState();
};

export const onThreadLiveActivityAppStateChanged = async (nextState: AppStateStatus): Promise<void> => {
	currentAppState = nextState;

	if (!canUseLiveActivities() || !renderedEntry || isTerminalPhase(renderedEntry.state.phase)) {
		return;
	}

	await reconcileRenderedState();
};

export const isThreadLiveActivityEnabled = (): boolean => canUseLiveActivities();

export const getTrackedThreadLiveActivityChatIds = async (): Promise<string[]> => {
	if (!canUseLiveActivities()) {
		return [];
	}

	await initializeThreadLiveActivityManager();
	return toTrackedChatsSorted().map((trackedChat) => trackedChat.chatId);
};

export const hasActiveLiveActivityEntry = (chatId: string): boolean => {
	const trackedChat = trackedChats.get(chatId);
	return Boolean(trackedChat)
		&& !isTrackedTerminalPhase(trackedChat!.phase)
		&& hasEntryBinding();
};

export const setThreadLiveActivityRemoteManaged = async (input: {
	chatId: string;
	remoteManaged: boolean;
}): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	const trackedChat = trackedChats.get(input.chatId);
	if (!trackedChat) {
		return;
	}

	if (trackedChat.remoteManaged === input.remoteManaged) {
		return;
	}

	trackedChats.set(input.chatId, {
		...trackedChat,
		remoteManaged: input.remoteManaged,
	});

	if (renderedEntry) {
		renderedEntry.awaitingAuthoritativeSync = input.remoteManaged && !isTerminalPhase(renderedEntry.state.phase);
		renderedEntry.awaitingAuthoritativeSyncStartedAtMs = renderedEntry.awaitingAuthoritativeSync ? nowMs() : 0;
	}

	await reconcileRenderedState({
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

export const getThreadLiveActivityStateForBackgroundTask = (): PersistedLiveActivityState | null => {
	if (!renderedEntry) {
		return null;
	}

	return renderedEntry.state;
};

export const getPushToStartToken = async (): Promise<string | null> => {
	try {
		const persistedToken = await SecureStore.getItemAsync(PUSH_TO_START_TOKEN_KEY);
		if (persistedToken && persistedToken.trim().length > 0) {
			return persistedToken.trim();
		}

		const nativeToken = await getNativePushToStartToken();
		if (nativeToken) {
			await SecureStore.setItemAsync(PUSH_TO_START_TOKEN_KEY, nativeToken);
		}
		return nativeToken;
	} catch {
		return null;
	}
};

export const subscribePushToStartToken = (
	listener: (token: string) => void,
): (() => void) => {
	pushToStartTokenListeners.add(listener);
	return () => {
		pushToStartTokenListeners.delete(listener);
	};
};

export const resetThreadLiveActivityManagerForTests = (): void => {
	clearHeartbeat();
	pushToStartTokenSubscription?.remove();
	pushToStartTokenSubscription = null;
	clearEntryFlush();
	detachPushTokenSubscription();
	renderedEntry = null;
	trackedChats.clear();
	nextTrackedChatSequence = 1;
	sessionWorstOutcome = null;
	pushTokenListeners.clear();
	pushToStartTokenListeners.clear();
	initialized = false;
	liveActivitiesUnavailable = false;
	currentAppState = "active";
};
