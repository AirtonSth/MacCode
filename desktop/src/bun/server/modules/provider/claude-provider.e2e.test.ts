import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test, afterAll, beforeAll, describe } from "bun:test";

import { ServerBootstrap } from "../../app";
import { serverConfig } from "../../config";

let testServer: Awaited<ReturnType<typeof ServerBootstrap.buildServerApp>> | null = null;
let baseUrl = "";
let port = 0;

const getNextPort = (() => {
	let p = 49300;
	return () => ++p;
})();

const createAuthHeaders = () => ({
	authorization: `Bearer ${serverConfig.token}`,
	"content-type": "application/json",
});

const createTestServer = async () => {
	port = getNextPort();
	const root = mkdtempSync(join(tmpdir(), "remotecode-claude-e2e-"));
	const databasePath = join(root, "remotecode.sqlite");
	testServer = await ServerBootstrap.buildServerApp({
		databasePath,
		disableLiveActivityPush: true,
		port,
	});
	testServer.app.listen({ hostname: "127.0.0.1", port });
	baseUrl = `http://127.0.0.1:${port}`;
	return { baseUrl, root };
};

const get = async (path: string) =>
	fetch(`${baseUrl}/v1${path}`, { headers: createAuthHeaders() });

const post = async (path: string, body?: unknown) =>
	fetch(`${baseUrl}/v1${path}`, {
		body: body ? JSON.stringify(body) : undefined,
		headers: createAuthHeaders(),
		method: "POST",
	});

describe("Claude Provider E2E", () => {
	let root = "";

	beforeAll(async () => {
		const result = await createTestServer();
		root = result.root;
	});

	afterAll(() => {
		testServer?.db.close();
		if (root) {
			rmSync(root, { force: true, recursive: true });
		}
	});

	test("GET /providers/claude/models returns Claude model catalog", async () => {
		const response = await get("/providers/claude/models");
		expect(response.status).toBe(200);

		const body = (await response.json()) as {
			models: Array<{ id: string; model: string; displayName: string; isDefault: boolean }>;
			nextCursor: string | null;
		};

		expect(body.models.length).toBeGreaterThan(0);
		expect(body.nextCursor).toBeNull();

		const sonnet = body.models.find((m) => m.model === "sonnet");
		expect(sonnet).toBeDefined();
		expect(sonnet!.displayName).toBe("Claude Sonnet");
		expect(sonnet!.isDefault).toBe(true);

		const opus = body.models.find((m) => m.model === "opus");
		expect(opus).toBeDefined();
		expect(opus!.displayName).toBe("Claude Opus");

		const haiku = body.models.find((m) => m.model === "haiku");
		expect(haiku).toBeDefined();
		expect(haiku!.displayName).toBe("Claude Haiku");
	});

	test("POST /projects/:id/chats creates chat with claude provider", async () => {
		const projectRes = await post("/projects", { path: mkdtempSync(join(tmpdir(), "remotecode-claude-project-")) });
		const project = ((await projectRes.json()) as { project: { id: string } }).project;

		const chatRes = await post(`/projects/${project.id}/chats`, {
			title: "Claude thread",
			provider: "claude",
		});
		expect(chatRes.status).toBe(201);

		const body = (await chatRes.json()) as {
			chat: { id: string; provider: string; title: string; status: string };
		};

		expect(body.chat.provider).toBe("claude");
		expect(body.chat.title).toBe("Claude thread");
		expect(body.chat.status).toBe("pending");
	});

	test("POST /projects/:id/chats defaults to codex provider", async () => {
		const projectRes = await post("/projects", { path: mkdtempSync(join(tmpdir(), "remotecode-codex-project-")) });
		const project = ((await projectRes.json()) as { project: { id: string } }).project;

		const chatRes = await post(`/projects/${project.id}/chats`, {
			title: "Codex thread",
		});
		expect(chatRes.status).toBe(201);

		const body = (await chatRes.json()) as {
			chat: { id: string; provider: string };
		};

		expect(body.chat.provider).toBe("codex");
	});

	test("POST /projects/:id/chats rejects invalid provider", async () => {
		const projectRes = await post("/projects", { path: mkdtempSync(join(tmpdir(), "remotecode-invalid-prov-")) });
		const project = ((await projectRes.json()) as { project: { id: string } }).project;

		const chatRes = await post(`/projects/${project.id}/chats`, {
			title: "Bad provider",
			provider: "invalid-provider",
		});
		expect(chatRes.status).toBe(400);
	});

	test("PATCH /selection persists selectedProvider", async () => {
		const projectRes = await post("/projects", { path: mkdtempSync(join(tmpdir(), "remotecode-sel-prov-")) });
		const project = ((await projectRes.json()) as { project: { id: string } }).project;

		const patchRes = await fetch(`${baseUrl}/v1/selection`, {
			body: JSON.stringify({
				selectedProjectId: project.id,
				selectedChatId: null,
				selectedProvider: "claude",
			}),
			headers: createAuthHeaders(),
			method: "PATCH",
		});
		expect(patchRes.status).toBe(200);

		const body = (await patchRes.json()) as { selectedProvider: string | null };
		expect(body.selectedProvider).toBe("claude");

		const getRes = await get("/selection");
		const selection = (await getRes.json()) as { selectedProvider: string | null };
		expect(selection.selectedProvider).toBe("claude");
	});
});
