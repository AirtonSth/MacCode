import { and, asc, eq, inArray } from "drizzle-orm";

import type { ChatTurnDTO } from "../../types";
import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { chatTurnSnapshots } from "../../shared/db/db.schema";

const parsePayload = (value: string): ChatTurnDTO | null => {
	try {
		const parsed = JSON.parse(value) as unknown;
		if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
			return null;
		}

		return parsed as ChatTurnDTO;
	} catch {
		return null;
	}
};

export interface ChatTurnSnapshotRepositoryContract {
	listByAnchorMessageIds: (chatId: string, anchorMessageIds: string[]) => ChatTurnDTO[];
	upsertByAnchorMessageId: (chatId: string, anchorMessageId: string, turns: ChatTurnDTO[]) => void;
}

export class ChatTurnSnapshotRepository implements ChatTurnSnapshotRepositoryContract {
	private readonly database: DrizzleDatabaseClient["orm"];

	constructor(databaseClient: DrizzleDatabaseClient["orm"]) {
		this.database = databaseClient;
	}

	listByAnchorMessageIds(chatId: string, anchorMessageIds: string[]): ChatTurnDTO[] {
		if (anchorMessageIds.length === 0) {
			return [];
		}

		const anchorIndexes = new Map(anchorMessageIds.map((messageId, index) => [messageId, index]));
		const rows = this.database
			.select()
			.from(chatTurnSnapshots)
			.where(
				and(
					eq(chatTurnSnapshots.chatId, chatId),
					inArray(chatTurnSnapshots.anchorMessageId, anchorMessageIds),
				),
			)
			.orderBy(asc(chatTurnSnapshots.createdAt))
			.all() as typeof chatTurnSnapshots.$inferSelect[];

		return rows
			.sort((left, right) => {
				const leftIndex = anchorIndexes.get(left.anchorMessageId) ?? Number.MAX_SAFE_INTEGER;
				const rightIndex = anchorIndexes.get(right.anchorMessageId) ?? Number.MAX_SAFE_INTEGER;
				if (leftIndex !== rightIndex) {
					return leftIndex - rightIndex;
				}
				if (left.createdAt !== right.createdAt) {
					return left.createdAt.localeCompare(right.createdAt);
				}
				return left.turnId.localeCompare(right.turnId);
			})
			.map((row) => parsePayload(row.payloadJson))
			.filter((turn): turn is ChatTurnDTO => turn !== null);
	}

	upsertByAnchorMessageId(chatId: string, anchorMessageId: string, turns: ChatTurnDTO[]): void {
		if (turns.length === 0) {
			return;
		}

		const now = new Date().toISOString();
		for (const turn of turns) {
			this.database
				.insert(chatTurnSnapshots)
				.values({
					anchorMessageId,
					chatId,
					createdAt: now,
					payloadJson: JSON.stringify(turn),
					turnId: turn.turnId,
					updatedAt: now,
				})
				.onConflictDoUpdate({
					target: chatTurnSnapshots.turnId,
					set: {
						anchorMessageId,
						chatId,
						payloadJson: JSON.stringify(turn),
						updatedAt: now,
					},
				})
				.run();
		}
	}
}

export const createChatTurnSnapshotRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	new ChatTurnSnapshotRepository(databaseClient);
