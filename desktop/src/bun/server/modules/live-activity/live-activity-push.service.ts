import type { AssistantStreamEvent } from "../../../../shared/assistant-stream-event";
import type {
	LiveActivityPhase,
	LiveActivityPushFinishInput,
	LiveActivityPushServiceContract,
	LiveActivityPushStartInput,
	LiveActivityPushStoredSubscription,
	LiveActivityPushSubscriptionInput,
	LiveActivityPushSubscriptionStoreContract,
	LiveActivityPushTokenType,
	PushToStartTokenInput,
	PushToStartTokenStoreContract,
	PushToStartTokenStored,
} from "./live-activity-push.model";
import { createApnsSender, loadApnsConfigFromEnvironment, type ApnsSendInput } from "./apns-sender";

const PUSH_MIN_UPDATE_INTERVAL_MS = 15_000;
const PUSH_HEARTBEAT_INTERVAL_MS = 15_000;
const PUSH_STALE_WINDOW_SECONDS = 180;
const PUSH_END_DISMISS_SECONDS = 30;
const PRIVATE_BACKEND_STATUS_CACHE_TTL_MS = 30_000;
const GLOBAL_ACTIVITY_CHAT_ID = "active-threads";
const GLOBAL_ACTIVITY_TITLE = "Active Threads";
const PREVIEW_LIMIT = 140;
const TITLE_LIMIT = 80;
const STATUS_LIMIT = 80;
const SANITIZE_INPUT_CODEPOINT_LIMIT = 4_096;
const PREVIEW_ELLIPSIS = "...";
const LIVE_ACTIVITY_ATTRIBUTES_TYPE = "RemoteCodeLiveActivityAttributes";
const LIVE_ACTIVITY_DEEP_LINK = "remotecode-mobile://active-threads";
const LIVE_ACTIVITY_LOG_PREFIX = "[live-activity]";


type PushEvent = "update" | "end" | "start";
type TerminalOutcome = Extract<LiveActivityPhase, "completed" | "error" | "failed">;

interface LiveActivityContentState {
	chatId: string;
	chatTitle: string;
	elapsedSeconds: number;
	phase: LiveActivityPhase;
	preview: string;
	statusLine: string;
}

interface LiveActivitySubscription {
	chatId: string;
	chatTitle?: string;
	pushToken: string;
	pushTokenType: LiveActivityPushTokenType;
	liveActivityToken: string;
	lastDeliveredSignature?: string;
	lastTimestampSeconds?: number;
	updatedAtMs: number;
}

interface ChatRuntimeState {
	chatId: string;
	chatTitle: string;
	phase: LiveActivityPhase;
	preview: string;
	previewSource: "default" | "event" | "legacy-response" | "structured-response";
	startedAtMs: number;
	statusLine: string;
	lastSentAtMs: number;
	flushTimeout: ReturnType<typeof setTimeout> | null;
	heartbeatInterval: ReturnType<typeof setInterval> | null;
	sending: boolean;
	sendAgain: boolean;
	pendingEvent: PushEvent | null;
}

interface GlobalSessionState {
	elapsedSecondsSnapshot: number | null;
	flushTimeout: ReturnType<typeof setTimeout> | null;
	heartbeatInterval: ReturnType<typeof setInterval> | null;
	lastSentAtMs: number;
	pendingEvent: PushEvent | null;
	revision: number;
	sendAgain: boolean;
	sending: boolean;
	startedAtMs: number;
}

interface LiveActivityPushDeliveryInput {
	contentState: LiveActivityContentState;
	event: PushEvent;
	pushToken: string;
	pushTokenType: LiveActivityPushTokenType;
	liveActivityToken: string;
	timestampSeconds: number;
	attributesType?: string;
	attributes?: Record<string, unknown>;
}

export interface LiveActivityPushDeliveryResult {
	delivered: boolean;
	errorCode?: string;
	shouldDropSubscription: boolean;
}

interface PrivateBackendPushStatus {
	authoritative: boolean;
	enabled: boolean;
	supportedPushTokenTypes: ReadonlySet<LiveActivityPushTokenType>;
}

type LiveActivityPushSender = (input: LiveActivityPushDeliveryInput) => Promise<LiveActivityPushDeliveryResult>;

export interface LiveActivityPushConnectorCredentials {
	backendUrl: string;
	connectorId: string;
	connectorToken: string;
}

export interface LiveActivityPushEnvironmentInput {
	getConnectorCredentials: () => LiveActivityPushConnectorCredentials | null;
	privateBackendUrl: string;
	subscriptionStore?: LiveActivityPushSubscriptionStoreContract;
	pushToStartTokenStore?: PushToStartTokenStoreContract;
}

export interface LiveActivityPushDebugSendInput {
	chatId: string;
	chatTitle?: string;
	elapsedSeconds?: number;
	event: PushEvent;
	liveActivityToken: string;
	phase?: LiveActivityPhase;
	preview?: string;
	pushToken: string;
	pushTokenType: LiveActivityPushTokenType;
	statusLine?: string;
	timestampSeconds?: number;
}

export interface LiveActivityPushDebugClientContract {
	getIsEnabled(): boolean;
	getSupportedPushTokenTypes(): ReadonlySet<LiveActivityPushTokenType>;
	send(input: LiveActivityPushDebugSendInput): Promise<LiveActivityPushDeliveryResult>;
}

export const buildLiveActivityApsPayload = (input: {
	contentState: {
		chatId: string;
		chatTitle: string;
		elapsedSeconds: number;
		phase: LiveActivityPhase;
		preview: string;
		statusLine: string;
	};
	event: PushEvent;
	timestampSeconds?: number;
	nowMs?: number;
	attributesType?: string;
	attributes?: Record<string, unknown>;
}): Record<string, unknown> => {
	const timestampSeconds = typeof input.timestampSeconds === "number" && Number.isFinite(input.timestampSeconds)
		? Math.max(0, Math.floor(input.timestampSeconds))
		: Math.floor((input.nowMs ?? Date.now()) / 1_000);
	const normalizedContentState = (() => {
		try {
			const parsed = JSON.parse(JSON.stringify(input.contentState)) as unknown;
			if (!parsed || typeof parsed !== "object") {
				throw new Error("invalid serialized props");
			}
			return parsed as Record<string, unknown>;
		} catch {
			return {
				chatId: "unknown",
				chatTitle: "Thread",
				elapsedSeconds: 0,
				phase: "running",
				preview: "Working on your latest request.",
				statusLine: "Generating response",
			};
		}
	})();
	const apsPayload: Record<string, unknown> = {
		timestamp: timestampSeconds,
		event: input.event,
		"content-state": normalizedContentState,
	};

	if (input.event === "start") {
		apsPayload["attributes-type"] = input.attributesType ?? LIVE_ACTIVITY_ATTRIBUTES_TYPE;
		apsPayload["attributes"] = input.attributes ?? {
			deepLink: LIVE_ACTIVITY_DEEP_LINK,
		};
		apsPayload["stale-date"] = timestampSeconds + PUSH_STALE_WINDOW_SECONDS;
	}

	if (input.event === "update") {
		apsPayload["stale-date"] = timestampSeconds + PUSH_STALE_WINDOW_SECONDS;
	}

	if (input.event === "end") {
		apsPayload["dismissal-date"] = timestampSeconds + PUSH_END_DISMISS_SECONDS;
		apsPayload["sound"] = "default";
	}

	return apsPayload;
};

const toNormalized = (value: string | undefined | null): string => value?.trim() ?? "";

const toNormalizedPreviewText = (value: string): string => value.replace(/\s+/gu, " ").trim();
type LiveActivityTextField = "title" | "status" | "preview";
const ANSI_ESCAPE_PATTERN =
	/\u001B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\u0007]*(?:\u0007|\u001B\\)|P[^\u001B]*\u001B\\|\^.*?\u001B\\|_.*?\u001B\\)/gu;
const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001F\u007F-\u009F]/gu;
const INVISIBLE_FORMAT_CHARACTER_PATTERN = /[\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]/gu;
const BROKEN_SURROGATE_PATTERN = /[\uD800-\uDFFF]/gu;
const MARKDOWN_CODE_FENCE_PATTERN = /```[\s\S]*?```/gu;
const INLINE_CODE_PATTERN = /`[^`]*`/gu;
const STRUCTURAL_CODE_CHARACTER_PATTERN = /[`\\<>{}\[\]|$*=~^"]/gu;
const TITLE_STATUS_ALLOWED_PATTERN = /[^\p{L}\p{N}\p{Zs}'.,;:!?@#%&+\-_/()]/gu;
const PREVIEW_ALLOWED_PATTERN = /[^\p{L}\p{N}\p{Zs}'.,;:!?@#%&+\-_/()]/gu;
const PREVIEW_UTF8_BYTE_LIMIT = 192;
const TITLE_UTF8_BYTE_LIMIT = 256;
const STATUS_UTF8_BYTE_LIMIT = 256;

const toUtf8ByteLength = (value: string): number => new TextEncoder().encode(value).length;
const toCodePointHead = (value: string, maxLength: number): string => {
	const points = Array.from(value);
	if (points.length <= maxLength) {
		return value;
	}

	return points.slice(0, maxLength).join("");
};
const toUtf8Head = (value: string, maxBytes: number): string => {
	if (toUtf8ByteLength(value) <= maxBytes) {
		return value;
	}

	const points = Array.from(value);
	const kept: string[] = [];
	let bytes = 0;
	for (let index = 0; index < points.length; index += 1) {
		const point = points[index]!;
		const pointBytes = toUtf8ByteLength(point);
		if (bytes + pointBytes > maxBytes) {
			break;
		}

		kept.push(point);
		bytes += pointBytes;
	}

	return kept.join("").trim();
};
const toFieldByteLimit = (field: LiveActivityTextField): number => {
	switch (field) {
		case "title": {
			return TITLE_UTF8_BYTE_LIMIT;
		}
		case "status": {
			return STATUS_UTF8_BYTE_LIMIT;
		}
		case "preview":
		default: {
			return PREVIEW_UTF8_BYTE_LIMIT;
		}
	}
};
const toFieldAllowPattern = (field: LiveActivityTextField): RegExp =>
	field === "preview" ? PREVIEW_ALLOWED_PATTERN : TITLE_STATUS_ALLOWED_PATTERN;
const withOptionalEllipsis = (value: string, maxLength: number, field: LiveActivityTextField): string => {
	if (field !== "preview") {
		return toCodePointHead(value, maxLength);
	}

	const points = Array.from(value);
	if (points.length <= maxLength) {
		return value;
	}
	if (maxLength <= PREVIEW_ELLIPSIS.length) {
		return PREVIEW_ELLIPSIS.slice(0, maxLength);
	}

	return `${points.slice(0, maxLength - PREVIEW_ELLIPSIS.length).join("")}${PREVIEW_ELLIPSIS}`;
};
const toSafeLiveActivityText = (value: string, maxLength: number, field: LiveActivityTextField): string => {
	if (maxLength <= 0) {
		return "";
	}

	const boundedInput = toCodePointHead(String(value ?? ""), SANITIZE_INPUT_CODEPOINT_LIMIT);
	const normalizedValue = boundedInput.normalize("NFKC");
	const withoutAnsi = normalizedValue.replace(ANSI_ESCAPE_PATTERN, " ");
	const withoutControlChars = withoutAnsi
		.replace(CONTROL_CHARACTER_PATTERN, " ")
		.replace(INVISIBLE_FORMAT_CHARACTER_PATTERN, " ")
		.replace(BROKEN_SURROGATE_PATTERN, " ");
	const withoutCodeFrames = withoutControlChars
		.replace(MARKDOWN_CODE_FENCE_PATTERN, " ")
		.replace(INLINE_CODE_PATTERN, " ")
		.replace(STRUCTURAL_CODE_CHARACTER_PATTERN, " ");
	const asciiSafeQuotes = withoutCodeFrames
		.replace(/[\u2018\u2019]/gu, "'")
		.replace(/[\u201C\u201D]/gu, "\"");
	const fieldOnlyAllowed = asciiSafeQuotes.replace(toFieldAllowPattern(field), " ");
	const collapsedWhitespace = toNormalizedPreviewText(fieldOnlyAllowed);
	if (collapsedWhitespace.length === 0) {
		return "";
	}

	const utf8Bounded = toUtf8Head(collapsedWhitespace, toFieldByteLimit(field));
	const codePointBounded = withOptionalEllipsis(utf8Bounded, maxLength, field);
	return toNormalizedPreviewText(codePointBounded);
};

const toDefaultStatusLine = (phase: LiveActivityPhase): string => {
	switch (phase) {
		case "background": {
			return "Running in background";
		}
		case "completed": {
			return "Response is ready";
		}
		case "error": {
			return "Thread ended with an error";
		}
		case "failed": {
			return "Thread failed";
		}
		case "finalizing": {
			return "Finalizing response";
		}
		case "running":
		default: {
			return "Generating response";
		}
	}
};

const toDefaultPreview = (phase: LiveActivityPhase): string => {
	switch (phase) {
		case "background": {
			return "The response keeps running while the app is not active.";
		}
		case "completed": {
			return "Tap to open the thread and review the full answer.";
		}
		case "error": {
			return "Open the thread to see the error details.";
		}
		case "failed": {
			return "Open the thread to retry the request.";
		}
		case "finalizing": {
			return "Wrapping up the final answer.";
		}
		case "running":
		default: {
			return "Working on your latest request.";
		}
	}
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
		: "RemoteCode is wrapping up the remaining threads.";

const toTerminalStatusLine = (outcome: TerminalOutcome): string => {
	switch (outcome) {
		case "failed": {
			return "At least one thread failed";
		}
		case "error": {
			return "At least one thread ended with an error";
		}
		case "completed":
		default: {
			return "All threads completed";
		}
	}
};

const toTerminalPreview = (): string => "No active threads right now.";

const toEventSummary = (event: AssistantStreamEvent): string | undefined => {
	switch (event.type) {
		case "item_delta": {
			if (event.target === "body" || event.target === "summary" || event.target === "output") {
				return toNormalized(event.delta) || undefined;
			}

			return undefined;
		}
		case "item_completed":
		case "item_state": {
			return toNormalized(event.summary) || undefined;
		}
		case "item_started": {
			const summary = toNormalized(event.summary);
			if (summary.length > 0) {
				return summary;
			}

			switch (event.itemType) {
				case "assistant_message": {
					return "Writing response...";
				}
				case "plan": {
					return "Planning...";
				}
				case "reasoning": {
					return "Thinking...";
				}
				case "tool": {
					return "Running tool...";
				}
				default: {
					return undefined;
				}
			}
		}
		default: {
			return undefined;
		}
	}
};

const toStatusLineFromEvent = (event: AssistantStreamEvent): string | undefined => {
	switch (event.type) {
		case "item_delta": {
			if (event.target === "summary") {
				return toNormalized(event.delta) || undefined;
			}

			return undefined;
		}
		case "item_completed": {
			return toNormalized(event.summary) || "Working...";
		}
		case "item_started": {
			const summary = toNormalized(event.summary);
			if (summary.length > 0) {
				return summary;
			}

			switch (event.itemType) {
				case "assistant_message": {
					return "Writing response...";
				}
				case "plan": {
					return "Planning...";
				}
				case "reasoning": {
					return "Thinking...";
				}
				case "tool": {
					return "Running tool...";
				}
				default: {
					return "Working...";
				}
			}
		}
		case "item_state": {
			return toNormalized(event.summary) || `Step ${event.state}`;
		}
		case "turn_completed": {
			return "Finalizing response";
		}
		default: {
			return undefined;
		}
	}
};

const toPhaseFromEvent = (event: AssistantStreamEvent): LiveActivityPhase => {
	if (event.type === "turn_completed") {
		return "finalizing";
	}

	return "running";
};

const toPreviewChunk = (preview: string, delta: string): string => {
	const normalizedDelta = toNormalizedPreviewText(delta);
	if (normalizedDelta.length === 0) {
		return preview;
	}

	const base = toNormalizedPreviewText(preview);
	const next = `${base} ${normalizedDelta}`.trim();
	return toUtf8Head(next, PREVIEW_UTF8_BYTE_LIMIT);
};

const toLatestPreview = (preview: string): string => toUtf8Head(toNormalizedPreviewText(preview), PREVIEW_UTF8_BYTE_LIMIT);

const toElapsedSeconds = (startedAtMs: number): number => {
	const started = Number.isFinite(startedAtMs) && startedAtMs > 0 ? startedAtMs : Date.now();
	return Math.max(0, Math.floor((Date.now() - started) / 1_000));
};

const toSubscriptionKey = (
	subscription: { liveActivityToken: string; pushToken: string; pushTokenType: LiveActivityPushTokenType },
): string => `${subscription.pushTokenType}::${subscription.pushToken}::${subscription.liveActivityToken}`;

const toPushDeviceKey = (
	input: { pushToken: string; pushTokenType: LiveActivityPushTokenType },
): string => `${input.pushTokenType}::${input.pushToken}`;

const toDeliverySignature = (input: {
	contentState: LiveActivityContentState;
	event: PushEvent;
}): string => (
	[
		input.event,
		input.contentState.chatId,
		input.contentState.chatTitle,
		input.contentState.phase,
		String(input.contentState.elapsedSeconds),
		input.contentState.statusLine,
		input.contentState.preview,
	].join("\u0001")
);

const toNextTimestampSeconds = (input: { lastTimestampSeconds?: number; nowMs?: number }): number => {
	const nowSeconds = Math.floor((input.nowMs ?? Date.now()) / 1_000);
	if (
		typeof input.lastTimestampSeconds === "number"
		&& Number.isFinite(input.lastTimestampSeconds)
		&& input.lastTimestampSeconds > 0
	) {
		return Math.max(nowSeconds, Math.floor(input.lastTimestampSeconds) + 1);
	}

	return nowSeconds;
};

const isTerminalPhase = (phase: LiveActivityPhase): boolean =>
	phase === "completed" || phase === "failed" || phase === "error";

const toTerminalOutcomeSeverity = (outcome: TerminalOutcome | null): number => {
	switch (outcome) {
		case "completed": {
			return 1;
		}
		case "failed": {
			return 2;
		}
		case "error": {
			return 3;
		}
		default: {
			return 0;
		}
	}
};

const toWorstTerminalOutcome = (
	left: TerminalOutcome | null,
	right: TerminalOutcome | null,
): TerminalOutcome | null =>
	toTerminalOutcomeSeverity(right) > toTerminalOutcomeSeverity(left)
		? right
		: left;

const LIVE_ACTIVITY_LOG_META_KEY_WIDTH = 24;
const LIVE_ACTIVITY_COLOR_RESET = "\u001B[0m";
const LIVE_ACTIVITY_COLOR_DIM = "\u001B[2m";
const LIVE_ACTIVITY_COLOR_CYAN = "\u001B[36m";
const LIVE_ACTIVITY_COLOR_YELLOW = "\u001B[33m";
const LIVE_ACTIVITY_COLOR_GRAY = "\u001B[90m";
const LIVE_ACTIVITY_LOG_PLAIN = process.env.REMOTECODE_LIVE_ACTIVITY_PLAIN_LOGS === "1";
const LIVE_ACTIVITY_LOG_CAN_COLOR = Boolean(process.stdout?.isTTY) && !LIVE_ACTIVITY_LOG_PLAIN;

const withAnsiColor = (text: string, color: string): string => (
	LIVE_ACTIVITY_LOG_CAN_COLOR
		? `${color}${text}${LIVE_ACTIVITY_COLOR_RESET}`
		: text
);

const toLogTimeLabel = (): string => new Date().toISOString().slice(11, 19);

const toLogValue = (value: unknown): string => {
	if (typeof value === "string") {
		return value.length > 0 ? value : "\"\"";
	}
	if (typeof value === "number" || typeof value === "boolean") {
		return String(value);
	}
	if (value === null || value === undefined) {
		return "-";
	}
	try {
		return JSON.stringify(value);
	} catch {
		return "[unserializable]";
	}
};

const toSortedLogEntries = (meta: Record<string, unknown>): [string, unknown][] => {
	const prioritizedKeys = [
		"chatId",
		"event",
		"phase",
		"outcome",
		"code",
		"sentAnyUpdate",
		"remainingSubscriptions",
		"transientFailureCount",
		"droppedSubscriptionsCount",
		"pushTokenType",
		"pushToken",
		"liveActivityToken",
	] as const;

	const entries = Object.entries(meta);
	const keyRank = new Map<string, number>();
	for (const [index, key] of prioritizedKeys.entries()) {
		keyRank.set(key, index);
	}

	return [...entries].sort(([leftKey], [rightKey]) => {
		const leftRank = keyRank.get(leftKey);
		const rightRank = keyRank.get(rightKey);
		if (leftRank !== undefined && rightRank !== undefined) {
			return leftRank - rightRank;
		}
		if (leftRank !== undefined) {
			return -1;
		}
		if (rightRank !== undefined) {
			return 1;
		}
		return leftKey.localeCompare(rightKey);
	});
};

const logLiveActivity = (
	level: "info" | "warn",
	message: string,
	meta?: Record<string, unknown>,
): void => {
	const timeLabel = withAnsiColor(toLogTimeLabel(), LIVE_ACTIVITY_COLOR_DIM);
	const levelLabel = level === "warn"
		? withAnsiColor("WARN", LIVE_ACTIVITY_COLOR_YELLOW)
		: withAnsiColor("INFO", LIVE_ACTIVITY_COLOR_CYAN);
	const prefix = withAnsiColor(LIVE_ACTIVITY_LOG_PREFIX, LIVE_ACTIVITY_COLOR_GRAY);
	const header = `${timeLabel} ${prefix} ${levelLabel} ${message}`;

	if (!meta || Object.keys(meta).length === 0) {
		if (level === "warn") {
			console.warn(header);
			return;
		}
		console.info(header);
		return;
	}

	if (LIVE_ACTIVITY_LOG_PLAIN || !process.stdout?.isTTY) {
		const plainLine = `${LIVE_ACTIVITY_LOG_PREFIX} ${level.toUpperCase()} ${message} ${JSON.stringify(meta)}`;
		if (level === "warn") {
			console.warn(plainLine);
			return;
		}
		console.info(plainLine);
		return;
	}

	const sortedEntries = toSortedLogEntries(meta);
	const metaLines = sortedEntries.map(([key, value]) => {
		const paddedKey = `${key}:`.padEnd(LIVE_ACTIVITY_LOG_META_KEY_WIDTH, " ");
		return `  ${withAnsiColor(paddedKey, LIVE_ACTIVITY_COLOR_GRAY)} ${toLogValue(value)}`;
	});
	const fullBlock = `${header}\n${metaLines.join("\n")}`;
	if (level === "warn") {
		console.warn(fullBlock);
		return;
	}
	console.info(fullBlock);
};

const logLiveActivityInfo = (message: string, meta?: Record<string, unknown>): void => {
	logLiveActivity("info", message, meta);
};

const logLiveActivityWarn = (message: string, meta?: Record<string, unknown>): void => {
	logLiveActivity("warn", message, meta);
};

const toTokenPreview = (token: string): string => {
	if (token.length <= 12) {
		return token;
	}

	return `${token.slice(0, 6)}...${token.slice(-4)}`;
};

const createNoopSender = (): LiveActivityPushSender => async () => ({
	delivered: true,
	shouldDropSubscription: false,
});

const PRIVATE_BACKEND_PUSH_TIMEOUT_MS = 20_000;

const createPrivateBackendSender = (input: {
	getConnectorCredentials: () => LiveActivityPushConnectorCredentials | null;
	privateBackendUrl: string;
}): LiveActivityPushSender => async (deliveryInput) => {
	const credentials = input.getConnectorCredentials();
	if (!credentials) {
		logLiveActivityWarn("push skipped (no connector credentials)", {
			chatId: deliveryInput.contentState.chatId,
			event: deliveryInput.event,
		});
		return {
			delivered: false,
			errorCode: "push/no-connector-credentials",
			shouldDropSubscription: false,
		};
	}

	const backendUrl = credentials.backendUrl || input.privateBackendUrl;
	const url = `${backendUrl.replace(/\/+$/u, "")}/v1/private/push-notification/deliver`;

	try {
		const controller = new AbortController();
		const timeout = setTimeout(() => controller.abort(), PRIVATE_BACKEND_PUSH_TIMEOUT_MS);

		const response = await fetch(url, {
			method: "POST",
			headers: {
				"content-type": "application/json",
				"x-connector-id": credentials.connectorId,
				"x-connector-token": credentials.connectorToken,
			},
			body: JSON.stringify({
				contentState: deliveryInput.contentState,
				event: deliveryInput.event,
				liveActivityToken: deliveryInput.liveActivityToken,
				pushToken: deliveryInput.pushToken,
				pushTokenType: deliveryInput.pushTokenType,
				timestampSeconds: deliveryInput.timestampSeconds,
				...(deliveryInput.attributesType ? { attributesType: deliveryInput.attributesType } : {}),
				...(deliveryInput.attributes ? { attributes: deliveryInput.attributes } : {}),
			}),
			signal: controller.signal,
		});

		clearTimeout(timeout);

		if (!response.ok) {
			const errorText = await response.text().catch(() => "");
			logLiveActivityWarn("private backend push delivery failed", {
				chatId: deliveryInput.contentState.chatId,
				event: deliveryInput.event,
				pushTokenType: deliveryInput.pushTokenType,
				status: response.status,
				error: errorText.slice(0, 200),
			});
			return {
				delivered: false,
				errorCode: `push/backend-status-${response.status}`,
				shouldDropSubscription: false,
			};
		}

		const result = await response.json() as LiveActivityPushDeliveryResult;
		logLiveActivityInfo("private backend push delivery result", {
			chatId: deliveryInput.contentState.chatId,
			event: deliveryInput.event,
			pushTokenType: deliveryInput.pushTokenType,
			delivered: result.delivered ?? false,
			shouldDropSubscription: result.shouldDropSubscription ?? false,
			errorCode: result.errorCode ?? null,
		});
		return {
			delivered: result.delivered ?? false,
			errorCode: result.errorCode,
			shouldDropSubscription: result.shouldDropSubscription ?? false,
		};
	} catch (error) {
		const isAbortError = error instanceof Error && error.name === "AbortError";
		logLiveActivityWarn("private backend push delivery error", {
			chatId: deliveryInput.contentState.chatId,
			event: deliveryInput.event,
			pushTokenType: deliveryInput.pushTokenType,
			error: isAbortError ? "timeout" : (error instanceof Error ? error.message : "unknown"),
		});
		return {
			delivered: false,
			errorCode: isAbortError ? "push/backend-timeout" : "push/backend-error",
			shouldDropSubscription: false,
		};
	}
};

const toPrivateBackendSupportedPushTokenTypes = (value: unknown): ReadonlySet<LiveActivityPushTokenType> => {
	if (!Array.isArray(value)) {
		return new Set();
	}

	const supportedPushTokenTypes = new Set<LiveActivityPushTokenType>();
	for (const entry of value) {
		if (entry === "apns" || entry === "fcm") {
			supportedPushTokenTypes.add(entry);
		}
	}

	return supportedPushTokenTypes;
};

const createPrivateBackendStatusReader = (input: {
	getConnectorCredentials: () => LiveActivityPushConnectorCredentials | null;
	privateBackendUrl: string;
}): (() => Promise<PrivateBackendPushStatus>) => async () => {
	const credentials = input.getConnectorCredentials();
	if (!credentials) {
		return {
			authoritative: true,
			enabled: false,
			supportedPushTokenTypes: new Set(),
		};
	}

	const backendUrl = credentials.backendUrl || input.privateBackendUrl;
	const url = `${backendUrl.replace(/\/+$/u, "")}/v1/private/push-notification/status`;
	let timeout: ReturnType<typeof setTimeout> | null = null;

	try {
		const controller = new AbortController();
		timeout = setTimeout(() => controller.abort(), PRIVATE_BACKEND_PUSH_TIMEOUT_MS);

		const response = await fetch(url, {
			method: "GET",
			headers: {
				"x-connector-id": credentials.connectorId,
				"x-connector-token": credentials.connectorToken,
			},
			signal: controller.signal,
		});

		clearTimeout(timeout);
		timeout = null;

		if (!response.ok) {
			const errorText = await response.text().catch(() => "");
			logLiveActivityWarn("private backend push status failed", {
				status: response.status,
				error: errorText.slice(0, 200),
			});
			return {
				authoritative: false,
				enabled: false,
				supportedPushTokenTypes: new Set(),
			};
		}

		const parsed = await response.json() as {
			enabled?: unknown;
			supportedPushTokenTypes?: unknown;
		};
		const supportedPushTokenTypes = toPrivateBackendSupportedPushTokenTypes(parsed.supportedPushTokenTypes);
		return {
			authoritative: true,
			enabled: parsed.enabled === true && supportedPushTokenTypes.size > 0,
			supportedPushTokenTypes,
		};
	} catch (error) {
		if (timeout) {
			clearTimeout(timeout);
		}
		const isAbortError = error instanceof Error && error.name === "AbortError";
		logLiveActivityWarn("private backend push status error", {
			error: isAbortError ? "timeout" : (error instanceof Error ? error.message : "unknown"),
		});
		return {
			authoritative: false,
			enabled: false,
			supportedPushTokenTypes: new Set(),
		};
	}
};

const toDebugContentState = (input: LiveActivityPushDebugSendInput): LiveActivityContentState => {
	const phase = input.phase ?? (input.event === "end" ? "completed" : "running");
	const chatTitle = toSafeLiveActivityText(
		toNormalized(input.chatTitle) || "Manual Live Activity Debug",
		TITLE_LIMIT,
		"title",
	);
	const preview = toSafeLiveActivityText(
		toNormalized(input.preview) || toDefaultPreview(phase),
		PREVIEW_LIMIT,
		"preview",
	);
	const statusLine = toSafeLiveActivityText(
		toNormalized(input.statusLine) || toDefaultStatusLine(phase),
		STATUS_LIMIT,
		"status",
	);

	return {
		chatId: toNormalized(input.chatId) || "manual-debug",
		chatTitle: chatTitle.length > 0 ? chatTitle : "Manual Live Activity Debug",
		elapsedSeconds: Math.max(0, Math.floor(input.elapsedSeconds ?? 0)),
		phase,
		preview: preview.length > 0 ? preview : toDefaultPreview(phase),
		statusLine: statusLine.length > 0 ? statusLine : toDefaultStatusLine(phase),
	};
};

class NoopLiveActivityPushService implements LiveActivityPushServiceContract {
	getIsEnabled(): boolean {
		return false;
	}

	async getSupportedPushTokenTypes(): Promise<ReadonlySet<LiveActivityPushTokenType>> {
		return new Set();
	}

	onAssistantDelta(): void {}

	onAssistantEvent(): void {}

	async onChatFinished(): Promise<void> {}

	onChatStarted(): void {}

	async upsertSubscription(): Promise<boolean> {
		return false;
	}

	async registerPushToStartToken(): Promise<void> {}
}

export class LiveActivityPushService implements LiveActivityPushServiceContract {
	private readonly runtimesByChatId = new Map<string, ChatRuntimeState>();
	private readonly subscriptions = new Map<string, LiveActivitySubscription>();
	private readonly pushToStartTokens = new Map<string, PushToStartTokenStored>();
	private readonly session: GlobalSessionState = {
		elapsedSecondsSnapshot: null,
		flushTimeout: null,
		heartbeatInterval: null,
		lastSentAtMs: 0,
		pendingEvent: null,
		revision: 0,
		sendAgain: false,
		sending: false,
		startedAtMs: 0,
	};
	private supportedPushTokenTypes: Set<LiveActivityPushTokenType>;

	constructor(
		private readonly sender: LiveActivityPushSender,
		supportedPushTokenTypes: ReadonlySet<LiveActivityPushTokenType> = new Set(["apns", "fcm"]),
		private readonly subscriptionStore?: LiveActivityPushSubscriptionStoreContract,
		private readonly pushToStartTokenStore?: PushToStartTokenStoreContract,
	) {
		this.supportedPushTokenTypes = new Set(supportedPushTokenTypes);
		this.restorePersistedSubscriptions();
		this.restorePersistedPushToStartTokens();
	}

	private restorePersistedPushToStartTokens(): void {
		const tokens = this.pushToStartTokenStore?.listAll() ?? [];
		for (const token of tokens) {
			if (!this.supportedPushTokenTypes.has(token.pushTokenType)) {
				continue;
			}
			const key = `${token.pushTokenType}::${token.pushToken}`;
			this.pushToStartTokens.set(key, token);
		}

		logLiveActivityInfo("restore push-to-start tokens", {
			hasStore: Boolean(this.pushToStartTokenStore),
			persisted: tokens.length,
			loaded: this.pushToStartTokens.size,
		});
	}

	private restorePersistedSubscriptions(): void {
		const persistedSubscriptions = this.subscriptionStore?.listAll() ?? [];
		for (const subscription of persistedSubscriptions) {
			if (!this.supportedPushTokenTypes.has(subscription.pushTokenType)) {
				continue;
			}
			this.setSubscriptionInMemory(subscription);
		}
		this.pruneStaleSubscriptionsByDevice();

		logLiveActivityInfo("restore subscriptions", {
			hasStore: Boolean(this.subscriptionStore),
			persisted: persistedSubscriptions.length,
			loaded: this.subscriptions.size,
		});
	}

	private setSubscriptionInMemory(input: LiveActivityPushStoredSubscription): LiveActivitySubscription {
		const subscriptionKey = toSubscriptionKey({
			pushToken: input.pushToken,
			pushTokenType: input.pushTokenType,
			liveActivityToken: input.liveActivityToken,
		});
		const previousSubscription = this.subscriptions.get(subscriptionKey);
		const subscription: LiveActivitySubscription = {
			chatId: input.chatId,
			chatTitle: toNormalized(input.chatTitle) || undefined,
			liveActivityToken: input.liveActivityToken,
			pushToken: input.pushToken,
			pushTokenType: input.pushTokenType,
			lastDeliveredSignature: previousSubscription?.lastDeliveredSignature,
			lastTimestampSeconds: previousSubscription?.lastTimestampSeconds,
			updatedAtMs: Date.parse(input.updatedAt) || Date.now(),
		};
		this.subscriptions.set(subscriptionKey, subscription);
		return subscription;
	}

	private pruneStaleSubscriptionsByDevice(): void {
		const latestByDevice = new Map<string, { key: string; subscription: LiveActivitySubscription }>();
		for (const [key, subscription] of this.subscriptions.entries()) {
			const deviceKey = toPushDeviceKey(subscription);
			const current = latestByDevice.get(deviceKey);
			if (!current || subscription.updatedAtMs >= current.subscription.updatedAtMs) {
				latestByDevice.set(deviceKey, { key, subscription });
			}
		}

		for (const [key, subscription] of this.subscriptions.entries()) {
			const deviceKey = toPushDeviceKey(subscription);
			const latest = latestByDevice.get(deviceKey);
			if (!latest || latest.key === key) {
				continue;
			}

			this.subscriptions.delete(key);
			this.deletePersistedSubscription({
				chatId: subscription.chatId,
				chatTitle: subscription.chatTitle,
				liveActivityToken: subscription.liveActivityToken,
				pushToken: subscription.pushToken,
				pushTokenType: subscription.pushTokenType,
			});
			logLiveActivityInfo("pruned stale subscription for device", {
				chatId: subscription.chatId,
				pushTokenType: subscription.pushTokenType,
				pushToken: toTokenPreview(subscription.pushToken),
				liveActivityToken: toTokenPreview(subscription.liveActivityToken),
			});
		}
	}

	private deleteConflictingSubscriptions(input: LiveActivityPushSubscriptionInput): void {
		for (const [key, subscriptionEntry] of this.subscriptions.entries()) {
			const samePushTokenWithOldActivityToken =
				subscriptionEntry.pushToken === input.pushToken
				&& subscriptionEntry.pushTokenType === input.pushTokenType
				&& subscriptionEntry.liveActivityToken !== input.liveActivityToken;
			const sameActivityTokenWithDifferentPushToken =
				subscriptionEntry.liveActivityToken === input.liveActivityToken
				&& (
					subscriptionEntry.pushToken !== input.pushToken
					|| subscriptionEntry.pushTokenType !== input.pushTokenType
				);
			if (!samePushTokenWithOldActivityToken && !sameActivityTokenWithDifferentPushToken) {
				continue;
			}

			this.subscriptions.delete(key);
			this.deletePersistedSubscription({
				chatId: subscriptionEntry.chatId,
				chatTitle: subscriptionEntry.chatTitle,
				liveActivityToken: subscriptionEntry.liveActivityToken,
				pushToken: subscriptionEntry.pushToken,
				pushTokenType: subscriptionEntry.pushTokenType,
			});
			logLiveActivityInfo("replacing stale subscription token pair", {
				chatId: subscriptionEntry.chatId,
				nextChatId: input.chatId,
				pushTokenType: subscriptionEntry.pushTokenType,
				pushToken: toTokenPreview(subscriptionEntry.pushToken),
				liveActivityToken: toTokenPreview(subscriptionEntry.liveActivityToken),
			});
		}
	}

	getIsEnabled(): boolean {
		return true;
	}

	async getSupportedPushTokenTypes(): Promise<ReadonlySet<LiveActivityPushTokenType>> {
		return new Set(this.supportedPushTokenTypes);
	}

	private persistSubscription(input: LiveActivityPushSubscriptionInput): LiveActivityPushStoredSubscription | null {
		if (!this.subscriptionStore) {
			return {
				...input,
				updatedAt: new Date().toISOString(),
			};
		}

		try {
			return this.subscriptionStore.upsert(input);
		} catch {
			logLiveActivityWarn("subscription persistence failed", {
				chatId: input.chatId,
				pushTokenType: input.pushTokenType,
				pushToken: toTokenPreview(input.pushToken),
				liveActivityToken: toTokenPreview(input.liveActivityToken),
			});
			return null;
		}
	}

	private deletePersistedSubscription(input: LiveActivityPushSubscriptionInput): void {
		if (!this.subscriptionStore) {
			return;
		}

		try {
			this.subscriptionStore.deleteExact(input);
		} catch {
			logLiveActivityWarn("subscription persistence delete failed", {
				chatId: input.chatId,
				pushTokenType: input.pushTokenType,
				pushToken: toTokenPreview(input.pushToken),
				liveActivityToken: toTokenPreview(input.liveActivityToken),
			});
		}
	}

	private deletePersistedPushToStartToken(input: PushToStartTokenStored): void {
		if (!this.pushToStartTokenStore) {
			return;
		}

		try {
			this.pushToStartTokenStore.deleteByPushToken(input.pushToken, input.pushTokenType);
		} catch {
			logLiveActivityWarn("push-to-start token persistence delete failed", {
				pushTokenType: input.pushTokenType,
				pushToken: toTokenPreview(input.pushToken),
			});
		}
	}

	private getRuntime(chatId: string): ChatRuntimeState | null {
		return this.runtimesByChatId.get(chatId) ?? null;
	}

	private hasSubscriptions(): boolean {
		return this.subscriptions.size > 0;
	}

	private getSessionCounts(): {
		activeCount: number;
		finalizingCount: number;
		runningCount: number;
		worstOutcome: TerminalOutcome | null;
	} {
		let runningCount = 0;
		let finalizingCount = 0;
		let worstOutcome: TerminalOutcome | null = null;

		for (const runtime of this.runtimesByChatId.values()) {
			if (runtime.phase === "running") {
				runningCount += 1;
				continue;
			}
			if (runtime.phase === "finalizing") {
				finalizingCount += 1;
				continue;
			}
			if (runtime.phase === "completed" || runtime.phase === "failed" || runtime.phase === "error") {
				worstOutcome = toWorstTerminalOutcome(worstOutcome, runtime.phase);
			}
		}

		return {
			activeCount: runningCount + finalizingCount,
			finalizingCount,
			runningCount,
			worstOutcome,
		};
	}

	private hasRenderableSession(): boolean {
		return this.runtimesByChatId.size > 0;
	}

	private resetGlobalSession(startedAtMs: number): void {
		this.session.revision += 1;
		this.clearScheduledFlush();
		this.clearHeartbeat();
		this.runtimesByChatId.clear();
		this.session.elapsedSecondsSnapshot = null;
		this.session.lastSentAtMs = 0;
		this.session.pendingEvent = null;
		this.session.sendAgain = false;
		this.session.sending = false;
		this.session.startedAtMs = startedAtMs;
	}

	private getOrCreateRuntime(input: { chatId: string; chatTitle?: string }): ChatRuntimeState {
		const existing = this.runtimesByChatId.get(input.chatId);
		if (existing) {
			const nextTitle = toNormalized(input.chatTitle);
			if (nextTitle.length > 0) {
				existing.chatTitle = nextTitle;
			}
			return existing;
		}

		const runtime: ChatRuntimeState = {
			chatId: input.chatId,
			chatTitle: toNormalized(input.chatTitle) || "Thread",
			phase: "running",
			preview: toDefaultPreview("running"),
			previewSource: "default",
			startedAtMs: Date.now(),
			statusLine: toDefaultStatusLine("running"),
			lastSentAtMs: 0,
			flushTimeout: null,
			heartbeatInterval: null,
			sending: false,
			sendAgain: false,
			pendingEvent: null,
		};
		this.runtimesByChatId.set(input.chatId, runtime);
		return runtime;
	}

	private getLatestActiveRuntime(): ChatRuntimeState | null {
		let latest: ChatRuntimeState | null = null;
		for (const runtime of this.runtimesByChatId.values()) {
			if (runtime.phase === "running" || runtime.phase === "finalizing") {
				if (!latest || runtime.startedAtMs >= latest.startedAtMs) {
					latest = runtime;
				}
			}
		}
		return latest;
	}

	private toContentState(): LiveActivityContentState | null {
		const { activeCount, finalizingCount, runningCount, worstOutcome } = this.getSessionCounts();
		if (!this.hasRenderableSession()) {
			return null;
		}

		if (activeCount > 0) {
			const phase: LiveActivityPhase = runningCount > 0 ? "running" : "finalizing";
			const dynamicTitle = toSafeLiveActivityText(
				`${String(activeCount)} Active Thread${activeCount === 1 ? "" : "s"}`,
				TITLE_LIMIT,
				"title",
			);
			const latestRuntime = this.getLatestActiveRuntime();
			const statusLine = latestRuntime
				? toSafeLiveActivityText(latestRuntime.statusLine, STATUS_LIMIT, "status") || (runningCount > 0 ? toRunningStatusLine(activeCount) : toFinalizingStatusLine(finalizingCount))
				: (runningCount > 0 ? toRunningStatusLine(activeCount) : toFinalizingStatusLine(finalizingCount));
			const preview = latestRuntime && latestRuntime.previewSource !== "default"
				? toSafeLiveActivityText(latestRuntime.preview, PREVIEW_LIMIT, "preview") || (runningCount > 0 ? toRunningPreview(activeCount) : toFinalizingPreview(finalizingCount))
				: (runningCount > 0 ? toRunningPreview(activeCount) : toFinalizingPreview(finalizingCount));

			return {
				chatId: GLOBAL_ACTIVITY_CHAT_ID,
				chatTitle: dynamicTitle.length > 0 ? dynamicTitle : GLOBAL_ACTIVITY_TITLE,
				elapsedSeconds: toElapsedSeconds(this.session.startedAtMs),
				phase,
				preview,
				statusLine,
			};
		}

		const outcome = worstOutcome ?? "completed";
		return {
			chatId: GLOBAL_ACTIVITY_CHAT_ID,
			chatTitle: GLOBAL_ACTIVITY_TITLE,
			elapsedSeconds: Math.max(0, Math.floor(this.session.elapsedSecondsSnapshot ?? 0)),
			phase: outcome,
			preview: toTerminalPreview(),
			statusLine: toTerminalStatusLine(outcome),
		};
	}

	private clearScheduledFlush(): void {
		if (!this.session.flushTimeout) {
			return;
		}

		clearTimeout(this.session.flushTimeout);
		this.session.flushTimeout = null;
	}

	private hasAnyDeliveryTarget(): boolean {
		return this.hasSubscriptions() || this.pushToStartTokens.size > 0;
	}

	private ensureHeartbeat(): void {
		const { activeCount } = this.getSessionCounts();
		if (this.session.heartbeatInterval || activeCount === 0 || !this.hasAnyDeliveryTarget()) {
			return;
		}

		logLiveActivityInfo("heartbeat started", {
			chatId: GLOBAL_ACTIVITY_CHAT_ID,
			intervalMs: PUSH_HEARTBEAT_INTERVAL_MS,
		});
		this.session.heartbeatInterval = setInterval(() => {
			void this.queueFlush("update");
		}, PUSH_HEARTBEAT_INTERVAL_MS);
		this.session.heartbeatInterval.unref?.();
	}

	private clearHeartbeat(): void {
		if (!this.session.heartbeatInterval) {
			return;
		}

		logLiveActivityInfo("heartbeat stopped", { chatId: GLOBAL_ACTIVITY_CHAT_ID });
		clearInterval(this.session.heartbeatInterval);
		this.session.heartbeatInterval = null;
	}

	private markPendingEvent(event: PushEvent): void {
		if (event === "end" || this.session.pendingEvent !== "end") {
			this.session.pendingEvent = event;
		}
	}

	private scheduleUpdateFlush(): void {
		if (this.session.flushTimeout || this.session.pendingEvent === "end") {
			return;
		}

		const elapsedSinceLastSendMs = Date.now() - this.session.lastSentAtMs;
		const delayMs = this.session.lastSentAtMs <= 0
			? 0
			: Math.max(0, PUSH_MIN_UPDATE_INTERVAL_MS - elapsedSinceLastSendMs);

		logLiveActivityInfo("flush scheduled", {
			chatId: GLOBAL_ACTIVITY_CHAT_ID,
			delayMs,
		});
		this.session.flushTimeout = setTimeout(() => {
			this.session.flushTimeout = null;
			void this.flushSession("update");
		}, delayMs);
		this.session.flushTimeout.unref?.();
	}

	private queueFlush(event: PushEvent, input?: { immediate?: boolean }): void {
		if (!this.hasRenderableSession()) {
			return;
		}

		this.markPendingEvent(event);
		if (this.session.sending) {
			this.session.sendAgain = true;
			return;
		}
		const immediate = input?.immediate ?? event === "end";
		if (immediate) {
			logLiveActivityInfo("queue flush immediate", {
				chatId: GLOBAL_ACTIVITY_CHAT_ID,
				event,
			});
			this.clearScheduledFlush();
			void this.flushSession(event, {
				force: true,
			});
			return;
		}

		this.ensureHeartbeat();
		this.scheduleUpdateFlush();
	}

	private async flushSession(event: PushEvent, input?: { force?: boolean }): Promise<void> {
		if (!this.hasRenderableSession()) {
			return;
		}

		const revision = this.session.revision;
		const nextEvent: PushEvent = this.session.pendingEvent === "end" ? "end" : event;
		const deliveryEvent: PushEvent = nextEvent === "end" ? "update" : nextEvent;
		if (nextEvent === "end") {
			this.clearScheduledFlush();
		}

		const subscriptions = [...this.subscriptions.entries()];
		const hasSubscriptions = subscriptions.length > 0;
		const hasPushToStartTokens = this.pushToStartTokens.size > 0;

		if (!hasSubscriptions && !hasPushToStartTokens) {
			if (this.session.pendingEvent === nextEvent) {
				this.session.pendingEvent = null;
			}
			logLiveActivityInfo("flush skipped (no subscriptions or devices)", {
				chatId: GLOBAL_ACTIVITY_CHAT_ID,
				event: nextEvent,
			});
			this.clearHeartbeat();
			return;
		}

		if (this.session.sending) {
			logLiveActivityInfo("flush skipped (already sending)", {
				chatId: GLOBAL_ACTIVITY_CHAT_ID,
				event: nextEvent,
			});
			this.markPendingEvent(nextEvent);
			this.session.sendAgain = true;
			return;
		}

		this.session.sending = true;
		if (this.session.pendingEvent === nextEvent) {
			this.session.pendingEvent = null;
		}

		try {
			const contentState = this.toContentState();
			if (!contentState) {
				return;
			}
			const force = input?.force ?? false;
			const elapsedSinceLastSendMs = Date.now() - this.session.lastSentAtMs;
			if (nextEvent === "update" && !force && this.session.lastSentAtMs > 0 && elapsedSinceLastSendMs < PUSH_MIN_UPDATE_INTERVAL_MS) {
				this.markPendingEvent("update");
				logLiveActivityInfo("flush deferred by min interval", {
					chatId: GLOBAL_ACTIVITY_CHAT_ID,
					elapsedSinceLastSendMs,
					minIntervalMs: PUSH_MIN_UPDATE_INTERVAL_MS,
				});
				this.scheduleUpdateFlush();
				return;
			}
			const deliverySignature = toDeliverySignature({
				contentState,
				event: deliveryEvent,
			});
			let attemptedAnyDelivery = false;
			let sentAnyUpdate = false;
			let hadTransientFailure = false;
			let retainedFailureCount = 0;
			let skippedDuplicateCount = 0;
			let transientFailureCount = 0;
			const coveredPushToStartDeviceKeys = new Set<string>();
			const { activeCount } = this.getSessionCounts();

			for (const [key, subscription] of subscriptions) {
				const subscriptionDeviceKey = toPushDeviceKey(subscription);
				if (deliveryEvent === "update" && !force && subscription.lastDeliveredSignature === deliverySignature) {
					skippedDuplicateCount += 1;
					coveredPushToStartDeviceKeys.add(subscriptionDeviceKey);
					continue;
				}

				const timestampSeconds = toNextTimestampSeconds({
					lastTimestampSeconds: subscription.lastTimestampSeconds,
				});
				attemptedAnyDelivery = true;
				const deliveryResult = await this.sender({
					contentState,
					event: deliveryEvent,
					pushToken: subscription.pushToken,
					pushTokenType: subscription.pushTokenType,
					liveActivityToken: subscription.liveActivityToken,
					timestampSeconds,
				});
				if (this.session.revision !== revision) {
					return;
				}
				if (deliveryResult.shouldDropSubscription) {
					hadTransientFailure = true;
					retainedFailureCount += 1;
					transientFailureCount += 1;
					logLiveActivityWarn("permanent push delivery failure (subscription kept)", {
						chatId: GLOBAL_ACTIVITY_CHAT_ID,
						event: deliveryEvent,
						code: deliveryResult.errorCode ?? "unknown",
						pushTokenType: subscription.pushTokenType,
						pushToken: toTokenPreview(subscription.pushToken),
						liveActivityToken: toTokenPreview(subscription.liveActivityToken),
					});
					continue;
				}
				if (!deliveryResult.delivered) {
					hadTransientFailure = true;
					transientFailureCount += 1;
					logLiveActivityWarn("transient push delivery failure", {
						chatId: GLOBAL_ACTIVITY_CHAT_ID,
						event: deliveryEvent,
						code: deliveryResult.errorCode ?? "unknown",
						pushTokenType: subscription.pushTokenType,
						pushToken: toTokenPreview(subscription.pushToken),
						liveActivityToken: toTokenPreview(subscription.liveActivityToken),
					});
					continue;
				}

				this.subscriptions.set(key, {
					...subscription,
					lastDeliveredSignature: deliverySignature,
					lastTimestampSeconds: timestampSeconds,
				});
				coveredPushToStartDeviceKeys.add(subscriptionDeviceKey);
				sentAnyUpdate = true;
			}

			// Push-to-start is only a bootstrap/recovery path for active sessions.
			if (activeCount > 0) {
				for (const tokenEntry of this.pushToStartTokens.values()) {
					const deviceKey = toPushDeviceKey(tokenEntry);
					if (coveredPushToStartDeviceKeys.has(deviceKey)) {
						continue;
					}
					try {
						attemptedAnyDelivery = true;
						const pushToStartResult = await this.sender({
							contentState,
							event: "start",
							pushToken: tokenEntry.pushToken,
							pushTokenType: tokenEntry.pushTokenType,
							liveActivityToken: tokenEntry.pushToStartToken,
							timestampSeconds: toNextTimestampSeconds({}),
							attributesType: LIVE_ACTIVITY_ATTRIBUTES_TYPE,
							attributes: {
								deepLink: LIVE_ACTIVITY_DEEP_LINK,
							},
						});
						if (this.session.revision !== revision) {
							return;
						}
						if (pushToStartResult.delivered) {
							sentAnyUpdate = true;
						} else {
							logLiveActivityWarn("push-to-start broadcast delivery failed", {
								chatId: GLOBAL_ACTIVITY_CHAT_ID,
								event: nextEvent,
								code: pushToStartResult.errorCode ?? "unknown",
								pushTokenType: tokenEntry.pushTokenType,
								pushToken: toTokenPreview(tokenEntry.pushToken),
							});
						}
					} catch {
						logLiveActivityWarn("push-to-start broadcast error", {
							chatId: GLOBAL_ACTIVITY_CHAT_ID,
							pushTokenType: tokenEntry.pushTokenType,
						});
					}
				}
			}

			if (hadTransientFailure) {
				this.markPendingEvent(nextEvent);
			}

			if (attemptedAnyDelivery) {
				this.session.lastSentAtMs = Date.now();
			}
			logLiveActivityInfo("flush completed", {
				chatId: GLOBAL_ACTIVITY_CHAT_ID,
				retainedFailureCount,
				elapsedSeconds: contentState.elapsedSeconds,
				event: deliveryEvent,
				hadTransientFailure,
				phase: contentState.phase,
				previewTail: contentState.preview.slice(-80),
				remainingSubscriptions: this.subscriptions.size,
				pushToStartDevices: this.pushToStartTokens.size,
				sentAnyUpdate,
				skippedDuplicateCount,
				statusLine: contentState.statusLine,
				transientFailureCount,
			});
		} finally {
			if (this.session.revision !== revision) {
				return;
			}
			this.session.sending = false;
			const shouldFlushAgain = this.session.sendAgain;
			this.session.sendAgain = false;
			if (shouldFlushAgain) {
				this.queueFlush("update", {
					immediate: true,
				});
				return;
			}
			if (this.session.pendingEvent === "update" || this.session.pendingEvent === "end") {
				this.scheduleUpdateFlush();
				if (this.getSessionCounts().activeCount > 0) {
					this.ensureHeartbeat();
				} else {
					this.clearHeartbeat();
				}
				return;
			}
			if (this.getSessionCounts().activeCount > 0) {
				this.ensureHeartbeat();
				return;
			}
			this.clearHeartbeat();
		}
	}

	onChatStarted(input: LiveActivityPushStartInput): void {
		const { activeCount } = this.getSessionCounts();
		if (activeCount === 0) {
			this.resetGlobalSession(Date.now());
		}

		const hadRuntime = this.getRuntime(input.chatId) !== null;
		const runtime = this.getOrCreateRuntime({
			chatId: input.chatId,
			chatTitle: input.chatTitle,
		});
		const alreadyActive = hadRuntime && !isTerminalPhase(runtime.phase);
		if (!alreadyActive) {
			logLiveActivityInfo("chat started", {
				chatId: input.chatId,
				chatTitle: runtime.chatTitle,
				sessionStartedAtMs: this.session.startedAtMs,
			});
		}
		if (isTerminalPhase(runtime.phase)) {
			runtime.preview = toDefaultPreview("running");
			runtime.previewSource = "default";
		}
		runtime.pendingEvent = null;
		this.clearScheduledFlush();
		runtime.phase = "running";
		runtime.statusLine = toDefaultStatusLine("running");
		if (toNormalized(runtime.preview).length === 0) {
			runtime.preview = toDefaultPreview("running");
			runtime.previewSource = "default";
		}
		if (alreadyActive) {
			this.ensureHeartbeat();
			return;
		}

		this.queueFlush("update", {
			immediate: true,
		});

		if (!this.hasSubscriptions() && this.pushToStartTokens.size === 0) {
			logLiveActivityInfo("chat started without any registered devices", {
				chatId: input.chatId,
			});
		}
		this.ensureHeartbeat();
	}

	onAssistantDelta(chatId: string, delta: string): void {
		const runtime = this.getRuntime(chatId);
		if (!runtime) {
			return;
		}

		const normalizedDelta = toNormalizedPreviewText(delta);
		if (
			normalizedDelta.length > 0
			&& (runtime.previewSource === "default" || runtime.previewSource === "legacy-response")
		) {
			const previewBase = runtime.previewSource === "legacy-response"
				? runtime.preview
				: "";
			runtime.preview = toPreviewChunk(previewBase, normalizedDelta);
			runtime.previewSource = "legacy-response";
		}
		const previousPhase = runtime.phase;
		if (runtime.phase !== "finalizing") {
			runtime.phase = "running";
		}
		runtime.statusLine = toDefaultStatusLine(runtime.phase);
		if (previousPhase !== runtime.phase) {
			this.queueFlush("update");
		}
	}

	onAssistantEvent(chatId: string, event: AssistantStreamEvent): void {
		const runtime = this.getRuntime(chatId);
		if (!runtime) {
			return;
		}

		if (
			event.type !== "item_delta"
			&& event.type !== "item_started"
			&& event.type !== "item_completed"
			&& event.type !== "item_state"
			&& event.type !== "turn_completed"
		) {
			return;
		}

		if (event.type === "item_delta") {
			const previousPhase = runtime.phase;
			runtime.phase = "running";
			const deltaText = toNormalizedPreviewText(event.delta);
			if ((event.target === "body" || event.target === "output") && deltaText.length > 0) {
				const previewBase = runtime.previewSource === "structured-response" ? runtime.preview : "";
				runtime.preview = toPreviewChunk(previewBase, deltaText);
				runtime.previewSource = "structured-response";
			}
			if (event.target === "summary" && deltaText.length > 0) {
				runtime.statusLine = deltaText;
				runtime.preview = toLatestPreview(deltaText);
				runtime.previewSource = "event";
			}
			if (previousPhase !== runtime.phase) {
				this.queueFlush("update");
			}
			return;
		}

		const previousPhase = runtime.phase;
		runtime.phase = toPhaseFromEvent(event);
		runtime.statusLine = toStatusLineFromEvent(event) ?? toDefaultStatusLine(runtime.phase);
		const eventSummary = toEventSummary(event);
		if (eventSummary) {
			runtime.preview = toLatestPreview(eventSummary);
			runtime.previewSource = "event";
		}
		logLiveActivityInfo("assistant event", {
			chatId,
			event: event.type,
			previousPhase,
			phase: runtime.phase,
			statusLine: runtime.statusLine,
		});
		if (previousPhase !== runtime.phase || event.type === "turn_completed") {
			this.queueFlush("update", {
				immediate: true,
			});
		}
	}

	async onChatFinished(input: LiveActivityPushFinishInput): Promise<void> {
		const runtime = this.getRuntime(input.chatId) ?? this.getOrCreateRuntime({
			chatId: input.chatId,
			chatTitle: input.chatTitle,
		});
		const normalizedTitle = toNormalized(input.chatTitle);
		if (normalizedTitle.length > 0) {
			runtime.chatTitle = normalizedTitle;
		}

		runtime.phase = input.outcome;
		runtime.statusLine = toDefaultStatusLine(input.outcome);
		if (toNormalized(runtime.preview).length === 0) {
			runtime.preview = toDefaultPreview(input.outcome);
			runtime.previewSource = "default";
		}
		const countsAfter = this.getSessionCounts();
		if (countsAfter.activeCount === 0) {
			this.session.elapsedSecondsSnapshot = this.session.startedAtMs > 0
				? toElapsedSeconds(this.session.startedAtMs)
				: 0;
		}
		logLiveActivityInfo("chat finished", {
			chatId: input.chatId,
			outcome: input.outcome,
			phase: runtime.phase,
			activeThreadCount: countsAfter.activeCount,
		});

		this.clearScheduledFlush();
		if (countsAfter.activeCount === 0) {
			this.clearHeartbeat();
		}
		await this.flushSession("update", {
			force: true,
		});
		logLiveActivityInfo("chat finish cleanup completed", {
			chatId: input.chatId,
		});
	}

	async registerPushToStartToken(input: PushToStartTokenInput): Promise<void> {
		const pushToken = toNormalized(input.pushToken);
		const pushTokenType = input.pushTokenType;
		const pushToStartToken = toNormalized(input.pushToStartToken);
		if (
			pushToken.length === 0
			|| pushToStartToken.length === 0
			|| (pushTokenType !== "apns" && pushTokenType !== "fcm")
		) {
			return;
		}

		if (!this.supportedPushTokenTypes.has(pushTokenType)) {
			return;
		}

		const key = `${pushTokenType}::${pushToken}`;
		this.pushToStartTokens.set(key, {
			pushToStartToken,
			pushToken,
			pushTokenType,
			updatedAt: new Date().toISOString(),
		});

		try {
			this.pushToStartTokenStore?.upsert({
				pushToStartToken,
				pushToken,
				pushTokenType,
			});
		} catch {
			logLiveActivityWarn("push-to-start token persistence failed", {
				pushTokenType,
				pushToken: toTokenPreview(pushToken),
			});
		}

		logLiveActivityInfo("push-to-start token registered", {
			pushTokenType,
			pushToken: toTokenPreview(pushToken),
			pushToStartToken: toTokenPreview(pushToStartToken),
		});

		// Send push-to-start to all active (non-terminal) chats so the device
		// creates a Live Activity and registers a real subscription back.
		if (this.getSessionCounts().activeCount > 0) {
			logLiveActivityInfo("queueing active-session bootstrap for late-registered device", {
				chatId: GLOBAL_ACTIVITY_CHAT_ID,
				pushTokenType,
				pushToken: toTokenPreview(pushToken),
			});
			this.queueFlush("update", {
				immediate: true,
			});
		}
	}

	pruneUnsupportedPushTokenTypes(supportedPushTokenTypes: ReadonlySet<LiveActivityPushTokenType>): void {
		this.supportedPushTokenTypes = new Set(supportedPushTokenTypes);
		let removedSubscriptions = 0;
		for (const [key, subscriptionEntry] of this.subscriptions.entries()) {
			if (this.supportedPushTokenTypes.has(subscriptionEntry.pushTokenType)) {
				continue;
			}

			this.subscriptions.delete(key);
			this.deletePersistedSubscription({
				chatId: subscriptionEntry.chatId,
				chatTitle: subscriptionEntry.chatTitle,
				liveActivityToken: subscriptionEntry.liveActivityToken,
				pushToken: subscriptionEntry.pushToken,
				pushTokenType: subscriptionEntry.pushTokenType,
			});
			removedSubscriptions += 1;
		}

		let removedPushToStartTokens = 0;
		for (const [key, tokenEntry] of this.pushToStartTokens.entries()) {
			if (this.supportedPushTokenTypes.has(tokenEntry.pushTokenType)) {
				continue;
			}

			this.pushToStartTokens.delete(key);
			this.deletePersistedPushToStartToken(tokenEntry);
			removedPushToStartTokens += 1;
		}

		logLiveActivityInfo("backend capability refresh", {
			removedPushToStartTokens,
			removedSubscriptions,
			supportedPushTokenTypes: Array.from(supportedPushTokenTypes),
		});
	}

	async upsertSubscription(input: LiveActivityPushSubscriptionInput): Promise<boolean> {
		const pushToken = toNormalized(input.pushToken);
		const pushTokenType = input.pushTokenType;
		const liveActivityToken = toNormalized(input.liveActivityToken);
		const chatId = toNormalized(input.chatId);
		if (
			chatId.length === 0
			|| pushToken.length === 0
			|| liveActivityToken.length === 0
			|| (pushTokenType !== "apns" && pushTokenType !== "fcm")
		) {
			logLiveActivityWarn("subscription rejected (invalid input)", {
				chatId: chatId || "(empty)",
				pushTokenType,
				hasPushToken: pushToken.length > 0,
				hasLiveActivityToken: liveActivityToken.length > 0,
			});
			return false;
		}
		if (!this.supportedPushTokenTypes.has(pushTokenType)) {
			logLiveActivityWarn("subscription ignored (unsupported push token type)", {
				chatId,
				pushTokenType,
			});
			return false;
		}

		this.deleteConflictingSubscriptions({
			chatId,
			chatTitle: input.chatTitle,
			liveActivityToken,
			pushToken,
			pushTokenType,
		});
		const subscriptionKey = toSubscriptionKey({
			pushToken,
			pushTokenType,
			liveActivityToken,
		});
		const previousSubscription = this.subscriptions.get(subscriptionKey);
		const persistedSubscription = this.persistSubscription({
			chatId,
			chatTitle: toNormalized(input.chatTitle) || undefined,
			liveActivityToken,
			pushToken,
			pushTokenType,
		});
		if (!persistedSubscription) {
			return false;
		}

		this.setSubscriptionInMemory(persistedSubscription);
		this.pruneStaleSubscriptionsByDevice();
		logLiveActivityInfo("subscription upserted", {
			chatId,
			isNewSubscription: !previousSubscription,
			subscriptions: this.subscriptions.size,
			pushTokenType,
			pushToken: toTokenPreview(pushToken),
			liveActivityToken: toTokenPreview(liveActivityToken),
		});

		const contentState = this.toContentState();
		if (!contentState) {
			return true;
		}
		if (this.getSessionCounts().activeCount > 0) {
			this.ensureHeartbeat();
		}
		const shouldFlushImmediately =
			!previousSubscription
			|| previousSubscription.chatId !== chatId
			|| previousSubscription.chatTitle !== (toNormalized(input.chatTitle) || undefined)
			|| contentState.phase !== "running";
		if (shouldFlushImmediately) {
			await this.flushSession("update", {
				force: true,
			});
		}
		return true;
	}
}

class PrivateBackendLiveActivityPushService implements LiveActivityPushServiceContract {
	private capabilityCache: {
		expiresAtMs: number;
		value: PrivateBackendPushStatus;
	} | null = null;
	private capabilityRequest: Promise<PrivateBackendPushStatus> | null = null;

	constructor(
		private readonly delegate: LiveActivityPushService,
		private readonly getConnectorCredentials: () => LiveActivityPushConnectorCredentials | null,
		private readonly readStatus: () => Promise<PrivateBackendPushStatus>,
	) {}

	getIsEnabled(): boolean {
		if (!this.getConnectorCredentials()) {
			return false;
		}

		return this.capabilityCache?.value.enabled ?? true;
	}

	private async getCapabilities(): Promise<PrivateBackendPushStatus> {
		const now = Date.now();
		if (this.capabilityCache && this.capabilityCache.expiresAtMs > now) {
			return this.capabilityCache.value;
		}

		if (this.capabilityRequest) {
			return await this.capabilityRequest;
		}

		this.capabilityRequest = (async () => {
			const value = await this.readStatus();
			this.capabilityCache = {
				expiresAtMs: now + PRIVATE_BACKEND_STATUS_CACHE_TTL_MS,
				value,
			};
			if (value.authoritative) {
				this.delegate.pruneUnsupportedPushTokenTypes(value.supportedPushTokenTypes);
			}
			return value;
		})();

		try {
			return await this.capabilityRequest;
		} finally {
			this.capabilityRequest = null;
		}
	}

	async getSupportedPushTokenTypes(): Promise<ReadonlySet<LiveActivityPushTokenType>> {
		const capabilities = await this.getCapabilities();
		return new Set(capabilities.supportedPushTokenTypes);
	}

	onAssistantDelta(chatId: string, delta: string): void {
		this.delegate.onAssistantDelta(chatId, delta);
	}

	onAssistantEvent(chatId: string, event: AssistantStreamEvent): void {
		this.delegate.onAssistantEvent(chatId, event);
	}

	onChatStarted(input: LiveActivityPushStartInput): void {
		this.delegate.onChatStarted(input);
	}

	async onChatFinished(input: LiveActivityPushFinishInput): Promise<void> {
		await this.delegate.onChatFinished(input);
	}

	async upsertSubscription(input: LiveActivityPushSubscriptionInput): Promise<boolean> {
		await this.getCapabilities();
		return await this.delegate.upsertSubscription(input);
	}

	async registerPushToStartToken(input: PushToStartTokenInput): Promise<void> {
		await this.getCapabilities();
		await this.delegate.registerPushToStartToken(input);
	}
}

export const createNoopLiveActivityPushService = (): LiveActivityPushServiceContract =>
	new NoopLiveActivityPushService();

export const createLiveActivityPushServiceFromEnvironment = (
	input: LiveActivityPushEnvironmentInput,
): LiveActivityPushServiceContract => {
	const privateBackendSender = createPrivateBackendSender({
		getConnectorCredentials: input.getConnectorCredentials,
		privateBackendUrl: input.privateBackendUrl,
	});
	const readStatus = createPrivateBackendStatusReader({
		getConnectorCredentials: input.getConnectorCredentials,
		privateBackendUrl: input.privateBackendUrl,
	});

	const apnsConfig = loadApnsConfigFromEnvironment();
	const apnsSend = apnsConfig ? createApnsSender(apnsConfig) : null;
	const sender: LiveActivityPushSender = apnsSend
		? async (deliveryInput) => {
			const apnsResult = await apnsSend({
				contentState: deliveryInput.contentState,
				event: deliveryInput.event,
				liveActivityToken: deliveryInput.liveActivityToken,
				timestampSeconds: deliveryInput.timestampSeconds,
				attributesType: deliveryInput.attributesType,
				attributes: deliveryInput.attributes,
			});
			if (apnsResult.delivered) {
				return apnsResult;
			}
			// Fall back to private backend on APNS failure (not token-level errors)
			if (!apnsResult.shouldDropSubscription) {
				return await privateBackendSender(deliveryInput);
			}
			return apnsResult;
		}
		: privateBackendSender;

	logLiveActivityInfo("service enabled", {
		privateBackendUrl: input.privateBackendUrl,
		apnsDirect: Boolean(apnsSend),
		apnsSandbox: apnsConfig?.useSandbox ?? false,
	});

	return new PrivateBackendLiveActivityPushService(
		new LiveActivityPushService(sender, new Set(["apns", "fcm"]), input.subscriptionStore, input.pushToStartTokenStore),
		input.getConnectorCredentials,
		readStatus,
	);
};

export const createLiveActivityPushDebugClientFromEnvironment = (
	input: LiveActivityPushEnvironmentInput,
): LiveActivityPushDebugClientContract => {
	const sender = createPrivateBackendSender({
		getConnectorCredentials: input.getConnectorCredentials,
		privateBackendUrl: input.privateBackendUrl,
	});

	return {
		getIsEnabled: () => true,
		getSupportedPushTokenTypes: () => new Set<LiveActivityPushTokenType>(["apns", "fcm"]),
		send: async (debugInput) => await sender({
			contentState: toDebugContentState(debugInput),
			event: debugInput.event,
			liveActivityToken: toNormalized(debugInput.liveActivityToken),
			pushToken: toNormalized(debugInput.pushToken),
			pushTokenType: debugInput.pushTokenType,
			timestampSeconds: debugInput.timestampSeconds ?? Math.floor(Date.now() / 1_000),
		}),
	};
};

export const createLiveActivityPushServiceForTests = (
	sender?: LiveActivityPushSender,
	subscriptionStore?: LiveActivityPushSubscriptionStoreContract,
	pushToStartTokenStore?: PushToStartTokenStoreContract,
): LiveActivityPushService =>
	new LiveActivityPushService(sender ?? createNoopSender(), new Set(["apns", "fcm"]), subscriptionStore, pushToStartTokenStore);
