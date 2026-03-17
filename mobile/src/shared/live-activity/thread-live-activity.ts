import * as SecureStore from "expo-secure-store";
import type { LiveActivity } from "expo-widgets";
import { Platform, type AppStateStatus } from "react-native";

import type {
	ThreadLiveActivityPhase,
	ThreadLiveActivityProps,
} from "./thread-live-activity.widget";

const LOG_PREFIX = "[thread-live-activity]";
const ACTIVE_STATE_KEY = "remotecode.live_activity.active_state";
const PUSH_TOKEN_KEY = "remotecode.live_activity.push_token";
const PUSH_TO_START_TOKEN_KEY = "remotecode.live_activity.push_to_start_token";
const LOCAL_CONTENT_UPDATE_MIN_INTERVAL_MS = 1_000;
const LOCAL_HEARTBEAT_INTERVAL_MS = 1_000;
const LOCAL_ELAPSED_BUCKET_SECONDS = 1;
const LOCAL_STATE_PERSIST_MIN_INTERVAL_MS = 5_000;
const PREVIEW_LIMIT = 140;
const TITLE_LIMIT = 80;
const STATUS_LIMIT = 80;
const PREVIEW_ELLIPSIS = "...";
const MIN_IOS_LIVE_ACTIVITIES_MAJOR = 16;
const MIN_IOS_LIVE_ACTIVITIES_MINOR = 1;
const FINISH_DISMISS_DELAY_MS = 4_000;
const AUTHORITATIVE_SYNC_GRACE_PERIOD_MS = 30_000;
const MARKDOWN_CODE_FENCE_PATTERN = /```[\s\S]*?```/gu;
const INLINE_CODE_PATTERN = /`[^`]*`/gu;
const STRUCTURAL_CODE_CHARACTER_PATTERN = /[<>{}[\]\\|=]/gu;
const PREVIEW_ALLOWED_PATTERN = /[^\p{Letter}\p{Number}\p{Space_Separator}'.,;:!?@#%&+\-_/()]/gu;
const TITLE_STATUS_ALLOWED_PATTERN = /[^\p{Letter}\p{Number}\p{Space_Separator}'.,;:!?@#%&+\-_/()]/gu;

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

interface ActivityEntry {
	state: PersistedLiveActivityState;
	activity: LiveActivity<ThreadLiveActivityProps> | null;
	pushTokenSubscription: Subscription | null;
	finishInProgress: boolean;
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

interface PushToStartTokenEvent {
	activityPushToStartToken: string;
}

interface ThreadLiveActivityFactory {
	getInstances: () => LiveActivity<ThreadLiveActivityProps>[];
	start: (
		props: ThreadLiveActivityProps,
		deepLink: string,
	) => LiveActivity<ThreadLiveActivityProps>;
}

interface LiveActivityBindings {
	addPushToStartTokenListener: (listener: (event: PushToStartTokenEvent) => void) => Subscription;
	threadLiveActivityFactory: ThreadLiveActivityFactory;
}

let initialized = false;
let liveActivitiesUnavailable = false;
let liveActivityBindings: LiveActivityBindings | null = null;
let pushToStartTokenSubscription: Subscription | null = null;
let heartbeatInterval: ReturnType<typeof setInterval> | null = null;
let currentAppState: AppStateStatus = "active";
const entries = new Map<string, ActivityEntry>();
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

const loadLiveActivityBindings = async (): Promise<LiveActivityBindings | null> => {
	if (liveActivitiesUnavailable) {
		return null;
	}

	if (liveActivityBindings) {
		return liveActivityBindings;
	}

	try {
		const [widgetsModule, widgetModule] = await Promise.all([
			import("expo-widgets"),
			import("./thread-live-activity.widget"),
		]);

		const nextBindings: LiveActivityBindings = {
			addPushToStartTokenListener: widgetsModule.addPushToStartTokenListener,
			threadLiveActivityFactory: widgetModule.threadLiveActivityFactory,
		};
		// eslint-disable-next-line require-atomic-updates
		liveActivityBindings = nextBindings;
		return liveActivityBindings;
	} catch (error) {
		liveActivitiesUnavailable = true;
		log("live activities unavailable", {
			error: error instanceof Error ? error.message : "unknown-error",
		});
		return null;
	}
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

const hasAuthoritativeSyncTimedOut = (entry: ActivityEntry): boolean => (
	entry.awaitingAuthoritativeSync
	&& entry.awaitingAuthoritativeSyncStartedAtMs > 0
	&& (nowMs() - entry.awaitingAuthoritativeSyncStartedAtMs) >= AUTHORITATIVE_SYNC_GRACE_PERIOD_MS
);

const canEntryWriteLocally = (entry: ActivityEntry): boolean =>
	!entry.state.remoteManaged || !entry.awaitingAuthoritativeSync || hasAuthoritativeSyncTimedOut(entry);

const toElapsedSeconds = (startedAtMs: number): number => {
	const started = Number.isFinite(startedAtMs) && startedAtMs > 0 ? startedAtMs : nowMs();
	const deltaMs = Math.max(0, nowMs() - started);
	return Math.floor(deltaMs / 1_000);
};

const toElapsedBucket = (startedAtMs: number): number =>
	Math.floor(toElapsedSeconds(startedAtMs) / LOCAL_ELAPSED_BUCKET_SECONDS);

const toProps = (state: PersistedLiveActivityState): ThreadLiveActivityProps => ({
	chatId: state.chatId,
	chatTitle: sanitizeTitle(state.chatTitle, "Thread"),
	elapsedSeconds: toElapsedSeconds(state.startedAtMs),
	phase: state.phase,
	preview: sanitizePreview(state.preview, "Waiting for updates..."),
	statusLine: sanitizeStatusLine(state.statusLine, "Generating response"),
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

const persistAllEntries = async (): Promise<void> => {
	if (entries.size === 0) {
		await SecureStore.deleteItemAsync(ACTIVE_STATE_KEY);
		return;
	}

	const states = Array.from(entries.values(), (entry) => entry.state);
	await SecureStore.setItemAsync(ACTIVE_STATE_KEY, JSON.stringify(states));
};

const persistEntry = async (chatId: string): Promise<void> => {
	const entry = entries.get(chatId);
	if (entry) {
		entry.lastStatePersistAtMs = nowMs();
	}
	await persistAllEntries();
};

const hydratePersistedState = async (): Promise<void> => {
	const raw = await SecureStore.getItemAsync(ACTIVE_STATE_KEY);
	if (!raw) {
		return;
	}

	try {
		const parsed = JSON.parse(raw) as unknown;
		const toStates = (): Partial<PersistedLiveActivityState>[] => {
			if (Array.isArray(parsed)) {
				return parsed;
			}
			if (parsed && typeof parsed === "object" && "chatId" in parsed) {
				return [parsed as Partial<PersistedLiveActivityState>];
			}
			return [];
		};
		const states = toStates();

		for (const item of states) {
			const chatId = withDefault(item.chatId, "");
			if (chatId.length === 0 || entries.has(chatId)) {
				continue;
			}

			const state: PersistedLiveActivityState = {
				chatId,
				chatTitle: sanitizeTitle(item.chatTitle, "Thread"),
				phase: item.phase ?? "running",
				preview: sanitizePreview(item.preview, "Waiting for updates..."),
				startedAtMs:
					typeof item.startedAtMs === "number" && Number.isFinite(item.startedAtMs) && item.startedAtMs > 0
						? Math.floor(item.startedAtMs)
						: nowMs(),
				statusLine: sanitizeStatusLine(item.statusLine, "Generating response"),
				remoteManaged: item.remoteManaged !== false,
			};

			entries.set(chatId, {
				state,
				activity: null,
				pushTokenSubscription: null,
				finishInProgress: false,
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
		}
	} catch {
		// Ignore malformed persisted state.
	}
};

const emitPushToken = (chatId: string, pushToken: string): void => {
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

const detachEntryPushTokenSubscription = (entry: ActivityEntry): void => {
	if (!entry.pushTokenSubscription) {
		return;
	}

	entry.pushTokenSubscription.remove();
	// eslint-disable-next-line no-param-reassign
	entry.pushTokenSubscription = null;
};

const attachEntryPushTokenSubscription = (entry: ActivityEntry): void => {
	detachEntryPushTokenSubscription(entry);
	if (!entry.activity) {
		return;
	}

	// eslint-disable-next-line no-param-reassign
	entry.pushTokenSubscription = entry.activity.addPushTokenListener((event) => {
		const chatId = entry.state.chatId;
		const normalizedPushToken = withDefault(event.pushToken, "");
		if (normalizedPushToken.length === 0) {
			return;
		}

		log("push token listener received", {
			chatId,
			pushToken: toTokenPreview(normalizedPushToken),
		});
		void SecureStore.setItemAsync(PUSH_TOKEN_KEY, normalizedPushToken);
		emitPushToken(chatId, normalizedPushToken);
	});
};

const syncEntryPushToken = async (entry: ActivityEntry): Promise<void> => {
	if (!entry.activity) {
		return;
	}

	try {
		const pushToken = withDefault(await entry.activity.getPushToken() ?? "", "");
		if (pushToken.length === 0) {
			return;
		}

		await SecureStore.setItemAsync(PUSH_TOKEN_KEY, pushToken);
		log("activity push token synchronized", {
			chatId: entry.state.chatId,
			pushToken: toTokenPreview(pushToken),
		});
		emitPushToken(entry.state.chatId, pushToken);
	} catch {
		// Ignore push-token synchronization failures.
	}
};

async function resolveActivityInstance(entry: ActivityEntry): Promise<LiveActivity<ThreadLiveActivityProps> | null> {
	if (entry.activity) {
		return entry.activity;
	}

	const bindings = await loadLiveActivityBindings();
	if (!bindings) {
		return null;
	}

	const instances = bindings.threadLiveActivityFactory.getInstances();
	if (instances.length === 0) {
		return null;
	}

	// Try to match an unowned instance to this entry
	const ownedActivities = new Set<LiveActivity<ThreadLiveActivityProps>>();
	for (const other of entries.values()) {
		if (other.activity) {
			ownedActivities.add(other.activity);
		}
	}

	for (const instance of instances) {
		if (!ownedActivities.has(instance)) {
			// eslint-disable-next-line no-param-reassign
			entry.activity = instance;
			attachEntryPushTokenSubscription(entry);
			return instance;
		}
	}

	return null;
}

const clearEntryFlush = (entry: ActivityEntry): void => {
	if (!entry.flushTimeout) {
		return;
	}

	clearTimeout(entry.flushTimeout);
	// eslint-disable-next-line no-param-reassign
	entry.flushTimeout = null;
};

const clearHeartbeat = (): void => {
	if (!heartbeatInterval) {
		return;
	}

	clearInterval(heartbeatInterval);
	heartbeatInterval = null;
};

const ensureHeartbeat = (): void => {
	if (heartbeatInterval) {
		return;
	}

	const hasTickableEntries = Array.from(entries.values()).some(
		(entry) => !isTerminalPhase(entry.state.phase) && canEntryWriteLocally(entry),
	);
	if (!hasTickableEntries) {
		return;
	}

	heartbeatInterval = setInterval(() => {
		for (const [chatId, entry] of entries) {
			if (!isTerminalPhase(entry.state.phase) && canEntryWriteLocally(entry)) {
				void queueEntryStateUpdate(chatId);
			}
		}

		const stillHasTickable = Array.from(entries.values()).some(
			(e) => !isTerminalPhase(e.state.phase) && canEntryWriteLocally(e),
		);
		if (!stillHasTickable) {
			clearHeartbeat();
		}
	}, LOCAL_HEARTBEAT_INTERVAL_MS);
};

const flushEntryStateUpdate = async (chatId: string, input?: { force?: boolean }): Promise<void> => {
	const entry = entries.get(chatId);
	if (!entry || isTerminalPhase(entry.state.phase) || !canEntryWriteLocally(entry)) {
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
	const activity = await resolveActivityInstance(entry);
	const currentEntry = entries.get(chatId);
	if (!activity || !currentEntry || isTerminalPhase(currentEntry.state.phase)) {
		if (currentEntry) {
			currentEntry.writeInFlight = false;
			if (currentEntry.writeAgain || currentEntry.pendingForceWrite) {
				currentEntry.writeAgain = false;
				void queueEntryStateUpdate(chatId, {
					force: currentEntry.pendingForceWrite,
				});
			}
		}
		return;
	}

	const force = (input?.force ?? false) || currentEntry.pendingForceWrite;
	const elapsedSinceLastUpdate = nowMs() - currentEntry.lastContentUpdateAtMs;
	if (!force && currentEntry.lastContentUpdateAtMs > 0 && elapsedSinceLastUpdate < LOCAL_CONTENT_UPDATE_MIN_INTERVAL_MS) {
		currentEntry.writeInFlight = false;
		void queueEntryStateUpdate(chatId);
		return;
	}

	const signature = toContentSignature(currentEntry.state);
	if (!force && signature === currentEntry.lastContentSignature) {
		currentEntry.writeInFlight = false;
		return;
	}

	currentEntry.pendingForceWrite = false;
	try {
		await activity.update(toProps(currentEntry.state));
		currentEntry.lastContentSignature = signature;
		currentEntry.lastContentUpdateAtMs = nowMs();
	} catch {
		// Ignore runtime update failures.
	} finally {
		currentEntry.writeInFlight = false;
		if (currentEntry.writeAgain) {
			currentEntry.writeAgain = false;
			void queueEntryStateUpdate(chatId, {
				force: currentEntry.pendingForceWrite,
			});
		}
	}
};

async function queueEntryStateUpdate(chatId: string, input?: { immediate?: boolean; force?: boolean }): Promise<void> {
	const entry = entries.get(chatId);
	if (!entry || isTerminalPhase(entry.state.phase) || !canEntryWriteLocally(entry)) {
		return;
	}

	if (input?.force) {
		entry.pendingForceWrite = true;
	}

	if (input?.immediate) {
		clearEntryFlush(entry);
		await flushEntryStateUpdate(chatId, {
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
		entry.flushTimeout = null;
		void flushEntryStateUpdate(chatId);
	}, delayMs);
}

const removeEntry = async (chatId: string): Promise<void> => {
	const entry = entries.get(chatId);
	if (!entry) {
		return;
	}

	clearEntryFlush(entry);
	detachEntryPushTokenSubscription(entry);
	entries.delete(chatId);
	await persistAllEntries();

	if (entries.size === 0) {
		clearHeartbeat();
		await SecureStore.deleteItemAsync(PUSH_TOKEN_KEY);
	}
};

export const initializeThreadLiveActivityManager = async (): Promise<void> => {
	if (!canUseLiveActivities() || initialized) {
		return;
	}

	try {
		const bindings = await loadLiveActivityBindings();
		if (!bindings) {
			return;
		}

		// eslint-disable-next-line require-atomic-updates
		initialized = true;
		await hydratePersistedState();

		// Adopt existing OS-level activity instances
		const instances = bindings.threadLiveActivityFactory.getInstances();
		const ownedActivities = new Set<LiveActivity<ThreadLiveActivityProps>>();

		for (const [, entry] of entries) {
			if (instances.length === 0) {
				break;
			}

			const unowned = instances.find((inst) => !ownedActivities.has(inst));
			if (unowned) {
				entry.activity = unowned;
				ownedActivities.add(unowned);
				attachEntryPushTokenSubscription(entry);
			}
		}

		const unownedInstancesCount = instances.length - ownedActivities.size;
		if (unownedInstancesCount > 0) {
			log("unowned live activity instances detected; keeping them available for later adoption", {
				count: unownedInstancesCount,
			});
		}

		// Sync push tokens for all entries with activities
		await Promise.all(
			Array.from(entries.values())
				.filter((entry) => Boolean(entry.activity))
				.map(async (entry) => { await syncEntryPushToken(entry); }),
		);

		// Start heartbeat for active entries and flush initial state
		const hasActive = Array.from(entries.values()).some(
			(entry) => !isTerminalPhase(entry.state.phase) && canEntryWriteLocally(entry),
		);
		if (hasActive) {
			ensureHeartbeat();
			await Promise.all(
				Array.from(entries.entries())
					.filter(([, entry]) => !isTerminalPhase(entry.state.phase) && canEntryWriteLocally(entry))
					.map(async ([chatId]) => { await queueEntryStateUpdate(chatId, { immediate: true, force: true }); }),
			);
		}

		pushToStartTokenSubscription ||= bindings.addPushToStartTokenListener((event) => {
			log("push-to-start token received", {
				pushToken: toTokenPreview(event.activityPushToStartToken),
			});
			void SecureStore.setItemAsync(PUSH_TO_START_TOKEN_KEY, event.activityPushToStartToken);
			for (const listener of pushToStartTokenListeners) {
				try {
					listener(event.activityPushToStartToken);
				} catch {
					// Keep listeners isolated.
				}
			}
		});
	} catch {
		liveActivitiesUnavailable = true;

		// Reset all entries
		await Promise.all(Array.from(entries.keys(), async (chatId) => { await removeEntry(chatId); }));
		// eslint-disable-next-line require-atomic-updates
		initialized = false;
	}
};

export const startThreadLiveActivity = async (input: LiveActivityStartInput): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	const bindings = await loadLiveActivityBindings();
	if (!bindings) {
		return;
	}

	const existing = entries.get(input.chatId);

	if (input.restart && existing) {
		await clearThreadLiveActivity({ chatId: input.chatId });
	}

	const hasExplicitStartTime =
		typeof input.startedAtMs === "number" && Number.isFinite(input.startedAtMs) && input.startedAtMs > 0;
	let startedAtMs = nowMs();
	if (hasExplicitStartTime) {
		startedAtMs = Math.floor(input.startedAtMs ?? startedAtMs);
	} else if (existing && !input.restart) {
		startedAtMs = existing.state.startedAtMs;
	} else {
		startedAtMs = nowMs();
	}

	const previousState = entries.get(input.chatId)?.state;
	const state: PersistedLiveActivityState = {
		chatId: input.chatId,
		chatTitle: sanitizeTitle(
			input.chatTitle,
			previousState ? previousState.chatTitle : "Thread",
		),
		phase: currentAppState === "background" || currentAppState === "inactive" ? "background" : "running",
		preview: sanitizePreview(input.preview, "Waiting for updates..."),
		startedAtMs,
		statusLine: sanitizeStatusLine(
			input.statusLine,
			currentAppState === "background" || currentAppState === "inactive"
				? "Running in background"
				: "Generating response",
		),
		remoteManaged: input.remoteManaged ?? true,
	};

	let entry = entries.get(input.chatId);
	if (entry) {
		entry.state = state;
		entry.awaitingAuthoritativeSync = false;
		entry.awaitingAuthoritativeSyncStartedAtMs = 0;
		entry.finishInProgress = false;
	} else {
		entry = {
			state,
			activity: null,
			pushTokenSubscription: null,
			finishInProgress: false,
			lastContentSignature: "",
			lastContentUpdateAtMs: 0,
			lastStatePersistAtMs: 0,
			writeInFlight: false,
			writeAgain: false,
			pendingForceWrite: false,
			flushTimeout: null,
			awaitingAuthoritativeSync: false,
			awaitingAuthoritativeSyncStartedAtMs: 0,
		};
		entries.set(input.chatId, entry);
	}

	log("start requested", {
		chatId: state.chatId,
		chatTitle: state.chatTitle,
		remoteManaged: state.remoteManaged,
		restart: input.restart ?? false,
	});
	await persistEntry(input.chatId);
	ensureHeartbeat();

	const activity = await resolveActivityInstance(entry);
	if (activity) {
		log("reusing existing activity instance", { chatId: input.chatId });
		await queueEntryStateUpdate(input.chatId, {
			immediate: true,
			force: true,
		});
		await syncEntryPushToken(entry);
		return;
	}

	try {
		entry.activity = bindings.threadLiveActivityFactory.start(
			toProps(state),
			`remotecode-mobile://chat?chatId=${encodeURIComponent(input.chatId)}`,
		);
		log("activity instance started", { chatId: input.chatId });
		attachEntryPushTokenSubscription(entry);
		entry.lastContentSignature = toContentSignature(state);
		entry.lastContentUpdateAtMs = nowMs();
		await syncEntryPushToken(entry);
	} catch {
		// Ignore startup failures to keep app flow resilient.
	}
};

export const updateThreadLiveActivity = async (input: LiveActivityUpdateInput): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	const entry = entries.get(input.chatId);
	if (!entry) {
		return;
	}

	const nextState: PersistedLiveActivityState = {
		...entry.state,
		chatTitle: sanitizeTitle(input.chatTitle, entry.state.chatTitle),
		phase: input.phase ?? entry.state.phase,
		preview: sanitizePreview(input.preview, entry.state.preview),
		statusLine: sanitizeStatusLine(input.statusLine, entry.state.statusLine),
	};
	if (input.authoritative) {
		entry.awaitingAuthoritativeSync = false;
		entry.awaitingAuthoritativeSyncStartedAtMs = 0;
	}
	const shouldPersistState =
		Boolean(input.force)
		|| nextState.chatTitle !== entry.state.chatTitle
		|| nextState.phase !== entry.state.phase
		|| nextState.statusLine !== entry.state.statusLine
		|| nowMs() - entry.lastStatePersistAtMs >= LOCAL_STATE_PERSIST_MIN_INTERVAL_MS;
	entry.state = nextState;
	if (shouldPersistState) {
		await persistEntry(input.chatId);
	}
	if (isTerminalPhase(nextState.phase)) {
		clearEntryFlush(entry);
	} else {
		ensureHeartbeat();
	}
	await queueEntryStateUpdate(input.chatId, {
		force: input.force,
		immediate: false,
	});
};

export const finishThreadLiveActivity = async (input: LiveActivityFinishInput): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	const entry = entries.get(input.chatId);
	if (!entry) {
		return;
	}

	if (entry.finishInProgress) {
		return;
	}

	entry.finishInProgress = true;

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
		chatTitle: sanitizeTitle(input.chatTitle, entry.state.chatTitle),
		phase: outcomePhase,
		preview: sanitizePreview(input.preview, entry.state.preview),
		startedAtMs: entry.state.startedAtMs,
		statusLine: sanitizeStatusLine(input.statusLine, defaultStatusLine),
		remoteManaged: entry.state.remoteManaged,
	};
	entry.awaitingAuthoritativeSync = false;
	entry.awaitingAuthoritativeSyncStartedAtMs = 0;

	try {
		clearEntryFlush(entry);
		entry.state = finalState;
		await persistEntry(input.chatId);

		const activity = await resolveActivityInstance(entry);
		if (activity) {
			try {
				await activity.update(toProps(finalState));
			} catch {
				// Ignore final update failures.
			}

			// Always end the activity locally after a brief delay so the user sees the final state
			const chatIdToEnd = input.chatId;
			setTimeout(() => {
				void (async () => {
					try {
						await activity.end("default", toProps(finalState));
					} catch {
						// Ignore end failures.
					}

					// Only remove entry if it hasn't been replaced by a new start
					const currentEntry = entries.get(chatIdToEnd);
					if (currentEntry && isTerminalPhase(currentEntry.state.phase)) {
						await removeEntry(chatIdToEnd);
					}
				})();
			}, FINISH_DISMISS_DELAY_MS);
			return;
		}
	} finally {
		entry.finishInProgress = false;
	}

	await removeEntry(input.chatId);
};

export const clearThreadLiveActivity = async (input: { chatId: string }): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	const entry = entries.get(input.chatId);
	if (!entry) {
		return;
	}

	clearEntryFlush(entry);
	if (entry.activity) {
		try {
			await entry.activity.end("immediate");
		} catch {
			// Ignore cleanup failures.
		}
	}

	await removeEntry(input.chatId);
};

export const onThreadLiveActivityAppStateChanged = async (nextState: AppStateStatus): Promise<void> => {
	currentAppState = nextState;

	if (!canUseLiveActivities() || entries.size === 0) {
		return;
	}

	const updates: { chatId: string; phase: "background" | "running" }[] = [];

	for (const [chatId, entry] of entries) {
		if (isTerminalPhase(entry.state.phase)) {
			continue;
		}

		if (nextState === "background" || nextState === "inactive") {
			if (!canEntryWriteLocally(entry)) {
				continue;
			}
			ensureHeartbeat();
			if (entry.state.phase === "finalizing") {
				continue;
			}

			updates.push({ chatId, phase: "background" });
			continue;
		}

		if (nextState === "active") {
			if (!canEntryWriteLocally(entry)) {
				continue;
			}
			ensureHeartbeat();
			if (entry.state.phase === "finalizing") {
				continue;
			}

			updates.push({ chatId, phase: "running" });
		}
	}

	await Promise.all(
		updates.map(async (update) =>
			{ await updateThreadLiveActivity({
				chatId: update.chatId,
				phase: update.phase,
				force: false,
			}); },
		),
	);
};

export const isThreadLiveActivityEnabled = (): boolean => canUseLiveActivities();

export const hasActiveLiveActivityEntry = (chatId: string): boolean => {
	const entry = entries.get(chatId);
	return Boolean(entry) && !isTerminalPhase(entry!.state.phase);
};

export const setThreadLiveActivityRemoteManaged = async (input: {
	chatId: string;
	remoteManaged: boolean;
}): Promise<void> => {
	if (!canUseLiveActivities()) {
		return;
	}

	await initializeThreadLiveActivityManager();
	const entry = entries.get(input.chatId);
	if (!entry) {
		return;
	}

	if (entry.state.remoteManaged === input.remoteManaged) {
		return;
	}

	entry.state = {
		...entry.state,
		remoteManaged: input.remoteManaged,
	};
	entry.awaitingAuthoritativeSync = input.remoteManaged && !isTerminalPhase(entry.state.phase);
	entry.awaitingAuthoritativeSyncStartedAtMs = entry.awaitingAuthoritativeSync ? nowMs() : 0;
	await persistEntry(input.chatId);

	ensureHeartbeat();
	await queueEntryStateUpdate(input.chatId, {
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

export const getThreadLiveActivityStateForBackgroundTask = (): PersistedLiveActivityState | null => {
	for (const [, entry] of entries) {
		if (!isTerminalPhase(entry.state.phase)) {
			return entry.state;
		}
	}
	return null;
};

export const getPushToStartToken = async (): Promise<string | null> => {
	try {
		const token = await SecureStore.getItemAsync(PUSH_TO_START_TOKEN_KEY);
		return token && token.trim().length > 0 ? token.trim() : null;
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
	for (const entry of entries.values()) {
		clearEntryFlush(entry);
		detachEntryPushTokenSubscription(entry);
	}
	entries.clear();
	pushTokenListeners.clear();
	pushToStartTokenListeners.clear();
	initialized = false;
	liveActivitiesUnavailable = false;
	liveActivityBindings = null;
	currentAppState = "active";
};
