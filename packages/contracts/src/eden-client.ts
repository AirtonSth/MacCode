import { treaty } from "@elysiajs/eden";

export interface EdenClientConfig {
	baseUrl: string;
	token: string;
}

export interface EdenClient {
	v1: {
		chats: (params: { id: string }) => {
			delete: () => Promise<unknown>;
			messages: {
				get: () => Promise<unknown>;
			};
		};
		projects: {
			get: () => Promise<unknown>;
		} & ((params: { id: string }) => {
			chats: {
				get: () => Promise<unknown>;
				post: (body: { title?: string }) => Promise<unknown>;
			};
			patch: (body: { isFavorite: boolean }) => Promise<unknown>;
		});
		selection: {
			get: () => Promise<unknown>;
			patch: (body: { selectedChatId: string | null; selectedProjectId: string | null }) => Promise<unknown>;
		};
	};
}

const normalizeBaseUrl = (baseUrl: string): string => {
	const sanitized = baseUrl.trim().replace(/\/+$/u, "");

	return sanitized.length > 0 ? sanitized : "http://127.0.0.1:3001";
};

const normalizeToken = (token: string): string => {
	const sanitized = token.trim();

	return sanitized.length > 0 ? sanitized : "local-dev-token";
};

export const createEdenClient = (config: EdenClientConfig) => {
	const baseUrl = normalizeBaseUrl(config.baseUrl);
	const token = normalizeToken(config.token);

	return treaty(baseUrl, {
		headers: {
			authorization: `Bearer ${token}`,
		},
	}) as unknown as EdenClient;
};
