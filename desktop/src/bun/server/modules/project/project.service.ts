import { randomUUID } from "node:crypto";
import { existsSync, statSync } from "node:fs";
import { basename, isAbsolute, normalize, resolve } from "node:path";

import type { ProjectDTO } from "../../types";
import type { CreateProjectInput } from "./project.model";
import type { ProjectRepository } from "./project.repository";

export interface CreateProjectError {
	type: "invalid_path";
}

export interface CreateProjectResult {
	created: boolean;
	project: ProjectDTO;
}

export interface ProjectServiceContract {
	createProject: (
		input: CreateProjectInput,
	) => Promise<{ created: boolean; project: ProjectDTO } | { type: "invalid_path" }>;
	getProjectById: (id: string) => Promise<ProjectDTO | null>;
	listProjects: () => Promise<ProjectDTO[]>;
	setFavorite: (id: string, isFavorite: boolean) => Promise<ProjectDTO | null>;
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

	getProjectById(id: string): Promise<ProjectDTO | null> {
		return Promise.resolve(this.repository.findProjectById(id));
	}

	listProjects(): Promise<ProjectDTO[]> {
		return Promise.resolve(this.repository.listProjects());
	}

	setFavorite(id: string, isFavorite: boolean): Promise<ProjectDTO | null> {
		return Promise.resolve(this.repository.updateProjectFavorite(id, isFavorite));
	}
}

export const createProjectService = (repository: ProjectRepository) => new ProjectService(repository);

export const createProjectServiceFromRepository = createProjectService;
