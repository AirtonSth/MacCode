/* eslint-disable @typescript-eslint/naming-convention, functional/no-classes */
/* eslint-disable @typescript-eslint/parameter-properties */
/* eslint-disable max-lines, max-statements */
/* eslint-disable @typescript-eslint/no-magic-numbers */
import type {
	PrivateAuthCompletionExchangeRequestDto,
	PrivateBootstrapResponseDto,
	PrivateBootstrapStatusDto,
	PrivateConnectorsResponseDto,
	PrivateForgotPasswordRequestDto,
	PrivateForgotPasswordResponseDto,
	PrivateLoginRequestDto,
	PrivateLogoutRequestDto,
	PrivateMeResponseDto,
	PrivateMobileConnectBootstrapRequestDto,
	PrivateMobileConnectBootstrapResponseDto,
	PrivateMobileConnectClaimRequestDto,
	PrivateMobileConnectClaimResponseDto,
	PrivatePairingClaimRequestDto,
	PrivatePairingClaimResponseDto,
	PrivateRefreshRequestDto,
	PrivateRegisterRequestDto,
	PrivateResetPasswordRequestDto,
	PrivateResetPasswordResponseDto,
	PrivateResetPasswordValidateResponseDto,
	PrivateSessionDto,
	PrivateSignupIntentCheckoutResponseDto,
	PrivateSignupIntentCompletionResponseDto,
	PrivateSignupIntentRequestDto,
	PrivateSignupIntentResponseDto,
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

const parseErrorPayload = async (response: Response): Promise<{ message: string | null; payload: unknown }> => {
	const rawText = await response.text();

	if (!rawText.trim()) {
		return { message: null, payload: null };
	}

	try {
		const payload = JSON.parse(rawText) as unknown;

		return {
			message: toMessage(payload, rawText),
			payload,
		};
	} catch {
		return {
			message: rawText,
			payload: rawText,
		};
	}
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

		const { message, payload } = await parseErrorPayload(response.clone());

		if (!response.ok) {
			if (response.status === 401) {
				await config.onUnauthorized?.();
			}

			throw new PrivateApiError(
				response.status,
				payload,
				message ?? response.statusText ?? "private_request_failed",
			);
		}

		return (await response.json()) as T;
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

		claimMobileConnect: async (
			input: PrivateMobileConnectClaimRequestDto,
		): Promise<PrivateMobileConnectClaimResponseDto> =>
			await request<PrivateMobileConnectClaimResponseDto>({
				authenticated: false,
				body: input,
				method: "POST",
				path: "/v1/private/mobile-connect/claim",
			}),

		claimPairing: async (input: PrivatePairingClaimRequestDto): Promise<PrivatePairingClaimResponseDto> =>
			await request<PrivatePairingClaimResponseDto>({
				body: input,
				method: "POST",
				path: "/v1/private/pairing/claim",
			}),

		completeSignupIntent: async (
			signupIntentId: string,
		): Promise<PrivateSignupIntentCompletionResponseDto> =>
			await request<PrivateSignupIntentCompletionResponseDto>({
				authenticated: false,
				method: "POST",
				path: `/v1/private/auth/signup-intents/${encodeURIComponent(signupIntentId)}/complete`,
			}),

			createMobileConnectBootstrap: async (
			input: PrivateMobileConnectBootstrapRequestDto,
		): Promise<PrivateMobileConnectBootstrapResponseDto> =>
			await request<PrivateMobileConnectBootstrapResponseDto>({
				body: input,
				method: "POST",
				path: "/v1/private/mobile-connect/bootstrap",
			}),

		createSignupIntent: async (
			input: PrivateSignupIntentRequestDto,
		): Promise<PrivateSignupIntentResponseDto> =>
			await request<PrivateSignupIntentResponseDto>({
				authenticated: false,
				body: input,
				method: "POST",
				path: "/v1/private/auth/signup-intents",
			}),

		createSignupIntentCheckout: async (
			signupIntentId: string,
		): Promise<PrivateSignupIntentCheckoutResponseDto> =>
			await request<PrivateSignupIntentCheckoutResponseDto>({
				authenticated: false,
				method: "POST",
				path: `/v1/private/auth/signup-intents/${encodeURIComponent(signupIntentId)}/checkout`,
			}),

		exchangeCompletionToken: async (
			input: PrivateAuthCompletionExchangeRequestDto,
		): Promise<PrivateSessionDto> =>
			await request<PrivateSessionDto>({
				authenticated: false,
				body: input,
				method: "POST",
				path: "/v1/private/auth/completion/exchange",
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

		getSignupIntent: async (signupIntentId: string): Promise<PrivateSignupIntentResponseDto> =>
			await request<PrivateSignupIntentResponseDto>({
				authenticated: false,
				method: "GET",
				path: `/v1/private/auth/signup-intents/${encodeURIComponent(signupIntentId)}`,
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

		requestPasswordReset: async (
			input: PrivateForgotPasswordRequestDto,
		): Promise<PrivateForgotPasswordResponseDto> =>
			await request<PrivateForgotPasswordResponseDto>({
				authenticated: false,
				body: input,
				method: "POST",
				path: "/v1/private/auth/forgot-password",
			}),

		resetPassword: async (
			input: PrivateResetPasswordRequestDto,
		): Promise<PrivateResetPasswordResponseDto> =>
			await request<PrivateResetPasswordResponseDto>({
				authenticated: false,
				body: input,
				method: "POST",
				path: "/v1/private/auth/reset-password",
			}),

		validatePasswordResetToken: async (
			token: string,
		): Promise<PrivateResetPasswordValidateResponseDto> =>
			await request<PrivateResetPasswordValidateResponseDto>({
				authenticated: false,
				method: "GET",
				path: `/v1/private/auth/reset-password/${encodeURIComponent(token)}/validate`,
			}),
	};
};
