import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Database } from "bun:sqlite";
import { expect, test } from "bun:test";

import { createBackendServer } from "../../app";
import { createEdenClient } from "../../eden-client";
import { createTestServer } from "../../shared/core/test-server";

const unwrap = <T>(payload: unknown): T => {
	if (payload && typeof payload === "object" && "data" in payload) {
		return (payload as { data: T }).data;
	}

	return payload as T;
};

const getTerminalHistory = async (baseUrl: string, chatId: string, query = "") => {
	const response = await fetch(`${baseUrl}/v1/chats/${chatId}/terminal${query}`, {
		headers: {
			authorization: "Bearer local-dev-token",
		},
		method: "GET",
	});

	return {
		body: unwrap<{
			commands?: Array<{ id: string; command: string; status: string }>;
			entries?: Array<{ id: number; commandId: string; data: string; stream: "stdout" | "stderr" }>;
			error?: string;
		}>(await response.json()),
		status: response.status,
	};
};

const execTerminal = async (
	baseUrl: string,
	chatId: string,
	input: { command: string; timeoutMs?: number },
) => {
	const response = await fetch(`${baseUrl}/v1/chats/${chatId}/terminal/exec`, {
		body: JSON.stringify(input),
		headers: {
			authorization: "Bearer local-dev-token",
			"content-type": "application/json",
		},
		method: "POST",
	});

	return {
		body: unwrap<{
			command?: { id: string; status: "running" | "completed" | "failed" | "timeout"; exitCode: number | null };
			entries?: Array<{ data: string; stream: "stdout" | "stderr" }>;
			error?: string;
		}>(await response.json()),
		status: response.status,
	};
};

const resolvePort = (server: unknown): number => {
	if (!server || typeof server !== "object") {
		throw new Error("server port is not available");
	}

	const candidate = server as { port?: number };
	if (!candidate.port) {
		throw new Error("server port is not available");
	}

	return candidate.port;
};

test("GET and POST terminal endpoints return 404 for missing chat", async () => {
	const { baseUrl, cleanup } = await createTestServer();

	try {
		const history = await getTerminalHistory(baseUrl, "missing-chat-id");
		expect(history.status).toBe(404);
		expect(history.body.error).toBe("chat not found");

		const execResult = await execTerminal(baseUrl, "missing-chat-id", { command: "pwd" });
		expect(execResult.status).toBe(404);
		expect(execResult.body.error).toBe("chat not found");
	} finally {
		await cleanup();
	}
});

test("POST /v1/chats/:id/terminal/exec returns stdout/stderr and persists history", async () => {
	const { baseUrl, cleanup, client } = await createTestServer();
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-terminal-controller-rest-"));

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "terminal rest history" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		const execResult = await execTerminal(baseUrl, chatId, {
			command: "printf 'hello-stdout\\n'; printf 'hello-stderr\\n' 1>&2",
		});

		expect(execResult.status).toBe(200);
		expect(execResult.body.command?.status).toBe("completed");
		expect(execResult.body.entries?.map((entry) => entry.stream)).toEqual(["stdout", "stderr"]);
		expect(execResult.body.entries?.[0]?.data).toContain("hello-stdout");
		expect(execResult.body.entries?.[1]?.data).toContain("hello-stderr");

		const history = await getTerminalHistory(baseUrl, chatId);
		expect(history.status).toBe(200);
		expect(history.body.commands?.length).toBeGreaterThan(0);
		expect(history.body.entries?.length).toBeGreaterThan(0);
		expect(history.body.entries?.some((entry) => entry.stream === "stdout")).toBe(true);
		expect(history.body.entries?.some((entry) => entry.stream === "stderr")).toBe(true);

		const cursor = history.body.entries?.[0]?.id;
		const paginated = await getTerminalHistory(baseUrl, chatId, `?limit=200&cursor=${cursor}`);
		expect(paginated.status).toBe(200);
		expect(paginated.body.entries?.every((entry) => entry.id > Number(cursor))).toBe(true);
	} finally {
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
});

test("terminal exec is isolated per command (no persistent export between commands)", async () => {
	const { baseUrl, cleanup, client } = await createTestServer();
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-terminal-isolated-"));

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "terminal isolation" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;
		const token = `isolated-${Date.now()}-${Math.random().toString(16).slice(2, 6)}`;

		const firstExec = await execTerminal(baseUrl, chatId, {
			command: `export REST_TERMINAL_TOKEN=\"${token}\"`,
		});
		expect(firstExec.status).toBe(200);
		expect(firstExec.body.command?.status).toBe("completed");

		const secondExec = await execTerminal(baseUrl, chatId, {
			command: 'printf "__rest_token__%s__\\n" "$REST_TERMINAL_TOKEN"',
		});
		expect(secondExec.status).toBe(200);

		const combinedOutput = (secondExec.body.entries ?? []).map((entry) => entry.data).join("\n");
		expect(combinedOutput).toContain("__rest_token____");
		expect(combinedOutput).not.toContain(`__rest_token__${token}__`);
	} finally {
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
});

test("POST /exec supports timeout and marks command as timeout", async () => {
	const { baseUrl, cleanup, client } = await createTestServer();
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-terminal-timeout-"));

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "terminal timeout" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		const result = await execTerminal(baseUrl, chatId, {
			command: "sleep 1",
			timeoutMs: 100,
		});

		expect(result.status).toBe(200);
		expect(result.body.command?.status).toBe("timeout");
		expect(result.body.command?.exitCode).toBeNull();
	} finally {
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
});

test("GET /v1/chats/:id/terminal keeps history after server restart with same sqlite file", async () => {
	const root = mkdtempSync(join(tmpdir(), "remotecode-terminal-restart-"));
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-terminal-restart-workspace-"));
	const databasePath = join(root, "remotecode.sqlite");
	let backend = await createBackendServer({ databasePath, port: 0 });
	let baseUrl = `http://127.0.0.1:${resolvePort(backend.server)}`;
	let client = createEdenClient({ baseUrl });
	let chatId: string | null = null;

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "terminal restart" });
		chatId = (chat.data as { chat: { id: string } }).chat.id;

		const execResult = await execTerminal(baseUrl, chatId, { command: "printf 'restart-ok\\n'" });
		expect(execResult.status).toBe(200);
		expect(execResult.body.command?.status).toBe("completed");

		await backend.app.stop(true);
		backend.db.close();

		backend = await createBackendServer({ databasePath, port: 0 });
		baseUrl = `http://127.0.0.1:${resolvePort(backend.server)}`;
		client = createEdenClient({ baseUrl });

		const history = await getTerminalHistory(baseUrl, chatId);
		expect(history.status).toBe(200);
		expect(history.body.commands?.some((command) => command.command.includes("restart-ok"))).toBe(true);
		expect(history.body.entries?.some((entry) => entry.data.includes("restart-ok"))).toBe(true);
	} finally {
		await backend.app.stop(true);
		backend.db.close();
		rmSync(root, { force: true, recursive: true });
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
});

test("deleting chat cascades terminal commands and entries", async () => {
	const { cleanup, client, databasePath, baseUrl } = await createTestServer();
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-terminal-cascade-"));

	try {
		const project = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (project.data as { project: { id: string } }).project.id;
		const chat = await client.v1.projects({ id: projectId }).chats.post({ title: "terminal cascade" });
		const chatId = (chat.data as { chat: { id: string } }).chat.id;

		const execResult = await execTerminal(baseUrl, chatId, { command: "printf 'cascade\\n'" });
		expect(execResult.status).toBe(200);
		expect(execResult.body.command?.id).toEqual(expect.any(String));

		const deleteResult = await client.v1.chats({ id: chatId }).delete();
		expect((deleteResult.data as { deleted: boolean }).deleted).toBe(true);

		const verify = new Database(databasePath);
		try {
			const remainingCommands = verify
				.prepare("SELECT COUNT(1) AS count FROM terminal_commands WHERE chatId = ?")
				.get(chatId) as { count: number };
			const remainingEntries = verify
				.prepare("SELECT COUNT(1) AS count FROM terminal_entries WHERE chatId = ?")
				.get(chatId) as { count: number };

			expect(remainingCommands.count).toBe(0);
			expect(remainingEntries.count).toBe(0);
		} finally {
			verify.close();
		}
	} finally {
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
});
