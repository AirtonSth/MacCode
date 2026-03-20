import { treaty } from "@elysiajs/eden";

export interface EdenClientConfig {
	baseUrl: string;
	token: string;
}

interface MutationRequestMetadata {
	clientId?: string;
	requestId?: string;
}

interface GitCommitRequestBody extends MutationRequestMetadata {
	message?: string;
	// eslint-disable-next-line @typescript-eslint/naming-convention
	includeUnstaged?: boolean;
	// eslint-disable-next-line @typescript-eslint/naming-convention
	push?: boolean;
}

export interface EdenClient {
	v1: {
		auth: {
			verify: {
				post: (body?: { token?: string } & MutationRequestMetadata) => Promise<unknown>;
			};
		};
		chats: (params: { id: string }) => {
			context: {
				get: () => Promise<unknown>;
			};
			delete: () => Promise<unknown>;
			messages: {
				get: () => Promise<unknown>;
			};
			terminal: {
				get: (options?: { query?: { cursor?: number; limit?: number } }) => Promise<unknown>;
				exec: {
					post: (body: { command: string; timeoutMs?: number } & MutationRequestMetadata) => Promise<unknown>;
				};
			};
		};
		discovery: {
			get: () => Promise<unknown>;
		};
		fs: {
			list: {
				get: (options: { query: { path: string } }) => Promise<unknown>;
			};
			roots: {
				get: () => Promise<unknown>;
			};
		};
		providers: {
			codex: {
				models: {
					get: () => Promise<unknown>;
				};
			};
		};
		projects: {
			get: () => Promise<unknown>;
			post: (body: { path: string; name?: string } & MutationRequestMetadata) => Promise<unknown>;
			workspaces: {
				get: () => Promise<unknown>;
			};
		} & ((params: { id: string }) => {
			threads: {
				get: () => Promise<unknown>;
			};
			chats: {
				get: () => Promise<unknown>;
				post: (body: { title?: string } & MutationRequestMetadata) => Promise<unknown>;
			};
			patch: (body: { isFavorite: boolean } & MutationRequestMetadata) => Promise<unknown>;
			delete: () => Promise<unknown>;
			git: {
				status: {
					get: () => Promise<unknown>;
				};
				branches: {
					get: () => Promise<unknown>;
					checkout: {
						post: (body: { branch: string } & MutationRequestMetadata) => Promise<unknown>;
					};
					create: {
						post: (body: { name: string } & MutationRequestMetadata) => Promise<unknown>;
					};
				};
				commit: {
					post: (body: GitCommitRequestBody) => Promise<unknown>;
				};
			};
		});
		selection: {
			get: () => Promise<unknown>;
				patch: (
					body: {
						selectedChatId: string | null;
						selectedProjectId: string | null;
						permissionMode?: string;
						selectedModel?: string | null;
						selectedProvider?: string | null;
						selectedReasoningEffort?: string | null;
					} & MutationRequestMetadata,
				) => Promise<unknown>;
			};
	};
}

const normalizeBaseUrl = (baseUrl: string): string => {
	const sanitized = baseUrl.trim().replace(/\/+$/u, "");

	return sanitized.length > 0 ? sanitized : "http://127.0.0.1:8835";
};

const normalizeToken = (token: string): string => {
	const sanitized = token.trim();
	const isLegacyDefault = sanitized === "local-dev-token";

	return sanitized.length > 0 && !isLegacyDefault ? sanitized : "remotecode.io-token";
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
