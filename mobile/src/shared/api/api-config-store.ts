import * as SecureStore from "expo-secure-store";

export type ActiveConnectionTarget =
	| {
		baseUrl: string;
		kind: "local";
		token: string;
	}
	| {
		accessToken: string;
		backendUrl: string;
		connectorId: string;
		kind: "private";
	};

export interface ApiConfig {
	activeTarget: ActiveConnectionTarget;
	baseUrl: string;
	token: string;
}

export interface SavedConnection {
	baseUrl: string;
	lastConnectedAt: string;
	token: string;
}

interface SecureStoreLike {
	deleteItemAsync: (key: string) => Promise<void>;
	getItemAsync: (key: string) => Promise<string | null>;
	setItemAsync: (key: string, value: string) => Promise<void>;
}

const BASE_URL_KEY = "remotecode.base_url";
const TOKEN_KEY = "remotecode.token";
const ACTIVE_TARGET_KEY = "remotecode.active_target";
const SERVER_TOKEN_PREFIX = "remotecode.server_token.";
const SERVER_BASE_URL_PREFIX = "remotecode.server_base_url.";
const SAVED_CONNECTIONS_KEY = "remotecode.saved_connections";
const LEGACY_DEFAULT_TOKEN = "local-dev-token";
const MAX_SAVED_CONNECTIONS = 24;

let secureStoreOverride: SecureStoreLike | null = null;

const getSecureStore = (): SecureStoreLike => {
	if (secureStoreOverride) {
		return secureStoreOverride;
	}

	return SecureStore;
};

const defaultLocalTarget: ActiveConnectionTarget = {
	baseUrl: "http://127.0.0.1:8835",
	kind: "local",
	token: "remotecode.io-token",
};

const normalizeBaseUrl = (value: string): string => {
	const trimmed = value.trim().replace(/\/+$/u, "");
	return trimmed.length > 0 ? trimmed : defaultLocalTarget.baseUrl;
};

const normalizeToken = (value: string): string => {
	const trimmed = value.trim();
	const isEmpty = trimmed.length === 0;
	const isLegacyDefault = trimmed === LEGACY_DEFAULT_TOKEN;
	return isEmpty || isLegacyDefault ? defaultLocalTarget.token : trimmed;
};

const normalizePrivateTarget = (target: {
	accessToken: string;
	backendUrl: string;
	connectorId: string;
}): ActiveConnectionTarget => ({
	accessToken: target.accessToken.trim(),
	backendUrl: normalizeBaseUrl(target.backendUrl),
	connectorId: target.connectorId.trim(),
	kind: "private",
});

export const toApiConfig = (activeTarget: ActiveConnectionTarget): ApiConfig => ({
	activeTarget,
	baseUrl: activeTarget.kind === "local" ? activeTarget.baseUrl : activeTarget.backendUrl,
	token: activeTarget.kind === "local" ? activeTarget.token : activeTarget.accessToken,
});

const normalizeActiveTarget = (target: ActiveConnectionTarget): ActiveConnectionTarget => {
	if (target.kind === "private") {
		return normalizePrivateTarget(target);
	}

	return {
		baseUrl: normalizeBaseUrl(target.baseUrl),
		kind: "local",
		token: normalizeToken(target.token),
	};
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

const parseActiveTarget = (raw: string | null, fallback: { baseUrl: string; token: string }): ActiveConnectionTarget => {
	if (!raw) {
		return {
			baseUrl: normalizeBaseUrl(fallback.baseUrl),
			kind: "local",
			token: normalizeToken(fallback.token),
		};
	}

	try {
		const parsed = JSON.parse(raw) as ActiveConnectionTarget | null;
		if (!parsed || typeof parsed !== "object" || typeof parsed.kind !== "string") {
			return {
				baseUrl: normalizeBaseUrl(fallback.baseUrl),
				kind: "local",
				token: normalizeToken(fallback.token),
			};
		}

		return normalizeActiveTarget(parsed);
	} catch {
		return {
			baseUrl: normalizeBaseUrl(fallback.baseUrl),
			kind: "local",
			token: normalizeToken(fallback.token),
		};
	}
};

const writeSavedConnections = async (connections: SavedConnection[]): Promise<SavedConnection[]> => {
	const normalized = connections.slice(0, MAX_SAVED_CONNECTIONS);

	if (normalized.length === 0) {
		await getSecureStore().deleteItemAsync(SAVED_CONNECTIONS_KEY);
		return [];
	}

	await getSecureStore().setItemAsync(SAVED_CONNECTIONS_KEY, JSON.stringify(normalized));
	return normalized;
};

export const ApiConfigStore = {
	defaultConfig: toApiConfig(defaultLocalTarget),
	async read(): Promise<ApiConfig> {
		const [baseUrl, token, rawActiveTarget] = await Promise.all([
			getSecureStore().getItemAsync(BASE_URL_KEY),
			getSecureStore().getItemAsync(TOKEN_KEY),
			getSecureStore().getItemAsync(ACTIVE_TARGET_KEY),
		]);

		const activeTarget = parseActiveTarget(rawActiveTarget, {
			baseUrl: baseUrl ?? defaultLocalTarget.baseUrl,
			token: token ?? defaultLocalTarget.token,
		});
		const normalized = toApiConfig(activeTarget);

		await Promise.all([
			getSecureStore().setItemAsync(BASE_URL_KEY, normalized.baseUrl),
			getSecureStore().setItemAsync(TOKEN_KEY, normalized.token),
			getSecureStore().setItemAsync(ACTIVE_TARGET_KEY, JSON.stringify(activeTarget)),
		]);

		return normalized;
	},
	async save(config: ApiConfig): Promise<ApiConfig> {
		const activeTarget = normalizeActiveTarget(config.activeTarget);
		const normalized = toApiConfig(activeTarget);

		await Promise.all([
			getSecureStore().setItemAsync(BASE_URL_KEY, normalized.baseUrl),
			getSecureStore().setItemAsync(TOKEN_KEY, normalized.token),
			getSecureStore().setItemAsync(ACTIVE_TARGET_KEY, JSON.stringify(activeTarget)),
		]);

		return normalized;
	},
	async saveServerConnection(input: { serverId: string; baseUrl: string; token: string }): Promise<ApiConfig> {
		const serverId = input.serverId.trim();
		const activeTarget = normalizeActiveTarget({
			baseUrl: input.baseUrl,
			kind: "local",
			token: input.token,
		});
		const normalized = toApiConfig(activeTarget);

		await Promise.all([
			getSecureStore().setItemAsync(`${SERVER_TOKEN_PREFIX}${serverId}`, normalized.token),
			getSecureStore().setItemAsync(`${SERVER_BASE_URL_PREFIX}${serverId}`, normalized.baseUrl),
			getSecureStore().setItemAsync(BASE_URL_KEY, normalized.baseUrl),
			getSecureStore().setItemAsync(TOKEN_KEY, normalized.token),
			getSecureStore().setItemAsync(ACTIVE_TARGET_KEY, JSON.stringify(activeTarget)),
		]);

		return normalized;
	},
	async readTokenForServer(serverId: string): Promise<string | null> {
		const key = `${SERVER_TOKEN_PREFIX}${serverId}`;
		const token = await getSecureStore().getItemAsync(key);
		if (!token) {
			return null;
		}

		const normalized = normalizeToken(token);
		if (token.trim() !== normalized) {
			await getSecureStore().setItemAsync(key, normalized);
		}
		return normalized.length > 0 ? normalized : null;
	},
	async readBaseUrlForServer(serverId: string): Promise<string | null> {
		const key = `${SERVER_BASE_URL_PREFIX}${serverId}`;
		const baseUrl = await getSecureStore().getItemAsync(key);
		if (!baseUrl) {
			return null;
		}

		const normalized = normalizeBaseUrl(baseUrl);
		return normalized.length > 0 ? normalized : null;
	},
	async readSavedConnections(): Promise<SavedConnection[]> {
		const raw = await getSecureStore().getItemAsync(SAVED_CONNECTIONS_KEY);
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

export const setSecureStoreAdapterForTests = (adapter: SecureStoreLike) => {
	secureStoreOverride = adapter;
};

export const resetSecureStoreAdapterForTests = () => {
	secureStoreOverride = null;
};
