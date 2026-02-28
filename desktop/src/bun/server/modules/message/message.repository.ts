import { randomUUID } from "node:crypto";

import { asc, eq } from "drizzle-orm";

import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { messages } from "../../shared/db/db.schema";
import type { MessageDTO } from "../../types";

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

private readonly database: DrizzleDatabaseClient["orm"];

	constructor(databaseClient: DrizzleDatabaseClient["orm"]) {
		this.database = databaseClient;
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

	listMessagesByChatId(chatId: string): MessageDTO[] {
		const rows = this.database
			.select()
			.from(messages)
			.where(eq(messages.chatId, chatId))
			.orderBy(asc(messages.createdAt))
			.all() as typeof messages.$inferSelect[];

		return rows.map(MessageRepository.toMessageDto);
	}
}

export const createMessageRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	new MessageRepository(databaseClient);
