import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { initializeDatabaseSchema } from "../../shared/db/db.bootstrap";
import { createDatabaseClient } from "../../shared/db/db.client";
import { createChatRepository } from "../chat/chat.repository";
import { createProjectRepository } from "../project/project.repository";
import { createSelectionRepository } from "./selection.repository";
import { createSelectionService } from "./selection.service";

test("selection service persists and reads workspace selection", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-selection-service-integration-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);

		const repository = createSelectionRepository(client.orm);
		const projectRepository = createProjectRepository(client.orm);
		const chatRepository = createChatRepository(client.orm);
		const project = await projectRepository.createProject("/tmp", "Workspace");
		const chat = await chatRepository.createChat(project.id, "Thread");
		const service = createSelectionService(repository);

			const initial = await service.getWorkspaceSelection();
			expect(initial).toEqual({
				selectedProjectId: null,
				selectedChatId: null,
				permissionMode: "default",
				selectedModel: null,
				selectedProvider: null,
				selectedReasoningEffort: null,
			});

			const updated = await service.saveWorkspaceSelection({
				selectedProjectId: project.id,
				selectedChatId: chat.id,
				permissionMode: "plan",
				selectedModel: "gpt-5.3-codex",
				selectedProvider: "claude",
				selectedReasoningEffort: "high",
			});

			expect(updated).toEqual({
				selectedProjectId: project.id,
				selectedChatId: chat.id,
				permissionMode: "plan",
				selectedModel: "gpt-5.3-codex",
				selectedProvider: "claude",
				selectedReasoningEffort: "high",
			});

		const loaded = await service.getWorkspaceSelection();
		expect(loaded).toEqual(updated);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
