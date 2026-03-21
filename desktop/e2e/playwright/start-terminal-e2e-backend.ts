import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type { BackendHandle } from "../../src/bun/server/app";
import { createBackendServer } from "../../src/bun/server/app";

const token = process.env.RC_E2E_TOKEN ?? "remotecode.io-token";
const port = Number(process.env.RC_E2E_PORT ?? 0);
const statePath = join(import.meta.dir, ".terminal-e2e-state.json");

const rootPath = mkdtempSync(join(tmpdir(), "remotecode-desktop-terminal-e2e-"));
const databasePath = join(rootPath, "remotecode.sqlite");
const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-desktop-terminal-workspace-"));
const workspaceParentPath = join(workspaceRoot, "parent");
const workspacePath = join(workspaceParentPath, "project");

mkdirSync(workspacePath, { recursive: true });
const canonicalWorkspaceParentPath = realpathSync(workspaceParentPath);
const canonicalWorkspacePath = realpathSync(workspacePath);

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
		await backend.db.close();
		backend = null;
	}

	rmSync(rootPath, { force: true, recursive: true });
	rmSync(workspaceRoot, { force: true, recursive: true });
	rmSync(statePath, { force: true });
};

const bootstrap = async () => {
	backend = await createBackendServer({
		databasePath,
		port,
	});

	const actualPort = (backend.server as { port?: number } | null)?.port ?? port;
	const baseUrl = `http://127.0.0.1:${String(actualPort)}`;
	const createdProject = await requestJson<{ created: boolean; project: { id: string } }>(
		baseUrl,
		"POST",
		"/v1/projects",
		{ name: "Terminal E2E Workspace", path: workspacePath },
	);
	const projectId = createdProject.project.id;

	const createdChat = await requestJson<{ chat: { id: string } }>(
		baseUrl,
		"POST",
		`/v1/projects/${projectId}/chats`,
		{ title: "Terminal Session" },
	);
	const chatId = createdChat.chat.id;

	await requestJson(
		baseUrl,
		"PATCH",
		"/v1/selection",
		{
			permissionMode: "default",
			selectedChatId: chatId,
			selectedProjectId: projectId,
		},
	);

	writeFileSync(
		statePath,
		JSON.stringify(
			{
				baseUrl,
				chatId,
				expectedInitialCwd: canonicalWorkspacePath,
				expectedParentCwd: canonicalWorkspaceParentPath,
				projectId,
				token,
			},
			null,
			2,
		),
		"utf8",
	);

	console.log(`[desktop-terminal-e2e] ready on ${baseUrl}`);
	console.log(`[desktop-terminal-e2e] workspace: ${workspacePath}`);
	console.log(`[desktop-terminal-e2e] state file: ${statePath}`);
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

process.on("uncaughtException", (error) => {
	console.error("[desktop-terminal-e2e] uncaughtException", error);
	void stopAndExit(1);
});

process.on("unhandledRejection", (error) => {
	console.error("[desktop-terminal-e2e] unhandledRejection", error);
	void stopAndExit(1);
});

await bootstrap();

await new Promise(() => {
	// Keep the backend alive for Playwright.
});
