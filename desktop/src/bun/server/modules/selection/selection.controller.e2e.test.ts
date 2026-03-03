import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { createBackendServer } from "../../app";
import { createEdenClient } from "../../eden-client";

const toPort = (server: unknown): number => {
	if (!server || typeof server !== "object") {
		return 3001;
	}

	return (server as { port?: number }).port ?? 3001;
};

test("selection persists across server restarts with shared sqlite", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-selection-persistence-"));
	const databasePath = join(root, "remodecode.sqlite");

	let firstServer:
		| Awaited<ReturnType<typeof createBackendServer>>
		| undefined;
	let secondServer:
		| Awaited<ReturnType<typeof createBackendServer>>
		| undefined;

	try {
		firstServer = await createBackendServer({ databasePath, port: 0 });

		const firstBaseUrl = `http://127.0.0.1:${toPort(firstServer.server)}`;
		const firstClient = createEdenClient({ baseUrl: firstBaseUrl });

		const project = await firstClient.v1.projects.post({ path: "/tmp" });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await firstClient.v1.projects({ id: projectId }).chats.post({ title: "Saved thread" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		const updated = await firstClient.v1.selection.patch({
			selectedChatId: chatId,
			selectedProjectId: projectId,
			permissionMode: "plan",
			selectedModel: "gpt-5.3-codex",
			selectedReasoningEffort: "high",
		});
		const saved = updated.data as {
			selectedProjectId: string | null;
			selectedChatId: string | null;
			permissionMode: string;
			selectedModel: string | null;
			selectedReasoningEffort: string | null;
		};

		expect(updated.status).toBe(200);
		expect(saved.selectedProjectId).toBe(projectId);
		expect(saved.selectedChatId).toBe(chatId);
		expect(saved.permissionMode).toBe("plan");
		expect(saved.selectedModel).toBe("gpt-5.3-codex");
		expect(saved.selectedReasoningEffort).toBe("high");

		await firstServer.app.stop(true);
		firstServer.db.close();
		firstServer = undefined;

		secondServer = await createBackendServer({ databasePath, port: 0 });
		const secondBaseUrl = `http://127.0.0.1:${toPort(secondServer.server)}`;
		const secondClient = createEdenClient({ baseUrl: secondBaseUrl });
		const restored = await secondClient.v1.selection.get();
		const loaded = restored.data as {
			selectedProjectId: string | null;
			selectedChatId: string | null;
			permissionMode: string;
			selectedModel: string | null;
			selectedReasoningEffort: string | null;
		};

		expect(restored.status).toBe(200);
		expect(loaded.selectedProjectId).toBe(projectId);
		expect(loaded.selectedChatId).toBe(chatId);
		expect(loaded.permissionMode).toBe("plan");
		expect(loaded.selectedModel).toBe("gpt-5.3-codex");
		expect(loaded.selectedReasoningEffort).toBe("high");
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
	}
});

test("PATCH /v1/selection requires project when chat is selected", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-selection-invalid-"));
	const databasePath = join(root, "remodecode.sqlite");
	let server:
		| Awaited<ReturnType<typeof createBackendServer>>
		| undefined;

	try {
		server = await createBackendServer({ databasePath, port: 0 });
		const client = createEdenClient({ baseUrl: `http://127.0.0.1:${toPort(server.server)}` });

		const invalid = await client.v1.selection.patch({
			selectedChatId: "orphan-chat",
			selectedProjectId: null,
		});
		const errorPayload =
			invalid.error && "value" in invalid.error ? (invalid.error as { value: { error?: string } }).value : undefined;

		expect(invalid.status).toBe(400);
		expect(errorPayload?.error).toBe("selectedChatId requires a selectedProjectId");
	} finally {
		if (server) {
			await server.app.stop(true);
			server.db.close();
		}
		rmSync(root, { force: true, recursive: true });
	}
});

test("deleting a selected thread clears selectedChatId in sqlite", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-selection-delete-thread-"));
	const databasePath = join(root, "remodecode.sqlite");
	let server:
		| Awaited<ReturnType<typeof createBackendServer>>
		| undefined;

	try {
		server = await createBackendServer({ databasePath, port: 0 });
		const client = createEdenClient({ baseUrl: `http://127.0.0.1:${toPort(server.server)}` });

		const project = await client.v1.projects.post({ path: "/tmp" });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "Thread to clear" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		const persisted = await client.v1.selection.patch({
			selectedProjectId: projectId,
			selectedChatId: chatId,
			permissionMode: "full",
			selectedModel: "gpt-5.3-codex-spark",
			selectedReasoningEffort: "xhigh",
		});
		const selectionBefore = persisted.data as {
			selectedProjectId: string | null;
			selectedChatId: string | null;
			permissionMode: string;
			selectedModel: string | null;
			selectedReasoningEffort: string | null;
		};
		expect(persisted.status).toBe(200);
		expect(selectionBefore.selectedChatId).toBe(chatId);
		expect(selectionBefore.permissionMode).toBe("full");

		const deletedThread = await client.v1.chats({ id: chatId }).delete();
		expect(deletedThread.status).toBe(200);

		const selectionAfter = await client.v1.selection.get();
		const restored = selectionAfter.data as {
			selectedProjectId: string | null;
			selectedChatId: string | null;
			permissionMode: string;
			selectedModel: string | null;
			selectedReasoningEffort: string | null;
		};

		expect(selectionAfter.status).toBe(200);
		expect(restored.selectedProjectId).toBe(projectId);
		expect(restored.selectedChatId).toBeNull();
		expect(restored.permissionMode).toBe("full");
		expect(restored.selectedModel).toBe("gpt-5.3-codex-spark");
		expect(restored.selectedReasoningEffort).toBe("xhigh");
	} finally {
		if (server) {
			await server.app.stop(true);
			server.db.close();
		}
		rmSync(root, { force: true, recursive: true });
	}
});

test("deleting a selected workspace clears selectedProjectId in sqlite", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-selection-delete-workspace-"));
	const databasePath = join(root, "remodecode.sqlite");
	let server:
		| Awaited<ReturnType<typeof createBackendServer>>
		| undefined;

	try {
		server = await createBackendServer({ databasePath, port: 0 });
		const client = createEdenClient({ baseUrl: `http://127.0.0.1:${toPort(server.server)}` });

		const project = await client.v1.projects.post({ path: "/tmp" });
		const projectId = (project.data as { project: { id: string } }).project.id;

		const persisted = await client.v1.selection.patch({
			selectedProjectId: projectId,
			selectedChatId: null,
			permissionMode: "plan",
			selectedModel: "gpt-5.3-codex",
			selectedReasoningEffort: "medium",
		});
		const selectionBefore = persisted.data as {
			selectedProjectId: string | null;
			selectedChatId: string | null;
			permissionMode: string;
			selectedModel: string | null;
			selectedReasoningEffort: string | null;
		};
		expect(persisted.status).toBe(200);
		expect(selectionBefore.selectedProjectId).toBe(projectId);

		const deletedWorkspace = await client.v1.projects({ id: projectId }).delete();
		expect(deletedWorkspace.status).toBe(200);

		const selectionAfter = await client.v1.selection.get();
		const restored = selectionAfter.data as {
			selectedProjectId: string | null;
			selectedChatId: string | null;
			permissionMode: string;
			selectedModel: string | null;
			selectedReasoningEffort: string | null;
		};

		expect(selectionAfter.status).toBe(200);
		expect(restored.selectedProjectId).toBeNull();
		expect(restored.selectedChatId).toBeNull();
		expect(restored.permissionMode).toBe("plan");
		expect(restored.selectedModel).toBe("gpt-5.3-codex");
		expect(restored.selectedReasoningEffort).toBe("medium");
	} finally {
		if (server) {
			await server.app.stop(true);
			server.db.close();
		}
		rmSync(root, { force: true, recursive: true });
	}
});
