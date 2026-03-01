import { expect, test } from "bun:test";

import { RemoteCodeApi } from "./remotecode-http";

const jsonResponse = (payload: unknown, status = 200): Response => {
	return new Response(JSON.stringify(payload), {
		headers: {
			"content-type": "application/json",
		},
		status,
	});
};

const createMockFetch = (handler: (url: URL, init?: RequestInit) => Response) => {
	const previousFetch = globalThis.fetch;

	globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
		const url = new URL(input as string);
		return Promise.resolve(handler(url, init));
	}) as typeof fetch;

	return () => {
		globalThis.fetch = previousFetch;
	};
};

test("RemoteCodeApi returns workspace selection from GET /v1/selection", async () => {
	let method = "";
	let path = "";
	const restore = createMockFetch((url, init) => {
		method = (init?.method ?? "GET").toUpperCase();
		path = url.pathname;

		return jsonResponse({
			data: {
				selectedChatId: "chat-1",
				selectedProjectId: "project-1",
			},
		});
	});

	try {
		const client = RemoteCodeApi.createClient({
			baseUrl: "http://127.0.0.1:3001/",
			token: "unit-token",
		});
		const selection = await client.getWorkspaceSelection();

		expect(method).toBe("GET");
		expect(path).toBe("/v1/selection");
		expect(selection).toEqual({ selectedChatId: "chat-1", selectedProjectId: "project-1" });
	} finally {
		restore();
	}
});

test("RemoteCodeApi persists workspace selection with PATCH /v1/selection", async () => {
	let receivedBody = "";
	let method = "";
	const restore = createMockFetch((_url, init) => {
		method = (init?.method ?? "GET").toUpperCase();
		receivedBody = String(init?.body ?? "");
		return jsonResponse({
			data: {
				selectedChatId: "chat-2",
				selectedProjectId: "project-2",
			},
		});
	});

	try {
		const client = RemoteCodeApi.createClient({
			baseUrl: "http://127.0.0.1:3001",
			token: "unit-token",
		});
		const selection = await client.updateWorkspaceSelection({
			selectedChatId: "chat-2",
			selectedProjectId: "project-2",
		});

		expect(method).toBe("PATCH");
		expect(receivedBody).toBe(JSON.stringify({ selectedChatId: "chat-2", selectedProjectId: "project-2" }));
		expect(selection).toEqual({ selectedChatId: "chat-2", selectedProjectId: "project-2" });
	} finally {
		restore();
	}
});

test("RemoteCodeApi returns codex model catalog from GET /v1/providers/codex/models", async () => {
	let method = "";
	let path = "";
	const restore = createMockFetch((url, init) => {
		method = (init?.method ?? "GET").toUpperCase();
		path = url.pathname;
		return jsonResponse({
			data: {
				models: [
					{
						defaultReasoningEffort: "medium",
						description: "Latest frontier agentic coding model.",
						displayName: "gpt-5.3-codex",
						id: "gpt-5.3-codex",
						isDefault: true,
						model: "gpt-5.3-codex",
						supportedReasoningEfforts: [
							{ description: "Low", reasoningEffort: "low" },
							{ description: "Medium", reasoningEffort: "medium" },
							{ description: "High", reasoningEffort: "high" },
							{ description: "Extra high", reasoningEffort: "xhigh" },
						],
					},
				],
				nextCursor: null,
			},
		});
	});

	try {
		const client = RemoteCodeApi.createClient({
			baseUrl: "http://127.0.0.1:3001/",
			token: "unit-token",
		});
		const catalog = await client.listCodexModels();

		expect(method).toBe("GET");
		expect(path).toBe("/v1/providers/codex/models");
		expect(catalog.models).toHaveLength(1);
		expect(catalog.models[0]?.model).toBe("gpt-5.3-codex");
		expect(catalog.models[0]?.supportedReasoningEfforts.map((item) => item.reasoningEffort)).toEqual([
			"low",
			"medium",
			"high",
			"xhigh",
		]);
		expect(catalog.nextCursor).toBeNull();
	} finally {
		restore();
	}
});

test("RemoteCodeApi issues delete requests for projects and chats", async () => {
	const calls: string[] = [];
	const restore = createMockFetch((url) => {
		calls.push(url.pathname);
		return jsonResponse({ data: { deleted: true } });
	});

	try {
		const client = RemoteCodeApi.createClient({
			baseUrl: "http://127.0.0.1:3001",
			token: "unit-token",
		});
		const deletedProject = await client.deleteProject("project-1");
		const deletedChat = await client.deleteChat("chat-1");

		expect(calls).toEqual(["/v1/projects/project-1", "/v1/chats/chat-1"]);
		expect(deletedProject).toEqual({ deleted: true });
		expect(deletedChat).toEqual({ deleted: true });
	} finally {
		restore();
	}
});

test("RemoteCodeApi loads terminal history with commands and entries", async () => {
	let method = "";
	let pathname = "";
	let search = "";
	const restore = createMockFetch((url, init) => {
		method = (init?.method ?? "GET").toUpperCase();
		pathname = url.pathname;
		search = url.search;
		return jsonResponse({
			data: {
				commands: [
					{
						id: "1700000000000-a",
						chatId: "chat-1",
						command: "pwd",
						cwd: "/tmp/workspace",
						shell: "/bin/zsh",
						status: "completed",
						exitCode: 0,
						durationMs: 4,
						startedAt: "2026-01-01T00:00:00.000Z",
						finishedAt: "2026-01-01T00:00:00.004Z",
					},
				],
				entries: [
					{
						id: 1,
						commandId: "1700000000000-a",
						chatId: "chat-1",
						stream: "stdout",
						data: "/tmp/workspace\n",
						createdAt: "2026-01-01T00:00:00.003Z",
					},
				],
			},
		});
	});

	try {
		const client = RemoteCodeApi.createClient({
			baseUrl: "http://127.0.0.1:3001/",
			token: "unit-token",
		});
		const history = await client.getTerminalHistory("chat-1", { cursor: 12, limit: 333 });

		expect(method).toBe("GET");
		expect(pathname).toBe("/v1/chats/chat-1/terminal");
		expect(search).toContain("cursor=12");
		expect(search).toContain("limit=333");
		expect(history.commands).toHaveLength(1);
		expect(history.entries).toHaveLength(1);
		expect(history.entries[0]?.stream).toBe("stdout");
	} finally {
		restore();
	}
});

test("RemoteCodeApi executes terminal command via POST /v1/chats/:id/terminal/exec", async () => {
	let method = "";
	let pathname = "";
	let body = "";

	const restore = createMockFetch((url, init) => {
		method = (init?.method ?? "GET").toUpperCase();
		pathname = url.pathname;
		body = String(init?.body ?? "");

		return jsonResponse({
			data: {
				command: {
					id: "1700000000000-b",
					chatId: "chat-1",
					command: "echo hi",
					cwd: "/tmp/workspace",
					shell: "/bin/zsh",
					status: "completed",
					exitCode: 0,
					durationMs: 3,
					startedAt: "2026-01-01T00:00:01.000Z",
					finishedAt: "2026-01-01T00:00:01.003Z",
				},
				entries: [
					{
						id: 2,
						commandId: "1700000000000-b",
						chatId: "chat-1",
						stream: "stdout",
						data: "hi\n",
						createdAt: "2026-01-01T00:00:01.002Z",
					},
				],
			},
		});
	});

	try {
		const client = RemoteCodeApi.createClient({
			baseUrl: "http://127.0.0.1:3001",
			token: "unit-token",
		});

		const result = await client.execTerminalCommand("chat-1", {
			command: "echo hi",
			timeoutMs: 5_000,
		});

		expect(method).toBe("POST");
		expect(pathname).toBe("/v1/chats/chat-1/terminal/exec");
		expect(body).toBe(JSON.stringify({ command: "echo hi", timeoutMs: 5000 }));
		expect(result.command.id).toBe("1700000000000-b");
		expect(result.entries[0]?.data).toBe("hi\n");
	} finally {
		restore();
	}
});

test("RemoteCodeApi throws RemoteCodeApiError when request fails", async () => {
	const restore = createMockFetch(() => jsonResponse({ error: "forbidden" }, 403));

	try {
		const client = RemoteCodeApi.createClient({
			baseUrl: "http://127.0.0.1:3001",
			token: "unit-token",
		});

		await expect(client.listProjects()).rejects.toMatchObject({
			status: 403,
			code: "403",
			payload: {
				error: "forbidden",
			},
		});
	} finally {
		restore();
	}
});
