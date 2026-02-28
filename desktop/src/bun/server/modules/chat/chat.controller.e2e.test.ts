import { expect, test } from "bun:test";

import { createTestServer } from "../../shared/core/test-server";

test("POST /v1/projects/:id/chats creates pending chat and lists by project order", async () => {
	const { cleanup, client } = await createTestServer();

	try {
		const project = await client.v1.projects.post({ path: "/tmp" });
		const projectId = (project.data as { project: { id: string } }).project.id;

		expect(projectId).toBeTruthy();

		const first = await client.v1.projects({ id: projectId }).chats.post({});
		const firstChat = (first.data as {
			chat: {
				diffAdded: number;
				diffRemoved: number;
				id: string;
				projectId: string;
				provider: string;
				status: "pending" | "running" | "completed" | "failed";
				title: string;
				updatedAt: string;
			};
		}).chat;

		expect(first.status).toBe(201);
		expect(firstChat.provider).toBe("codex");
		expect(firstChat.status).toBe("pending");

		const second = await client.v1.projects({ id: projectId }).chats.post({
			title: "Second",
		});
		const secondChat = (second.data as {
			chat: {
				diffAdded: number;
				diffRemoved: number;
				id: string;
				projectId: string;
				provider: string;
				status: "pending" | "running" | "completed" | "failed";
				title: string;
				updatedAt: string;
			};
		}).chat;

		expect(second.status).toBe(201);
		expect(secondChat.status).toBe("pending");

		const list = await client.v1.projects({ id: projectId }).chats.get();
		const { chats } = (list.data as { chats: { id: string }[] });

		expect(list.status).toBe(200);
		expect(chats.length).toBe(2);
		expect(chats).toContainEqual(expect.objectContaining({ id: firstChat.id }));
		expect(chats).toContainEqual(expect.objectContaining({ id: secondChat.id }));
	} finally {
		await cleanup();
	}
});

test("POST /v1/projects/:id/chats returns 404 for missing project", async () => {
	const { cleanup, client } = await createTestServer();

	try {
		const response = await client.v1.projects({ id: "non-existing" }).chats.post({ title: "missing project" });
		const errorPayload = response.error && "value" in response.error ? (response.error as { value: { error?: string } }).value : undefined;

		expect(response.status).toBe(404);
		expect(errorPayload?.error).toBe("project not found");
	} finally {
		await cleanup();
	}
});

test("DELETE /v1/chats/:id deletes thread", async () => {
	const { cleanup, client } = await createTestServer();

	try {
		const project = await client.v1.projects.post({ path: "/tmp" });
		const projectId = (project.data as { project: { id: string } }).project.id;

		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "temporary thread" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		const deleted = await client.v1.chats({ id: chatId }).delete();
		const deletePayload = deleted.data as { deleted: boolean };

		expect(deleted.status).toBe(200);
		expect(deletePayload.deleted).toBe(true);

		const list = await client.v1.projects({ id: projectId }).chats.get();
		const chatList = (list.data as { chats: { id: string }[] }).chats;
		expect(chatList.some((item) => item.id === chatId)).toBe(false);
	} finally {
		await cleanup();
	}
});

test("DELETE /v1/chats/:id returns 404 for missing chat", async () => {
	const { cleanup, client } = await createTestServer();

	try {
		const response = await client.v1.chats({ id: "missing-chat" }).delete();
		const errorPayload = response.error && "value" in response.error
			? (response.error as { value: { error?: string } }).value
			: undefined;

		expect(response.status).toBe(404);
		expect(errorPayload?.error).toBe("chat not found");
	} finally {
		await cleanup();
	}
});
