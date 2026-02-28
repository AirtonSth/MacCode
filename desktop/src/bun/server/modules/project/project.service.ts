import { randomUUID } from "node:crypto";
import { existsSync, statSync } from "node:fs";
import { basename, isAbsolute, normalize, resolve } from "node:path";

import type { ProjectDTO } from "../../types";
import type { CreateProjectInput } from "./project.model";
import type { ProjectRepository } from "./project.repository";

const normalizeProjectPath = (value: string): string => normalize(resolve(value));

const isExistingDirectory = (value: string): boolean => {
	if (!isAbsolute(value) || !existsSync(value)) {
		return false;
	}

	return statSync(value).isDirectory();
};

export interface CreateProjectError {
	type: "invalid_path";
}

export interface CreateProjectResult {
	created: boolean;
	project: ProjectDTO;
}

export interface ProjectService {
	createProject: (
		input: CreateProjectInput,
	) => Promise<{ created: boolean; project: ProjectDTO; } | { type: "invalid_path" }>;
	getProjectById: (id: string) => Promise<ProjectDTO | null>;
	listProjects: () => Promise<ProjectDTO[]>;
	setFavorite: (id: string, isFavorite: boolean) => Promise<ProjectDTO | null>;
}

export const createProjectService = (repository: ProjectRepository): ProjectService => ({
		createProject: async ({ name, path }) => {
			const normalizedPath = normalizeProjectPath(path);

			if (!isExistingDirectory(normalizedPath)) {
				return { type: "invalid_path" };
			}

			const existing = await repository.findProjectByPath(normalizedPath);

			if (existing) {
				return {
					created: false,
					project: existing,
				};
			}

			const resolvedName = (name?.trim().length ? name.trim() : basename(normalizedPath)) || randomUUID();
			const project = await repository.createProject(normalizedPath, resolvedName);

			return {
				created: true,
				project,
			};
		},

		getProjectById: async (id) => repository.findProjectById(id),

		listProjects: async () => repository.listProjects(),

		setFavorite: async (id, isFavorite) => repository.updateProjectFavorite(id, isFavorite),
	});

export const createProjectServiceFromRepository = createProjectService;
