import { appendFileSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import type { ProjectDTO } from "../../types";
import type { ProjectRepository } from "./project.repository";
import { ProjectService } from "./project.service";

const createMemoryProject = (id: string, path: string): ProjectDTO => {
	const now = new Date().toISOString();
	return {
		createdAt: now,
		id,
		isFavorite: false,
		name: `project-${id}`,
		path,
		updatedAt: now,
	};
};

const createProject = (id: string, path: string, name = `project-${id}`): ProjectDTO => {
	const now = new Date().toISOString();
	return {
		createdAt: now,
		id,
		isFavorite: false,
		name,
		path,
		updatedAt: now,
	};
};

test("ProjectService.createProject normalizes and rejects invalid paths", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-project-service-unit-"));
	const validDirectory = join(root, "repo");
	const invalidDirectory = join(root, "not-a-directory");

	mkdirSync(validDirectory);
	appendFileSync(invalidDirectory, "not a directory");

	const existingPath = join(root, "existing");

	mkdirSync(existingPath);

	const normalizedExisting = join(existingPath, "..", "existing", ".");

	const repo = {
		createProject: (path: string, name: string): ProjectDTO =>
			createProject("created-id", path, name),

		findProjectById: () => null,

		findProjectByPath: (path: string) =>
			path === normalizedExisting ? createProject("existing-id", normalizedExisting) : null,

		listProjects: () => [],
		updateProjectFavorite: () => null,
	} as unknown as ProjectRepository;

	const service = new ProjectService(repo);

	const relativePath = await service.createProject({
		path: join("relative", "folder"),
	});

	expect(relativePath).toEqual({ type: "invalid_path" });

	const notDirectory = await service.createProject({
		path: invalidDirectory,
	});

	expect(notDirectory).toEqual({ type: "invalid_path" });

	const invalid = await service.createProject({ path: "/invalid/dir/does-not-exist" });

	expect(invalid).toEqual({ type: "invalid_path" });

	const existing = await service.createProject({ path: `${normalizedExisting  }/../existing` });

	expect(existing).toEqual({
		created: false,
		project: createMemoryProject("existing-id", normalizedExisting),
	});

	const created = await service.createProject({ name: "repo", path: validDirectory });

	expect(created).toEqual({
		created: true,

		project: expect.objectContaining({
			name: "repo",
			path: validDirectory,
		}),
	});

	rmSync(root, { force: true, recursive: true });
});

	test("ProjectService listProjects and setFavorite delegate to repository", async () => {
	const repo = {
		createProject: () => null,
		findProjectById: () => createMemoryProject("project-id", "/tmp"),
		findProjectByPath: () => null,

		listProjects: () => [
			createMemoryProject("first", "/tmp/first"),
			createMemoryProject("second", "/tmp/second"),
		],

		updateProjectFavorite: (id: string, isFavorite: boolean) =>
			({
				...createMemoryProject(id, "/tmp/updated"),
				isFavorite,
			}),
	} as unknown as ProjectRepository;
	const service = new ProjectService(repo);

	const projects = await service.listProjects();
	const updated = await service.setFavorite("project-id", true);

	expect(projects).toHaveLength(2);
	expect(updated?.id).toBe("project-id");
	expect(updated?.isFavorite).toBe(true);

	const byId = await service.getProjectById("project-id");

	expect(byId?.id).toBe("project-id");
});
