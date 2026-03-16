import { afterEach, expect, test } from "bun:test";

import { ServerConfig } from "./config";

const CONFIG_ENV_KEYS = [
	"REMOTECODE_PRIVATE_BACKEND_URL",
	"NODE_ENV",
] as const;

const originalEnv = new Map<string, string | undefined>(
	CONFIG_ENV_KEYS.map((key) => [key, process.env[key]]),
);

const clearConfigEnv = (): void => {
	for (const key of CONFIG_ENV_KEYS) {
		delete process.env[key];
	}
};

afterEach(() => {
	clearConfigEnv();
	for (const key of CONFIG_ENV_KEYS) {
		const previous = originalEnv.get(key);
		if (previous === undefined) {
			delete process.env[key];
			continue;
		}
		process.env[key] = previous;
	}
});

test("ServerConfig.load uses a private backend URL override when configured", () => {
	clearConfigEnv();
	process.env.REMOTECODE_PRIVATE_BACKEND_URL = "https://private.remotecode.io:8787/";

	const config = ServerConfig.load();

	expect(config.privateBackendUrl).toBe("https://private.remotecode.io:8787");
});

test("ServerConfig.load falls back to the release private backend URL outside production", () => {
	clearConfigEnv();

	const config = ServerConfig.load();

	expect(config.privateBackendUrl).toBe("https://private.remotecode.io:8787");
});

test("ServerConfig.load falls back to the release private backend URL in production", () => {
	clearConfigEnv();
	process.env.NODE_ENV = "production";

	const config = ServerConfig.load();

	expect(config.privateBackendUrl).toBe("https://private.remotecode.io:8787");
});
