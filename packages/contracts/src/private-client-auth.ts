/* eslint-disable @typescript-eslint/naming-convention */
import type {
	PrivateForgotPasswordRequestDto,
	PrivateForgotPasswordResponseDto,
	PrivateLoginRequestDto,
	PrivateLogoutRequestDto,
	PrivateMeResponseDto,
	PrivateRefreshRequestDto,
	PrivateRegisterRequestDto,
	PrivateResetPasswordRequestDto,
	PrivateResetPasswordResponseDto,
	PrivateResetPasswordValidateResponseDto,
	PrivateRevenueCatSyncResponseDto,
	PrivateSessionDto,
} from "./private-protocol";

export const createPrivateAuthMethods = (
	request: <T>(options: {
		authenticated?: boolean;
		body?: unknown;
		headers?: HeadersInit;
		method: "GET" | "POST";
		path: string;
	}) => Promise<T>,
) => ({
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

	syncRevenueCatSubscription: async (): Promise<PrivateRevenueCatSyncResponseDto> =>
		await request<PrivateRevenueCatSyncResponseDto>({
			method: "POST",
			path: "/v1/private/billing/revenuecat/sync",
		}),

	validatePasswordResetToken: async (
		token: string,
	): Promise<PrivateResetPasswordValidateResponseDto> =>
		await request<PrivateResetPasswordValidateResponseDto>({
			authenticated: false,
			method: "GET",
			path: `/v1/private/auth/reset-password/${encodeURIComponent(token)}/validate`,
		}),
});
