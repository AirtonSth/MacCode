import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Database } from "bun:sqlite";

import type { BackendHandle } from "../../desktop/src/bun/server/app";
import { createBackendServer } from "../../desktop/src/bun/server/app";

const token = process.env.RC_E2E_TOKEN ?? "local-dev-token";
const port = Number(process.env.RC_E2E_PORT ?? 8835);

const rootPath = mkdtempSync(join(tmpdir(), "remotecode-ios-e2e-"));
const databasePath = join(rootPath, "remodecode.sqlite");
const workspacePath = mkdtempSync(join(tmpdir(), "remotecode-ios-e2e-workspace-"));
const statePath = join(import.meta.dir, ".ios-e2e-state.json");

let backend: BackendHandle | null = null;

const headers = {
	authorization: `Bearer ${token}`,
	"content-type": "application/json",
};

const requestJson = async <T>(baseUrl: string, method: string, path: string, body?: unknown): Promise<T> => {
	const response = await fetch(`${baseUrl}${path}`, {
		body: body === undefined ? undefined : JSON.stringify(body),
		headers,
		method,
	});

	if (!response.ok) {
		const responseText = await response.text();
		throw new Error(`${method} ${path} failed (${String(response.status)}): ${responseText}`);
	}

	return (await response.json()) as T;
};

const cleanup = async () => {
	if (backend) {
		await backend.app.stop(true);
		backend.db.close();
		backend = null;
	}

	rmSync(rootPath, { force: true, recursive: true });
	rmSync(workspacePath, { force: true, recursive: true });
};

const bootstrap = async () => {
	backend = await createBackendServer({
		databasePath,
		port,
	});

	const baseUrl = `http://127.0.0.1:${String(port)}`;

	const createdProject = await requestJson<{ created: boolean; project: { id: string } }>(
		baseUrl,
		"POST",
		"/v1/projects",
		{ name: "iOS E2E Workspace", path: workspacePath },
	);
	const projectId = createdProject.project.id;

	const activeChat = await requestJson<{ chat: { id: string } }>(
		baseUrl,
		"POST",
		`/v1/projects/${projectId}/chats`,
		{ title: "Active Thread" },
	);
	const idleTopChat = await requestJson<{ chat: { id: string } }>(
		baseUrl,
		"POST",
		`/v1/projects/${projectId}/chats`,
		{ title: "Idle Top" },
	);
	const idleBottomChat = await requestJson<{ chat: { id: string } }>(
		baseUrl,
		"POST",
		`/v1/projects/${projectId}/chats`,
		{ title: "Idle Bottom" },
	);

	await requestJson(
		baseUrl,
		"PATCH",
		"/v1/selection",
		{
			permissionMode: "default",
			selectedChatId: activeChat.chat.id,
			selectedProjectId: projectId,
		},
	);

	const sqlite = new Database(databasePath);
	try {
		sqlite
			.prepare("UPDATE chats SET status = ?, isActive = ?, updatedAt = ? WHERE id = ?")
			.run("running", 1, "2026-01-01T00:00:03.000Z", activeChat.chat.id);
		sqlite
			.prepare("UPDATE chats SET status = ?, isActive = ?, updatedAt = ? WHERE id = ?")
			.run("completed", 0, "2026-01-01T00:00:02.000Z", idleTopChat.chat.id);
		sqlite
			.prepare("UPDATE chats SET status = ?, isActive = ?, updatedAt = ? WHERE id = ?")
			.run("completed", 0, "2026-01-01T00:00:01.000Z", idleBottomChat.chat.id);
	} finally {
		sqlite.close();
	}

	writeFileSync(
		statePath,
		JSON.stringify(
			{
				baseUrl,
				chats: {
					active: {
						id: activeChat.chat.id,
						title: "Active Thread",
					},
					idleBottom: {
						id: idleBottomChat.chat.id,
						title: "Idle Bottom",
					},
					idleTop: {
						id: idleTopChat.chat.id,
						title: "Idle Top",
					},
				},
				projectId,
			},
			null,
			2,
		),
		"utf8",
	);

	console.log(`[ios-e2e-backend] ready on ${baseUrl}`);
	console.log(`[ios-e2e-backend] database: ${databasePath}`);
	console.log(`[ios-e2e-backend] state file: ${statePath}`);
};

const stopAndExit = async (code: number) => {
	try {
		await cleanup();
	} finally {
		process.exit(code);
	}
};

process.on("SIGINT", () => {
	void stopAndExit(0);
});
process.on("SIGTERM", () => {
	void stopAndExit(0);
});

try {
	await bootstrap();
	await new Promise<void>(() => {
		// Keep process alive until explicitly terminated by the runner script.
	});
} catch (error) {
	console.error(
		"[ios-e2e-backend] failed:",
		error instanceof Error ? error.message : String(error),
	);
	await stopAndExit(1);
}
