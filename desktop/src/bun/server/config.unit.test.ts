import { afterEach, expect, test } from "bun:test";

import { ServerConfig } from "./config";

const LIVE_ACTIVITY_ENV_KEYS = [
	"REMOTECODE_LIVE_ACTIVITY_APNS_AUTH_KEY_ID",
	"REMOTECODE_LIVE_ACTIVITY_APNS_PRIVATE_KEY_PATH",
	"REMOTECODE_LIVE_ACTIVITY_APNS_TEAM_ID",
	"REMOTECODE_LIVE_ACTIVITY_APNS_USE_SANDBOX",
	"REMOTECODE_LIVE_ACTIVITY_BUNDLE_IDENTIFIER",
	"REMOTECODE_LIVE_ACTIVITY_BUNDLE_ID",
	"REMOTECODE_LIVE_ACTIVITY_FIREBASE_PROJECT_ID",
	"REMOTECODE_FIREBASE_PROJECT_ID",
	"REMOTECODE_LIVE_ACTIVITY_SERVICE_ACCOUNT_PATH",
	"REMOTECODE_FIREBASE_SERVICE_ACCOUNT_PATH",
	"REMOTECODE_PRIVATE_BACKEND_URL",
	"NODE_ENV",
] as const;

const originalEnv = new Map<string, string | undefined>(
	LIVE_ACTIVITY_ENV_KEYS.map((key) => [key, process.env[key]]),
);

const clearLiveActivityEnv = (): void => {
	for (const key of LIVE_ACTIVITY_ENV_KEYS) {
		delete process.env[key];
	}
};

afterEach(() => {
	clearLiveActivityEnv();
	for (const key of LIVE_ACTIVITY_ENV_KEYS) {
		const previous = originalEnv.get(key);
		if (previous === undefined) {
			delete process.env[key];
			continue;
		}
		process.env[key] = previous;
	}
});

test("ServerConfig.load accepts legacy live activity environment variable names", () => {
	clearLiveActivityEnv();
	process.env.REMOTECODE_LIVE_ACTIVITY_BUNDLE_ID = "io.remotecode";
	process.env.REMOTECODE_FIREBASE_PROJECT_ID = "remotecode-io";
	process.env.REMOTECODE_FIREBASE_SERVICE_ACCOUNT_PATH = "/tmp/service-account.json";

	const config = ServerConfig.load();

	expect(config.liveActivityBundleIdentifier).toBe("io.remotecode");
	expect(config.liveActivityFirebaseProjectId).toBe("remotecode-io");
	expect(config.liveActivityServiceAccountPath).toBe("/tmp/service-account.json");
	expect(config.liveActivityApnsUseSandbox).toBe(false);
});

test("ServerConfig.load prioritizes explicit live activity environment variable names", () => {
	clearLiveActivityEnv();
	process.env.REMOTECODE_LIVE_ACTIVITY_BUNDLE_ID = "io.legacy.bundle";
	process.env.REMOTECODE_LIVE_ACTIVITY_BUNDLE_IDENTIFIER = "io.new.bundle";
	process.env.REMOTECODE_FIREBASE_PROJECT_ID = "legacy-project";
	process.env.REMOTECODE_LIVE_ACTIVITY_FIREBASE_PROJECT_ID = "new-project";
	process.env.REMOTECODE_FIREBASE_SERVICE_ACCOUNT_PATH = "/tmp/legacy.json";
	process.env.REMOTECODE_LIVE_ACTIVITY_SERVICE_ACCOUNT_PATH = "/tmp/new.json";

	const config = ServerConfig.load();

	expect(config.liveActivityBundleIdentifier).toBe("io.new.bundle");
	expect(config.liveActivityFirebaseProjectId).toBe("new-project");
	expect(config.liveActivityServiceAccountPath).toBe("/tmp/new.json");
});

test("ServerConfig.load falls back to legacy live activity environment variables when explicit values are blank", () => {
	clearLiveActivityEnv();
	process.env.REMOTECODE_LIVE_ACTIVITY_BUNDLE_ID = "io.legacy.bundle";
	process.env.REMOTECODE_LIVE_ACTIVITY_BUNDLE_IDENTIFIER = "   ";
	process.env.REMOTECODE_FIREBASE_PROJECT_ID = "legacy-project";
	process.env.REMOTECODE_LIVE_ACTIVITY_FIREBASE_PROJECT_ID = "   ";
	process.env.REMOTECODE_FIREBASE_SERVICE_ACCOUNT_PATH = "/tmp/legacy.json";
	process.env.REMOTECODE_LIVE_ACTIVITY_SERVICE_ACCOUNT_PATH = "   ";

	const config = ServerConfig.load();

	expect(config.liveActivityBundleIdentifier).toBe("io.legacy.bundle");
	expect(config.liveActivityFirebaseProjectId).toBe("legacy-project");
	expect(config.liveActivityServiceAccountPath).toBe("/tmp/legacy.json");
});

test("ServerConfig.load parses apns live activity environment values", () => {
	clearLiveActivityEnv();
	process.env.REMOTECODE_LIVE_ACTIVITY_APNS_AUTH_KEY_ID = "ABCD1234";
	process.env.REMOTECODE_LIVE_ACTIVITY_APNS_TEAM_ID = "TEAM1234";
	process.env.REMOTECODE_LIVE_ACTIVITY_APNS_PRIVATE_KEY_PATH = "/tmp/AuthKey_ABCD1234.p8";
	process.env.REMOTECODE_LIVE_ACTIVITY_APNS_USE_SANDBOX = "true";

	const config = ServerConfig.load();

	expect(config.liveActivityApnsAuthKeyId).toBe("ABCD1234");
	expect(config.liveActivityApnsTeamId).toBe("TEAM1234");
	expect(config.liveActivityApnsPrivateKeyPath).toBe("/tmp/AuthKey_ABCD1234.p8");
	expect(config.liveActivityApnsUseSandbox).toBe(true);
});

test("ServerConfig.load uses a private backend URL override when configured", () => {
	clearLiveActivityEnv();
	process.env.REMOTECODE_PRIVATE_BACKEND_URL = "https://private.remotecode.io:8787/";

	const config = ServerConfig.load();

	expect(config.privateBackendUrl).toBe("https://private.remotecode.io:8787");
});

test("ServerConfig.load falls back to the development private backend URL outside production", () => {
	clearLiveActivityEnv();

	const config = ServerConfig.load();

	expect(config.privateBackendUrl).toBe("http://127.0.0.1:8787");
});

test("ServerConfig.load falls back to the release private backend URL in production", () => {
	clearLiveActivityEnv();
	process.env.NODE_ENV = "production";

	const config = ServerConfig.load();

	expect(config.privateBackendUrl).toBe("https://private.remotecode.io:8787");
});
