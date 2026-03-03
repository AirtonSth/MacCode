import { eq } from "drizzle-orm";

import {
	DEFAULT_CODEX_PERMISSION_MODE,
	parseCodexPermissionMode,
} from "../../../../shared/codex-permission-mode";
import { parseCodexReasoningEffort } from "../../../../shared/codex-model-config";
import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { workspaceSelection } from "../../shared/db/db.schema";
import type { WorkspaceSelection } from "./selection.model";

const WORKSPACE_SELECTION_ID = "default";

export class WorkspaceSelectionRepository {
	private static toWorkspaceSelectionDto(row: typeof workspaceSelection.$inferSelect | undefined): WorkspaceSelection {
		const parsedPermissionMode = parseCodexPermissionMode(row?.permissionMode);
		const permissionMode = parsedPermissionMode ?? DEFAULT_CODEX_PERMISSION_MODE;
		const selectedModel =
			typeof row?.selectedModel === "string" && row.selectedModel.trim().length > 0
				? row.selectedModel.trim()
				: null;
		const selectedReasoningEffort = parseCodexReasoningEffort(row?.selectedReasoningEffort) ?? null;

		return {
			selectedChatId: row?.selectedChatId ?? null,
			selectedProjectId: row?.selectedProjectId ?? null,
			permissionMode,
			selectedModel,
			selectedReasoningEffort,
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
				permissionMode: selection.permissionMode,
				selectedModel: selection.selectedModel,
				selectedReasoningEffort: selection.selectedReasoningEffort,
				updatedAt: now,
			})
			.onConflictDoUpdate({
				target: workspaceSelection.id,
				set: {
					selectedChatId: selection.selectedChatId,
					selectedProjectId: selection.selectedProjectId,
					permissionMode: selection.permissionMode,
					selectedModel: selection.selectedModel,
					selectedReasoningEffort: selection.selectedReasoningEffort,
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
