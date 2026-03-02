import * as Network from "expo-network";
import * as SecureStore from "expo-secure-store";

import type { DiscoveryInfoDTO } from "./types";
import { ApiConfigStore } from "./api-config-store";

export interface DiscoveredServer extends DiscoveryInfoDTO {
	baseUrl: string;
	lastSeenAt: string;
}

interface DiscoveryCacheRecord {
	items: DiscoveredServer[];
}

const normalizeToken = (value: string): string => {
	const trimmed = value.trim();
	const isEmpty = trimmed.length === 0;
	const isLegacyDefault = trimmed === "local-dev-token";
	return isEmpty || isLegacyDefault ? "remotecode.io-token" : trimmed;
};

const DISCOVERY_PORT = 8835;
const DISCOVERY_PATH = "/v1/discovery";
const CACHE_KEY = "remotecode.discovery.cache";
const DEFAULT_TIMEOUT_MS = 500;
const DEFAULT_CONCURRENCY = 24;
const MAX_CACHE_ITEMS = 32;
const LOG_PREFIX = "[LAN_DISCOVERY]";

const log = (...args: unknown[]) => {
	if (__DEV__) {
		console.log(LOG_PREFIX, ...args);
	}
};

const normalizeBaseUrl = (host: string): string => `http://${host}:${DISCOVERY_PORT}`;

const parseHostFromBaseUrl = (baseUrl: string): string | null => {
	const trimmed = baseUrl.trim();
	if (trimmed.length === 0) {
		return null;
	}

	const withoutProtocol = trimmed.includes("://") ? trimmed.split("://", 2)[1] : trimmed;
	const withoutPath = withoutProtocol.split(/[/?#]/u, 1)[0] ?? "";
	if (withoutPath.length === 0) {
		return null;
	}

	const atIndex = withoutPath.lastIndexOf("@");
	const hostPort = atIndex !== -1 ? withoutPath.slice(atIndex + 1) : withoutPath;
	if (hostPort.startsWith("[")) {
		const closingIndex = hostPort.indexOf("]");
		if (closingIndex > 1) {
			return hostPort.slice(1, closingIndex).trim();
		}
		return null;
	}

	const host = hostPort.split(":", 1)[0];
	const normalized = host.trim();
	return normalized.length > 0 ? normalized : null;
};

const parseJson = (input: string | null): unknown => {
	if (!input) {
		return null;
	}

	try {
		return JSON.parse(input) as unknown;
	} catch {
		return null;
	}
};

const isDiscoveryInfo = (value: unknown): value is DiscoveryInfoDTO => {
	if (!value || typeof value !== "object") {
		return false;
	}

	const candidate = value as Record<string, unknown>;
	return (
		typeof candidate.serverId === "string" &&
		typeof candidate.hostname === "string" &&
		typeof candidate.port === "number" &&
		typeof candidate.version === "string" &&
		typeof candidate.authMode === "string" &&
		typeof candidate.capabilitiesVersion === "string"
	);
};

const toSubnetPrefix = (ipAddress: string): string | null => {
	const parts = ipAddress.trim().split(".");
	if (parts.length !== 4) {
		return null;
	}

	const numbers = parts.map((part) => Number.parseInt(part, 10));
	if (numbers.some((value) => Number.isNaN(value) || value < 0 || value > 255)) {
		return null;
	}

	return `${numbers[0]}.${numbers[1]}.${numbers[2]}`;
};

const toScanHosts = (subnetPrefix: string): string[] => {
	const hosts: string[] = [];
	for (let host = 1; host <= 254; host += 1) {
		hosts.push(`${subnetPrefix}.${host}`);
	}

	return hosts;
};

const dedupeServers = (input: DiscoveredServer[]): DiscoveredServer[] => {
	const byServerId = new Map<string, DiscoveredServer>();
	for (const item of input) {
		const current = byServerId.get(item.serverId);
		if (!current) {
			byServerId.set(item.serverId, item);
			continue;
		}

		if (new Date(item.lastSeenAt).getTime() >= new Date(current.lastSeenAt).getTime()) {
			byServerId.set(item.serverId, item);
		}
	}

	return Array.from(byServerId.values()).sort((left, right) =>
		right.lastSeenAt.localeCompare(left.lastSeenAt),
	);
};

const resolveDiscovery = async (host: string, timeoutMs: number, token?: string): Promise<Response | null> => {
	const baseUrl = normalizeBaseUrl(host);
	const headers: Record<string, string> = {};
	if (token) {
		headers.authorization = `Bearer ${token}`;
	}

	const controller = new AbortController();
	const timeoutId = setTimeout(() => {
		controller.abort();
	}, timeoutMs);

	try {
		const response = await fetch(`${baseUrl}${DISCOVERY_PATH}`, {
			method: "GET",
			headers,
			signal: controller.signal,
		});
		if (!response.ok) {
			return response;
		}

		return response;
	} catch (error) {
		log("probe request error", baseUrl, error instanceof Error ? error.message : "unknown");
		return null;
	} finally {
		clearTimeout(timeoutId);
	}
};

const readResponseText = async (response: Response): Promise<string> => {
	try {
		return await response.text();
	} catch {
		return "";
	}
};

const parseDiscoveryResponse = async (baseUrl: string, response: Response): Promise<DiscoveredServer | null> => {
	const payload = (await response.json()) as unknown;
	if (!isDiscoveryInfo(payload)) {
		log("probe invalid payload", baseUrl);
		return null;
	}

	return {
		...payload,
		baseUrl,
		lastSeenAt: new Date().toISOString(),
	};
};

const probeServer = async (
	host: string,
	timeoutMs: number,
	token?: string,
): Promise<DiscoveredServer | null> => {
	const baseUrl = normalizeBaseUrl(host);
	log("probe start", baseUrl);

	const firstAttempt = await resolveDiscovery(host, timeoutMs);
	if (firstAttempt?.ok) {
		log("probe success", baseUrl);
		return await parseDiscoveryResponse(baseUrl, firstAttempt);
	}

	if (token && firstAttempt) {
		log("probe non-ok", baseUrl, firstAttempt.status, "retrying with token");
		const secondAttempt = await resolveDiscovery(host, timeoutMs, token);
		if (!secondAttempt) {
			return null;
		}
		if (!secondAttempt.ok) {
			const body = await readResponseText(secondAttempt);
			log("probe non-ok", baseUrl, secondAttempt.status, body || "no-body");
			return null;
		}

		log("probe success", baseUrl);
		return await parseDiscoveryResponse(baseUrl, secondAttempt);
	}

	if (firstAttempt) {
		const body = await readResponseText(firstAttempt);
		log("probe non-ok", baseUrl, firstAttempt.status, body || "no-body");
	}

	return null;
};

const runLimited = async <T>(
	items: string[],
	worker: (value: string) => Promise<T | null>,
	concurrency: number,
): Promise<T[]> => {
	const results: T[] = [];
	let cursor = 0;
	const runnerCount = Math.max(1, concurrency);

	const runNext = async (): Promise<void> => {
		const index = cursor;
		cursor += 1;
		if (index >= items.length) {
			return;
		}

		try {
			const result = await worker(items[index]);
			if (result) {
				results.push(result);
			}
		} catch {
			// Ignore non-responsive hosts
		}
		await runNext();
	};

	const runners = Array.from({ length: runnerCount }, async () => {
		await runNext();
	});

	await Promise.all(runners);
	log("scan workers done", {
		totalItems: items.length,
		completed: results.length,
		runners: runnerCount,
	});
	return results;
};

const readCache = async (): Promise<DiscoveredServer[]> => {
	const raw = await SecureStore.getItemAsync(CACHE_KEY);
	const parsed = parseJson(raw) as DiscoveryCacheRecord | null;
	if (!parsed || !Array.isArray(parsed.items)) {
		return [];
	}

	return parsed.items.filter((item) => isDiscoveryInfo(item)).map((item) => ({
		...item,
		baseUrl: typeof item.baseUrl === "string" ? item.baseUrl : normalizeBaseUrl(item.hostname),
		lastSeenAt: typeof item.lastSeenAt === "string" ? item.lastSeenAt : new Date(0).toISOString(),
	}));
};

const writeCache = async (items: DiscoveredServer[]): Promise<void> => {
	const payload: DiscoveryCacheRecord = {
		items: items.slice(0, MAX_CACHE_ITEMS),
	};

	await SecureStore.setItemAsync(CACHE_KEY, JSON.stringify(payload));
};

const pushUniqueHost = (hosts: string[], seen: Set<string>, host: string | null | undefined): void => {
	const normalized = host?.trim();
	if (!normalized || normalized.length === 0) {
		return;
	}

	if (seen.has(normalized)) {
		return;
	}

	seen.add(normalized);
	hosts.push(normalized);
};

const resolveCandidateHosts = async (recent: DiscoveredServer[]): Promise<string[]> => {
	let ip = "";
	try {
		ip = await Network.getIpAddressAsync();
		log("getIpAddressAsync success", ip);
	} catch {
		ip = "";
		log("getIpAddressAsync error");
	}

	const hosts: string[] = [];
	const seen = new Set<string>();

	for (const item of recent) {
		pushUniqueHost(hosts, seen, parseHostFromBaseUrl(item.baseUrl));
	}

	pushUniqueHost(hosts, seen, ip);
	pushUniqueHost(hosts, seen, "127.0.0.1");
	pushUniqueHost(hosts, seen, "localhost");

	const prefix = toSubnetPrefix(ip);
	if (prefix) {
		log("scan subnet prefix", prefix);
		for (const host of toScanHosts(prefix)) {
			pushUniqueHost(hosts, seen, host);
		}
	} else {
		log("scan subnet prefix unavailable", ip);
	}

	log("scan candidates prepared", {
		count: hosts.length,
		recentCount: recent.length,
	});
	return hosts;
};

export const DiscoveryManager = {
	async readRecent(): Promise<DiscoveredServer[]> {
		const recent = await readCache();
		log("cache read", { count: recent.length });
		return recent;
	},

	async scan(input?: { concurrency?: number; timeoutMs?: number; token?: string }): Promise<DiscoveredServer[]> {
		const timeoutMs = input?.timeoutMs ?? DEFAULT_TIMEOUT_MS;
		const concurrency = input?.concurrency ?? DEFAULT_CONCURRENCY;
		const config = await ApiConfigStore.read();
		const token = normalizeToken(input?.token ?? config.token);
		log("scan start", { timeoutMs, concurrency });
		const recent = await readCache();
		const candidateHosts = await resolveCandidateHosts(recent);
		log("scan start candidates", {
			candidateCount: candidateHosts.length,
			recentCount: recent.length,
		});

		const scanned = await runLimited(
			candidateHosts,
			async (host) => await probeServer(host, timeoutMs, token),
			concurrency,
		);
		log("scan results", { scannedCount: scanned.length });

		const merged = dedupeServers([...scanned, ...recent]);
		log("scan merged", { mergedCount: merged.length });
		await writeCache(merged);
		return merged;
	},
};
