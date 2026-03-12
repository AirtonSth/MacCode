import type {
	PrivateAccountStateDto,
	PrivateLoginRequestDto,
} from "@remotecode/contracts";

const toBaseUrl = (value?: string): string => {
	const normalized = (value?.trim() || import.meta.env.VITE_REMOTECODE_SERVER_URL || "http://127.0.0.1:8835").trim();
	return normalized.replace(/\/+$/u, "");
};

const toToken = (value?: string): string => {
	return (value?.trim() || import.meta.env.VITE_REMOTECODE_LOCAL_TOKEN || "remotecode.io-token").trim();
};

export class PrivateAccountApiError extends Error {
	public readonly status: number;

	public constructor(status: number, message: string) {
		super(message);
		this.name = "PrivateAccountApiError";
		this.status = status;
	}
}

export interface PrivateAccountApiClient {
	browserForgotPassword: (input?: { email?: string }) => Promise<{ url: string }>;
	browserManageSubscription: () => Promise<{ url: string }>;
	browserRegister: (input?: { email?: string }) => Promise<{ url: string }>;
	getState: () => Promise<PrivateAccountStateDto>;
	login: (input: PrivateLoginRequestDto) => Promise<PrivateAccountStateDto>;
	logout: () => Promise<PrivateAccountStateDto>;
}

export const createPrivateAccountApiClient = (config?: {
	baseUrl?: string;
	token?: string;
}): PrivateAccountApiClient => {
	const baseUrl = toBaseUrl(config?.baseUrl);
	const token = toToken(config?.token);

	const request = async <T>(input: {
		body?: unknown;
		method: "GET" | "POST";
		path: string;
	}): Promise<T> => {
		const response = await fetch(`${baseUrl}/v1${input.path}`, {
			body: input.body === undefined ? undefined : JSON.stringify(input.body),
			headers: {
				authorization: `Bearer ${token}`,
				"content-type": "application/json",
			},
			method: input.method,
		});

		if (response.status === 204) {
			return null as T;
		}

		if (!response.ok) {
			const rawText = await response.text();
			let payload: Record<string, unknown> | null = null;
			if (rawText.trim().length > 0) {
				try {
					payload = JSON.parse(rawText) as Record<string, unknown>;
				} catch {
					payload = null;
				}
			}

			const message =
				typeof payload?.error === "string" && payload.error.trim().length > 0
					? payload.error
					: rawText.trim().length > 0
						? rawText
					: response.statusText || "private_account_request_failed";
			throw new PrivateAccountApiError(response.status, message);
		}

		return await response.json() as T;
	};

	return {
		browserForgotPassword: async (input) => await request<{ url: string }>({
			body: input,
			method: "POST",
			path: "/private-account/browser/forgot-password",
		}),
		browserManageSubscription: async () => await request<{ url: string }>({
			method: "GET",
			path: "/private-account/browser/manage-subscription",
		}),
		browserRegister: async (input) => await request<{ url: string }>({
			body: input,
			method: "POST",
			path: "/private-account/browser/register",
		}),
		getState: async () => await request<PrivateAccountStateDto>({
			method: "GET",
			path: "/private-account/state",
		}),
		login: async (input) => await request<PrivateAccountStateDto>({
			body: input,
			method: "POST",
			path: "/private-account/login",
		}),
		logout: async () => await request<PrivateAccountStateDto>({
			method: "POST",
			path: "/private-account/logout",
		}),
	};
};
