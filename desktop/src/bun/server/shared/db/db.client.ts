import { mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";

import { Database } from "bun:sqlite";
import { drizzle } from "drizzle-orm/bun-sqlite";

import { serverConfig } from "../../config";
import { DatabaseSchema } from "./db.schema";

const requireModule = createRequire(import.meta.url);

export interface DrizzleDatabaseClient {
	close: () => void;
	readonly dbPath: string;
	readonly orm: ReturnType<typeof drizzle>;
	readonly sqlite: Database;
}

export class DatabaseClientFactory {
	private static resolveDatabasePath(): string {
		const configuredPath = serverConfig.databasePath;

		if (configuredPath) {
			return configuredPath;
		}

		return join(DatabaseClientFactory.getUserDataPath(), "remodecode-server", "remodecode.sqlite");
	}

private static getUserDataPath(): string {
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
	}

static async create(pathOverride?: string): Promise<DrizzleDatabaseClient> {
		const databasePath = pathOverride ?? DatabaseClientFactory.resolveDatabasePath();

		mkdirSync(dirname(databasePath), { recursive: true });

		const sqlite = new Database(databasePath);
		const orm = drizzle(sqlite, {
			schema: {
				chats: DatabaseSchema.chats,
				messages: DatabaseSchema.messages,
				projects: DatabaseSchema.projects,
				workspaceSelection: DatabaseSchema.workspaceSelection,
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
	}

	

	
}

export const createDatabaseClient = async (pathOverride?: string) => await DatabaseClientFactory.create(pathOverride);
