import { and, desc, eq, ne, or } from "drizzle-orm";

import type {
	LiveActivityPushStoredSubscription,
	LiveActivityPushSubscriptionInput,
	LiveActivityPushSubscriptionStoreContract,
} from "./live-activity-push.model";
import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { liveActivitySubscriptions } from "../../shared/db/db.schema";

const toOptionalText = (value: string | undefined): string | null => {
	const normalized = value?.trim();
	return normalized && normalized.length > 0 ? normalized : null;
};

const toStoredSubscription = (
	row: typeof liveActivitySubscriptions.$inferSelect,
): LiveActivityPushStoredSubscription => ({
	chatId: row.chatId,
	chatTitle: row.chatTitle ?? undefined,
	liveActivityToken: row.liveActivityToken,
	pushToken: row.pushToken,
	pushTokenType: row.pushTokenType as LiveActivityPushStoredSubscription["pushTokenType"],
	updatedAt: row.updatedAt,
});

export class LiveActivitySubscriptionRepository implements LiveActivityPushSubscriptionStoreContract {
	private readonly database: DrizzleDatabaseClient["orm"];

	constructor(databaseClient: DrizzleDatabaseClient["orm"]) {
		this.database = databaseClient;
	}

	listAll(): LiveActivityPushStoredSubscription[] {
		const rows = this.database
			.select()
			.from(liveActivitySubscriptions)
			.orderBy(desc(liveActivitySubscriptions.updatedAt), desc(liveActivitySubscriptions.id))
			.all() as Array<typeof liveActivitySubscriptions.$inferSelect>;

		return rows.map((row) => toStoredSubscription(row));
	}

	upsert(input: LiveActivityPushSubscriptionInput): LiveActivityPushStoredSubscription {
		const now = new Date().toISOString();
		const chatTitle = toOptionalText(input.chatTitle);

		this.database
			.delete(liveActivitySubscriptions)
			.where(or(
				and(
					eq(liveActivitySubscriptions.pushToken, input.pushToken),
					eq(liveActivitySubscriptions.pushTokenType, input.pushTokenType),
					ne(liveActivitySubscriptions.liveActivityToken, input.liveActivityToken),
				),
				and(
					eq(liveActivitySubscriptions.liveActivityToken, input.liveActivityToken),
					or(
						ne(liveActivitySubscriptions.pushToken, input.pushToken),
						ne(liveActivitySubscriptions.pushTokenType, input.pushTokenType),
					),
				),
				and(
					eq(liveActivitySubscriptions.pushToken, input.pushToken),
					eq(liveActivitySubscriptions.pushTokenType, input.pushTokenType),
					eq(liveActivitySubscriptions.liveActivityToken, input.liveActivityToken),
					ne(liveActivitySubscriptions.chatId, input.chatId),
				),
			))
			.run();

		this.deleteExact(input);

		this.database
			.insert(liveActivitySubscriptions)
			.values({
				chatId: input.chatId,
				chatTitle,
				liveActivityToken: input.liveActivityToken,
				pushToken: input.pushToken,
				pushTokenType: input.pushTokenType,
				updatedAt: now,
			})
			.run();

		return {
			chatId: input.chatId,
			chatTitle: chatTitle ?? undefined,
			liveActivityToken: input.liveActivityToken,
			pushToken: input.pushToken,
			pushTokenType: input.pushTokenType,
			updatedAt: now,
		};
	}

	deleteExact(input: LiveActivityPushSubscriptionInput): void {
		this.database
			.delete(liveActivitySubscriptions)
			.where(and(
				eq(liveActivitySubscriptions.liveActivityToken, input.liveActivityToken),
				eq(liveActivitySubscriptions.pushToken, input.pushToken),
				eq(liveActivitySubscriptions.pushTokenType, input.pushTokenType),
			))
			.run();
	}
}

export const createLiveActivitySubscriptionRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	new LiveActivitySubscriptionRepository(databaseClient);
