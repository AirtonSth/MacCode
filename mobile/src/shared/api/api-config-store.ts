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

export interface LocalSavedConnection {
	baseUrl: string;
	kind: "local";
	lastConnectedAt: string;
	token: string;
}

export interface PrivateSavedConnection {
	backendUrl: string;
	connectorId: string;
	connectorName: string;
	kind: "private";
	lastConnectedAt: string;
}

export type SavedConnection = LocalSavedConnection | PrivateSavedConnection;

export interface LegacySavedConnection {
	baseUrl: string;
	lastConnectedAt: string;
	token: string;
}

const isSavedConnection = (value: SavedConnection | null): value is SavedConnection => value !== null;

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
let secureStorePromise: Promise<SecureStoreLike> | null = null;

const loadSecureStore = async (): Promise<SecureStoreLike> => {
	const module = await import("expo-secure-store");
	return {
		deleteItemAsync: module.deleteItemAsync,
		getItemAsync: module.getItemAsync,
		setItemAsync: module.setItemAsync,
	};
};

const getSecureStore = async (): Promise<SecureStoreLike> => {
	if (secureStoreOverride) {
		return secureStoreOverride;
	}

	secureStorePromise ??= loadSecureStore();
	return await secureStorePromise;
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

const normalizeConnectorId = (value: string): string => value.trim();
const normalizeConnectorName = (value: string): string => {
	const trimmed = value.trim();
	return trimmed.length > 0 ? trimmed : "Desktop Connector";
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

const toSavedConnectionKey = (connection: SavedConnection): string =>
	connection.kind === "local"
		? `local:${connection.baseUrl}`
		: `private:${connection.backendUrl}:${connection.connectorId}`;

const normalizeSavedTimestamp = (value: unknown): string =>
	typeof value === "string" && !Number.isNaN(Date.parse(value))
		? value
		: new Date(0).toISOString();

const parseSavedConnection = (item: unknown): SavedConnection | null => {
	if (!item || typeof item !== "object") {
		return null;
	}

	const candidate = item as Record<string, unknown>;
	const kind = typeof candidate.kind === "string" ? candidate.kind : "local";
	const lastConnectedAt = normalizeSavedTimestamp(candidate.lastConnectedAt);

	if (kind === "private") {
		const backendUrl = normalizeBaseUrl(String(candidate.backendUrl ?? ""));
		const connectorId = normalizeConnectorId(String(candidate.connectorId ?? ""));
		if (connectorId.length === 0) {
			return null;
		}

		return {
			backendUrl,
			connectorId,
			connectorName: normalizeConnectorName(String(candidate.connectorName ?? "")),
			kind: "private",
			lastConnectedAt,
		};
	}

	const legacyBaseUrl = normalizeBaseUrl(String(candidate.baseUrl ?? ""));
	return {
		baseUrl: legacyBaseUrl,
		kind: "local",
		lastConnectedAt,
		token: normalizeToken(String(candidate.token ?? "")),
	};
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

		const entries = parsed.map((item) => parseSavedConnection(item)).filter(isSavedConnection);

		const uniqueById = new Map<string, SavedConnection>();
		for (const entry of entries) {
			const key = toSavedConnectionKey(entry);
			const current = uniqueById.get(key);
			if (!current || toTimestamp(entry.lastConnectedAt) > toTimestamp(current.lastConnectedAt)) {
				uniqueById.set(key, entry);
			}
		}

		return Array.from(uniqueById.values())
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
	const secureStore = await getSecureStore();

	if (normalized.length === 0) {
		await secureStore.deleteItemAsync(SAVED_CONNECTIONS_KEY);
		return [];
	}

	await secureStore.setItemAsync(SAVED_CONNECTIONS_KEY, JSON.stringify(normalized));
	return normalized;
};

export const ApiConfigStore = {
	defaultConfig: toApiConfig(defaultLocalTarget),
	async read(): Promise<ApiConfig> {
		const secureStore = await getSecureStore();
		const [baseUrl, token, rawActiveTarget] = await Promise.all([
			secureStore.getItemAsync(BASE_URL_KEY),
			secureStore.getItemAsync(TOKEN_KEY),
			secureStore.getItemAsync(ACTIVE_TARGET_KEY),
		]);

		const activeTarget = parseActiveTarget(rawActiveTarget, {
			baseUrl: baseUrl ?? defaultLocalTarget.baseUrl,
			token: token ?? defaultLocalTarget.token,
		});
		const normalized = toApiConfig(activeTarget);

		await Promise.all([
			secureStore.setItemAsync(BASE_URL_KEY, normalized.baseUrl),
			secureStore.setItemAsync(TOKEN_KEY, normalized.token),
			secureStore.setItemAsync(ACTIVE_TARGET_KEY, JSON.stringify(activeTarget)),
		]);

		return normalized;
	},
	async save(config: ApiConfig): Promise<ApiConfig> {
		const activeTarget = normalizeActiveTarget(config.activeTarget);
		const normalized = toApiConfig(activeTarget);
		const secureStore = await getSecureStore();

		await Promise.all([
			secureStore.setItemAsync(BASE_URL_KEY, normalized.baseUrl),
			secureStore.setItemAsync(TOKEN_KEY, normalized.token),
			secureStore.setItemAsync(ACTIVE_TARGET_KEY, JSON.stringify(activeTarget)),
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
		const secureStore = await getSecureStore();

		await Promise.all([
			secureStore.setItemAsync(`${SERVER_TOKEN_PREFIX}${serverId}`, normalized.token),
			secureStore.setItemAsync(`${SERVER_BASE_URL_PREFIX}${serverId}`, normalized.baseUrl),
			secureStore.setItemAsync(BASE_URL_KEY, normalized.baseUrl),
			secureStore.setItemAsync(TOKEN_KEY, normalized.token),
			secureStore.setItemAsync(ACTIVE_TARGET_KEY, JSON.stringify(activeTarget)),
		]);

		return normalized;
	},
	async readTokenForServer(serverId: string): Promise<string | null> {
		const key = `${SERVER_TOKEN_PREFIX}${serverId}`;
		const secureStore = await getSecureStore();
		const token = await secureStore.getItemAsync(key);
		if (!token) {
			return null;
		}

		const normalized = normalizeToken(token);
		if (token.trim() !== normalized) {
			await secureStore.setItemAsync(key, normalized);
		}
		return normalized.length > 0 ? normalized : null;
	},
	async readBaseUrlForServer(serverId: string): Promise<string | null> {
		const key = `${SERVER_BASE_URL_PREFIX}${serverId}`;
		const secureStore = await getSecureStore();
		const baseUrl = await secureStore.getItemAsync(key);
		if (!baseUrl) {
			return null;
		}

		const normalized = normalizeBaseUrl(baseUrl);
		return normalized.length > 0 ? normalized : null;
	},
	async readSavedConnections(): Promise<SavedConnection[]> {
		const secureStore = await getSecureStore();
		const raw = await secureStore.getItemAsync(SAVED_CONNECTIONS_KEY);
		return parseSavedConnections(raw);
	},
	async saveSavedConnection(input:
		| {
			baseUrl: string;
			kind: "local";
			token: string;
		}
		| {
			backendUrl: string;
			connectorId: string;
			connectorName: string;
			kind: "private";
		}): Promise<SavedConnection[]> {
		const normalizedEntry: SavedConnection = input.kind === "private"
			? {
				backendUrl: normalizeBaseUrl(input.backendUrl),
				connectorId: normalizeConnectorId(input.connectorId),
				connectorName: normalizeConnectorName(input.connectorName),
				kind: "private",
				lastConnectedAt: new Date().toISOString(),
			}
			: {
				baseUrl: normalizeBaseUrl(input.baseUrl),
				kind: "local",
				lastConnectedAt: new Date().toISOString(),
				token: normalizeToken(input.token),
			};

		const current = await this.readSavedConnections();
		const next = [normalizedEntry, ...current.filter((item) => toSavedConnectionKey(item) !== toSavedConnectionKey(normalizedEntry))];
		return await writeSavedConnections(next);
	},
	async deleteSavedConnection(connection: SavedConnection): Promise<SavedConnection[]> {
		const normalizedConnection = connection.kind === "private"
			? {
				backendUrl: normalizeBaseUrl(connection.backendUrl),
				connectorId: normalizeConnectorId(connection.connectorId),
				connectorName: normalizeConnectorName(connection.connectorName),
				kind: "private" as const,
				lastConnectedAt: connection.lastConnectedAt,
			}
			: {
				baseUrl: normalizeBaseUrl(connection.baseUrl),
				kind: "local" as const,
				lastConnectedAt: connection.lastConnectedAt,
				token: normalizeToken(connection.token),
			};
		const current = await this.readSavedConnections();
		const next = current.filter((item) => toSavedConnectionKey(item) !== toSavedConnectionKey(normalizedConnection));
		return await writeSavedConnections(next);
	},
};

export const setSecureStoreAdapterForTests = (adapter: SecureStoreLike) => {
	secureStoreOverride = adapter;
};

export const resetSecureStoreAdapterForTests = () => {
	secureStoreOverride = null;
	secureStorePromise = null;
};
