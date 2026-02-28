const DEFAULT_PORT = 3001;
const DEFAULT_TOKEN = "local-dev-token";

export const serverConfig = {
	databasePath: process.env.REMOTECODE_DB_PATH,
	port: parsePort(process.env.REMOTECODE_SERVER_PORT),
	token: process.env.REMOTECODE_LOCAL_TOKEN?.trim() || DEFAULT_TOKEN,
};

function parsePort(raw: string | undefined): number {
	if (!raw) {
		return DEFAULT_PORT;
	}

	const parsed = Number.parseInt(raw, 10);

	if (Number.isNaN(parsed) || parsed <= 0 || parsed > 65_535) {
		return DEFAULT_PORT;
	}

	return parsed;
}
