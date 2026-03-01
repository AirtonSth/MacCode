import { randomUUID } from "node:crypto";

import { and, asc, desc, eq, gt } from "drizzle-orm";

import type {
	TerminalCommandDTO,
	TerminalCommandStatus,
	TerminalEntryDTO,
	TerminalEntryStream,
} from "../../types";
import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { terminalCommands, terminalEntries } from "../../shared/db/db.schema";

const DEFAULT_HISTORY_LIMIT = 200;
const MAX_HISTORY_LIMIT = 1_000;

export interface TerminalCommandResultInput {
	durationMs: number;
	exitCode: number | null;
	finishedAt: string;
	status: Extract<TerminalCommandStatus, "completed" | "failed" | "timeout">;
}

export class TerminalRepository {
	private readonly database: DrizzleDatabaseClient["orm"];

	constructor(databaseClient: DrizzleDatabaseClient["orm"]) {
		this.database = databaseClient;
	}

	private static toCommandDto(row: typeof terminalCommands.$inferSelect): TerminalCommandDTO {
		return {
			chatId: row.chatId,
			command: row.command,
			cwd: row.cwd,
			durationMs: row.durationMs ?? null,
			exitCode: row.exitCode ?? null,
			finishedAt: row.finishedAt ?? null,
			id: row.id,
			shell: row.shell,
			startedAt: row.startedAt,
			status: row.status as TerminalCommandStatus,
		};
	}

	private static toEntryDto(row: typeof terminalEntries.$inferSelect): TerminalEntryDTO {
		return {
			chatId: row.chatId,
			commandId: row.commandId,
			createdAt: row.createdAt,
			data: row.data,
			id: Number(row.id),
			stream: row.stream as TerminalEntryStream,
		};
	}

	private static normalizeLimit(limit: number | undefined): number {
		if (typeof limit !== "number" || !Number.isFinite(limit) || limit <= 0) {
			return DEFAULT_HISTORY_LIMIT;
		}

		return Math.min(MAX_HISTORY_LIMIT, Math.floor(limit));
	}

	private getCommandById(commandId: string): TerminalCommandDTO | null {
		const rows = this.database
			.select()
			.from(terminalCommands)
			.where(eq(terminalCommands.id, commandId))
			.limit(1)
			.all() as typeof terminalCommands.$inferSelect[];

		const row = rows[0];
		if (!row) {
			return null;
		}

		return TerminalRepository.toCommandDto(row);
	}

	createCommand(input: {
		chatId: string;
		command: string;
		cwd: string;
		shell: string;
		startedAt?: string;
	}): TerminalCommandDTO {
		const commandId = `${Date.now().toString().padStart(13, "0")}-${randomUUID()}`;
		const startedAt = input.startedAt ?? new Date().toISOString();

		this.database
			.insert(terminalCommands)
			.values({
				chatId: input.chatId,
				command: input.command,
				cwd: input.cwd,
				durationMs: null,
				exitCode: null,
				finishedAt: null,
				id: commandId,
				shell: input.shell,
				startedAt,
				status: "running",
			})
			.run();

		const created = this.getCommandById(commandId);
		if (!created) {
			throw new Error("failed to load created terminal command");
		}

		return created;
	}

	setCommandResult(commandId: string, result: TerminalCommandResultInput): TerminalCommandDTO | null {
		this.database
			.update(terminalCommands)
			.set({
				durationMs: result.durationMs,
				exitCode: result.exitCode,
				finishedAt: result.finishedAt,
				status: result.status,
			})
			.where(eq(terminalCommands.id, commandId))
			.run();

		return this.getCommandById(commandId);
	}

	listCommandsByChatId(chatId: string, query?: { limit?: number }): TerminalCommandDTO[] {
		const limit = TerminalRepository.normalizeLimit(query?.limit);
		const rows = this.database
			.select()
			.from(terminalCommands)
			.where(eq(terminalCommands.chatId, chatId))
			.orderBy(desc(terminalCommands.id))
			.limit(limit)
			.all() as typeof terminalCommands.$inferSelect[];

		return rows.reverse().map(TerminalRepository.toCommandDto);
	}

	appendEntry(commandId: string, chatId: string, stream: TerminalEntryStream, data: string, createdAt?: string): TerminalEntryDTO {
		const timestamp = createdAt ?? new Date().toISOString();

		this.database
			.insert(terminalEntries)
			.values({
				chatId,
				commandId,
				createdAt: timestamp,
				data,
				stream,
			})
			.run();

		const rows = this.database
			.select()
			.from(terminalEntries)
			.where(
				and(
					eq(terminalEntries.chatId, chatId),
					eq(terminalEntries.commandId, commandId),
					eq(terminalEntries.stream, stream),
					eq(terminalEntries.data, data),
					eq(terminalEntries.createdAt, timestamp),
				),
			)
			.orderBy(desc(terminalEntries.id))
			.limit(1)
			.all() as typeof terminalEntries.$inferSelect[];

		const entry = rows[0];
		if (!entry) {
			throw new Error("failed to load appended terminal entry");
		}

		return TerminalRepository.toEntryDto(entry);
	}

	appendEntries(commandId: string, chatId: string, stream: TerminalEntryStream, data: string): TerminalEntryDTO[] {
		if (!data) {
			return [];
		}

		const chunkSize = 16_384;
		const result: TerminalEntryDTO[] = [];
		let offset = 0;
		let chunkIndex = 0;

		while (offset < data.length) {
			const chunk = data.slice(offset, offset + chunkSize);
			offset += chunk.length;
			const createdAt = new Date(Date.now() + chunkIndex).toISOString();
			chunkIndex += 1;
			result.push(this.appendEntry(commandId, chatId, stream, chunk, createdAt));
		}

		return result;
	}

	listEntriesByChatId(chatId: string, query?: { cursor?: number; limit?: number }): TerminalEntryDTO[] {
		const cursor =
			typeof query?.cursor === "number" && Number.isFinite(query.cursor) && query.cursor > 0
				? Math.floor(query.cursor)
				: null;
		const limit = TerminalRepository.normalizeLimit(query?.limit);

		const rows =
			cursor === null
				? (this.database
						.select()
						.from(terminalEntries)
						.where(eq(terminalEntries.chatId, chatId))
						.orderBy(asc(terminalEntries.id))
						.limit(limit)
						.all() as typeof terminalEntries.$inferSelect[])
				: (this.database
						.select()
						.from(terminalEntries)
						.where(and(eq(terminalEntries.chatId, chatId), gt(terminalEntries.id, cursor)))
						.orderBy(asc(terminalEntries.id))
						.limit(limit)
						.all() as typeof terminalEntries.$inferSelect[]);

		return rows.map(TerminalRepository.toEntryDto);
	}
}

export const createTerminalRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	new TerminalRepository(databaseClient);
