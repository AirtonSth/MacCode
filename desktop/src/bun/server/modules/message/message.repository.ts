import { randomUUID } from "node:crypto";

import { and, asc, desc, eq, lt, or } from "drizzle-orm";

import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { messages } from "../../shared/db/db.schema";
import type { MessageDTO } from "../../types";

export interface MessageListPage {
	messages: MessageDTO[];
	hasMore: boolean;
	nextBeforeMessageId: string | null;
}

export class MessageRepository {
	private static toMessageDto(row: typeof messages.$inferSelect): MessageDTO {
		return {
			chatId: row.chatId,
			content: row.content,
			createdAt: row.createdAt,
			id: row.id,
			role: row.role as MessageDTO["role"],
		};
	}

	private static normalizeLimit(limit: number | undefined): number | null {
		if (typeof limit !== "number" || !Number.isFinite(limit) || limit <= 0) {
			return null;
		}

		return Math.min(Math.floor(limit), 200);
	}

	private readonly database: DrizzleDatabaseClient["orm"];

	constructor(databaseClient: DrizzleDatabaseClient["orm"]) {
		this.database = databaseClient;
	}

	private findCursorByMessageId(chatId: string, messageId: string): { id: string; createdAt: string } | null {
		const rows = this.database
			.select({
				createdAt: messages.createdAt,
				id: messages.id,
			})
			.from(messages)
			.where(and(eq(messages.chatId, chatId), eq(messages.id, messageId)))
			.limit(1)
			.all() as Array<{ createdAt: string; id: string }>;

		return rows[0] ?? null;
	}

	createMessage(chatId: string, role: MessageDTO["role"], content: string): MessageDTO {
		const id = randomUUID();
		const now = new Date().toISOString();

		this.database.insert(messages).values({
			chatId,
			content,
			createdAt: now,
			id,
			role,
		}).run();

		return {
			chatId,
			content,
			createdAt: now,
			id,
			role,
		};
	}

	listMessagesByChatId(
		chatId: string,
		options?: { beforeMessageId?: string; limit?: number },
	): MessageListPage {
		const normalizedLimit = MessageRepository.normalizeLimit(options?.limit);
		if (normalizedLimit === null) {
			const rows = this.database
				.select()
				.from(messages)
				.where(eq(messages.chatId, chatId))
				.orderBy(asc(messages.createdAt))
				.all() as typeof messages.$inferSelect[];

			return {
				hasMore: false,
				messages: rows.map(MessageRepository.toMessageDto),
				nextBeforeMessageId: null,
			};
		}

		const cursor = options?.beforeMessageId
			? this.findCursorByMessageId(chatId, options.beforeMessageId)
			: null;

		const rows = this.database
			.select()
			.from(messages)
			.where(
				cursor
					? and(
						eq(messages.chatId, chatId),
						or(
							lt(messages.createdAt, cursor.createdAt),
							and(eq(messages.createdAt, cursor.createdAt), lt(messages.id, cursor.id)),
						),
					)
					: eq(messages.chatId, chatId),
			)
			.orderBy(desc(messages.createdAt), desc(messages.id))
			.limit(normalizedLimit + 1)
			.all() as typeof messages.$inferSelect[];
		const hasMore = rows.length > normalizedLimit;
		const pageRows = hasMore ? rows.slice(0, normalizedLimit) : rows;
		const orderedRows = Array.from(pageRows).reverse();
		const nextBeforeMessageId = hasMore && pageRows.length > 0 ? pageRows.at(-1)?.id ?? null : null;

		return {
			hasMore,
			messages: orderedRows.map(MessageRepository.toMessageDto),
			nextBeforeMessageId,
		};
	}
}

export const createMessageRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	new MessageRepository(databaseClient);
