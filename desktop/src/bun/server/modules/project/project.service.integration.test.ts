import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { initializeDatabaseSchema } from "../../shared/db/db.bootstrap";
import { createDatabaseClient } from "../../shared/db/db.client";
import { createProjectRepository } from "./project.repository";
import { createProjectService } from "./project.service";

test("project service normalizePath and create idempotent", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-project-service-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);

		const repository = createProjectRepository(client.orm);
		const service = createProjectService(repository);
		const first = await service.createProject({ name: "Test", path: "/tmp" });

		if ("type" in first) {
			throw new Error(`unexpected project service error: ${first.type}`);
		}

		expect(first.created).toBe(true);

		const second = await service.createProject({ name: "Test 2", path: "/tmp/" });

		if ("type" in second) {
			throw new Error(`unexpected project service error: ${second.type}`);
		}

		expect(second.created).toBe(false);
		expect(second.project.id).toBe(first.project.id);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});

test("project repository preserves normalized lookup and list order", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-project-service-list-"));
	const databasePath = join(root, "remodecode.sqlite");
	const client = await createDatabaseClient(databasePath);

	try {
		initializeDatabaseSchema(client.sqlite);

		const repository = createProjectRepository(client.orm);
		const service = createProjectService(repository);

		const createResult = await service.createProject({ path: "/tmp" });

		if ("type" in createResult) {
			throw new Error(`unexpected project service error: ${createResult.type}`);
		}

		const projects = await service.listProjects();

		expect(createResult.project.path).toBe("/tmp");
		expect(projects.map((project) => project.id)).toContain(createResult.project.id);
	} finally {
		client.close();
		rmSync(root, { force: true, recursive: true });
	}
});
