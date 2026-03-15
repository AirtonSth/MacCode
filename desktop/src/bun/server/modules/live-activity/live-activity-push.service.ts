import { readFileSync } from "node:fs";
import { connect } from "node:http2";
import { createSign } from "node:crypto";

import { cert, getApps, initializeApp, type ServiceAccount } from "firebase-admin/app";
import { getMessaging } from "firebase-admin/messaging";
import type { Message } from "firebase-admin/messaging";

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
} from "./live-activity-push.model";

const PUSH_MIN_UPDATE_INTERVAL_MS = 15_000;
const PUSH_HEARTBEAT_INTERVAL_MS = 15_000;
const PUSH_STALE_WINDOW_SECONDS = 180;
const PUSH_UPDATE_EXPIRATION_SECONDS = 300;
const PUSH_END_EXPIRATION_SECONDS = 120;
const PUSH_END_DISMISS_SECONDS = 30;
const PREVIEW_LIMIT = 140;
const TITLE_LIMIT = 80;
const STATUS_LIMIT = 80;
const SANITIZE_INPUT_CODEPOINT_LIMIT = 4_096;
const PREVIEW_ELLIPSIS = "...";
const LIVE_ACTIVITY_NAME = "ThreadLiveActivity";
const LIVE_ACTIVITY_TOPIC_SUFFIX = ".push-type.liveactivity";
const LIVE_ACTIVITY_LOG_PREFIX = "[live-activity]";
const LIVE_ACTIVITY_VERBOSE_LOGS = process.env.REMOTECODE_LIVE_ACTIVITY_VERBOSE_LOGS === "1";
const APNS_PRODUCTION_HOST = "https://api.push.apple.com";
const APNS_SANDBOX_HOST = "https://api.sandbox.push.apple.com";
const APNS_AUTH_TOKEN_TTL_MS = 50 * 60_000;
const APNS_REQUEST_TIMEOUT_MS = 15_000;

type PushEvent = "update" | "end";

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

interface LiveActivityPushDeliveryInput {
	contentState: LiveActivityContentState;
	event: PushEvent;
	pushToken: string;
	pushTokenType: LiveActivityPushTokenType;
	liveActivityToken: string;
	timestampSeconds: number;
}

export interface LiveActivityPushDeliveryResult {
	delivered: boolean;
	errorCode?: string;
	shouldDropSubscription: boolean;
}

type LiveActivityPushSender = (input: LiveActivityPushDeliveryInput) => Promise<LiveActivityPushDeliveryResult>;

type LiveActivityFirebaseMessage = Message & {
	apns?: NonNullable<Message["apns"]> & {
		liveActivityToken?: string;
	};
};

export interface LiveActivityPushEnvironmentInput {
	apnsAuthKeyId?: string;
	apnsPrivateKeyPath?: string;
	apnsTeamId?: string;
	apnsUseSandbox?: boolean;
	bundleIdentifier: string;
	firebaseProjectId?: string;
	serviceAccountPath?: string;
	subscriptionStore?: LiveActivityPushSubscriptionStoreContract;
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
}): Record<string, unknown> => {
	const timestampSeconds = typeof input.timestampSeconds === "number" && Number.isFinite(input.timestampSeconds)
		? Math.max(0, Math.floor(input.timestampSeconds))
		: Math.floor((input.nowMs ?? Date.now()) / 1_000);
	const serializedProps = (() => {
		try {
			const payload = JSON.stringify(input.contentState);
			const parsed = JSON.parse(payload) as unknown;
			if (!parsed || typeof parsed !== "object") {
				throw new Error("invalid serialized props");
			}
			return payload;
		} catch {
			return JSON.stringify({
				chatId: "unknown",
				chatTitle: "Thread",
				elapsedSeconds: 0,
				phase: "running",
				preview: "Working on your latest request.",
				statusLine: "Generating response",
			});
		}
	})();
	const apsPayload: Record<string, unknown> = {
		timestamp: timestampSeconds,
		event: input.event,
		"content-state": {
			name: LIVE_ACTIVITY_NAME,
			props: serializedProps,
		},
	};

	if (input.event === "update") {
		apsPayload["stale-date"] = timestampSeconds + PUSH_STALE_WINDOW_SECONDS;
	}

	if (input.event === "end") {
		apsPayload["dismissal-date"] = timestampSeconds + PUSH_END_DISMISS_SECONDS;
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

const toLiveActivityTopic = (bundleIdentifier: string): string => {
	const normalizedBundleId = toNormalized(bundleIdentifier);
	if (normalizedBundleId.endsWith(LIVE_ACTIVITY_TOPIC_SUFFIX)) {
		return normalizedBundleId;
	}

	return `${normalizedBundleId}${LIVE_ACTIVITY_TOPIC_SUFFIX}`;
};

const isLikelyWidgetExtensionBundleIdentifier = (bundleIdentifier: string): boolean => {
	const normalizedTopic = toNormalized(bundleIdentifier).toLowerCase();
	const normalized = normalizedTopic.endsWith(LIVE_ACTIVITY_TOPIC_SUFFIX)
		? normalizedTopic.slice(0, -LIVE_ACTIVITY_TOPIC_SUFFIX.length)
		: normalizedTopic;
	return normalized.endsWith(".expowidgetstarget")
		|| normalized.endsWith(".widget")
		|| normalized.endsWith(".widgetextension");
};

const toApnsPriority = (event: PushEvent): "10" | "5" => (
	event === "end" ? "10" : "5"
);

export const buildLiveActivityApnsHeaders = (input: {
	event: PushEvent;
	expirationSeconds: number;
	topic: string;
}): Record<string, string> => ({
	"apns-expiration": String(input.expirationSeconds),
	"apns-priority": toApnsPriority(input.event),
	"apns-push-type": "liveactivity",
	"apns-topic": input.topic,
});

const isTerminalPhase = (phase: LiveActivityPhase): boolean =>
	phase === "completed" || phase === "failed" || phase === "error";

const isPermanentMessagingFailure = (code: string | undefined): boolean => (
	code === "messaging/registration-token-not-registered"
	|| code === "messaging/invalid-registration-token"
);

const APNS_PERMANENT_REASONS = new Set<string>([
	"BadDeviceToken",
	"DeviceTokenNotForTopic",
	"TopicDisallowed",
	"Unregistered",
]);

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

const toBase64Url = (value: Buffer | string): string => Buffer
	.from(value)
	.toString("base64")
	.replace(/\+/gu, "-")
	.replace(/\//gu, "_")
	.replace(/=+$/gu, "");

const createApnsJwtSigner = (input: {
	keyId: string;
	privateKey: string;
	teamId: string;
}): (() => string) => {
	let cachedToken: string | null = null;
	let cachedTokenExpiresAtMs = 0;

	return () => {
		const now = Date.now();
		if (cachedToken && cachedTokenExpiresAtMs > now) {
			return cachedToken;
		}

		const issuedAt = Math.floor(now / 1_000);
		const encodedHeader = toBase64Url(JSON.stringify({
			alg: "ES256",
			kid: input.keyId,
		}));
		const encodedPayload = toBase64Url(JSON.stringify({
			iat: issuedAt,
			iss: input.teamId,
		}));
		const unsignedToken = `${encodedHeader}.${encodedPayload}`;
		const signer = createSign("sha256");
		signer.update(unsignedToken);
		signer.end();
		const signature = signer.sign(input.privateKey);
		const encodedSignature = toBase64Url(signature);
		const token = `${unsignedToken}.${encodedSignature}`;
		cachedToken = token;
		cachedTokenExpiresAtMs = now + APNS_AUTH_TOKEN_TTL_MS;
		return token;
	};
};

const createApnsSender = (input: {
	apnsAuthKeyId: string;
	apnsPrivateKeyPath: string;
	apnsTeamId: string;
	bundleIdentifier: string;
	useSandbox: boolean;
}): LiveActivityPushSender => {
	const privateKey = readFileSync(input.apnsPrivateKeyPath, "utf8");
	const topic = toLiveActivityTopic(input.bundleIdentifier);
	const host = input.useSandbox ? APNS_SANDBOX_HOST : APNS_PRODUCTION_HOST;
	const toBearerToken = createApnsJwtSigner({
		keyId: input.apnsAuthKeyId,
		privateKey,
		teamId: input.apnsTeamId,
	});

	return async (deliveryInput) => {
		if (deliveryInput.pushTokenType !== "apns") {
			return {
				delivered: false,
				errorCode: "apns/unsupported-token-type",
				shouldDropSubscription: false,
			};
		}

		const apsPayload = buildLiveActivityApsPayload({
			contentState: deliveryInput.contentState,
			event: deliveryInput.event,
			timestampSeconds: deliveryInput.timestampSeconds,
		});
		const nowSeconds = Math.floor(Date.now() / 1_000);
		const expirationSeconds = deliveryInput.event === "end"
			? nowSeconds + PUSH_END_EXPIRATION_SECONDS
			: nowSeconds + PUSH_UPDATE_EXPIRATION_SECONDS;
		const headers = buildLiveActivityApnsHeaders({
			event: deliveryInput.event,
			expirationSeconds,
			topic,
		});

			const requestBody = JSON.stringify({
				aps: apsPayload,
			});
			const session = connect(host);
			return await new Promise<LiveActivityPushDeliveryResult>((resolve) => {
				let settled = false;
				let statusCode = 0;
				let responseBody = "";
				let request: ReturnType<typeof session.request> | null = null;
				const timeout = setTimeout(() => {
					try {
						request?.close();
					} catch {
						// Ignore timeout teardown errors.
					}
					try {
						session.destroy();
					} catch {
						// Ignore timeout teardown errors.
					}
					settle({
						delivered: false,
						errorCode: "apns/timeout",
						shouldDropSubscription: false,
					});
				}, APNS_REQUEST_TIMEOUT_MS);
				const settle = (result: LiveActivityPushDeliveryResult): void => {
					if (settled) {
						return;
					}
					settled = true;
					clearTimeout(timeout);
					try {
						session.close();
					} catch {
						// Ignore teardown errors.
					}
					resolve(result);
				};

				session.on("error", () => {
					settle({
						delivered: false,
						errorCode: "apns/session-error",
						shouldDropSubscription: false,
					});
				});

				request = session.request({
					":method": "POST",
					":path": `/3/device/${deliveryInput.liveActivityToken}`,
					authorization: `bearer ${toBearerToken()}`,
					"content-type": "application/json",
					...headers,
				});
				request.setEncoding("utf8");
				request.on("response", (responseHeaders) => {
					const rawStatus = responseHeaders[":status"];
					statusCode = typeof rawStatus === "number" ? rawStatus : Number(rawStatus ?? 0);
				});
				request.on("data", (chunk) => {
					responseBody += chunk;
				});
				request.on("error", () => {
					settle({
						delivered: false,
						errorCode: "apns/request-error",
						shouldDropSubscription: false,
					});
				});
				request.on("end", () => {
					if (statusCode === 200) {
						settle({
							delivered: true,
							shouldDropSubscription: false,
						});
						return;
					}

					let reason: string | undefined;
					try {
						const parsed = JSON.parse(responseBody) as { reason?: unknown };
						reason = typeof parsed.reason === "string" ? parsed.reason : undefined;
					} catch {
						reason = undefined;
					}
					const shouldDropSubscription = statusCode === 410
						|| (statusCode === 400 && Boolean(reason && APNS_PERMANENT_REASONS.has(reason)));
					settle({
						delivered: false,
						errorCode: reason ? `apns/${reason}` : `apns/status-${statusCode}`,
						shouldDropSubscription,
					});
				});

				request.end(requestBody);
		});
	};
};

const createFirebaseSender = (input: {
	bundleIdentifier: string;
	firebaseProjectId?: string;
	serviceAccountPath: string;
}): LiveActivityPushSender => {
	const raw = readFileSync(input.serviceAccountPath, "utf8");
	const parsed = JSON.parse(raw) as Partial<ServiceAccount> | null;
	if (!parsed || typeof parsed !== "object") {
		throw new Error("invalid firebase service account json");
	}

	const existingApp = getApps().find((entry) => entry.name === "remotecode-live-activity");
	const app = existingApp ?? initializeApp(
		{
			credential: cert(parsed as ServiceAccount),
			...(toNormalized(input.firebaseProjectId).length > 0 ? { projectId: toNormalized(input.firebaseProjectId) } : {}),
		},
		"remotecode-live-activity",
	);
	const messaging = getMessaging(app);
	const topic = toLiveActivityTopic(input.bundleIdentifier);
	const toMessagingErrorCode = (error: unknown): string | undefined => (
		typeof error === "object" && error !== null && "code" in error && typeof error.code === "string"
			? error.code
			: undefined
	);

	return async (deliveryInput) => {
		if (deliveryInput.pushTokenType !== "fcm") {
			return {
				delivered: false,
				errorCode: "messaging/unsupported-token-type",
				shouldDropSubscription: false,
			};
		}

		const apsPayload = buildLiveActivityApsPayload({
			contentState: deliveryInput.contentState,
			event: deliveryInput.event,
			timestampSeconds: deliveryInput.timestampSeconds,
		});
		const nowSeconds = Math.floor(Date.now() / 1_000);
		const expirationSeconds = deliveryInput.event === "end"
			? nowSeconds + PUSH_END_EXPIRATION_SECONDS
			: nowSeconds + PUSH_UPDATE_EXPIRATION_SECONDS;
		const headers = buildLiveActivityApnsHeaders({
			event: deliveryInput.event,
			expirationSeconds,
			topic,
		});

			try {
				const message: LiveActivityFirebaseMessage = {
					token: deliveryInput.pushToken,
					apns: {
						liveActivityToken: deliveryInput.liveActivityToken,
						headers,
						payload: {
							aps: apsPayload as never,
						},
					},
				};

				// Firebase messaging SDK typing currently omits liveActivityToken from ApnsConfig.
				await messaging.send(message as Message);
				return {
					delivered: true,
					shouldDropSubscription: false,
				};
		} catch (primaryError) {
			const primaryCode = toMessagingErrorCode(primaryError);

			logLiveActivityWarn("push send failed", {
				chatId: deliveryInput.contentState.chatId,
				code: primaryCode ?? "unknown",
				event: deliveryInput.event,
				pushTokenType: deliveryInput.pushTokenType,
				pushToken: toTokenPreview(deliveryInput.pushToken),
				liveActivityToken: toTokenPreview(deliveryInput.liveActivityToken),
			});
			return {
				delivered: false,
				errorCode: primaryCode,
				shouldDropSubscription: isPermanentMessagingFailure(primaryCode),
			};
		}
	};
};

const createRoutedSender = (input: {
	apnsSender?: LiveActivityPushSender;
	firebaseSender?: LiveActivityPushSender;
}): LiveActivityPushSender => async (deliveryInput) => {
	if (deliveryInput.pushTokenType === "apns") {
		if (input.apnsSender) {
			return await input.apnsSender(deliveryInput);
		}

		return {
			delivered: false,
			errorCode: "apns/no-sender-configured",
			shouldDropSubscription: true,
		};
	}

	if (input.firebaseSender) {
		return await input.firebaseSender(deliveryInput);
	}

	return {
		delivered: false,
		errorCode: "messaging/no-sender-configured",
		shouldDropSubscription: true,
	};
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

	onAssistantDelta(): void {}

	onAssistantEvent(): void {}

	async onChatFinished(): Promise<void> {}

	onChatStarted(): void {}

	async upsertSubscription(): Promise<boolean> {
		return false;
	}
}

export class LiveActivityPushService implements LiveActivityPushServiceContract {
	private readonly runtimesByChatId = new Map<string, ChatRuntimeState>();
	private readonly subscriptionsByChatId = new Map<string, Map<string, LiveActivitySubscription>>();

	constructor(
		private readonly sender: LiveActivityPushSender,
		private readonly supportedPushTokenTypes: ReadonlySet<LiveActivityPushTokenType> = new Set(["apns", "fcm"]),
		private readonly subscriptionStore?: LiveActivityPushSubscriptionStoreContract,
	) {
		this.restorePersistedSubscriptions();
	}

	private restorePersistedSubscriptions(): void {
		const persistedSubscriptions = this.subscriptionStore?.listAll() ?? [];
		for (const subscription of persistedSubscriptions) {
			if (!this.supportedPushTokenTypes.has(subscription.pushTokenType)) {
				continue;
			}
			this.setSubscriptionInMemory(subscription);
		}

		if (persistedSubscriptions.length > 0) {
			logLiveActivityInfo("restored persisted subscriptions", {
				subscriptionsCount: [...this.subscriptionsByChatId.values()].reduce((total, byChat) => total + byChat.size, 0),
			});
		}
	}

	private setSubscriptionInMemory(input: LiveActivityPushStoredSubscription): LiveActivitySubscription {
		const existingByChat = this.subscriptionsByChatId.get(input.chatId) ?? new Map<string, LiveActivitySubscription>();
		const subscriptionKey = toSubscriptionKey({
			pushToken: input.pushToken,
			pushTokenType: input.pushTokenType,
			liveActivityToken: input.liveActivityToken,
		});
		const previousSubscription = existingByChat.get(subscriptionKey);
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
		existingByChat.set(subscriptionKey, subscription);
		this.subscriptionsByChatId.set(input.chatId, existingByChat);
		return subscription;
	}

	getIsEnabled(): boolean {
		return true;
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

	private deletePersistedSubscriptionsByChatId(chatId: string): void {
		if (!this.subscriptionStore) {
			return;
		}

		try {
			this.subscriptionStore.deleteByChatId(chatId);
		} catch {
			logLiveActivityWarn("subscription persistence delete-by-chat failed", {
				chatId,
			});
		}
	}

	private getRuntime(chatId: string): ChatRuntimeState | null {
		return this.runtimesByChatId.get(chatId) ?? null;
	}

	private hasSubscriptions(chatId: string): boolean {
		return (this.subscriptionsByChatId.get(chatId)?.size ?? 0) > 0;
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

	private toContentState(runtime: ChatRuntimeState): LiveActivityContentState {
		const safeTitle = toSafeLiveActivityText(runtime.chatTitle, TITLE_LIMIT, "title");
		const safePreview = toSafeLiveActivityText(
			toNormalized(runtime.preview) || toDefaultPreview(runtime.phase),
			PREVIEW_LIMIT,
			"preview",
		);
		const safeStatusLine = toSafeLiveActivityText(
			toNormalized(runtime.statusLine) || toDefaultStatusLine(runtime.phase),
			STATUS_LIMIT,
			"status",
		);

		return {
			chatId: runtime.chatId,
			chatTitle: safeTitle.length > 0 ? safeTitle : "Thread",
			elapsedSeconds: toElapsedSeconds(runtime.startedAtMs),
			phase: runtime.phase,
			preview: safePreview.length > 0 ? safePreview : toDefaultPreview(runtime.phase),
			statusLine: safeStatusLine.length > 0 ? safeStatusLine : toDefaultStatusLine(runtime.phase),
		};
	}

	private clearScheduledFlush(chatId: string): void {
		const runtime = this.getRuntime(chatId);
		if (!runtime?.flushTimeout) {
			return;
		}

		clearTimeout(runtime.flushTimeout);
		runtime.flushTimeout = null;
	}

	private ensureHeartbeat(chatId: string): void {
		const runtime = this.getRuntime(chatId);
		if (!runtime || runtime.heartbeatInterval || isTerminalPhase(runtime.phase) || !this.hasSubscriptions(chatId)) {
			return;
		}

		runtime.heartbeatInterval = setInterval(() => {
			void this.queueFlush(chatId, "update");
		}, PUSH_HEARTBEAT_INTERVAL_MS);
	}

	private clearHeartbeat(chatId: string): void {
		const runtime = this.getRuntime(chatId);
		if (!runtime?.heartbeatInterval) {
			return;
		}

		clearInterval(runtime.heartbeatInterval);
		runtime.heartbeatInterval = null;
	}

	private markPendingEvent(runtime: ChatRuntimeState, event: PushEvent): void {
		if (event === "end" || runtime.pendingEvent !== "end") {
			runtime.pendingEvent = event;
		}
	}

	private scheduleUpdateFlush(chatId: string): void {
		const runtime = this.getRuntime(chatId);
		if (!runtime || runtime.flushTimeout || runtime.pendingEvent === "end") {
			return;
		}

		const elapsedSinceLastSendMs = Date.now() - runtime.lastSentAtMs;
		const delayMs = runtime.lastSentAtMs <= 0
			? 0
			: Math.max(0, PUSH_MIN_UPDATE_INTERVAL_MS - elapsedSinceLastSendMs);

		runtime.flushTimeout = setTimeout(() => {
			const current = this.getRuntime(chatId);
			if (!current) {
				return;
			}

			current.flushTimeout = null;
			void this.flushChat(chatId, "update");
		}, delayMs);
	}

	private scheduleEndRetry(chatId: string): void {
		const runtime = this.getRuntime(chatId);
		if (!runtime || runtime.flushTimeout) {
			return;
		}
		logLiveActivityWarn("scheduling end retry", {
			chatId,
		});

		runtime.flushTimeout = setTimeout(() => {
			const current = this.getRuntime(chatId);
			if (!current) {
				return;
			}

			current.flushTimeout = null;
			void this.flushChat(chatId, "end", {
				force: true,
			});
		}, PUSH_MIN_UPDATE_INTERVAL_MS);
	}

	private queueFlush(chatId: string, event: PushEvent, input?: { immediate?: boolean }): void {
		const runtime = this.getRuntime(chatId);
		if (!runtime) {
			return;
		}

		this.markPendingEvent(runtime, event);
		if (runtime.sending) {
			runtime.sendAgain = true;
			return;
		}
		const immediate = input?.immediate ?? event === "end";
		if (immediate) {
			if (LIVE_ACTIVITY_VERBOSE_LOGS) {
				logLiveActivityInfo("queue flush immediate", {
					chatId,
					event,
				});
			}
			this.clearScheduledFlush(chatId);
			void this.flushChat(chatId, event, {
				force: true,
			});
			return;
		}

		this.ensureHeartbeat(chatId);
		this.scheduleUpdateFlush(chatId);
	}

	private async waitForTerminalFlush(chatId: string): Promise<void> {
		for (let attempt = 0; attempt < 20; attempt += 1) {
			const runtime = this.getRuntime(chatId);
			if (!runtime) {
				return;
			}

			if (runtime.pendingEvent !== "end" && !runtime.sending && !runtime.sendAgain) {
				return;
			}

			await new Promise<void>((resolve) => {
				setTimeout(resolve, 50);
			});
		}
	}

	private async flushChat(chatId: string, event: PushEvent, input?: { force?: boolean }): Promise<void> {
		const runtime = this.getRuntime(chatId);
		if (!runtime) {
			return;
		}

		const nextEvent: PushEvent = runtime.pendingEvent === "end" ? "end" : event;
		if (nextEvent === "end") {
			this.clearScheduledFlush(chatId);
		}

		const subscriptions = this.subscriptionsByChatId.get(chatId);
		if (!subscriptions || subscriptions.size === 0) {
			if (runtime.pendingEvent === nextEvent) {
				runtime.pendingEvent = null;
			}
			if (LIVE_ACTIVITY_VERBOSE_LOGS) {
				logLiveActivityInfo("flush skipped (no subscriptions)", {
					chatId,
					event: nextEvent,
				});
			}
			this.clearHeartbeat(chatId);
			return;
		}

		if (runtime.sending) {
			if (LIVE_ACTIVITY_VERBOSE_LOGS) {
				logLiveActivityInfo("flush skipped (already sending)", {
					chatId,
					event: nextEvent,
				});
			}
			this.markPendingEvent(runtime, nextEvent);
			runtime.sendAgain = true;
			return;
		}

		runtime.sending = true;
		if (runtime.pendingEvent === nextEvent) {
			runtime.pendingEvent = null;
		}
		let completedEndEvent = false;

		try {
			const force = input?.force ?? false;
			const elapsedSinceLastSendMs = Date.now() - runtime.lastSentAtMs;
			if (nextEvent === "update" && !force && runtime.lastSentAtMs > 0 && elapsedSinceLastSendMs < PUSH_MIN_UPDATE_INTERVAL_MS) {
				this.markPendingEvent(runtime, "update");
				if (LIVE_ACTIVITY_VERBOSE_LOGS) {
					logLiveActivityInfo("flush deferred by min interval", {
						chatId,
						elapsedSinceLastSendMs,
						minIntervalMs: PUSH_MIN_UPDATE_INTERVAL_MS,
					});
				}
				this.scheduleUpdateFlush(chatId);
				return;
			}

			const contentState = this.toContentState(runtime);
			const deliverySignature = toDeliverySignature({
				contentState,
				event: nextEvent,
			});
			let sentAnyUpdate = false;
			let hadTransientFailure = false;
			let droppedSubscriptionsCount = 0;
			let skippedDuplicateCount = 0;
			let transientFailureCount = 0;

			for (const [key, subscription] of subscriptions.entries()) {
				if (nextEvent === "update" && !force && subscription.lastDeliveredSignature === deliverySignature) {
					skippedDuplicateCount += 1;
					continue;
				}

				const timestampSeconds = toNextTimestampSeconds({
					lastTimestampSeconds: subscription.lastTimestampSeconds,
				});
					const deliveryResult = await this.sender({
						contentState,
						event: nextEvent,
						pushToken: subscription.pushToken,
						pushTokenType: subscription.pushTokenType,
						liveActivityToken: subscription.liveActivityToken,
						timestampSeconds,
					});
				if (deliveryResult.shouldDropSubscription) {
					subscriptions.delete(key);
					this.deletePersistedSubscription({
						chatId,
						chatTitle: subscription.chatTitle,
						liveActivityToken: subscription.liveActivityToken,
						pushToken: subscription.pushToken,
						pushTokenType: subscription.pushTokenType,
					});
					droppedSubscriptionsCount += 1;
						logLiveActivityWarn("dropping subscription after permanent delivery error", {
							chatId,
							event: nextEvent,
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
							chatId,
							event: nextEvent,
							code: deliveryResult.errorCode ?? "unknown",
							pushTokenType: subscription.pushTokenType,
							pushToken: toTokenPreview(subscription.pushToken),
							liveActivityToken: toTokenPreview(subscription.liveActivityToken),
						});
					continue;
				}

				subscription.lastDeliveredSignature = deliverySignature;
				subscription.lastTimestampSeconds = timestampSeconds;
				sentAnyUpdate = true;
			}
			if (hadTransientFailure) {
				this.markPendingEvent(runtime, nextEvent);
			}

			if (subscriptions.size === 0) {
				this.subscriptionsByChatId.delete(chatId);
				this.clearHeartbeat(chatId);
			}

			if (sentAnyUpdate) {
				runtime.lastSentAtMs = Date.now();
			}
			if (LIVE_ACTIVITY_VERBOSE_LOGS || hadTransientFailure || droppedSubscriptionsCount > 0) {
				logLiveActivityInfo("flush completed", {
					chatId,
					droppedSubscriptionsCount,
					elapsedSeconds: contentState.elapsedSeconds,
					event: nextEvent,
					hadTransientFailure,
					phase: contentState.phase,
					previewTail: contentState.preview.slice(-80),
					remainingSubscriptions: subscriptions.size,
					sentAnyUpdate,
					skippedDuplicateCount,
					statusLine: contentState.statusLine,
					transientFailureCount,
				});
			}
			if (nextEvent === "end" && !hadTransientFailure) {
				completedEndEvent = true;
			}
		} finally {
			runtime.sending = false;
			const shouldFlushAgain = runtime.sendAgain;
			runtime.sendAgain = false;
			if (completedEndEvent && runtime.pendingEvent !== "end") {
				this.clearScheduledFlush(chatId);
				this.clearHeartbeat(chatId);
				this.deletePersistedSubscriptionsByChatId(chatId);
				this.runtimesByChatId.delete(chatId);
				this.subscriptionsByChatId.delete(chatId);
				return;
			}
			if (runtime.pendingEvent === "end") {
				this.scheduleEndRetry(chatId);
				return;
			}
			if (shouldFlushAgain) {
				this.queueFlush(chatId, "update", {
					immediate: true,
				});
				return;
			}
			if (runtime.pendingEvent === "update") {
				this.scheduleUpdateFlush(chatId);
				this.ensureHeartbeat(chatId);
				return;
			}
		}
	}

	onChatStarted(input: LiveActivityPushStartInput): void {
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
			});
		}
		if (isTerminalPhase(runtime.phase)) {
			runtime.startedAtMs = Date.now();
			runtime.preview = toDefaultPreview("running");
			runtime.previewSource = "default";
		}
		runtime.pendingEvent = null;
		this.clearScheduledFlush(input.chatId);
		runtime.phase = "running";
		runtime.statusLine = toDefaultStatusLine("running");
		if (toNormalized(runtime.preview).length === 0) {
			runtime.preview = toDefaultPreview("running");
			runtime.previewSource = "default";
		}
		if (alreadyActive) {
			this.ensureHeartbeat(input.chatId);
			return;
		}

		if (this.hasSubscriptions(input.chatId)) {
			this.queueFlush(input.chatId, "update", {
				immediate: true,
			});
		}
		this.ensureHeartbeat(input.chatId);
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
		if (runtime.phase !== "finalizing") {
			runtime.phase = "running";
		}
		runtime.statusLine = toDefaultStatusLine(runtime.phase);
		this.queueFlush(chatId, "update");
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
			this.queueFlush(chatId, "update");
			return;
		}

		runtime.phase = toPhaseFromEvent(event);
		runtime.statusLine = toStatusLineFromEvent(event) ?? toDefaultStatusLine(runtime.phase);
		const eventSummary = toEventSummary(event);
		if (eventSummary) {
			runtime.preview = toLatestPreview(eventSummary);
			runtime.previewSource = "event";
		}
		this.queueFlush(chatId, "update");
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
		logLiveActivityInfo("chat finished (queueing end)", {
			chatId: input.chatId,
			outcome: input.outcome,
			phase: runtime.phase,
		});

		this.clearScheduledFlush(input.chatId);
		runtime.pendingEvent = "end";
		await this.flushChat(input.chatId, "end", {
			force: true,
		});
		await this.waitForTerminalFlush(input.chatId);
		const currentRuntime = this.getRuntime(input.chatId);
		if (!currentRuntime) {
			logLiveActivityInfo("chat finish cleanup completed", {
				chatId: input.chatId,
			});
			return;
		}
		if (currentRuntime.pendingEvent === "end" || currentRuntime.sending || currentRuntime.sendAgain) {
			this.scheduleEndRetry(input.chatId);
			logLiveActivityWarn("chat finish pending retry", {
				chatId: input.chatId,
			});
			return;
		}

		this.clearScheduledFlush(input.chatId);
		this.deletePersistedSubscriptionsByChatId(input.chatId);
		this.runtimesByChatId.delete(input.chatId);
		this.subscriptionsByChatId.delete(input.chatId);
		logLiveActivityInfo("chat finish cleanup completed", {
			chatId: input.chatId,
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
			return false;
		}
		if (!this.supportedPushTokenTypes.has(pushTokenType)) {
			logLiveActivityWarn("subscription ignored (unsupported push token type)", {
				chatId,
				pushTokenType,
			});
			return false;
		}

		const existingByChat = this.subscriptionsByChatId.get(chatId) ?? new Map<string, LiveActivitySubscription>();
		for (const [key, subscriptionEntry] of existingByChat.entries()) {
			const samePushTokenWithOldActivityToken =
				subscriptionEntry.pushToken === pushToken
				&& subscriptionEntry.pushTokenType === pushTokenType
				&& subscriptionEntry.liveActivityToken !== liveActivityToken;
			const sameActivityTokenWithDifferentPushToken =
				subscriptionEntry.liveActivityToken === liveActivityToken
				&& (
					subscriptionEntry.pushToken !== pushToken
					|| subscriptionEntry.pushTokenType !== pushTokenType
				);
			if (samePushTokenWithOldActivityToken || sameActivityTokenWithDifferentPushToken) {
				existingByChat.delete(key);
				logLiveActivityInfo("replacing stale subscription token pair", {
					chatId,
					pushTokenType: subscriptionEntry.pushTokenType,
					pushToken: toTokenPreview(subscriptionEntry.pushToken),
					liveActivityToken: toTokenPreview(subscriptionEntry.liveActivityToken),
				});
			}
		}
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

		const subscriptionKey = toSubscriptionKey({
			pushToken,
			pushTokenType,
			liveActivityToken,
		});
		const previousSubscription = existingByChat.get(subscriptionKey);
		this.setSubscriptionInMemory(persistedSubscription);
		logLiveActivityInfo("subscription upserted", {
			chatId,
			isNewSubscription: !previousSubscription,
			subscriptionsForChat: this.subscriptionsByChatId.get(chatId)?.size ?? 0,
			pushTokenType,
			pushToken: toTokenPreview(pushToken),
			liveActivityToken: toTokenPreview(liveActivityToken),
		});

		const runtime = this.getRuntime(chatId);
		if (!runtime) {
			return true;
		}

		if (toNormalized(input.chatTitle).length > 0) {
			runtime.chatTitle = toNormalized(input.chatTitle);
		}

		if (!isTerminalPhase(runtime.phase)) {
			this.ensureHeartbeat(chatId);
		}

		const nextEvent: PushEvent = isTerminalPhase(runtime.phase) ? "end" : "update";
		if (!previousSubscription) {
			runtime.pendingEvent = nextEvent;
			await this.flushChat(chatId, nextEvent, {
				force: true,
			});
		}
		return true;
	}
}

export const createNoopLiveActivityPushService = (): LiveActivityPushServiceContract =>
	new NoopLiveActivityPushService();

interface ResolvedLiveActivityPushEnvironment {
	bundleIdentifier: string;
	firebaseProjectId?: string;
	sender: LiveActivityPushSender;
	supportedPushTokenTypes: ReadonlySet<LiveActivityPushTokenType>;
}

const resolveLiveActivityPushEnvironment = (
	input: LiveActivityPushEnvironmentInput,
): ResolvedLiveActivityPushEnvironment | null => {
	const serviceAccountPath = toNormalized(input.serviceAccountPath);
	const apnsTeamId = toNormalized(input.apnsTeamId);
	const apnsAuthKeyId = toNormalized(input.apnsAuthKeyId);
	const apnsPrivateKeyPath = toNormalized(input.apnsPrivateKeyPath);
	const bundleIdentifier = toNormalized(input.bundleIdentifier);
		if (bundleIdentifier.length === 0) {
			logLiveActivityWarn("service disabled (missing configuration)", {
				hasBundleIdentifier: bundleIdentifier.length > 0,
			});
			return null;
		}
		if (isLikelyWidgetExtensionBundleIdentifier(bundleIdentifier)) {
			logLiveActivityWarn("service disabled (invalid bundle identifier for apns-topic)", {
				bundleIdentifier,
			});
			return null;
		}

	let firebaseSender: LiveActivityPushSender | undefined;
	if (serviceAccountPath.length > 0) {
		try {
			firebaseSender = createFirebaseSender({
				bundleIdentifier,
				firebaseProjectId: input.firebaseProjectId,
				serviceAccountPath,
			});
		} catch {
			logLiveActivityWarn("firebase sender disabled (failed to initialize)");
		}
	}

	let apnsSender: LiveActivityPushSender | undefined;
	const hasAnyApnsConfig =
		apnsTeamId.length > 0 || apnsAuthKeyId.length > 0 || apnsPrivateKeyPath.length > 0;
	const hasCompleteApnsConfig =
		apnsTeamId.length > 0 && apnsAuthKeyId.length > 0 && apnsPrivateKeyPath.length > 0;
	if (hasAnyApnsConfig && !hasCompleteApnsConfig) {
		logLiveActivityWarn("apns sender disabled (incomplete configuration)", {
			hasApnsAuthKeyId: apnsAuthKeyId.length > 0,
			hasApnsPrivateKeyPath: apnsPrivateKeyPath.length > 0,
			hasApnsTeamId: apnsTeamId.length > 0,
		});
	}
	if (hasCompleteApnsConfig) {
		try {
			apnsSender = createApnsSender({
				apnsAuthKeyId,
				apnsPrivateKeyPath,
				apnsTeamId,
				bundleIdentifier,
				useSandbox: input.apnsUseSandbox ?? false,
			});
		} catch {
			logLiveActivityWarn("apns sender disabled (failed to initialize)");
		}
	}

	if (!firebaseSender && !apnsSender) {
		logLiveActivityWarn("service disabled (no sender configured)", {
			hasApnsConfig: hasAnyApnsConfig,
			hasFirebaseConfig: serviceAccountPath.length > 0,
		});
		return null;
	}

	const sender = createRoutedSender({
		apnsSender,
		firebaseSender,
	});
	const supportedPushTokenTypes = new Set<LiveActivityPushTokenType>([
		...(firebaseSender ? (["fcm"] as const) : []),
		...(apnsSender ? (["apns"] as const) : []),
	]);
	logLiveActivityInfo("service enabled", {
		bundleIdentifier,
		enabledProviders: [
			...(firebaseSender ? ["firebase"] : []),
			...(apnsSender ? ["apns"] : []),
		],
		firebaseProjectId: toNormalized(input.firebaseProjectId) || "default",
	});
	return {
		bundleIdentifier,
		firebaseProjectId: toNormalized(input.firebaseProjectId) || undefined,
		sender,
		supportedPushTokenTypes,
	};
};

export const createLiveActivityPushServiceFromEnvironment = (
	input: LiveActivityPushEnvironmentInput,
): LiveActivityPushServiceContract => {
	const resolved = resolveLiveActivityPushEnvironment(input);
	if (!resolved) {
		return createNoopLiveActivityPushService();
	}

	return new LiveActivityPushService(resolved.sender, resolved.supportedPushTokenTypes, input.subscriptionStore);
};

export const createLiveActivityPushDebugClientFromEnvironment = (
	input: LiveActivityPushEnvironmentInput,
): LiveActivityPushDebugClientContract => {
	const resolved = resolveLiveActivityPushEnvironment(input);
	if (!resolved) {
		return {
			getIsEnabled: () => false,
			getSupportedPushTokenTypes: () => new Set<LiveActivityPushTokenType>(),
			send: async () => ({
				delivered: false,
				errorCode: "live-activity/not-configured",
				shouldDropSubscription: false,
			}),
		};
	}

	return {
		getIsEnabled: () => true,
		getSupportedPushTokenTypes: () => resolved.supportedPushTokenTypes,
		send: async (debugInput) => await resolved.sender({
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
): LiveActivityPushService =>
	new LiveActivityPushService(sender ?? createNoopSender(), new Set(["apns", "fcm"]), subscriptionStore);
