import { expect, test } from "bun:test";

import type { WorkspaceSelection } from "./selection.model";
import type { WorkspaceSelectionRepository } from "./selection.repository";
import { WorkspaceSelectionService, createSelectionService, createWorkspaceSelectionService } from "./selection.service";

const createSelection = (input: {
	selectedProjectId: string | null;
	selectedChatId: string | null;
	permissionMode?: "default" | "plan" | "full";
	selectedModel?: string | null;
	selectedReasoningEffort?: "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | null;
}): WorkspaceSelection => ({
	selectedChatId: input.selectedChatId,
	selectedProjectId: input.selectedProjectId,
	permissionMode: input.permissionMode ?? "default",
	selectedModel: input.selectedModel ?? null,
	selectedReasoningEffort: input.selectedReasoningEffort ?? null,
});

test("Selection service loads workspace selection from repository", async () => {
	const expected = createSelection({
		selectedChatId: "chat-id",
		selectedProjectId: "project-id",
		permissionMode: "plan",
		selectedModel: "gpt-5.3-codex",
		selectedReasoningEffort: "high",
	});

	const repository = {
		getWorkspaceSelection: () => expected,
		saveWorkspaceSelection: () => expected,
	} as unknown as WorkspaceSelectionRepository;

	const service = new WorkspaceSelectionService(repository);
	const loaded = await service.getWorkspaceSelection();

	expect(loaded).toEqual(expected);
});

test("Selection service saves workspace selection through repository", async () => {
	const input = createSelection({
		selectedChatId: "thread-id",
		selectedProjectId: "project-id",
	});

	let saved: WorkspaceSelection | undefined;

		const repository = {
			getWorkspaceSelection: () =>
				createSelection({
					selectedChatId: null,
					selectedProjectId: null,
					permissionMode: "default",
					selectedModel: null,
					selectedReasoningEffort: null,
				}),
			saveWorkspaceSelection: (selection: WorkspaceSelection) => {
				saved = selection;

				return {
					selectedProjectId: selection.selectedProjectId,
					selectedChatId: selection.selectedChatId,
					permissionMode: selection.permissionMode,
					selectedModel: selection.selectedModel,
					selectedReasoningEffort: selection.selectedReasoningEffort,
				};
			},
		} as unknown as WorkspaceSelectionRepository;

	const service = new WorkspaceSelectionService(repository);
	const savedSelection = await service.saveWorkspaceSelection(input);

	expect(saved).toBeDefined();
	expect(saved).toEqual(input);
	expect(savedSelection).toEqual(input);
});

test("Selection service factory aliases preserve WorkspaceSelectionService contract", () => {
	const repository = {
		getWorkspaceSelection: () =>
			createSelection({
				selectedChatId: null,
				selectedProjectId: null,
				permissionMode: "default",
				selectedModel: null,
				selectedReasoningEffort: null,
			}),
		saveWorkspaceSelection: () =>
			createSelection({
				selectedChatId: null,
				selectedProjectId: null,
				permissionMode: "default",
				selectedModel: null,
				selectedReasoningEffort: null,
			}),
	} as unknown as WorkspaceSelectionRepository;

	const defaultFactory = createSelectionService(repository);
	const namedFactory = createWorkspaceSelectionService(repository);

	expect(defaultFactory).toBeInstanceOf(WorkspaceSelectionService);
	expect(namedFactory).toBeInstanceOf(WorkspaceSelectionService);
	expect(defaultFactory).toBeInstanceOf(Object.getPrototypeOf(namedFactory).constructor);
});
