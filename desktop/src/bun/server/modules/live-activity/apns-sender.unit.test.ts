import { describe, test, expect, mock, beforeEach } from "bun:test";

const originalEnv = { ...process.env };

beforeEach(() => {
	process.env = { ...originalEnv };
});

const { loadApnsConfigFromEnvironment } = await import("./apns-sender");

describe("loadApnsConfigFromEnvironment", () => {
	test("returns null when no APNS env vars are set", () => {
		delete process.env.REMOTECODE_LIVE_ACTIVITY_APNS_PRIVATE_KEY_PATH;
		delete process.env.REMOTECODE_LIVE_ACTIVITY_APNS_AUTH_KEY_ID;
		delete process.env.REMOTECODE_LIVE_ACTIVITY_APNS_TEAM_ID;

		const config = loadApnsConfigFromEnvironment();
		expect(config).toBeNull();
	});

	test("returns null when key path is missing", () => {
		process.env.REMOTECODE_LIVE_ACTIVITY_APNS_PRIVATE_KEY_PATH = "";
		process.env.REMOTECODE_LIVE_ACTIVITY_APNS_AUTH_KEY_ID = "KEYID123";
		process.env.REMOTECODE_LIVE_ACTIVITY_APNS_TEAM_ID = "TEAMID456";

		const config = loadApnsConfigFromEnvironment();
		expect(config).toBeNull();
	});

	test("returns config when all required env vars are present", () => {
		process.env.REMOTECODE_LIVE_ACTIVITY_APNS_PRIVATE_KEY_PATH = "/path/to/key.p8";
		process.env.REMOTECODE_LIVE_ACTIVITY_APNS_AUTH_KEY_ID = "KEYID123";
		process.env.REMOTECODE_LIVE_ACTIVITY_APNS_TEAM_ID = "TEAMID456";
		process.env.REMOTECODE_LIVE_ACTIVITY_APNS_USE_SANDBOX = "true";

		const config = loadApnsConfigFromEnvironment();
		expect(config).toEqual({
			authKeyPath: "/path/to/key.p8",
			keyId: "KEYID123",
			teamId: "TEAMID456",
			bundleId: "io.remotecode",
			useSandbox: true,
		});
	});

	test("defaults bundleId to io.remotecode", () => {
		process.env.REMOTECODE_LIVE_ACTIVITY_APNS_PRIVATE_KEY_PATH = "/path/to/key.p8";
		process.env.REMOTECODE_LIVE_ACTIVITY_APNS_AUTH_KEY_ID = "KEYID123";
		process.env.REMOTECODE_LIVE_ACTIVITY_APNS_TEAM_ID = "TEAMID456";
		delete process.env.REMOTECODE_LIVE_ACTIVITY_APNS_BUNDLE_ID;

		const config = loadApnsConfigFromEnvironment();
		expect(config?.bundleId).toBe("io.remotecode");
	});

	test("defaults useSandbox to false", () => {
		process.env.REMOTECODE_LIVE_ACTIVITY_APNS_PRIVATE_KEY_PATH = "/path/to/key.p8";
		process.env.REMOTECODE_LIVE_ACTIVITY_APNS_AUTH_KEY_ID = "KEYID123";
		process.env.REMOTECODE_LIVE_ACTIVITY_APNS_TEAM_ID = "TEAMID456";
		delete process.env.REMOTECODE_LIVE_ACTIVITY_APNS_USE_SANDBOX;

		const config = loadApnsConfigFromEnvironment();
		expect(config?.useSandbox).toBe(false);
	});
});
