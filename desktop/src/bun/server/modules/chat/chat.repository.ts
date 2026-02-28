import { randomUUID } from "node:crypto";

import { desc,eq } from "drizzle-orm";

import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { chats } from "../../shared/db/db.schema";
import type { ChatDTO, ChatStatus } from "../../types";

const toNumber = (value: number | null | undefined): number => Number(value ?? 0);

const toChatDto = (row: typeof chats.$inferSelect): ChatDTO => ({
	diffAdded: toNumber(row.diffAdded),
	diffRemoved: toNumber(row.diffRemoved),
	id: row.id,
	projectId: row.projectId,
	provider: "fake",
	status: row.status as ChatStatus,
	title: row.title,
	updatedAt: row.updatedAt,
});

export const createChatRepository = (databaseClient: DrizzleDatabaseClient["orm"]) => {
	const database = databaseClient;

	return {
		createChat: (projectId: string, title: string) => {
			const now = new Date().toISOString();
			const chatId = randomUUID();

			database.insert(chats).values({
				diffAdded: 0,
				diffRemoved: 0,
				id: chatId,
				projectId,
				provider: "fake",
				status: "pending",
				title,
				updatedAt: now,
			}).run();

			const rows = database.select().from(chats).where(eq(chats.id, chatId)).all() as typeof chats.$inferSelect[];

			return toChatDto(rows[0]);
		},

		findChatById: (id: string) => {
			const rows = database
				.select()
				.from(chats)
				.where(eq(chats.id, id))
				.all() as typeof chats.$inferSelect[];

			return rows[0] ? toChatDto(rows[0]) : null;
		},

		getChatsByProjectId: (projectId: string) => {
			const rows = database
				.select()
				.from(chats)
				.where(eq(chats.projectId, projectId))
				.orderBy(desc(chats.updatedAt))
				.all() as typeof chats.$inferSelect[];

			return rows.map(toChatDto);
		},

		updateChat: (chatId: string, update: Partial<Pick<ChatDTO, "status" | "diffAdded" | "diffRemoved">>) => {
			database
				.update(chats)
				.set({
					...(update.status === undefined ? {} : { status: update.status }),
					...(update.diffAdded === undefined ? {} : { diffAdded: update.diffAdded }),
					...(update.diffRemoved === undefined ? {} : { diffRemoved: update.diffRemoved }),
					updatedAt: new Date().toISOString(),
				})
				.where(eq(chats.id, chatId))
				.run();

			const rows = database.select().from(chats).where(eq(chats.id, chatId)).all() as typeof chats.$inferSelect[];

			return rows[0] ? toChatDto(rows[0]) : null;
		},
	};
};

export type ChatRepository = ReturnType<typeof createChatRepository>;
