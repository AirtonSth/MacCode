import { eq } from "drizzle-orm";

import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { workspaceSelection } from "../../shared/db/db.schema";
import type { WorkspaceSelection } from "./selection.model";

const WORKSPACE_SELECTION_ID = "default";

export class WorkspaceSelectionRepository {
	private static toWorkspaceSelectionDto(row: typeof workspaceSelection.$inferSelect | undefined): WorkspaceSelection {
		return {
			selectedChatId: row?.selectedChatId ?? null,
			selectedProjectId: row?.selectedProjectId ?? null,
		};
	}

	private readonly database: DrizzleDatabaseClient["orm"];

	constructor(databaseClient: DrizzleDatabaseClient["orm"]) {
		this.database = databaseClient;
	}

	getWorkspaceSelection(): WorkspaceSelection {
		const rows = this.database
			.select()
			.from(workspaceSelection)
			.where(eq(workspaceSelection.id, WORKSPACE_SELECTION_ID))
			.all() as typeof workspaceSelection.$inferSelect[];

		if (rows.length === 0) {
			return WorkspaceSelectionRepository.toWorkspaceSelectionDto(undefined);
		}

		return WorkspaceSelectionRepository.toWorkspaceSelectionDto(rows[0]);
	}

	saveWorkspaceSelection(selection: WorkspaceSelection): WorkspaceSelection {
		const now = new Date().toISOString();

		this.database
			.insert(workspaceSelection)
			.values({
				id: WORKSPACE_SELECTION_ID,
				selectedChatId: selection.selectedChatId,
				selectedProjectId: selection.selectedProjectId,
				updatedAt: now,
			})
			.onConflictDoUpdate({
				target: workspaceSelection.id,
				set: {
					selectedChatId: selection.selectedChatId,
					selectedProjectId: selection.selectedProjectId,
					updatedAt: now,
				},
			})
			.run();

		const rows = this.database
			.select()
			.from(workspaceSelection)
			.where(eq(workspaceSelection.id, WORKSPACE_SELECTION_ID))
			.all() as typeof workspaceSelection.$inferSelect[];

		return WorkspaceSelectionRepository.toWorkspaceSelectionDto(rows[0]);
	}
}

export const createWorkspaceSelectionRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	new WorkspaceSelectionRepository(databaseClient);

export const createSelectionRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	createWorkspaceSelectionRepository(databaseClient);
