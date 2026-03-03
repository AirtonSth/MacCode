import { and, asc, desc, eq, gt } from "drizzle-orm";

import type { AssistantStreamEvent } from "../../../../shared/assistant-stream-event";
import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { chatStreamEvents } from "../../shared/db/db.schema";
import type { ChatStreamEventDTO } from "../../types";

const parseEventJson = (value: string): AssistantStreamEvent | null => {
	try {
		const parsed = JSON.parse(value) as unknown;
		if (!parsed || typeof parsed !== "object") {
			return null;
		}

		return parsed as AssistantStreamEvent;
	} catch {
		return null;
	}
};

const toEventDto = (row: typeof chatStreamEvents.$inferSelect): ChatStreamEventDTO | null => {
	const event = parseEventJson(row.eventJson);
	if (!event) {
		return null;
	}

	return {
		id: row.id,
		chatId: row.chatId,
		createdAt: row.createdAt,
		event,
		turnId: row.turnId,
	};
};

export interface ChatStreamEventRepositoryContract {
	append: (chatId: string, event: AssistantStreamEvent) => ChatStreamEventDTO;
	listByChatId: (chatId: string, options?: { afterId?: number; limit?: number }) => ChatStreamEventDTO[];
}

export class ChatStreamEventRepository implements ChatStreamEventRepositoryContract {
	private readonly database: DrizzleDatabaseClient["orm"];

	constructor(databaseClient: DrizzleDatabaseClient["orm"]) {
		this.database = databaseClient;
	}

	append(chatId: string, event: AssistantStreamEvent): ChatStreamEventDTO {
		const now = new Date().toISOString();
		this.database
			.insert(chatStreamEvents)
			.values({
				chatId,
				eventJson: JSON.stringify(event),
				turnId: event.turnId,
				createdAt: now,
			})
			.run();

		const created = this.database
			.select()
			.from(chatStreamEvents)
			.where(eq(chatStreamEvents.chatId, chatId))
			.orderBy(desc(chatStreamEvents.id))
			.limit(1)
			.get() as typeof chatStreamEvents.$inferSelect | undefined;

		if (!created) {
			throw new Error("failed to persist chat stream event");
		}

		const dto = toEventDto(created);
		if (!dto) {
			throw new Error("failed to parse persisted chat stream event");
		}

		return dto;
	}

	listByChatId(chatId: string, options?: { afterId?: number; limit?: number }): ChatStreamEventDTO[] {
		const afterId = options?.afterId && options.afterId > 0 ? options.afterId : 0;
		const limit = options?.limit && options.limit > 0 ? options.limit : 500;
		const rows = this.database
			.select()
			.from(chatStreamEvents)
			.where(and(eq(chatStreamEvents.chatId, chatId), gt(chatStreamEvents.id, afterId)))
			.orderBy(asc(chatStreamEvents.id))
			.limit(limit)
			.all() as typeof chatStreamEvents.$inferSelect[];

		return rows.map((row) => toEventDto(row)).filter((row): row is ChatStreamEventDTO => row !== null);
	}
}

export const createChatStreamEventRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	new ChatStreamEventRepository(databaseClient);
