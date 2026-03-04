import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir, hostname, networkInterfaces } from "node:os";
import { dirname, join } from "node:path";

import { serverConfig } from "../../config";
import type { DiscoveryConnectHintsDTO, DiscoveryInfoDTO } from "./server.types";

const requireModule = createRequire(import.meta.url);
const SERVER_ID_FILE_NAME = "server-id";

const resolveUserDataPath = (): string => {
	const configuredUserDataPath = process.env.REMOTECODE_USER_DATA_PATH?.trim();
	if (configuredUserDataPath) {
		return configuredUserDataPath;
	}

	try {
		const electrobun = requireModule("electrobun/bun") as {
			Utils?: {
				paths?: {
					userData?: string;
				};
			};
		};

		const electrobunUserDataPath = electrobun.Utils?.paths?.userData?.trim();
		if (electrobunUserDataPath) {
			return electrobunUserDataPath;
		}
	} catch {
		// Fallback below
	}

	return join(homedir(), ".remotecode");
};

const resolveServerIdFilePath = (): string => {
	const configuredPath = process.env.REMOTECODE_SERVER_ID_PATH?.trim();
	if (configuredPath) {
		return configuredPath;
	}

	return join(resolveUserDataPath(), "remotecode-server", SERVER_ID_FILE_NAME);
};

const readPersistedServerId = (): string | null => {
	const filePath = resolveServerIdFilePath();
	if (!existsSync(filePath)) {
		return null;
	}

	try {
		const value = readFileSync(filePath, "utf8").trim();
		return value.length > 0 ? value : null;
	} catch {
		return null;
	}
};

const persistServerId = (value: string): void => {
	const filePath = resolveServerIdFilePath();
	mkdirSync(dirname(filePath), { recursive: true });
	writeFileSync(filePath, `${value}\n`, "utf8");
};

const resolveVersion = (): string => {
	const configuredVersion = process.env.REMOTECODE_SERVER_VERSION?.trim();
	if (configuredVersion) {
		return configuredVersion;
	}

	return "1.0.0";
};

const resolveServerId = (): string => {
	const configuredId = process.env.REMOTECODE_SERVER_ID?.trim();
	if (configuredId) {
		return configuredId;
	}

	const persisted = readPersistedServerId();
	if (persisted) {
		return persisted;
	}

	const created = randomUUID();
	persistServerId(created);
	return created;
};

const serverId = resolveServerId();

const normalizeAddress = (address: string): string => {
	const trimmed = address.trim();
	const zoneIndex = trimmed.indexOf("%");
	return zoneIndex >= 0 ? trimmed.slice(0, zoneIndex) : trimmed;
};

const isTailscaleIPv4 = (address: string): boolean => {
	const parts = address.split(".");
	if (parts.length !== 4) {
		return false;
	}

	const numbers = parts.map((part) => Number.parseInt(part, 10));
	if (numbers.some((value) => Number.isNaN(value) || value < 0 || value > 255)) {
		return false;
	}

	return numbers[0] === 100 && numbers[1] >= 64 && numbers[1] <= 127;
};

const isTailscaleIPv6 = (address: string): boolean => {
	return address.toLowerCase().startsWith("fd7a:115c:a1e0:");
};

const isTailscaleAddress = (address: string): boolean => {
	if (address.includes(":")) {
		return isTailscaleIPv6(address);
	}

	return isTailscaleIPv4(address);
};

const toBaseUrl = (address: string, port: number): string => {
	if (address.includes(":")) {
		return `http://[${address}]:${String(port)}`;
	}

	return `http://${address}:${String(port)}`;
};

const resolveInterfaceAddresses = (): string[] => {
	const addresses = new Set<string>();
	const interfaces = networkInterfaces();

	for (const entries of Object.values(interfaces)) {
		if (!entries) {
			continue;
		}

		for (const entry of entries) {
			const family = String(entry.family);
			if (family !== "IPv4" && family !== "IPv6" && family !== "4" && family !== "6") {
				continue;
			}

			if (entry.internal) {
				continue;
			}

			const normalized = normalizeAddress(entry.address ?? "");
			if (!normalized || normalized === "127.0.0.1" || normalized === "::1") {
				continue;
			}

			addresses.add(normalized);
		}
	}

	return Array.from(addresses).sort((left, right) => left.localeCompare(right));
};

export const getServerConnectHints = (port: number): DiscoveryConnectHintsDTO => {
	const addresses = resolveInterfaceAddresses();
	const tailscaleAddresses = addresses.filter((address) => isTailscaleAddress(address));
	const recommendedBaseUrls = addresses.map((address) => toBaseUrl(address, port));

	return {
		addresses,
		recommendedBaseUrls,
		tailscaleAddresses,
	};
};

export const getServerDiscoveryInfo = (): DiscoveryInfoDTO => ({
	serverId,
	hostname: hostname(),
	port: serverConfig.port,
	version: resolveVersion(),
	authMode: "token_lan",
	capabilitiesVersion: "2",
});

export const getServerId = (): string => serverId;
