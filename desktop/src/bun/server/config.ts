const DEFAULT_PORT = 8835;
const DEFAULT_TOKEN = "remotecode.io-token";
const DEFAULT_RELEASE_PRIVATE_BACKEND_URL = "https://private.remotecode.io:8787";

export interface ServerConfigValues {
	databasePath?: string;
	host: string;
	port: number;
	privateBackendUrl: string;
	token: string;
}

export class ServerConfig {
	static load(): ServerConfigValues {
		return {
			databasePath: process.env.REMOTECODE_DB_PATH,
			host: ServerConfig.parseHost(process.env.REMOTECODE_SERVER_HOST),
			port: ServerConfig.parsePort(process.env.REMOTECODE_SERVER_PORT),
			privateBackendUrl: ServerConfig.parsePrivateBackendUrl(process.env.REMOTECODE_PRIVATE_BACKEND_URL),
			token: process.env.REMOTECODE_LOCAL_TOKEN?.trim() || DEFAULT_TOKEN,
		};
	}

	private static parsePrivateBackendUrl(raw: string | undefined): string {
		const normalized = raw?.trim().replace(/\/+$/u, "");
		return normalized && normalized.length > 0 ? normalized : ServerConfig.defaultPrivateBackendUrl();
	}

	private static defaultPrivateBackendUrl(): string {
		return DEFAULT_RELEASE_PRIVATE_BACKEND_URL;
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
