import { eq } from "drizzle-orm";

import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { terminalSessions } from "../../shared/db/db.schema";
import type { TerminalSessionSnapshotDTO, TerminalSessionStateDTO, TerminalSessionStatus } from "../../types";

const toSnapshotDto = (row: typeof terminalSessions.$inferSelect): TerminalSessionSnapshotDTO => ({
	chatId: row.chatId,
	cols: Number(row.cols),
	cwd: row.cwd,
	exitCode: row.exitCode ?? null,
	exitedAt: row.exitedAt ?? null,
	rows: Number(row.rows),
	seq: Number(row.seq),
	sessionId: row.sessionId,
	shell: row.shell,
	snapshot: row.snapshot,
	startedAt: row.startedAt,
	status: row.status as TerminalSessionStatus,
});

export class TerminalSessionRepository {
	private readonly database: DrizzleDatabaseClient["orm"];

	constructor(databaseClient: DrizzleDatabaseClient["orm"]) {
		this.database = databaseClient;
	}

	deleteByChatId(chatId: string): void {
		this.database.delete(terminalSessions).where(eq(terminalSessions.chatId, chatId)).run();
	}

	findSnapshotByChatId(chatId: string): TerminalSessionSnapshotDTO | null {
		const rows = this.database
			.select()
			.from(terminalSessions)
			.where(eq(terminalSessions.chatId, chatId))
			.limit(1)
			.all() as typeof terminalSessions.$inferSelect[];

		const row = rows[0];
		return row ? toSnapshotDto(row) : null;
	}

	saveSnapshot(snapshot: TerminalSessionSnapshotDTO): TerminalSessionSnapshotDTO {
		const now = new Date().toISOString();

		this.database
			.insert(terminalSessions)
			.values({
				chatId: snapshot.chatId,
				cols: snapshot.cols,
				cwd: snapshot.cwd,
				exitCode: snapshot.exitCode,
				exitedAt: snapshot.exitedAt,
				rows: snapshot.rows,
				seq: snapshot.seq,
				sessionId: snapshot.sessionId,
				shell: snapshot.shell,
				snapshot: snapshot.snapshot,
				startedAt: snapshot.startedAt,
				status: snapshot.status,
				updatedAt: now,
			})
			.onConflictDoUpdate({
				target: terminalSessions.chatId,
				set: {
					cols: snapshot.cols,
					cwd: snapshot.cwd,
					exitCode: snapshot.exitCode,
					exitedAt: snapshot.exitedAt,
					rows: snapshot.rows,
					seq: snapshot.seq,
					sessionId: snapshot.sessionId,
					shell: snapshot.shell,
					snapshot: snapshot.snapshot,
					startedAt: snapshot.startedAt,
					status: snapshot.status,
					updatedAt: now,
				},
			})
			.run();

		const persisted = this.findSnapshotByChatId(snapshot.chatId);
		if (!persisted) {
			throw new Error("failed to load persisted terminal session snapshot");
		}

		return persisted;
	}

	toStateDto(snapshot: TerminalSessionSnapshotDTO): TerminalSessionStateDTO {
		return {
			chatId: snapshot.chatId,
			cols: snapshot.cols,
			cwd: snapshot.cwd,
			exitCode: snapshot.exitCode,
			exitedAt: snapshot.exitedAt,
			rows: snapshot.rows,
			seq: snapshot.seq,
			sessionId: snapshot.sessionId,
			shell: snapshot.shell,
			startedAt: snapshot.startedAt,
			status: snapshot.status,
		};
	}
}

export const createTerminalSessionRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	new TerminalSessionRepository(databaseClient);
