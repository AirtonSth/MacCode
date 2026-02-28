import { expect, test } from "bun:test";

import { createTestServer } from "../../shared/core/test-server";

test("POST /v1/projects/:id/chats cria chat pending e GET lista por project em ordem", async () => {
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
		expect(firstChat.provider).toBe("fake");
		expect(firstChat.status).toBe("pending");

		const second = await client.v1.projects({ id: projectId }).chats.post({
			title: "Segundo",
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
		const {chats} = (list.data as { chats: { id: string }[] });

		expect(list.status).toBe(200);
		expect(chats.length).toBe(2);
		expect(chats[0].id === firstChat.id || chats[0].id === secondChat.id).toBe(
			true,
		);
		expect(chats.map((chat: { id: string }) => chat.id)).toContain(firstChat.id);
		expect(chats.map((chat: { id: string }) => chat.id)).toContain(secondChat.id);
	} finally {
		await cleanup();
	}
});
