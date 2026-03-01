import * as SecureStore from "expo-secure-store";

export interface ApiConfig {
	baseUrl: string;
	token: string;
}

const BASE_URL_KEY = "remotecode:base-url";
const TOKEN_KEY = "remotecode:token";

const defaultConfig: ApiConfig = {
	baseUrl: "http://127.0.0.1:3001",
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
};
