const DEFAULT_PORT = 8835;
const DEFAULT_TOKEN = "remotecode.io-token";

export interface ServerConfigValues {
	liveActivityApnsAuthKeyId?: string;
	liveActivityApnsPrivateKeyPath?: string;
	liveActivityApnsTeamId?: string;
	liveActivityApnsUseSandbox: boolean;
	databasePath?: string;
	host: string;
	liveActivityBundleIdentifier?: string;
	liveActivityFirebaseProjectId?: string;
	liveActivityServiceAccountPath?: string;
	port: number;
	token: string;
}

export class ServerConfig {
	static load(): ServerConfigValues {
		return {
			databasePath: process.env.REMOTECODE_DB_PATH,
			host: ServerConfig.parseHost(process.env.REMOTECODE_SERVER_HOST),
			liveActivityApnsAuthKeyId: ServerConfig.parseOptional(
				process.env.REMOTECODE_LIVE_ACTIVITY_APNS_AUTH_KEY_ID,
			),
			liveActivityApnsPrivateKeyPath: ServerConfig.parseOptional(
				process.env.REMOTECODE_LIVE_ACTIVITY_APNS_PRIVATE_KEY_PATH,
			),
			liveActivityApnsTeamId: ServerConfig.parseOptional(
				process.env.REMOTECODE_LIVE_ACTIVITY_APNS_TEAM_ID,
			),
			liveActivityApnsUseSandbox: ServerConfig.parseBoolean(
				process.env.REMOTECODE_LIVE_ACTIVITY_APNS_USE_SANDBOX,
			),
			liveActivityBundleIdentifier: ServerConfig.parseOptionalWithFallback(
				process.env.REMOTECODE_LIVE_ACTIVITY_BUNDLE_IDENTIFIER,
				process.env.REMOTECODE_LIVE_ACTIVITY_BUNDLE_ID,
			),
			liveActivityFirebaseProjectId: ServerConfig.parseOptionalWithFallback(
				process.env.REMOTECODE_LIVE_ACTIVITY_FIREBASE_PROJECT_ID,
				process.env.REMOTECODE_FIREBASE_PROJECT_ID,
			),
			liveActivityServiceAccountPath: ServerConfig.parseOptionalWithFallback(
				process.env.REMOTECODE_LIVE_ACTIVITY_SERVICE_ACCOUNT_PATH,
				process.env.REMOTECODE_FIREBASE_SERVICE_ACCOUNT_PATH,
			),
			port: ServerConfig.parsePort(process.env.REMOTECODE_SERVER_PORT),
			token: process.env.REMOTECODE_LOCAL_TOKEN?.trim() || DEFAULT_TOKEN,
		};
	}

	private static parseOptional(raw: string | undefined): string | undefined {
		const normalized = raw?.trim();
		return normalized && normalized.length > 0 ? normalized : undefined;
	}

	private static parseOptionalWithFallback(primary: string | undefined, fallback: string | undefined): string | undefined {
		return ServerConfig.parseOptional(primary) ?? ServerConfig.parseOptional(fallback);
	}

	private static parseHost(raw: string | undefined): string {
		const normalized = raw?.trim();
		if (!normalized || normalized.length === 0) {
			return "0.0.0.0";
		}

		const lowered = normalized.toLowerCase();
		if (lowered === "localhost" || lowered === "127.0.0.1" || lowered === "::1") {
			return "0.0.0.0";
		}

		return normalized;
	}

	private static parseBoolean(raw: string | undefined): boolean {
		const normalized = raw?.trim().toLowerCase();
		return normalized === "1" || normalized === "true" || normalized === "yes";
	}

	private static parsePort(raw: string | undefined): number {
		if (!raw) {
			return DEFAULT_PORT;
		}

		const parsed = Number.parseInt(raw, 10);

		if (Number.isNaN(parsed) || parsed <= 0 || parsed > 65_535) {
			return DEFAULT_PORT;
		}

		return parsed;
	}
}

export const serverConfig = Object.freeze(ServerConfig.load());
