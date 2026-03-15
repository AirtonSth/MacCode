import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { initializeDatabaseSchema } from "../../shared/db/db.bootstrap";
import { createDatabaseClient } from "../../shared/db/db.client";
import { workspaceSelection } from "../../shared/db/db.schema";
import { createChatRepository } from "../chat/chat.repository";
import { createProjectRepository } from "../project/project.repository";
import { createSelectionRepository } from "./selection.repository";
import type { WorkspaceSelection } from "./selection.model";

const createSelectionFromRow = (row: {
	selectedProjectId: string | null;
	selectedChatId: string | null;
	permissionMode: "default" | "plan" | "full";
	selectedModel: string | null;
	selectedProvider?: "fake" | "codex" | "claude" | null;
	selectedReasoningEffort: "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | null;
}): WorkspaceSelection => ({
	selectedProjectId: row.selectedProjectId,
	selectedChatId: row.selectedChatId,
	permissionMode: row.permissionMode,
	selectedModel: row.selectedModel,
	selectedProvider: row.selectedProvider ?? null,
	selectedReasoningEffort: row.selectedReasoningEffort,
});

test("selection repository upserts one row and returns stored selection", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-selection-repository-save-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);

		const repository = createSelectionRepository(client.orm);
		const projectRepository = createProjectRepository(client.orm);
		const chatRepository = createChatRepository(client.orm);
		const project = await projectRepository.createProject("/tmp", "Project for selection");
		const chat = await chatRepository.createChat(project.id, "Chat for selection");

			const first = repository.saveWorkspaceSelection({
				selectedChatId: null,
				selectedProjectId: null,
				permissionMode: "default",
				selectedModel: null,
				selectedProvider: null,
				selectedReasoningEffort: null,
			});
			expect(first).toEqual(
				createSelectionFromRow({
					selectedProjectId: null,
					selectedChatId: null,
					permissionMode: "default",
					selectedModel: null,
					selectedReasoningEffort: null,
				}),
			);

			const second = repository.saveWorkspaceSelection({
				selectedProjectId: project.id,
				selectedChatId: null,
				permissionMode: "plan",
				selectedModel: "gpt-5.3-codex",
				selectedProvider: null,
				selectedReasoningEffort: "high",
			});
			expect(second.selectedProjectId).toBe(project.id);
			expect(second.permissionMode).toBe("plan");

			const third = repository.saveWorkspaceSelection({
				selectedProjectId: project.id,
				selectedChatId: chat.id,
				permissionMode: "full",
				selectedModel: "gpt-5.3-codex-spark",
				selectedProvider: null,
				selectedReasoningEffort: "xhigh",
			});
			expect(third).toEqual(
				createSelectionFromRow({
					selectedProjectId: project.id,
					selectedChatId: chat.id,
					permissionMode: "full",
					selectedModel: "gpt-5.3-codex-spark",
					selectedReasoningEffort: "xhigh",
				}),
			);

			const loaded = repository.getWorkspaceSelection();
			expect(loaded).toEqual(createSelectionFromRow({
				selectedProjectId: project.id,
				selectedChatId: chat.id,
				permissionMode: "full",
				selectedModel: "gpt-5.3-codex-spark",
				selectedReasoningEffort: "xhigh",
			}));

			const rows = client.orm.select().from(workspaceSelection).all() as {
				id: string;
				selectedChatId: string | null;
				selectedProjectId: string | null;
				permissionMode: string | null;
				selectedModel: string | null;
				selectedReasoningEffort: string | null;
			}[];

		expect(rows).toHaveLength(1);
			expect(rows[0]).toMatchObject({
				id: "default",
				selectedProjectId: project.id,
				selectedChatId: chat.id,
				permissionMode: "full",
				selectedModel: "gpt-5.3-codex-spark",
				selectedReasoningEffort: "xhigh",
			});
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("selection repository clears ids when selected project is deleted", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-selection-repository-cleanup-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);

		const projectRepository = createProjectRepository(client.orm);
		const chatRepository = createChatRepository(client.orm);
		const repository = createSelectionRepository(client.orm);

		const project = await projectRepository.createProject("/tmp", "Selected project");
		const chat = await chatRepository.createChat(project.id, "Selected thread");

			await repository.saveWorkspaceSelection({
				selectedProjectId: project.id,
				selectedChatId: chat.id,
				permissionMode: "plan",
				selectedModel: "gpt-5.3-codex",
				selectedProvider: null,
				selectedReasoningEffort: "medium",
			});

		projectRepository.deleteProject(project.id);

		const selection = await repository.getWorkspaceSelection();
			expect(selection).toEqual(
				createSelectionFromRow({
					selectedProjectId: null,
					selectedChatId: null,
					permissionMode: "plan",
					selectedModel: "gpt-5.3-codex",
					selectedReasoningEffort: "medium",
				}),
			);
		} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
