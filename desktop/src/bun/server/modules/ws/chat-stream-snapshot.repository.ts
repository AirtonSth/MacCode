import { eq, sql } from "drizzle-orm";

import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { chatStreamSnapshots } from "../../shared/db/db.schema";
import type { ChatStreamSnapshotDTO } from "../../types";

export interface ChatStreamSnapshotRepositoryContract {
	appendDelta: (chatId: string, delta: string) => ChatStreamSnapshotDTO;
	clear: (chatId: string) => void;
	getByChatId: (chatId: string) => ChatStreamSnapshotDTO | null;
	reset: (chatId: string) => ChatStreamSnapshotDTO;
}

export class ChatStreamSnapshotRepository implements ChatStreamSnapshotRepositoryContract {
	private readonly database: DrizzleDatabaseClient["orm"];

	constructor(databaseClient: DrizzleDatabaseClient["orm"]) {
		this.database = databaseClient;
	}

	private upsert(chatId: string, partialText: string): ChatStreamSnapshotDTO {
		const updatedAt = new Date().toISOString();

		this.database
			.insert(chatStreamSnapshots)
			.values({
				chatId,
				partialText,
				updatedAt,
			})
			.onConflictDoUpdate({
				target: chatStreamSnapshots.chatId,
				set: {
					partialText,
					updatedAt,
				},
			})
			.run();

		return {
			chatId,
			partialText,
			updatedAt,
		};
	}

	getByChatId(chatId: string): ChatStreamSnapshotDTO | null {
		const row = this.database
			.select()
			.from(chatStreamSnapshots)
			.where(eq(chatStreamSnapshots.chatId, chatId))
			.get() as typeof chatStreamSnapshots.$inferSelect | undefined;

		if (!row) {
			return null;
		}

		return {
			chatId: row.chatId,
			partialText: row.partialText,
			updatedAt: row.updatedAt,
		};
	}

	reset(chatId: string): ChatStreamSnapshotDTO {
		return this.upsert(chatId, "");
	}

	appendDelta(chatId: string, delta: string): ChatStreamSnapshotDTO {
		const updatedAt = new Date().toISOString();
		this.database
			.insert(chatStreamSnapshots)
			.values({
				chatId,
				partialText: delta,
				updatedAt,
			})
			.onConflictDoUpdate({
				target: chatStreamSnapshots.chatId,
				set: {
					partialText: sql`${chatStreamSnapshots.partialText} || ${delta}`,
					updatedAt,
				},
			})
			.run();

		const snapshot = this.getByChatId(chatId);
		if (!snapshot) {
			return {
				chatId,
				partialText: delta,
				updatedAt,
			};
		}

		return snapshot;
	}

	clear(chatId: string): void {
		this.database
			.delete(chatStreamSnapshots)
			.where(eq(chatStreamSnapshots.chatId, chatId))
			.run();
	}
}

export const createChatStreamSnapshotRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	new ChatStreamSnapshotRepository(databaseClient);
