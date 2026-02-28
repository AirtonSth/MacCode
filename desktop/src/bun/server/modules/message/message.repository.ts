import { randomUUID } from "node:crypto";

import { asc,eq } from "drizzle-orm";

import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { messages } from "../../shared/db/db.schema";
import type { MessageDTO } from "../../types";

const toMessageDto = (row: typeof messages.$inferSelect): MessageDTO => ({
	chatId: row.chatId,
	content: row.content,
	createdAt: row.createdAt,
	id: row.id,
	role: row.role as MessageDTO["role"],
});

export const createMessageRepository = (databaseClient: DrizzleDatabaseClient["orm"]) => {
	const database = databaseClient;

	return {
		createMessage: (chatId: string, role: MessageDTO["role"], content: string) => {
			const id = randomUUID();
			const now = new Date().toISOString();

			database.insert(messages).values({
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
		},

		listMessagesByChatId: (chatId: string) => {
			const rows = database
				.select()
				.from(messages)
				.where(eq(messages.chatId, chatId))
				.orderBy(asc(messages.createdAt))
				.all() as typeof messages.$inferSelect[];

			return rows.map(toMessageDto);
		},
	};
};

export type MessageRepository = ReturnType<typeof createMessageRepository>;
