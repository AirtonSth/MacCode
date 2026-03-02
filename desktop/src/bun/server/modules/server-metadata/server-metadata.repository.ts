import { eq } from "drizzle-orm";

import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { serverMetadata } from "../../shared/db/db.schema";

export class ServerMetadataRepository {
	private readonly database: DrizzleDatabaseClient["orm"];

	constructor(databaseClient: DrizzleDatabaseClient["orm"]) {
		this.database = databaseClient;
	}

	getValue(key: string): string | null {
		const row = this.database
			.select()
			.from(serverMetadata)
			.where(eq(serverMetadata.key, key))
			.limit(1)
			.get() as typeof serverMetadata.$inferSelect | undefined;

		if (!row) {
			return null;
		}

		return row.value;
	}

	setValue(key: string, value: string): void {
		const now = new Date().toISOString();
		this.database
			.insert(serverMetadata)
			.values({
				key,
				value,
				updatedAt: now,
			})
			.onConflictDoUpdate({
				target: serverMetadata.key,
				set: {
					value,
					updatedAt: now,
				},
			})
			.run();
	}
}

export const createServerMetadataRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	new ServerMetadataRepository(databaseClient);
