const DEFAULT_PORT = 8835;
const DEFAULT_TOKEN = "local-dev-token";

export interface ServerConfigValues {
	databasePath?: string;
	port: number;
	token: string;
}

export class ServerConfig {
	static load(): ServerConfigValues {
		return {
			databasePath: process.env.REMOTECODE_DB_PATH,
			port: ServerConfig.parsePort(process.env.REMOTECODE_SERVER_PORT),
			token: process.env.REMOTECODE_LOCAL_TOKEN?.trim() || DEFAULT_TOKEN,
		};
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
