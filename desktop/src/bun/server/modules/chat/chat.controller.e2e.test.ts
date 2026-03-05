import { expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createBackendServer } from "../../app";
import { createEdenClient } from "../../eden-client";
import { createTestServer } from "../../shared/core/test-server";

const toPort = (server: unknown): number => {
	if (!server || typeof server !== "object") {
		return 3001;
	}

	return (server as { port?: number }).port ?? 3001;
};

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

test("server restart clears stale active/running chats when no codex run is actually running", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-chat-runtime-state-"));
	const databasePath = join(root, "remodecode.sqlite");
	const workspacePath = mkdtempSync(join(tmpdir(), "runtime-state-workspace-"));
	let firstServer:
		| Awaited<ReturnType<typeof createBackendServer>>
		| undefined;
	let secondServer:
		| Awaited<ReturnType<typeof createBackendServer>>
		| undefined;

	try {
		firstServer = await createBackendServer({ databasePath, port: 0 });
		const firstClient = createEdenClient({
			baseUrl: `http://127.0.0.1:${toPort(firstServer.server)}`,
		});

		const project = await firstClient.v1.projects.post({ path: workspacePath });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const createdChat = await firstClient.v1.projects({ id: projectId }).chats.post({
			title: "Should not stay active",
		});
		const chatId = (createdChat.data as { chat: { id: string } }).chat.id;

		const sqlite = new Database(databasePath);
		try {
			sqlite.prepare("UPDATE chats SET status = ?, isActive = ? WHERE id = ?").run("running", 1, chatId);
		} finally {
			sqlite.close();
		}

		await firstServer.app.stop(true);
		firstServer.db.close();
		firstServer = undefined;

		secondServer = await createBackendServer({ databasePath, port: 0 });
		const secondClient = createEdenClient({
			baseUrl: `http://127.0.0.1:${toPort(secondServer.server)}`,
		});

		const activeThreads = await secondClient.v1.threads.active.get();
		const activeThreadsPayload = activeThreads.data as {
			threads: Array<{ id: string }>;
		};
		expect(activeThreads.status).toBe(200);
		expect(activeThreadsPayload.threads.some((thread) => thread.id === chatId)).toBe(false);

		const context = await secondClient.v1.chats({ id: chatId }).context.get();
		const contextPayload = context.data as {
			chat: {
				id: string;
				isActive: boolean;
				status: "pending" | "running" | "completed" | "failed";
			};
		};
		expect(context.status).toBe(200);
		expect(contextPayload.chat.id).toBe(chatId);
		expect(contextPayload.chat.isActive).toBe(false);
		expect(contextPayload.chat.status).toBe("failed");
	} finally {
		if (firstServer) {
			await firstServer.app.stop(true);
			firstServer.db.close();
		}
		if (secondServer) {
			await secondServer.app.stop(true);
			secondServer.db.close();
		}
		rmSync(root, { force: true, recursive: true });
		rmSync(workspacePath, { force: true, recursive: true });
	}
});

test("GET /v1/projects/:id/threads returns lightweight thread summaries", async () => {
	const { cleanup, client } = await createTestServer();

	try {
		const project = await client.v1.projects.post({ path: "/tmp" });
		const projectId = (project.data as { project: { id: string } }).project.id;

		await client.v1.projects({ id: projectId }).chats.post({ title: "First" });
		await client.v1.projects({ id: projectId }).chats.post({ title: "Second" });

		const list = await client.v1.projects({ id: projectId }).threads.get();
		const payload = list.data as { threads: Array<{ id: string; isActive: boolean; title: string; updatedAt: string }> };

		expect(list.status).toBe(200);
		expect(payload.threads.length).toBe(2);
		for (const thread of payload.threads) {
			expect(Object.keys(thread as unknown as Record<string, unknown>).sort()).toEqual(["id", "isActive", "title", "updatedAt"]);
		}
	} finally {
		await cleanup();
	}
});

test("GET /v1/threads/active returns only active threads across workspaces", async () => {
	const { cleanup, client, databasePath } = await createTestServer();
	const sqlite = new Database(databasePath);
	const firstWorkspacePath = mkdtempSync(join(tmpdir(), "active-threads-first-"));
	const secondWorkspacePath = mkdtempSync(join(tmpdir(), "active-threads-second-"));

	try {
		const firstProject = await client.v1.projects.post({ path: firstWorkspacePath });
		const secondProject = await client.v1.projects.post({ path: secondWorkspacePath });
		const firstProjectId = (firstProject.data as { project: { id: string } }).project.id;
		const secondProjectId = (secondProject.data as { project: { id: string } }).project.id;

		const firstChat = await client.v1.projects({ id: firstProjectId }).chats.post({ title: "First Active" });
		const secondChat = await client.v1.projects({ id: secondProjectId }).chats.post({ title: "Second Idle" });
		const firstChatId = (firstChat.data as { chat: { id: string } }).chat.id;
		const secondChatId = (secondChat.data as { chat: { id: string } }).chat.id;

		sqlite
			.prepare("UPDATE chats SET status = ?, isActive = ?, updatedAt = ? WHERE id = ?")
			.run("running", 1, "2026-01-01T00:00:02.000Z", firstChatId);
		sqlite
			.prepare("UPDATE chats SET status = ?, isActive = ?, updatedAt = ? WHERE id = ?")
			.run("completed", 0, "2026-01-01T00:00:01.000Z", secondChatId);

		const response = await client.v1.threads.active.get();
		const payload = response.data as {
			threads: Array<{
				id: string;
				projectId: string;
				projectName: string;
				title: string;
				updatedAt: string;
			}>;
		};

		expect(response.status).toBe(200);
		expect(payload.threads).toHaveLength(1);
		expect(payload.threads[0]).toEqual(
			expect.objectContaining({
				id: firstChatId,
				projectId: firstProjectId,
				title: "First Active",
			}),
		);
	} finally {
		sqlite.close();
		rmSync(firstWorkspacePath, { force: true, recursive: true });
		rmSync(secondWorkspacePath, { force: true, recursive: true });
		await cleanup();
	}
});

test("GET /v1/threads/active/runtime uses server runtime as source of truth", async () => {
	const { cleanup, client, databasePath } = await createTestServer();
	const sqlite = new Database(databasePath);
	const workspacePath = mkdtempSync(join(tmpdir(), "runtime-active-threads-workspace-"));

	try {
		const project = await client.v1.projects.post({ path: workspacePath });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const createdChat = await client.v1.projects({ id: projectId }).chats.post({ title: "stale runtime active" });
		const chatId = (createdChat.data as { chat: { id: string } }).chat.id;

		sqlite
			.prepare("UPDATE chats SET status = ?, isActive = ?, updatedAt = ? WHERE id = ?")
			.run("running", 1, "2026-01-01T00:00:10.000Z", chatId);

		const databaseActive = await client.v1.threads.active.get();
		const databasePayload = databaseActive.data as { threads: Array<{ id: string }> };
		expect(databaseActive.status).toBe(200);
		expect(databasePayload.threads.some((thread) => thread.id === chatId)).toBe(true);

		const runtimeActive = await client.v1.threads.active.runtime.get();
		const runtimePayload = runtimeActive.data as { threads: Array<{ id: string }> };
		expect(runtimeActive.status).toBe(200);
		expect(runtimePayload.threads).toEqual([]);
	} finally {
		sqlite.close();
		rmSync(workspacePath, { force: true, recursive: true });
		await cleanup();
	}
});

test("POST /v1/chats/:id/stop clears stale active thread state", async () => {
	const { cleanup, client, databasePath } = await createTestServer();
	const sqlite = new Database(databasePath);
	const workspacePath = mkdtempSync(join(tmpdir(), "runtime-stop-thread-workspace-"));

	try {
		const project = await client.v1.projects.post({ path: workspacePath });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const createdChat = await client.v1.projects({ id: projectId }).chats.post({ title: "stale-stop" });
		const chatId = (createdChat.data as { chat: { id: string } }).chat.id;

		sqlite
			.prepare("UPDATE chats SET status = ?, isActive = ?, updatedAt = ? WHERE id = ?")
			.run("running", 1, "2026-01-01T00:00:10.000Z", chatId);

		const stopResponse = await client.v1.chats({ id: chatId }).stop.post({});
		const stopPayload = stopResponse.data as {
			chat: { id: string; isActive: boolean; status: "pending" | "running" | "completed" | "failed" } | null;
			state: "not_running" | "stale_cleared" | "stopping";
			stopped: boolean;
		};

		expect(stopResponse.status).toBe(200);
		expect(stopPayload.state).toBe("stale_cleared");
		expect(stopPayload.stopped).toBe(true);
		expect(stopPayload.chat).toEqual(
			expect.objectContaining({
				id: chatId,
				isActive: false,
				status: "failed",
			}),
		);

		const context = await client.v1.chats({ id: chatId }).context.get();
		const contextPayload = context.data as {
			chat: {
				id: string;
				isActive: boolean;
				status: "pending" | "running" | "completed" | "failed";
			};
		};

		expect(context.status).toBe(200);
		expect(contextPayload.chat.id).toBe(chatId);
		expect(contextPayload.chat.isActive).toBe(false);
		expect(contextPayload.chat.status).toBe("failed");
	} finally {
		sqlite.close();
		rmSync(workspacePath, { force: true, recursive: true });
		await cleanup();
	}
});

test("POST /v1/chats/:id/stop returns 404 for missing chat", async () => {
	const { cleanup, client } = await createTestServer();

	try {
		const response = await client.v1.chats({ id: "missing-chat" }).stop.post({});
		const errorPayload = response.error && "value" in response.error
			? (response.error as { value: { error?: string } }).value
			: undefined;

		expect(response.status).toBe(404);
		expect(errorPayload?.error).toBe("chat not found");
	} finally {
		await cleanup();
	}
});

test("GET /v1/chats/:id/context returns chat and project context", async () => {
	const { cleanup, client } = await createTestServer();

	try {
		const project = await client.v1.projects.post({ path: "/tmp" });
		const projectPayload = (project.data as { project: { id: string; name: string; path: string } }).project;
		const createdChat = await client.v1.projects({ id: projectPayload.id }).chats.post({ title: "Context" });
		const chatId = (createdChat.data as { chat: { id: string } }).chat.id;

		const context = await client.v1.chats({ id: chatId }).context.get();
		const contextPayload = context.data as {
			chat: {
				id: string;
				projectId: string;
				title: string;
			};
			project: {
				id: string;
				name: string;
				path: string;
			};
		};

		expect(context.status).toBe(200);
		expect(contextPayload.chat.id).toBe(chatId);
		expect(contextPayload.chat.projectId).toBe(projectPayload.id);
		expect(contextPayload.project).toEqual({
			id: projectPayload.id,
			name: projectPayload.name,
			path: projectPayload.path,
		});
	} finally {
		await cleanup();
	}
});

test("GET /v1/chats/:id/context returns 404 for missing chat", async () => {
	const { cleanup, client } = await createTestServer();

	try {
		const response = await client.v1.chats({ id: "missing-chat" }).context.get();
		const errorPayload = response.error && "value" in response.error
			? (response.error as { value: { error?: string } }).value
			: undefined;

		expect(response.status).toBe(404);
		expect(errorPayload?.error).toBe("chat not found");
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
