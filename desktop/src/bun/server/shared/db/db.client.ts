import { mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";

import { Database } from "bun:sqlite";
import { drizzle } from "drizzle-orm/bun-sqlite";

import { serverConfig } from "../../config";
import { chats, messages, projects } from "./db.schema";

const requireModule = createRequire(import.meta.url);

const getUserDataPath = (): string => {
	try {
		const electrobun = requireModule("electrobun/bun") as {
			Utils?: {
				paths?: {
					userData?: string;
				};
			};
		};

		return electrobun.Utils?.paths?.userData || join(process.cwd(), ".remotecode");
	} catch {
		return join(process.cwd(), ".remotecode");
	}
};

const resolveDatabasePath = () => {
	const configuredPath = serverConfig.databasePath;

	if (configuredPath) {
		return configuredPath;
	}

	return join(getUserDataPath(), "remodecode-server", "remodecode.sqlite");
};

export interface DrizzleDatabaseClient {
	close: () => void;
	readonly dbPath: string;
	readonly orm: ReturnType<typeof drizzle>;
	readonly sqlite: Database;
}

export const createDatabaseClient = async (pathOverride?: string): Promise<DrizzleDatabaseClient> => {
	const databasePath = pathOverride ?? resolveDatabasePath();

	mkdirSync(dirname(databasePath), { recursive: true });

	const sqlite = new Database(databasePath);
	const orm = drizzle(sqlite, {
		schema: {
			chats,
			messages,
			projects,
		},
	});

	return {
		close: () => {
			sqlite.close();
		},

		dbPath: databasePath,
		orm,

		sqlite,
	};
};
