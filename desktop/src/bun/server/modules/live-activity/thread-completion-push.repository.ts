import { and, desc, eq } from "drizzle-orm";

import type {
	ThreadCompletionPushSubscriptionInput,
	ThreadCompletionPushStoredSubscription,
	ThreadCompletionPushSubscriptionStoreContract,
} from "./live-activity-push.model";
import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { threadCompletionPushSubscriptions } from "../../shared/db/db.schema";

const toOptionalText = (value: string | undefined): string | null => {
	const normalized = value?.trim();
	return normalized && normalized.length > 0 ? normalized : null;
};

const toStored = (
	row: typeof threadCompletionPushSubscriptions.$inferSelect,
): ThreadCompletionPushStoredSubscription => ({
	chatId: row.chatId,
	chatTitle: row.chatTitle ?? undefined,
	pushToken: row.pushToken,
	pushTokenType: row.pushTokenType as ThreadCompletionPushStoredSubscription["pushTokenType"],
	updatedAt: row.updatedAt,
});

export class ThreadCompletionPushRepository implements ThreadCompletionPushSubscriptionStoreContract {
	private readonly database: DrizzleDatabaseClient["orm"];

	constructor(databaseClient: DrizzleDatabaseClient["orm"]) {
		this.database = databaseClient;
	}

	listAll(): ThreadCompletionPushStoredSubscription[] {
		const rows = this.database
			.select()
			.from(threadCompletionPushSubscriptions)
			.orderBy(
				desc(threadCompletionPushSubscriptions.updatedAt),
				desc(threadCompletionPushSubscriptions.id),
			)
			.all() as Array<typeof threadCompletionPushSubscriptions.$inferSelect>;

		return rows.map((row) => toStored(row));
	}

	upsert(input: ThreadCompletionPushSubscriptionInput): ThreadCompletionPushStoredSubscription {
		const now = new Date().toISOString();
		const chatTitle = toOptionalText(input.chatTitle);

		this.deleteExact(input);
		this.database
			.insert(threadCompletionPushSubscriptions)
			.values({
				chatId: input.chatId,
				chatTitle,
				pushToken: input.pushToken,
				pushTokenType: input.pushTokenType,
				updatedAt: now,
			})
			.run();

		return {
			chatId: input.chatId,
			chatTitle: chatTitle ?? undefined,
			pushToken: input.pushToken,
			pushTokenType: input.pushTokenType,
			updatedAt: now,
		};
	}

	deleteExact(input: ThreadCompletionPushSubscriptionInput): void {
		this.database
			.delete(threadCompletionPushSubscriptions)
			.where(and(
				eq(threadCompletionPushSubscriptions.chatId, input.chatId),
				eq(threadCompletionPushSubscriptions.pushToken, input.pushToken),
				eq(threadCompletionPushSubscriptions.pushTokenType, input.pushTokenType),
			))
			.run();
	}
}

export const createThreadCompletionPushRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	new ThreadCompletionPushRepository(databaseClient);
