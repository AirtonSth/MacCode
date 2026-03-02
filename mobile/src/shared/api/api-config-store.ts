import * as SecureStore from "expo-secure-store";

export interface ApiConfig {
	baseUrl: string;
	token: string;
}

export interface SavedConnection {
	baseUrl: string;
	lastConnectedAt: string;
	token: string;
}

const BASE_URL_KEY = "remotecode.base_url";
const TOKEN_KEY = "remotecode.token";
const SERVER_TOKEN_PREFIX = "remotecode.server_token.";
const SERVER_BASE_URL_PREFIX = "remotecode.server_base_url.";
const SAVED_CONNECTIONS_KEY = "remotecode.saved_connections";
const LEGACY_DEFAULT_TOKEN = "local-dev-token";
const MAX_SAVED_CONNECTIONS = 24;

const defaultConfig: ApiConfig = {
	baseUrl: "http://127.0.0.1:8835",
	token: "remotecode.io-token",
};

const normalizeBaseUrl = (value: string): string => {
	const trimmed = value.trim().replace(/\/+$/u, "");
	return trimmed.length > 0 ? trimmed : defaultConfig.baseUrl;
};

const normalizeToken = (value: string): string => {
	const trimmed = value.trim();

	const isEmpty = trimmed.length === 0;
	const isLegacyDefault = trimmed === LEGACY_DEFAULT_TOKEN;
	return isEmpty || isLegacyDefault ? defaultConfig.token : trimmed;
};

const toTimestamp = (input: string): number => {
	const timestamp = Date.parse(input);
	return Number.isNaN(timestamp) ? 0 : timestamp;
};

const parseSavedConnections = (raw: string | null): SavedConnection[] => {
	if (!raw) {
		return [];
	}

	try {
		const parsed = JSON.parse(raw) as unknown;
		if (!Array.isArray(parsed)) {
			return [];
		}

		const entries = parsed
			.filter((item) => Boolean(item) && typeof item === "object")
			.map((item) => {
				const candidate = item as Record<string, unknown>;
				const baseUrl = normalizeBaseUrl(String(candidate.baseUrl ?? ""));
				const token = normalizeToken(String(candidate.token ?? ""));
				const lastConnectedAtRaw = candidate.lastConnectedAt;
				const lastConnectedAt =
					typeof lastConnectedAtRaw === "string" && !Number.isNaN(Date.parse(lastConnectedAtRaw))
						? lastConnectedAtRaw
						: new Date(0).toISOString();

				return {
					baseUrl,
					lastConnectedAt,
					token,
				};
			});

		const uniqueByBaseUrl = new Map<string, SavedConnection>();
			for (const entry of entries) {
				const current = uniqueByBaseUrl.get(entry.baseUrl);
				if (!current || toTimestamp(entry.lastConnectedAt) > toTimestamp(current.lastConnectedAt)) {
					uniqueByBaseUrl.set(entry.baseUrl, entry);
				}
			}

		return Array.from(uniqueByBaseUrl.values())
			.sort((left, right) => right.lastConnectedAt.localeCompare(left.lastConnectedAt))
			.slice(0, MAX_SAVED_CONNECTIONS);
	} catch {
		return [];
	}
};

const writeSavedConnections = async (connections: SavedConnection[]): Promise<SavedConnection[]> => {
	const normalized = connections.slice(0, MAX_SAVED_CONNECTIONS);

	if (normalized.length === 0) {
		await SecureStore.deleteItemAsync(SAVED_CONNECTIONS_KEY);
		return [];
	}

	await SecureStore.setItemAsync(SAVED_CONNECTIONS_KEY, JSON.stringify(normalized));
	return normalized;
};

export const ApiConfigStore = {
	defaultConfig,
	async read(): Promise<ApiConfig> {
		const [baseUrl, token] = await Promise.all([
			SecureStore.getItemAsync(BASE_URL_KEY),
			SecureStore.getItemAsync(TOKEN_KEY),
		]);
		const normalizedBaseUrl = normalizeBaseUrl(baseUrl ?? defaultConfig.baseUrl);
		const normalizedToken = normalizeToken(token ?? defaultConfig.token);

		if (token && token.trim() !== normalizedToken) {
			await SecureStore.setItemAsync(TOKEN_KEY, normalizedToken);
		}

		return {
			baseUrl: normalizedBaseUrl,
			token: normalizedToken,
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
		if (token.trim() !== normalized) {
			await SecureStore.setItemAsync(key, normalized);
		}
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
	async readSavedConnections(): Promise<SavedConnection[]> {
		const raw = await SecureStore.getItemAsync(SAVED_CONNECTIONS_KEY);
		return parseSavedConnections(raw);
	},
	async saveSavedConnection(input: { baseUrl: string; token: string }): Promise<SavedConnection[]> {
		const normalizedEntry: SavedConnection = {
			baseUrl: normalizeBaseUrl(input.baseUrl),
			lastConnectedAt: new Date().toISOString(),
			token: normalizeToken(input.token),
		};

		const current = await this.readSavedConnections();
		const next = [normalizedEntry, ...current.filter((item) => item.baseUrl !== normalizedEntry.baseUrl)];
		return await writeSavedConnections(next);
	},
	async deleteSavedConnection(baseUrl: string): Promise<SavedConnection[]> {
		const normalizedBaseUrl = normalizeBaseUrl(baseUrl);
		const current = await this.readSavedConnections();
		const next = current.filter((item) => item.baseUrl !== normalizedBaseUrl);
		return await writeSavedConnections(next);
	},
};
