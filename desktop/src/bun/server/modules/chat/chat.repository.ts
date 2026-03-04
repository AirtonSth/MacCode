import { randomUUID } from "node:crypto";

import { desc, eq } from "drizzle-orm";

import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { chats } from "../../shared/db/db.schema";
import type { ChatDTO, ChatProvider, ChatStatus, ThreadSummaryDTO } from "../../types";

export class ChatRepository {
	private readonly database: DrizzleDatabaseClient["orm"];

	constructor(databaseClient: DrizzleDatabaseClient["orm"]) {
		this.database = databaseClient;
	}

	private static toNumber(value: number | null | undefined): number {
		return Number(value ?? 0);
	}

	private static normalizeProvider(provider: string): ChatProvider {
		return provider === "codex" ? "codex" : "fake";
	}

	private static toChatDto(row: typeof chats.$inferSelect): ChatDTO {
		return {
			diffAdded: ChatRepository.toNumber(row.diffAdded),
			diffRemoved: ChatRepository.toNumber(row.diffRemoved),
			id: row.id,
			projectId: row.projectId,
			provider: ChatRepository.normalizeProvider(row.provider),
			status: row.status as ChatStatus,
			title: row.title,
			updatedAt: row.updatedAt,
		};
	}

	private static toThreadSummaryDto(row: { id: string; title: string; updatedAt: string }): ThreadSummaryDTO {
		return {
			id: row.id,
			title: row.title,
			updatedAt: row.updatedAt,
		};
	}

	createChat(projectId: string, title: string): ChatDTO {
		const now = new Date().toISOString();
		const chatId = randomUUID();

		this.database
			.insert(chats)
			.values({
				diffAdded: 0,
				diffRemoved: 0,
				id: chatId,
				projectId,
				provider: "codex",
				providerThreadId: null,
				status: "pending",
				title,
				updatedAt: now,
			})
			.run();

		const rows = this.database
			.select()
			.from(chats)
			.where(eq(chats.id, chatId))
			.all() as typeof chats.$inferSelect[];

		return ChatRepository.toChatDto(rows[0]);
	}

	findChatById(id: string): ChatDTO | null {
		const rows = this.database
			.select()
			.from(chats)
			.where(eq(chats.id, id))
			.all() as typeof chats.$inferSelect[];

		return rows[0] ? ChatRepository.toChatDto(rows[0]) : null;
	}

	findProviderThreadIdByChatId(id: string): string | null {
		const rows = this.database
			.select({ providerThreadId: chats.providerThreadId })
			.from(chats)
			.where(eq(chats.id, id))
			.all() as Array<{ providerThreadId: string | null }>;

		return rows[0]?.providerThreadId ?? null;
	}

	getChatsByProjectId(projectId: string): ChatDTO[] {
		const rows = this.database
			.select()
			.from(chats)
			.where(eq(chats.projectId, projectId))
			.orderBy(desc(chats.updatedAt))
			.all() as typeof chats.$inferSelect[];

		return rows.map(ChatRepository.toChatDto);
	}

	getThreadSummariesByProjectId(projectId: string): ThreadSummaryDTO[] {
		const rows = this.database
			.select({
				id: chats.id,
				title: chats.title,
				updatedAt: chats.updatedAt,
			})
			.from(chats)
			.where(eq(chats.projectId, projectId))
			.orderBy(desc(chats.updatedAt))
			.all() as Array<{ id: string; title: string; updatedAt: string }>;

		return rows.map(ChatRepository.toThreadSummaryDto);
	}

	updateChat(
		chatId: string,
		update: Partial<Pick<ChatDTO, "status" | "diffAdded" | "diffRemoved">>,
	): ChatDTO | null {
		this.database
			.update(chats)
			.set({
				...(update.status === undefined ? {} : { status: update.status }),
				...(update.diffAdded === undefined ? {} : { diffAdded: update.diffAdded }),
				...(update.diffRemoved === undefined ? {} : { diffRemoved: update.diffRemoved }),
				updatedAt: new Date().toISOString(),
			})
			.where(eq(chats.id, chatId))
			.run();

		const rows = this.database
			.select()
			.from(chats)
			.where(eq(chats.id, chatId))
			.all() as typeof chats.$inferSelect[];

		return rows[0] ? ChatRepository.toChatDto(rows[0]) : null;
	}

	updateProviderThreadId(chatId: string, providerThreadId: string | null): ChatDTO | null {
		this.database
			.update(chats)
			.set({
				providerThreadId,
				updatedAt: new Date().toISOString(),
			})
			.where(eq(chats.id, chatId))
			.run();

		const rows = this.database
			.select()
			.from(chats)
			.where(eq(chats.id, chatId))
			.all() as typeof chats.$inferSelect[];

		return rows[0] ? ChatRepository.toChatDto(rows[0]) : null;
	}

	deleteChat(id: string): boolean {
		const result = this.database.delete(chats).where(eq(chats.id, id)).run() as unknown as {
			changes?: number;
		};
		return (result.changes ?? 0) > 0;
	}
}

export const createChatRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	new ChatRepository(databaseClient);
