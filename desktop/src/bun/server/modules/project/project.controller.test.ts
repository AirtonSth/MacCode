import { expect, test } from "bun:test";

import { createTestServer } from "../../shared/core/test-server";

const toAbsolutePath = (path: string) => path;

test("POST /v1/projects is idempotent by normalized path", async () => {
	const { cleanup, client } = await createTestServer();
	const absolutePath = toAbsolutePath("/tmp");

	try {
		const createResponse = await client.v1.projects.post({
			name: "tmp project",
			path: absolutePath,
		});
		const createdProject = createResponse.data as {
			created: boolean;
			project: { id: string; name: string; path: string };
		};

		expect(createResponse.status).toBe(201);
		expect(createdProject.created).toBe(true);
		expect(createdProject.project.name).toBe("tmp project");
		expect(createdProject.project.path).toBe(absolutePath);

		const idempotent = await client.v1.projects.post({
			path: `${absolutePath}/`,
		});
		const idempotentProject = (idempotent.data as { project: { id: string } }).project;

		expect(idempotent.status).toBe(200);
		expect(idempotent.data?.created).toBe(false);
		expect(idempotentProject.id).toBe(createdProject.project.id);
	} finally {
		await cleanup();
	}
});

test("PATCH /v1/projects/:id toggles favorite", async () => {
	const { cleanup, client } = await createTestServer();

	try {
		const created = await client.v1.projects.post({ path: "/tmp" });
		const createdProject = (created.data as { project: { id: string } }).project;

		expect(createdProject.id).toBeTruthy();

		const updated = await client.v1.projects({ id: createdProject.id }).patch({ isFavorite: true });
		const updatedProject = (updated.data as { project: { isFavorite: boolean } }).project;

		expect(updated.status).toBe(200);
		expect(updatedProject.isFavorite).toBe(true);
	} finally {
		await cleanup();
	}
});
