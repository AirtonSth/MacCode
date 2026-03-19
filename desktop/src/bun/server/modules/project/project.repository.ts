import { randomUUID } from "node:crypto";

import { desc, eq } from "drizzle-orm";

import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { projects } from "../../shared/db/db.schema";
import type { ProjectDTO, WorkspaceSummaryDTO } from "../../types";

export class ProjectRepository {
	private static toBoolean(value: number | boolean | null | undefined): boolean {
		if (value === true) {
			return true;
		}

		if (value === 1) {
			return true;
		}

		return false;
	}

	private static toProjectDto(row: typeof projects.$inferSelect): ProjectDTO {
		return {
			createdAt: row.createdAt,
			id: row.id,
			isFavorite: ProjectRepository.toBoolean(row.isFavorite as number | boolean | null | undefined),
			name: row.name,
			path: row.path,
			unreadFinishedThreadCount: 0,
			updatedAt: row.updatedAt,
		};
	}

	private static toWorkspaceSummaryDto(row: {
		id: string;
		name: string;
		path: string;
	}): WorkspaceSummaryDTO {
		return {
			id: row.id,
			name: row.name,
			path: row.path,
		};
	}

	private readonly database: DrizzleDatabaseClient["orm"];

	constructor(databaseClient: DrizzleDatabaseClient["orm"]) {
		this.database = databaseClient;
	}

	createProject(path: string, name: string): ProjectDTO {
		const now = new Date().toISOString();
		const id = randomUUID();

		this.database
			.insert(projects)
			.values({
				createdAt: now,
				id,
				isFavorite: 0,
				name,
				path,
				updatedAt: now,
			})
			.run();

		const rows = this.database
			.select()
			.from(projects)
			.where(eq(projects.id, id))
			.all() as typeof projects.$inferSelect[];

		return ProjectRepository.toProjectDto(rows[0]);
	}

	findProjectById(id: string): ProjectDTO | null {
		const rows = this.database
			.select()
			.from(projects)
			.where(eq(projects.id, id))
			.all() as typeof projects.$inferSelect[];

		return rows[0] ? ProjectRepository.toProjectDto(rows[0]) : null;
	}

	deleteProject(id: string): boolean {
		const result = this.database.delete(projects).where(eq(projects.id, id)).run() as unknown as {
			changes?: number;
		};

		return (result.changes ?? 0) > 0;
	}

	findProjectByPath(path: string): ProjectDTO | null {
		const rows = this.database
			.select()
			.from(projects)
			.where(eq(projects.path, path))
			.all() as typeof projects.$inferSelect[];

		return rows[0] ? ProjectRepository.toProjectDto(rows[0]) : null;
	}

	listProjects(): ProjectDTO[] {
		const rows = this.database
			.select()
			.from(projects)
			.orderBy(desc(projects.updatedAt))
			.all() as typeof projects.$inferSelect[];

		return rows.map(ProjectRepository.toProjectDto);
	}

	listWorkspaceSummaries(): WorkspaceSummaryDTO[] {
		const rows = this.database
			.select({
				id: projects.id,
				name: projects.name,
				path: projects.path,
			})
			.from(projects)
			.orderBy(desc(projects.updatedAt))
			.all() as Array<{
				id: string;
				name: string;
				path: string;
			}>;

		return rows.map(ProjectRepository.toWorkspaceSummaryDto);
	}

	updateProject(
		id: string,
		input: {
			isFavorite?: boolean;
			name?: string;
		},
	): ProjectDTO | null {
		const now = new Date().toISOString();
		const updatePayload: {
			isFavorite?: number;
			name?: string;
			updatedAt: string;
		} = {
			updatedAt: now,
		};

		if (typeof input.isFavorite === "boolean") {
			updatePayload.isFavorite = input.isFavorite ? 1 : 0;
		}

		if (typeof input.name === "string") {
			updatePayload.name = input.name;
		}

		this.database
			.update(projects)
			.set(updatePayload)
			.where(eq(projects.id, id))
			.run();

		const rows = this.database
			.select()
			.from(projects)
			.where(eq(projects.id, id))
			.all() as typeof projects.$inferSelect[];

		if (rows.length === 0) {
			return null;
		}

		return ProjectRepository.toProjectDto(rows[0]);
	}

	updateProjectFavorite(id: string, isFavorite: boolean): ProjectDTO | null {
		return this.updateProject(id, { isFavorite });
	}
}

export const createProjectRepository = (databaseClient: DrizzleDatabaseClient["orm"]) =>
	new ProjectRepository(databaseClient);
