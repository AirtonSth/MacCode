import { asc, desc, gt } from "drizzle-orm";

import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { workspaceEvents } from "../../shared/db/db.schema";
import type {
	WorkspaceEventEnvelope,
	WorkspaceEventPublishInput,
	WorkspaceEventRepositoryContract,
	WorkspaceEventType,
} from "./workspace-events.model";

const DEFAULT_LIST_LIMIT = 500;
const MAX_LIST_LIMIT = 5_000;

const normalizeLimit = (limit: number | undefined): number => {
	if (typeof limit !== "number" || !Number.isFinite(limit) || limit <= 0) {
		return DEFAULT_LIST_LIMIT;
	}

	return Math.min(MAX_LIST_LIMIT, Math.floor(limit));
};

const parsePayload = (value: string): Record<string, unknown> => {
	try {
		const parsed = JSON.parse(value) as unknown;
		if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
			return parsed as Record<string, unknown>;
		}
	} catch {
		// Keep resilient and return empty payload
	}

	return {};
};

export class WorkspaceEventsRepository implements WorkspaceEventRepositoryContract {
	private readonly database: DrizzleDatabaseClient["orm"];

	constructor(databaseClient: DrizzleDatabaseClient["orm"]) {
		this.database = databaseClient;
	}

	private static toEnvelope(row: typeof workspaceEvents.$inferSelect): WorkspaceEventEnvelope {
		return {
			seq: row.seq,
			ts: row.createdAt,
			type: row.type as WorkspaceEventType,
			payload: parsePayload(row.payload),
			originClientId: row.originClientId ?? null,
			requestId: row.requestId ?? null,
		};
	}

	append(input: WorkspaceEventPublishInput): WorkspaceEventEnvelope {
		const createdAt = new Date().toISOString();
		this.database
			.insert(workspaceEvents)
			.values({
				type: input.type,
				payload: JSON.stringify(input.payload),
				originClientId: input.originClientId ?? null,
				requestId: input.requestId ?? null,
				createdAt,
			})
			.run();

		const insertResult = this.database
			.select()
			.from(workspaceEvents)
			.orderBy(desc(workspaceEvents.seq))
			.limit(1)
			.get() as typeof workspaceEvents.$inferSelect | undefined;

		if (!insertResult) {
			throw new Error("failed to persist workspace event");
		}

		return WorkspaceEventsRepository.toEnvelope(insertResult);
	}

	listAfterSeq(seq: number, limit?: number): WorkspaceEventEnvelope[] {
		const normalizedSeq = Number.isFinite(seq) ? Math.max(0, Math.floor(seq)) : 0;
		const normalizedLimit = normalizeLimit(limit);

		const rows = this.database
			.select()
			.from(workspaceEvents)
			.where(gt(workspaceEvents.seq, normalizedSeq))
			.orderBy(asc(workspaceEvents.seq))
			.limit(normalizedLimit)
			.all() as typeof workspaceEvents.$inferSelect[];

		return rows.map(WorkspaceEventsRepository.toEnvelope);
	}
}

export const createWorkspaceEventsRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	new WorkspaceEventsRepository(databaseClient);
