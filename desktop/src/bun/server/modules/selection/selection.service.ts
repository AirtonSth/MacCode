import type { WorkspaceSelection, WorkspaceSelectionInput } from "./selection.model";
import { WorkspaceSelectionRepository } from "./selection.repository";

export interface WorkspaceSelectionServiceContract {
	getWorkspaceSelection: () => Promise<WorkspaceSelection>;
	saveWorkspaceSelection: (input: WorkspaceSelectionInput) => Promise<WorkspaceSelection>;
}

export class WorkspaceSelectionService implements WorkspaceSelectionServiceContract {
	constructor(private readonly repository: WorkspaceSelectionRepository) {}

	getWorkspaceSelection(): Promise<WorkspaceSelection> {
		return Promise.resolve(this.repository.getWorkspaceSelection());
	}

	saveWorkspaceSelection(input: WorkspaceSelectionInput): Promise<WorkspaceSelection> {
		return Promise.resolve(this.repository.saveWorkspaceSelection(input));
	}
}

export const createWorkspaceSelectionService = (repository: WorkspaceSelectionRepository) =>
	new WorkspaceSelectionService(repository);

export const createSelectionService = (repository: WorkspaceSelectionRepository) =>
	createWorkspaceSelectionService(repository);
