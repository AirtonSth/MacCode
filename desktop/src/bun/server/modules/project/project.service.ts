import { randomUUID } from "node:crypto";
import { existsSync, statSync } from "node:fs";
import { basename, isAbsolute, normalize, resolve } from "node:path";

import type { ProjectDTO, WorkspaceSummaryDTO } from "../../types";
import type { CreateProjectInput } from "./project.model";
import type { ProjectRepository } from "./project.repository";

export interface CreateProjectError {
	type: "invalid_path";
}

export interface CreateProjectResult {
	created: boolean;
	project: ProjectDTO;
}

export interface UpdateProjectInput {
	isFavorite?: boolean;
	name?: string;
}

export interface UpdateProjectError {
	type: "invalid_name";
}

export interface ProjectServiceContract {
	createProject: (
		input: CreateProjectInput,
	) => Promise<{ created: boolean; project: ProjectDTO } | { type: "invalid_path" }>;
	getProjectById: (id: string) => Promise<ProjectDTO | null>;
	listProjects: () => Promise<ProjectDTO[]>;
	listWorkspaceSummaries: () => Promise<WorkspaceSummaryDTO[]>;
	updateProject: (
		id: string,
		input: UpdateProjectInput,
	) => Promise<ProjectDTO | UpdateProjectError | null>;
	setFavorite: (id: string, isFavorite: boolean) => Promise<ProjectDTO | null>;
	deleteProject: (id: string) => Promise<boolean>;
}

export class ProjectService implements ProjectServiceContract {
	private static normalizeProjectPath(value: string): string {
		return normalize(resolve(value));
	}

	private static isExistingDirectory(value: string): boolean {
		if (!isAbsolute(value) || !existsSync(value)) {
			return false;
		}

		return statSync(value).isDirectory();
	}

	constructor(private readonly repository: ProjectRepository) {}

	async getProjectById(id: string): Promise<ProjectDTO | null> {
		return this.repository.findProjectById(id);
	}

	async createProject({
		name,
		path,
	}: CreateProjectInput): Promise<CreateProjectResult | CreateProjectError> {
		const normalizedPath = ProjectService.normalizeProjectPath(path);

		if (!ProjectService.isExistingDirectory(normalizedPath)) {
			return { type: "invalid_path" };
		}

		const existing = await this.repository.findProjectByPath(normalizedPath);

		if (existing) {
			return {
				created: false,
				project: existing,
			};
		}

		const resolvedName = (name?.trim().length ? name.trim() : basename(normalizedPath)) || randomUUID();
		const project = await this.repository.createProject(normalizedPath, resolvedName);

		return {
			created: true,
			project,
		};
	}

	async listProjects(): Promise<ProjectDTO[]> {
		return this.repository.listProjects();
	}

	async listWorkspaceSummaries(): Promise<WorkspaceSummaryDTO[]> {
		return this.repository.listWorkspaceSummaries();
	}

	async updateProject(id: string, input: UpdateProjectInput): Promise<ProjectDTO | UpdateProjectError | null> {
		let normalizedName: string | undefined;
		if (typeof input.name === "string") {
			const trimmedName = input.name.trim();
			if (trimmedName.length === 0) {
				return { type: "invalid_name" };
			}
			normalizedName = trimmedName;
		}

		return this.repository.updateProject(id, {
			isFavorite: input.isFavorite,
			name: normalizedName,
		});
	}

	async setFavorite(id: string, isFavorite: boolean): Promise<ProjectDTO | null> {
		return this.repository.updateProjectFavorite(id, isFavorite);
	}

	async deleteProject(id: string): Promise<boolean> {
		return this.repository.deleteProject(id);
	}
}

export const createProjectService = (repository: ProjectRepository) => new ProjectService(repository);

export const createProjectServiceFromRepository = createProjectService;
