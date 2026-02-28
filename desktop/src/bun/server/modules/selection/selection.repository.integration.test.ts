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

const createSelectionFromRow = (row: {
	selectedProjectId: string | null;
	selectedChatId: string | null;
}) => ({ ...row });

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
		});
		expect(first).toEqual(createSelectionFromRow({ selectedProjectId: null, selectedChatId: null }));

		const second = repository.saveWorkspaceSelection({
			selectedProjectId: project.id,
			selectedChatId: null,
		});
		expect(second.selectedProjectId).toBe(project.id);

		const third = repository.saveWorkspaceSelection({
			selectedProjectId: project.id,
			selectedChatId: chat.id,
		});
		expect(third).toEqual(
			createSelectionFromRow({
				selectedProjectId: project.id,
				selectedChatId: chat.id,
			}),
		);

		const loaded = repository.getWorkspaceSelection();
		expect(loaded).toEqual(createSelectionFromRow({
			selectedProjectId: project.id,
			selectedChatId: chat.id,
		}));

		const rows = client.orm.select().from(workspaceSelection).all() as {
			id: string;
			selectedChatId: string | null;
			selectedProjectId: string | null;
		}[];

		expect(rows).toHaveLength(1);
		expect(rows[0]).toMatchObject({
			id: "default",
			selectedProjectId: project.id,
			selectedChatId: chat.id,
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
		});

		projectRepository.deleteProject(project.id);

		const selection = await repository.getWorkspaceSelection();
		expect(selection).toEqual(createSelectionFromRow({ selectedProjectId: null, selectedChatId: null }));
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
