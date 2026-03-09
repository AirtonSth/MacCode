/* eslint-disable @typescript-eslint/naming-convention, functional/no-classes */
/* eslint-disable @typescript-eslint/parameter-properties, max-statements */
/* eslint-disable @typescript-eslint/no-magic-numbers, functional/no-let */
import type {
	PrivateBootstrapResponseDto,
	PrivateBootstrapStatusDto,
	PrivateConnectorsResponseDto,
	PrivateLoginRequestDto,
	PrivateLogoutRequestDto,
	PrivateMeResponseDto,
	PrivatePairingClaimRequestDto,
	PrivatePairingClaimResponseDto,
	PrivateRefreshRequestDto,
	PrivateRegisterRequestDto,
	PrivateSessionDto,
} from "./private-protocol";

interface PrivateClientConfig {
	baseUrl: string;
	fetch?: typeof fetch;
	getAccessToken?: () => string | null | Promise<string | null>;
	onUnauthorized?: () => void | Promise<void>;
}

interface PrivateRequestOptions {
	authenticated?: boolean;
	body?: unknown;
	headers?: HeadersInit;
	method: "GET" | "POST";
	path: string;
}

export class PrivateApiError extends Error {
	public override name = "PrivateApiError";

	public constructor(
		public readonly status: number,
		public readonly payload: unknown,
		message: string,
	) {
		super(message);
	}
}

const isObject = (value: unknown): value is Record<string, unknown> =>
	typeof value === "object" && value !== null;

const normalizeBaseUrl = (value: string): string => {
	const trimmed = value.trim().replace(/\/+$/u, "");

	return trimmed.length > 0 ? trimmed : "http://127.0.0.1:8787";
};

const toMessage = (payload: unknown, fallback: string): string => {
	if (!isObject(payload)) {
		return fallback;
	}

	if (typeof payload.error === "string" && payload.error.trim().length > 0) {
		return payload.error;
	}

	if (typeof payload.message === "string" && payload.message.trim().length > 0) {
		return payload.message;
	}

	return fallback;
};

export const createPrivateClient = (config: PrivateClientConfig) => {
	const baseUrl = normalizeBaseUrl(config.baseUrl);
	const requestFetch = config.fetch ?? fetch;

	const request = async <T>(options: PrivateRequestOptions): Promise<T> => {
		const headers = new Headers(options.headers);

		if (options.body !== undefined) {
			headers.set("content-type", "application/json");
		}

		if (options.authenticated !== false) {
			const token = await config.getAccessToken?.();

			if (!token) {
				throw new PrivateApiError(401, null, "missing_private_access_token");
			}

			headers.set("authorization", `Bearer ${token}`);
		}

		const response = await requestFetch(`${baseUrl}${options.path}`, {
			body: options.body === undefined ? undefined : JSON.stringify(options.body),
			headers,
			method: options.method,
		});

		let payload: unknown = null;

		try {
			payload = await response.json();
		} catch {
			payload = null;
		}

		if (!response.ok) {
			if (response.status === 401) {
				await config.onUnauthorized?.();
			}

			throw new PrivateApiError(
				response.status,
				payload,
				toMessage(payload, response.statusText || "private_request_failed"),
			);
		}

		return payload as T;
	};

	return {
		bootstrapConnector: async (input: {
			hostname?: string;
			name?: string;
			relayCapabilitiesVersion?: string;
			relayVersion?: string;
		}): Promise<PrivateBootstrapResponseDto> =>
			await request<PrivateBootstrapResponseDto>({
				authenticated: false,
				body: input,
				method: "POST",
				path: "/v1/private/connectors/bootstrap",
			}),

		claimPairing: async (input: PrivatePairingClaimRequestDto): Promise<PrivatePairingClaimResponseDto> =>
			await request<PrivatePairingClaimResponseDto>({
				body: input,
				method: "POST",
				path: "/v1/private/pairing/claim",
			}),

			getBootstrapStatus: async (
				input: { pairingId: string; pollToken: string },
			): Promise<PrivateBootstrapStatusDto> =>
			await request<PrivateBootstrapStatusDto>({
				authenticated: false,
				method: "GET",

				path: `/v1/private/connectors/bootstrap/${encodeURIComponent(input.pairingId)}/status`
					+ `?pollToken=${encodeURIComponent(input.pollToken)}`,
			}),

		listConnectors: async (): Promise<PrivateConnectorsResponseDto> =>
			await request<PrivateConnectorsResponseDto>({
				method: "GET",
				path: "/v1/private/connectors",
			}),

		login: async (input: PrivateLoginRequestDto): Promise<PrivateSessionDto> =>
			await request<PrivateSessionDto>({
				authenticated: false,
				body: input,
				method: "POST",
				path: "/v1/private/auth/login",
			}),

		logout: async (input: PrivateLogoutRequestDto): Promise<void> => {
			await request<null>({
				body: input,
				method: "POST",
				path: "/v1/private/auth/logout",
			});
		},

		me: async (): Promise<PrivateMeResponseDto> =>
			await request<PrivateMeResponseDto>({
				method: "GET",
				path: "/v1/private/me",
			}),

		refresh: async (input: PrivateRefreshRequestDto): Promise<PrivateSessionDto> =>
			await request<PrivateSessionDto>({
				authenticated: false,
				body: input,
				method: "POST",
				path: "/v1/private/auth/refresh",
			}),

		register: async (input: PrivateRegisterRequestDto): Promise<PrivateSessionDto> =>
			await request<PrivateSessionDto>({
				authenticated: false,
				body: input,
				method: "POST",
				path: "/v1/private/auth/register",
			}),
	};
};
