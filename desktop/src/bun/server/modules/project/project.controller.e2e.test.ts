import { expect, test } from "bun:test";

import { createTestServer } from "../../shared/core/test-server";

test("POST /v1/projects is idempotent by normalized path", async () => {
	const { cleanup, client } = await createTestServer();

	try {
		const createResponse = await client.v1.projects.post({
			name: "tmp project",
			path: "/tmp",
		});
		const createdProject = createResponse.data as {
			created: boolean;
			project: { id: string; name: string; path: string };
		};

		expect(createResponse.status).toBe(201);
		expect(createdProject.created).toBe(true);
		expect(createdProject.project.name).toBe("tmp project");

		const idempotent = await client.v1.projects.post({
			path: "/tmp/",
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
		const createdProject = (created.data as { project: { id: string; isFavorite: boolean } }).project;

		expect(createdProject.id).toBeTruthy();

		const updated = await client.v1.projects({ id: createdProject.id }).patch({ isFavorite: true });
		const updatedProject = (updated.data as { project: { isFavorite: boolean } }).project;

		expect(updated.status).toBe(200);
		expect(updatedProject.isFavorite).toBe(true);

		const toggled = await client.v1.projects({ id: createdProject.id }).patch({ isFavorite: false });
		const toggledProject = (toggled.data as { project: { isFavorite: boolean } }).project;

		expect(toggled.status).toBe(200);
		expect(toggledProject.isFavorite).toBe(false);
	} finally {
		await cleanup();
	}
});

test("POST /v1/projects returns 400 for invalid path", async () => {
	const { cleanup, client } = await createTestServer();

	try {
		const response = await client.v1.projects.post({
			name: "invalid project",
			path: "/tmp/does-not-exist",
		});
		const errorPayload = response.error && "value" in response.error ? (response.error as { value: { error?: string } }).value : undefined;

		expect(response.status).toBe(400);
		expect(errorPayload?.error).toBe("path must be an existing absolute directory");
	} finally {
		await cleanup();
	}
});
