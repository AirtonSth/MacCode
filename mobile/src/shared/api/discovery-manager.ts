import * as Network from "expo-network";

import type { DiscoveryInfoDTO } from "./types";
import { ApiConfigStore, type LocalSavedConnection, type SavedConnection } from "./api-config-store";

export interface DiscoveredServer extends DiscoveryInfoDTO {
	baseUrl: string;
	lastSeenAt: string;
}

const normalizeToken = (value: string): string => {
	const trimmed = value.trim();
	const isEmpty = trimmed.length === 0;
	const isLegacyDefault = trimmed === "local-dev-token";
	return isEmpty || isLegacyDefault ? "remotecode.io-token" : trimmed;
};

const DISCOVERY_PORT = 8835;
const DISCOVERY_PATH = "/v1/discovery";
const DEFAULT_TIMEOUT_MS = 1_200;
const DEFAULT_CONCURRENCY = 24;
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

interface SavedProbeTarget {
	connection: LocalSavedConnection;
	host: string;
}

interface SavedProbeResult {
	connection: LocalSavedConnection;
	host: string;
	server: DiscoveredServer | null;
}

const isPrivateOrVpnIPv4 = (host: string): boolean => {
	const parts = host.split(".");
	if (parts.length !== 4) {
		return false;
	}

	const numbers = parts.map((part) => Number.parseInt(part, 10));
	if (numbers.some((part) => Number.isNaN(part) || part < 0 || part > 255)) {
		return false;
	}

	return (
		numbers[0] === 10 ||
		numbers[0] === 127 ||
		(numbers[0] === 169 && numbers[1] === 254) ||
		(numbers[0] === 172 && numbers[1] >= 16 && numbers[1] <= 31) ||
		(numbers[0] === 192 && numbers[1] === 168) ||
		(numbers[0] === 100 && numbers[1] >= 64 && numbers[1] <= 127)
	);
};

const isSavedProbeHost = (host: string): boolean => {
	const normalized = host.trim().toLowerCase();
	if (normalized.length === 0) {
		return false;
	}

	if (
		normalized === "localhost" ||
		normalized === "::1" ||
		normalized.endsWith(".local") ||
		normalized.endsWith(".lan") ||
		normalized.endsWith(".home") ||
		normalized.startsWith("fe80:") ||
		normalized.startsWith("fc") ||
		normalized.startsWith("fd")
	) {
		return true;
	}

	return isPrivateOrVpnIPv4(normalized);
};

const toStringArray = (value: unknown): string[] => {
	if (!Array.isArray(value)) {
		return [];
	}

	return value
		.map((item) => (typeof item === "string" ? item.trim() : ""))
		.filter((item) => item.length > 0);
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

const resolveCandidateHosts = async (input: {
	activeBaseUrl: string;
	recent: DiscoveredServer[];
	savedConnections: SavedConnection[];
}): Promise<string[]> => {
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

	for (const item of input.recent) {
		pushUniqueHost(hosts, seen, parseHostFromBaseUrl(item.baseUrl));
		pushUniqueHost(hosts, seen, item.hostname);

		for (const hintAddress of toStringArray(item.connectHints?.addresses)) {
			pushUniqueHost(hosts, seen, hintAddress);
		}
		for (const hintAddress of toStringArray(item.connectHints?.tailscaleAddresses)) {
			pushUniqueHost(hosts, seen, hintAddress);
		}
		for (const hintBaseUrl of toStringArray(item.connectHints?.recommendedBaseUrls)) {
			pushUniqueHost(hosts, seen, parseHostFromBaseUrl(hintBaseUrl));
		}
	}

	for (const item of input.savedConnections) {
		if (item.kind !== "local") {
			continue;
		}
		pushUniqueHost(hosts, seen, parseHostFromBaseUrl(item.baseUrl));
	}
	pushUniqueHost(hosts, seen, parseHostFromBaseUrl(input.activeBaseUrl));

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
		recentCount: input.recent.length,
		savedConnectionCount: input.savedConnections.length,
	});
	return hosts;
};

const toSavedProbeTargets = (savedConnections: SavedConnection[]): SavedProbeTarget[] => {
	const targets: SavedProbeTarget[] = [];
	const seen = new Set<string>();
	for (const connection of savedConnections) {
		if (connection.kind !== "local") {
			continue;
		}
		const host = parseHostFromBaseUrl(connection.baseUrl);
		if (!host) {
			continue;
		}

		if (!isSavedProbeHost(host)) {
			continue;
		}

		const dedupeKey = host.trim().toLowerCase();
		if (seen.has(dedupeKey)) {
			continue;
		}

		seen.add(dedupeKey);
		targets.push({
			connection,
			host,
		});
	}

	return targets;
};

const probeSavedConnections = async (
	targets: SavedProbeTarget[],
	timeoutMs: number,
): Promise<SavedProbeResult[]> =>
	await Promise.all(
		targets.map(async (target) => ({
			connection: target.connection,
			host: target.host,
			server: await probeServer(target.host, timeoutMs, normalizeToken(target.connection.token)),
		})),
	);

export const DiscoveryManager = {
	async readRecent(): Promise<DiscoveredServer[]> {
		return [];
	},

	async scan(input?: { concurrency?: number; timeoutMs?: number; token?: string }): Promise<DiscoveredServer[]> {
		const timeoutMs = input?.timeoutMs ?? DEFAULT_TIMEOUT_MS;
		const concurrency = input?.concurrency ?? DEFAULT_CONCURRENCY;
		const config = await ApiConfigStore.read();
		const savedConnections = await ApiConfigStore.readSavedConnections();
		const token = normalizeToken(input?.token ?? config.token);
		log("scan start", { timeoutMs, concurrency });

		const savedProbeTargets = toSavedProbeTargets(savedConnections);
		log("scan saved targets", { count: savedProbeTargets.length });
		const savedProbeResults = await probeSavedConnections(savedProbeTargets, timeoutMs);
		const savedOnline = savedProbeResults
			.filter((result) => Boolean(result.server))
			.map((result) => result.server!);
		const savedOfflineBaseUrls = savedProbeResults
			.filter((result) => !result.server)
			.map((result) => result.connection.baseUrl);
		log("scan saved results", {
			onlineCount: savedOnline.length,
			offlineCount: savedOfflineBaseUrls.length,
		});

		const candidateHosts = await resolveCandidateHosts({
			activeBaseUrl: config.baseUrl,
			recent: savedOnline,
			savedConnections,
		});
		const savedProbedHosts = new Set(savedProbeTargets.map((item) => item.host.trim().toLowerCase()));
		const hostsToScan = candidateHosts.filter((host) => !savedProbedHosts.has(host.trim().toLowerCase()));
		log("scan start candidates", {
			candidateCount: hostsToScan.length,
			recentCount: savedOnline.length,
		});

		const scanned = await runLimited(
			hostsToScan,
			async (host) => await probeServer(host, timeoutMs, token),
			concurrency,
		);
		log("scan results", { scannedCount: scanned.length });

		const merged = dedupeServers([...savedOnline, ...scanned]);
		log("scan merged", { mergedCount: merged.length });
		return merged;
	},
};
