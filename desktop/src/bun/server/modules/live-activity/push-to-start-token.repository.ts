import { and, eq } from "drizzle-orm";

import type {
	PushToStartTokenInput,
	PushToStartTokenStoreContract,
	PushToStartTokenStored,
} from "./live-activity-push.model";
import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { pushToStartTokens } from "../../shared/db/db.schema";

const toStored = (
	row: typeof pushToStartTokens.$inferSelect,
): PushToStartTokenStored => ({
	pushToStartToken: row.pushToStartToken,
	pushToken: row.pushToken,
	pushTokenType: row.pushTokenType as PushToStartTokenStored["pushTokenType"],
	updatedAt: row.updatedAt,
});

export class PushToStartTokenRepository implements PushToStartTokenStoreContract {
	private readonly database: DrizzleDatabaseClient["orm"];

	constructor(databaseClient: DrizzleDatabaseClient["orm"]) {
		this.database = databaseClient;
	}

	listAll(): PushToStartTokenStored[] {
		const rows = this.database
			.select()
			.from(pushToStartTokens)
			.all() as Array<typeof pushToStartTokens.$inferSelect>;

		return rows.map((row) => toStored(row));
	}

	upsert(input: PushToStartTokenInput): PushToStartTokenStored {
		const now = new Date().toISOString();

		this.database
			.delete(pushToStartTokens)
			.where(and(
				eq(pushToStartTokens.pushToken, input.pushToken),
				eq(pushToStartTokens.pushTokenType, input.pushTokenType),
			))
			.run();

		this.database
			.insert(pushToStartTokens)
			.values({
				pushToStartToken: input.pushToStartToken,
				pushToken: input.pushToken,
				pushTokenType: input.pushTokenType,
				updatedAt: now,
			})
			.run();

		return {
			pushToStartToken: input.pushToStartToken,
			pushToken: input.pushToken,
			pushTokenType: input.pushTokenType,
			updatedAt: now,
		};
	}

	deleteByPushToken(pushToken: string, pushTokenType: string): void {
		this.database
			.delete(pushToStartTokens)
			.where(and(
				eq(pushToStartTokens.pushToken, pushToken),
				eq(pushToStartTokens.pushTokenType, pushTokenType),
			))
			.run();
	}
}

export const createPushToStartTokenRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	new PushToStartTokenRepository(databaseClient);
