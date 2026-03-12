/* eslint-disable total-functions/no-partial-url-constructor */
import {
	createPrivateClient,
	isDesktopMobileConnectQrPayload,
	type DesktopMobileConnectQrPayloadDto,
	type PrivateMobileConnectClaimResponseDto,
} from "@remotecode/contracts";

import type { PersistedPrivateSessionRecord } from "./private-session-store";

export const DEV_PRIVATE_BACKEND_URL = "http://127.0.0.1:8787";
export const RELEASE_PRIVATE_BACKEND_URL = "https://private.remotecode.io:8787";
export const DEFAULT_PRIVATE_BACKEND_URL = RELEASE_PRIVATE_BACKEND_URL;

const PRIVATE_CONNECT_HOST = "qr.remotecode.dev";
const PRIVATE_CONNECT_PATH_PREFIX = "/connect";
const PRIVATE_CONNECT_SCHEMES = new Set(["remotecode", "remotecode-mobile"]);

export interface PrivateMobileConnectLink {
	backendUrl: string;
	code: string;
	sessionId: string;
}

export type PrivateConnectIntent =
	| {
			claim: PrivateMobileConnectLink;
			kind: "claim";
			rawValue: string;
		}
	| {
			kind: "legacy_qr";
			payload: DesktopMobileConnectQrPayloadDto;
			rawValue: string;
		};

const normalizeBackendUrl = (value: string | null | undefined): string => {
	const normalized = value?.trim().replace(/\/+$/u, "") ?? "";
	return normalized.length > 0 ? normalized : DEFAULT_PRIVATE_BACKEND_URL;
};

const sanitizeBackendUrl = (value: string | null | undefined): string => {
	const normalized = normalizeBackendUrl(value);
	const parsed = (() => {
		try {
			return new URL(normalized);
		} catch {
			return null;
		}
	})();

	if (!parsed) {
		return DEFAULT_PRIVATE_BACKEND_URL;
	}

	if (parsed.protocol === "https:" && parsed.hostname === "private.remotecode.io") {
		return RELEASE_PRIVATE_BACKEND_URL;
	}

	return DEFAULT_PRIVATE_BACKEND_URL;
};

const toLogicalPath = (url: URL): string => {
	if (url.protocol === "https:" || url.protocol === "http:") {
		return url.pathname;
	}

	const normalizedPath = url.pathname.length > 1 ? url.pathname : "";
	if (url.host.length > 0) {
		return `/${url.host}${normalizedPath}`;
	}

	return normalizedPath || "/";
};

const isTrustedPrivateConnectUrl = (url: URL): boolean => {
	const scheme = url.protocol.replace(/:$/u, "").toLowerCase();
	const logicalPath = toLogicalPath(url);
	if (scheme === "https") {
		return url.hostname === PRIVATE_CONNECT_HOST && logicalPath.startsWith(PRIVATE_CONNECT_PATH_PREFIX);
	}

	return PRIVATE_CONNECT_SCHEMES.has(scheme) && logicalPath.startsWith(PRIVATE_CONNECT_PATH_PREFIX);
};

const decodePathSegment = (segment: string): string => {
	try {
		return decodeURIComponent(segment);
	} catch {
		return segment;
	}
};

const parseUrl = (raw: string): URL | null => {
	try {
		return new URL(raw);
	} catch {
		return null;
	}
};

export const parsePrivateMobileConnectLink = (raw: string): PrivateMobileConnectLink => {
	const trimmed = raw.trim();
	if (trimmed.length === 0) {
		throw new Error("invalid_private_mobile_connect_link");
	}

	const parsed = parseUrl(trimmed);
	if (!parsed) {
		throw new Error("invalid_private_mobile_connect_link");
	}

	if (!isTrustedPrivateConnectUrl(parsed)) {
		throw new Error("invalid_private_mobile_connect_link");
	}

	const pathSegments = toLogicalPath(parsed)
		.split("/")
		.map((segment) => decodePathSegment(segment.trim()))
		.filter((segment) => segment.length > 0);
	const connectIndex = pathSegments.indexOf("connect");
	const sessionIdFromPath = connectIndex !== -1 ? pathSegments[connectIndex + 1] ?? "" : "";
	const codeFromPath = connectIndex !== -1 ? pathSegments[connectIndex + 2] ?? "" : "";
	const sessionId = sessionIdFromPath || parsed.searchParams.get("sessionId")?.trim() || "";
	const code = codeFromPath || parsed.searchParams.get("code")?.trim() || parsed.searchParams.get("token")?.trim() || "";
	if (!sessionId || !code) {
		throw new Error("invalid_private_mobile_connect_link");
	}

	return {
		backendUrl: sanitizeBackendUrl(parsed.searchParams.get("backendUrl")),
		code,
		sessionId,
	};
};

const parsePrivateConnectJson = (raw: string): PrivateConnectIntent | null => {
	try {
		const parsed = JSON.parse(raw) as unknown;
		if (!parsed || typeof parsed !== "object") {
			return null;
		}

		const candidate = parsed as DesktopMobileConnectQrPayloadDto & {
			linkUrl?: unknown;
		};
		if (typeof candidate.linkUrl === "string" && candidate.linkUrl.trim().length > 0) {
			const claim = parsePrivateMobileConnectLink(candidate.linkUrl);
			return {
				claim: {
					...claim,
					backendUrl: claim.backendUrl === DEFAULT_PRIVATE_BACKEND_URL
						? sanitizeBackendUrl(candidate.backendUrl)
						: claim.backendUrl,
				},
				kind: "claim",
				rawValue: candidate.linkUrl.trim(),
			};
		}

		if (!isDesktopMobileConnectQrPayload(parsed)) {
			return null;
		}

		return {
			kind: "legacy_qr",
			payload: {
				backendUrl: sanitizeBackendUrl(candidate.backendUrl),
				connectorId: candidate.connectorId.trim(),
				connectorName: candidate.connectorName.trim(),
				linkUrl: typeof candidate.linkUrl === "string" ? candidate.linkUrl.trim() : null,
				type: candidate.type,
				version: candidate.version,
			},
			rawValue: raw.trim(),
		};
	} catch {
		return null;
	}
};

export const parsePrivateConnectInput = (raw: string): PrivateConnectIntent => {
	const jsonIntent = parsePrivateConnectJson(raw);
	if (jsonIntent) {
		return jsonIntent;
	}

	try {
		return {
			claim: parsePrivateMobileConnectLink(raw),
			kind: "claim",
			rawValue: raw.trim(),
		};
	} catch {
		const parsed = parseUrl(raw);
		if (!parsed) {
			throw new Error("invalid_private_mobile_connect_link");
		}
		if (!isTrustedPrivateConnectUrl(parsed)) {
			throw new Error("invalid_private_mobile_connect_link");
		}

		const connectorId = parsed.searchParams.get("connectorId")?.trim() ?? "";
		const connectorName = parsed.searchParams.get("connectorName")?.trim() ?? "";
		if (!connectorId || !connectorName) {
			throw new Error("invalid_private_mobile_connect_link");
		}

		return {
			kind: "legacy_qr",
			payload: {
				backendUrl: sanitizeBackendUrl(parsed.searchParams.get("backendUrl")),
				connectorId,
				connectorName,
				type: "remotecode_private_mobile_connect",
				version: 1,
			},
			rawValue: raw.trim(),
		};
	}
};

export const buildPrivateConnectUrlFromParams = (input: {
	backendUrl?: string | null;
	code?: string | null;
	sessionId?: string | null;
}): string | null => {
	const sessionId = input.sessionId?.trim() ?? "";
	const code = input.code?.trim() ?? "";
	if (sessionId.length === 0 || code.length === 0) {
		return null;
	}

	const params = new URLSearchParams();
	const backendUrl = sanitizeBackendUrl(input.backendUrl);
	if (input.backendUrl && backendUrl.length > 0) {
		params.set("backendUrl", backendUrl);
	}
	const suffix = params.size > 0 ? `?${params.toString()}` : "";

	return `remotecode://connect/${encodeURIComponent(sessionId)}/${encodeURIComponent(code)}${suffix}`;
};

export const claimPrivateMobileConnect = async (input: {
	createClient?: typeof createPrivateClient;
	link: PrivateMobileConnectLink;
}): Promise<PrivateMobileConnectClaimResponseDto> => {
	const client = (input.createClient ?? createPrivateClient)({
		baseUrl: input.link.backendUrl,
	});
	return await client.claimMobileConnect({
		code: input.link.code,
		sessionId: input.link.sessionId,
	});
};

export const completePrivateMobileConnect = async (input: {
	activateConnector: (options: {
		backendUrl: string;
		connectorId: string;
		sessionRecordOverride?: PersistedPrivateSessionRecord;
	}) => Promise<void>;
	clearPendingQrPayload?: () => Promise<void>;
	createClient?: typeof createPrivateClient;
	link: PrivateMobileConnectLink;
	setSessionRecord: (sessionRecord: PersistedPrivateSessionRecord) => Promise<void>;
}): Promise<{
	connector: PrivateMobileConnectClaimResponseDto["connector"];
	sessionRecord: PersistedPrivateSessionRecord;
}> => {
	const response = await claimPrivateMobileConnect({
		createClient: input.createClient,
		link: input.link,
	});
	const sessionRecord = {
		backendUrl: normalizeBackendUrl(response.backendUrl),
		session: response.session,
	};
	await input.setSessionRecord(sessionRecord);
	if (!response.session.user.subscribed) {
		await input.clearPendingQrPayload?.();
		throw new Error("private_subscription_required");
	}
	await input.activateConnector({
		backendUrl: sessionRecord.backendUrl,
		connectorId: response.connector.id,
		sessionRecordOverride: sessionRecord,
	});
	await input.clearPendingQrPayload?.();
	return {
		connector: response.connector,
		sessionRecord,
	};
};

export const toPrivateConnectErrorMessage = (error: unknown): string =>
	{
		if (!(error instanceof Error) || error.message.trim().length === 0) {
			return "Unable to connect this QR code.";
		}

		if (error.message === "invalid_private_mobile_connect_link") {
			return "Invalid or expired private connection link.";
		}

		if (error.message === "invalid_private_mobile_qr_payload") {
			return "Invalid private connection QR code.";
		}

		if (error.message === "private_subscription_required") {
			return "A private subscription is required before this device can connect.";
		}

		return error.message;
	};
