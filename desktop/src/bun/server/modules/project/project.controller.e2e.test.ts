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

test("DELETE /v1/projects/:id deletes project and its data", async () => {
	const { cleanup, client } = await createTestServer();

	try {
		const create = await client.v1.projects.post({ path: "/tmp" });
		const project = (create.data as { project: { id: string } }).project;

		const createdChat = await client.v1.projects({ id: project.id }).chats.post({
			title: "Thread to delete later",
		});
		const chatId = (createdChat.data as { chat: { id: string } }).chat.id;
		expect(chatId).toBeTruthy();

		const deleted = await client.v1.projects({ id: project.id }).delete();
		const payload = deleted.data as { deleted: boolean };

		expect(deleted.status).toBe(200);
		expect(payload.deleted).toBe(true);

		const projects = await client.v1.projects.get();
		const projectList = (projects.data as { projects: { id: string }[] }).projects;
		expect(projectList.some((item) => item.id === project.id)).toBe(false);

		const chats = await client.v1.projects({ id: project.id }).chats.get();
		const errorPayload = chats.error && "value" in chats.error ? (chats.error as { value: { error?: string } }).value : undefined;

		expect(chats.status).toBe(404);
		expect(errorPayload?.error).toBe("project not found");

		const deletedChat = await client.v1.chats({ id: chatId }).delete();
		const chatPayload = deletedChat.data as { deleted: boolean };

		expect(deletedChat.status).toBe(404);
		expect(chatPayload?.deleted).toBeUndefined();
	} finally {
		await cleanup();
	}
});

test("DELETE /v1/projects/:id returns 404 for missing project", async () => {
	const { cleanup, client } = await createTestServer();

	try {
		const response = await client.v1.projects({ id: "missing-project" }).delete();
		const errorPayload = response.error && "value" in response.error
			? (response.error as { value: { error?: string } }).value
			: undefined;

		expect(response.status).toBe(404);
		expect(errorPayload?.error).toBe("project not found");
	} finally {
		await cleanup();
	}
});
