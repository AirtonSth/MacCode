import { readFileSync } from "node:fs";
import { createSign } from "node:crypto";
import { connect, constants, type ClientHttp2Session } from "node:http2";

import type { LiveActivityPushDeliveryResult } from "./live-activity-push.service";
import { buildLiveActivityApsPayload } from "./live-activity-push.service";
import type { LiveActivityPhase } from "./live-activity-push.model";

const APNS_PRODUCTION_HOST = "api.push.apple.com";
const APNS_SANDBOX_HOST = "api.sandbox.push.apple.com";
const APNS_PORT = 443;
const APNS_TOKEN_TTL_MS = 50 * 60 * 1_000; // 50 minutes (Apple allows 60)
const APNS_REQUEST_TIMEOUT_MS = 15_000;
const APNS_SESSION_IDLE_TIMEOUT_MS = 60_000;
const LOG_PREFIX = "[apns-sender]";

type PushEvent = "update" | "end" | "start";

export interface ApnsSenderConfig {
	authKeyPath: string;
	keyId: string;
	teamId: string;
	bundleId: string;
	useSandbox: boolean;
}

export interface ApnsSendInput {
	contentState: {
		chatId: string;
		chatTitle: string;
		elapsedSeconds: number;
		phase: LiveActivityPhase;
		preview: string;
		statusLine: string;
	};
	event: PushEvent;
	liveActivityToken: string;
	timestampSeconds: number;
	attributesType?: string;
	attributes?: Record<string, unknown>;
}

interface CachedJwt {
	token: string;
	expiresAtMs: number;
}

const toTokenPreview = (token: string): string =>
	token.length <= 12 ? token : `${token.slice(0, 6)}...${token.slice(-4)}`;

const log = (message: string, meta?: Record<string, unknown>): void => {
	if (meta) {
		console.info(LOG_PREFIX, message, JSON.stringify(meta));
		return;
	}
	console.info(LOG_PREFIX, message);
};

const warn = (message: string, meta?: Record<string, unknown>): void => {
	if (meta) {
		console.warn(LOG_PREFIX, message, JSON.stringify(meta));
		return;
	}
	console.warn(LOG_PREFIX, message);
};

const base64UrlEncode = (data: string | Buffer): string => {
	const base64 = typeof data === "string"
		? Buffer.from(data).toString("base64")
		: data.toString("base64");
	return base64
		.replace(/\+/gu, "-")
		.replace(/\//gu, "_")
		.replace(/=+$/u, "");
};

const createApnsJwt = (privateKeyPem: string, keyId: string, teamId: string): string => {
	const header = base64UrlEncode(JSON.stringify({
		alg: "ES256",
		kid: keyId,
		typ: "JWT",
	}));
	const issuedAt = Math.floor(Date.now() / 1_000);
	const claims = base64UrlEncode(JSON.stringify({
		iss: teamId,
		iat: issuedAt,
	}));
	const signingInput = `${header}.${claims}`;
	const signer = createSign("SHA256");
	signer.update(signingInput);
	const derSignature = signer.sign(privateKeyPem);

	// Convert DER-encoded ECDSA signature to raw r||s format for JWT
	const rawSignature = derToRawEcdsaSignature(derSignature);
	const signature = base64UrlEncode(rawSignature);

	return `${signingInput}.${signature}`;
};

const derToRawEcdsaSignature = (derBuffer: Buffer): Buffer => {
	// DER format: 0x30 <total-length> 0x02 <r-length> <r> 0x02 <s-length> <s>
	let offset = 2; // skip 0x30 and total length
	if (derBuffer[0] !== 0x30) {
		return derBuffer;
	}

	// Read r
	if (derBuffer[offset] !== 0x02) {
		return derBuffer;
	}
	offset += 1;
	const rLength = derBuffer[offset]!;
	offset += 1;
	const rBytes = derBuffer.subarray(offset, offset + rLength);
	offset += rLength;

	// Read s
	if (derBuffer[offset] !== 0x02) {
		return derBuffer;
	}
	offset += 1;
	const sLength = derBuffer[offset]!;
	offset += 1;
	const sBytes = derBuffer.subarray(offset, offset + sLength);

	// Pad or trim to 32 bytes each (P-256 = 256 bits = 32 bytes)
	const r = padOrTrimTo32(rBytes);
	const s = padOrTrimTo32(sBytes);

	return Buffer.concat([r, s]);
};

const padOrTrimTo32 = (bytes: Buffer): Buffer => {
	if (bytes.length === 32) {
		return bytes;
	}
	if (bytes.length > 32) {
		// Leading zero padding from DER encoding
		return bytes.subarray(bytes.length - 32);
	}
	// Pad with leading zeros
	const padded = Buffer.alloc(32);
	bytes.copy(padded, 32 - bytes.length);
	return padded;
};

export const loadApnsConfigFromEnvironment = (): ApnsSenderConfig | null => {
	const authKeyPath = process.env.REMOTECODE_LIVE_ACTIVITY_APNS_PRIVATE_KEY_PATH?.trim() ?? "";
	const keyId = process.env.REMOTECODE_LIVE_ACTIVITY_APNS_AUTH_KEY_ID?.trim() ?? "";
	const teamId = process.env.REMOTECODE_LIVE_ACTIVITY_APNS_TEAM_ID?.trim() ?? "";
	const bundleId = process.env.REMOTECODE_LIVE_ACTIVITY_APNS_BUNDLE_ID?.trim() || "io.remotecode";
	const useSandbox = process.env.REMOTECODE_LIVE_ACTIVITY_APNS_USE_SANDBOX === "true";

	if (authKeyPath.length === 0 || keyId.length === 0 || teamId.length === 0) {
		return null;
	}

	return { authKeyPath, keyId, teamId, bundleId, useSandbox };
};

const createHttp2Session = (authority: string): ClientHttp2Session => {
	const session = connect(authority);
	session.on("error", () => {
		// Silently handle session-level errors; requests will fail individually.
	});
	session.setTimeout(APNS_SESSION_IDLE_TIMEOUT_MS, () => {
		session.close();
	});
	session.unref();
	return session;
};

export const createApnsSender = (config: ApnsSenderConfig): ((input: ApnsSendInput) => Promise<LiveActivityPushDeliveryResult>) => {
	let privateKeyPem: string;
	try {
		privateKeyPem = readFileSync(config.authKeyPath, "utf-8");
	} catch (error) {
		warn("failed to read APNS auth key", {
			path: config.authKeyPath,
			error: error instanceof Error ? error.message : "unknown",
		});
		return async () => ({
			delivered: false,
			errorCode: "apns/key-not-found",
			shouldDropSubscription: false,
		});
	}

	const host = config.useSandbox ? APNS_SANDBOX_HOST : APNS_PRODUCTION_HOST;
	const authority = `https://${host}:${APNS_PORT}`;
	const topic = `${config.bundleId}.push-type.liveactivity`;
	let cachedJwt: CachedJwt | null = null;
	let session: ClientHttp2Session | null = null;

	log("initialized", {
		host,
		keyId: config.keyId,
		teamId: config.teamId,
		topic,
		sandbox: config.useSandbox,
	});

	const getJwt = (): string => {
		const now = Date.now();
		if (cachedJwt && cachedJwt.expiresAtMs > now) {
			return cachedJwt.token;
		}

		const token = createApnsJwt(privateKeyPem, config.keyId, config.teamId);
		cachedJwt = {
			token,
			expiresAtMs: now + APNS_TOKEN_TTL_MS,
		};
		return token;
	};

	const getSession = (): ClientHttp2Session => {
		if (session && !session.closed && !session.destroyed) {
			return session;
		}

		session = createHttp2Session(authority);
		return session;
	};

	const sendRequest = (
		path: string,
		headers: Record<string, string>,
		body: Buffer,
	): Promise<{ status: number; body: string }> =>
		new Promise((resolve, reject) => {
			let h2session: ClientHttp2Session;
			try {
				h2session = getSession();
			} catch (error) {
				reject(error);
				return;
			}

			const timer = setTimeout(() => {
				req.close(constants.NGHTTP2_CANCEL);
				reject(new Error("timeout"));
			}, APNS_REQUEST_TIMEOUT_MS);

			const req = h2session.request({
				[constants.HTTP2_HEADER_METHOD]: "POST",
				[constants.HTTP2_HEADER_PATH]: path,
				...headers,
			});

			let status = 0;
			const chunks: Buffer[] = [];

			req.on("response", (responseHeaders) => {
				status = Number(responseHeaders[constants.HTTP2_HEADER_STATUS] ?? 0);
			});

			req.on("data", (chunk: Buffer) => {
				chunks.push(chunk);
			});

			req.on("end", () => {
				clearTimeout(timer);
				resolve({
					status,
					body: Buffer.concat(chunks).toString("utf-8"),
				});
			});

			req.on("error", (error: Error) => {
				clearTimeout(timer);
				// Force session recreation on stream errors
				if (session === h2session) {
					try { session.close(); } catch { /* ignore */ }
					session = null;
				}
				reject(error);
			});

			req.end(body);
		});

	return async (input: ApnsSendInput): Promise<LiveActivityPushDeliveryResult> => {
		const apsPayload = buildLiveActivityApsPayload({
			contentState: input.contentState,
			event: input.event,
			timestampSeconds: input.timestampSeconds,
			attributesType: input.attributesType,
			attributes: input.attributes,
		});

		const body = Buffer.from(JSON.stringify({ aps: apsPayload }), "utf-8");
		const path = `/3/device/${input.liveActivityToken}`;
		const jwt = getJwt();

		try {
			const response = await sendRequest(
				path,
				{
					"authorization": `bearer ${jwt}`,
					"apns-topic": topic,
					"apns-push-type": "liveactivity",
					"apns-priority": "10",
					"content-type": "application/json",
				},
				body,
			);

			if (response.status === 200) {
				log("push delivered", {
					event: input.event,
					liveActivityToken: toTokenPreview(input.liveActivityToken),
				});
				return {
					delivered: true,
					shouldDropSubscription: false,
				};
			}

			let errorReason = "unknown";
			try {
				const parsed = JSON.parse(response.body) as { reason?: string };
				errorReason = parsed.reason ?? "unknown";
			} catch {
				// ignore parse errors
			}

			// Token-level errors that mean we should stop sending to this token
			const permanentTokenErrors = new Set([
				"BadDeviceToken",
				"Unregistered",
				"DeviceTokenNotForTopic",
				"ExpiredToken",
			]);

			if (permanentTokenErrors.has(errorReason)) {
				warn("push rejected (token invalid)", {
					event: input.event,
					liveActivityToken: toTokenPreview(input.liveActivityToken),
					status: response.status,
					reason: errorReason,
				});
				return {
					delivered: false,
					errorCode: `apns/${errorReason}`,
					shouldDropSubscription: true,
				};
			}

			// JWT/auth errors - invalidate cached JWT and retry next time
			if (errorReason === "ExpiredProviderToken" || errorReason === "InvalidProviderToken") {
				cachedJwt = null;
			}

			warn("push failed", {
				event: input.event,
				liveActivityToken: toTokenPreview(input.liveActivityToken),
				status: response.status,
				reason: errorReason,
			});
			return {
				delivered: false,
				errorCode: `apns/${errorReason}`,
				shouldDropSubscription: false,
			};
		} catch (error) {
			const errorMessage = error instanceof Error ? error.message : "unknown";
			const isTimeout = errorMessage === "timeout";
			warn("push error", {
				event: input.event,
				liveActivityToken: toTokenPreview(input.liveActivityToken),
				error: errorMessage,
			});
			return {
				delivered: false,
				errorCode: isTimeout ? "apns/timeout" : "apns/network-error",
				shouldDropSubscription: false,
			};
		}
	};
};
