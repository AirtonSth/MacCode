import { randomUUID } from "node:crypto";

import { desc, eq } from "drizzle-orm";

import type { DrizzleDatabaseClient } from "../../shared/db/db.client";
import { projects } from "../../shared/db/db.schema";
import type { ProjectDTO } from "../../types";

const toBoolean = (value: number | boolean | null | undefined): boolean => {
	if (value === true) {
		return true;
	}

	if (value === 1) {
		return true;
	}

	return false;
};

const toProjectDto = (row: typeof projects.$inferSelect): ProjectDTO => ({
	createdAt: row.createdAt,
	id: row.id,
	isFavorite: toBoolean(row.isFavorite as number | boolean | null | undefined),
	name: row.name,
	path: row.path,
	updatedAt: row.updatedAt,
});

export const createProjectRepository = (databaseClient: DrizzleDatabaseClient["orm"]) => {
	const database = databaseClient;

	return {
		createProject: (path: string, name: string) => {
			const now = new Date().toISOString();
			const id = randomUUID();

			database.insert(projects).values({
				createdAt: now,
				id,
				isFavorite: 0,
				name,
				path,
				updatedAt: now,
			}).run();

			const rows = database
				.select()
				.from(projects)
				.where(eq(projects.id, id))
				.all() as typeof projects.$inferSelect[];

			return toProjectDto(rows[0]);
		},

		findProjectById: (id: string) => {
			const rows = database
				.select()
				.from(projects)
				.where(eq(projects.id, id))
				.all() as typeof projects.$inferSelect[];

			return rows[0] ? toProjectDto(rows[0]) : null;
		},

		findProjectByPath: (path: string) => {
			const rows = database
				.select()
				.from(projects)
				.where(eq(projects.path, path))
				.all() as typeof projects.$inferSelect[];

			return rows[0] ? toProjectDto(rows[0]) : null;
		},

		listProjects: () => {
			const rows = database.select().from(projects).orderBy(desc(projects.updatedAt)).all() as typeof projects.$inferSelect[];

			return rows.map(toProjectDto);
		},

		updateProjectFavorite: (id: string, isFavorite: boolean) => {
			database
				.update(projects)
				.set({ isFavorite: isFavorite ? 1 : 0, updatedAt: new Date().toISOString() })
				.where(eq(projects.id, id))
				.run();

			const rows = database
				.select()
				.from(projects)
				.where(eq(projects.id, id))
				.all() as typeof projects.$inferSelect[];

			if (rows.length === 0) {
				return null;
			}

			return toProjectDto(rows[0]);
		},
	};
};

export type ProjectRepository = ReturnType<typeof createProjectRepository>;
