import * as Network from "expo-network";
import * as SecureStore from "expo-secure-store";

import type { DiscoveryInfoDTO } from "./types";

export interface DiscoveredServer extends DiscoveryInfoDTO {
	baseUrl: string;
	lastSeenAt: string;
}

interface DiscoveryCacheRecord {
	items: DiscoveredServer[];
}

const DISCOVERY_PORT = 8835;
const DISCOVERY_PATH = "/v1/discovery";
const CACHE_KEY = "remotecode.discovery.cache";
const DEFAULT_TIMEOUT_MS = 500;
const DEFAULT_CONCURRENCY = 24;
const MAX_CACHE_ITEMS = 32;

const normalizeBaseUrl = (host: string): string => `http://${host}:${DISCOVERY_PORT}`;

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

const toScanHosts = (subnetPrefix: string, localHost?: string): string[] => {
	const hosts: string[] = [];
	for (let host = 1; host <= 254; host += 1) {
		const candidate = `${subnetPrefix}.${host}`;
		if (candidate === localHost) {
			continue;
		}

		hosts.push(candidate);
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

const probeServer = async (host: string, timeoutMs: number): Promise<DiscoveredServer | null> => {
	const baseUrl = normalizeBaseUrl(host);
	const controller = new AbortController();
	const timeoutId = setTimeout(() => {
		controller.abort();
	}, timeoutMs);

	try {
		const response = await fetch(`${baseUrl}${DISCOVERY_PATH}`, {
			method: "GET",
			signal: controller.signal,
		});
		if (!response.ok) {
			return null;
		}

		const payload = (await response.json()) as unknown;
		if (!isDiscoveryInfo(payload)) {
			return null;
		}

		return {
			...payload,
			baseUrl,
			lastSeenAt: new Date().toISOString(),
		};
	} catch {
		return null;
	} finally {
		clearTimeout(timeoutId);
	}
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

const resolveCandidateHosts = async (): Promise<string[]> => {
	let ip = "";
	try {
		ip = await Network.getIpAddressAsync();
	} catch {
		ip = "";
	}

	const prefix = toSubnetPrefix(ip);
	if (prefix) {
		return toScanHosts(prefix, ip);
	}

	return [];
};

export const DiscoveryManager = {
	async readRecent(): Promise<DiscoveredServer[]> {
		return await readCache();
	},

	async scan(input?: { concurrency?: number; timeoutMs?: number }): Promise<DiscoveredServer[]> {
		const timeoutMs = input?.timeoutMs ?? DEFAULT_TIMEOUT_MS;
		const concurrency = input?.concurrency ?? DEFAULT_CONCURRENCY;
		const recent = await readCache();
		const candidateHosts = await resolveCandidateHosts();

		const scanned = await runLimited(
			candidateHosts,
			async (host) => await probeServer(host, timeoutMs),
			concurrency,
		);

		const merged = dedupeServers([...scanned, ...recent]);
		await writeCache(merged);
		return merged;
	},
};
