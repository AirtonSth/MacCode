import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir, hostname } from "node:os";
import { dirname, join } from "node:path";

import { serverConfig } from "../../config";
import type { DiscoveryInfoDTO } from "./server.types";

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

export const getServerDiscoveryInfo = (): DiscoveryInfoDTO => ({
	serverId,
	hostname: hostname(),
	port: serverConfig.port,
	version: resolveVersion(),
	authMode: "token_lan",
	capabilitiesVersion: "2",
});

export const getServerId = (): string => serverId;
