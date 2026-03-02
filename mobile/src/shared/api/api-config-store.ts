import * as SecureStore from "expo-secure-store";

export interface ApiConfig {
	baseUrl: string;
	token: string;
}

const BASE_URL_KEY = "remotecode.base_url";
const TOKEN_KEY = "remotecode.token";
const SERVER_TOKEN_PREFIX = "remotecode.server_token.";
const SERVER_BASE_URL_PREFIX = "remotecode.server_base_url.";

const defaultConfig: ApiConfig = {
	baseUrl: "http://127.0.0.1:8835",
	token: "local-dev-token",
};

const normalizeBaseUrl = (value: string): string => {
	const trimmed = value.trim().replace(/\/+$/u, "");
	return trimmed.length > 0 ? trimmed : defaultConfig.baseUrl;
};

const normalizeToken = (value: string): string => {
	const trimmed = value.trim();
	return trimmed.length > 0 ? trimmed : defaultConfig.token;
};

export const ApiConfigStore = {
	defaultConfig,
	async read(): Promise<ApiConfig> {
		const [baseUrl, token] = await Promise.all([
			SecureStore.getItemAsync(BASE_URL_KEY),
			SecureStore.getItemAsync(TOKEN_KEY),
		]);

		return {
			baseUrl: normalizeBaseUrl(baseUrl ?? defaultConfig.baseUrl),
			token: normalizeToken(token ?? defaultConfig.token),
		};
	},
	async save(config: ApiConfig): Promise<ApiConfig> {
		const normalized = {
			baseUrl: normalizeBaseUrl(config.baseUrl),
			token: normalizeToken(config.token),
		};

		await Promise.all([
			SecureStore.setItemAsync(BASE_URL_KEY, normalized.baseUrl),
			SecureStore.setItemAsync(TOKEN_KEY, normalized.token),
		]);

		return normalized;
	},
	async readTokenForServer(serverId: string): Promise<string | null> {
		const key = `${SERVER_TOKEN_PREFIX}${serverId}`;
		const token = await SecureStore.getItemAsync(key);
		if (!token) {
			return null;
		}

		const normalized = normalizeToken(token);
		return normalized.length > 0 ? normalized : null;
	},
	async readBaseUrlForServer(serverId: string): Promise<string | null> {
		const key = `${SERVER_BASE_URL_PREFIX}${serverId}`;
		const baseUrl = await SecureStore.getItemAsync(key);
		if (!baseUrl) {
			return null;
		}

		const normalized = normalizeBaseUrl(baseUrl);
		return normalized.length > 0 ? normalized : null;
	},
	async saveServerConnection(input: { serverId: string; baseUrl: string; token: string }): Promise<ApiConfig> {
		const serverId = input.serverId.trim();
		const normalizedConfig = {
			baseUrl: normalizeBaseUrl(input.baseUrl),
			token: normalizeToken(input.token),
		};

		await Promise.all([
			SecureStore.setItemAsync(`${SERVER_TOKEN_PREFIX}${serverId}`, normalizedConfig.token),
			SecureStore.setItemAsync(`${SERVER_BASE_URL_PREFIX}${serverId}`, normalizedConfig.baseUrl),
			SecureStore.setItemAsync(BASE_URL_KEY, normalizedConfig.baseUrl),
			SecureStore.setItemAsync(TOKEN_KEY, normalizedConfig.token),
		]);

		return normalizedConfig;
	},
};
