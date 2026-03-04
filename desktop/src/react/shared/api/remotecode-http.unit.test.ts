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
					permissionMode: "plan",
					selectedModel: "gpt-5.3-codex",
					selectedReasoningEffort: "high",
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
			expect(selection).toEqual({
				selectedChatId: "chat-1",
				selectedProjectId: "project-1",
				permissionMode: "plan",
				selectedModel: "gpt-5.3-codex",
				selectedReasoningEffort: "high",
			});
	} finally {
		restore();
	}
});

test("RemoteCodeApi lists workspace summaries from GET /v1/projects/workspaces", async () => {
	let method = "";
	let path = "";
	const restore = createMockFetch((url, init) => {
		method = (init?.method ?? "GET").toUpperCase();
		path = url.pathname;
		return jsonResponse({
			data: {
				workspaces: [
					{
						id: "project-1",
						name: "Workspace 1",
						path: "/tmp/workspace-1",
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
		const workspaces = await client.listWorkspaceSummaries();

		expect(method).toBe("GET");
		expect(path).toBe("/v1/projects/workspaces");
		expect(workspaces).toEqual([
			{
				id: "project-1",
				name: "Workspace 1",
				path: "/tmp/workspace-1",
			},
		]);
	} finally {
		restore();
	}
});

test("RemoteCodeApi lists thread summaries from GET /v1/projects/:id/threads", async () => {
	let method = "";
	let path = "";
	const restore = createMockFetch((url, init) => {
		method = (init?.method ?? "GET").toUpperCase();
		path = url.pathname;
		return jsonResponse({
			data: {
				threads: [
					{
						id: "chat-1",
						title: "Thread 1",
						updatedAt: "2026-01-01T00:00:00.000Z",
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
		const threads = await client.listThreadSummaries("project-1");

		expect(method).toBe("GET");
		expect(path).toBe("/v1/projects/project-1/threads");
		expect(threads).toEqual([
			{
				id: "chat-1",
				title: "Thread 1",
				updatedAt: "2026-01-01T00:00:00.000Z",
			},
		]);
	} finally {
		restore();
	}
});

test("RemoteCodeApi returns chat context from GET /v1/chats/:id/context", async () => {
	let method = "";
	let path = "";
	const restore = createMockFetch((url, init) => {
		method = (init?.method ?? "GET").toUpperCase();
		path = url.pathname;
		return jsonResponse({
			data: {
				chat: {
					id: "chat-1",
					projectId: "project-1",
					title: "Thread 1",
					status: "completed",
					provider: "codex",
					diffAdded: 3,
					diffRemoved: 1,
					updatedAt: "2026-01-01T00:00:00.000Z",
				},
				project: {
					id: "project-1",
					name: "Workspace 1",
					path: "/tmp/workspace-1",
				},
			},
		});
	});

	try {
		const client = RemoteCodeApi.createClient({
			baseUrl: "http://127.0.0.1:3001/",
			token: "unit-token",
		});
		const context = await client.getChatContext("chat-1");

		expect(method).toBe("GET");
		expect(path).toBe("/v1/chats/chat-1/context");
		expect(context.chat.id).toBe("chat-1");
		expect(context.chat.status).toBe("completed");
		expect(context.project.path).toBe("/tmp/workspace-1");
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
					permissionMode: "full",
					selectedModel: "gpt-5.3-codex-spark",
					selectedReasoningEffort: "xhigh",
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
				permissionMode: "full",
				selectedModel: "gpt-5.3-codex-spark",
				selectedReasoningEffort: "xhigh",
			});

			expect(method).toBe("PATCH");
			expect(receivedBody).toBe(
				JSON.stringify({
					selectedChatId: "chat-2",
					selectedProjectId: "project-2",
					permissionMode: "full",
					selectedModel: "gpt-5.3-codex-spark",
					selectedReasoningEffort: "xhigh",
				}),
			);
			expect(selection).toEqual({
				selectedChatId: "chat-2",
				selectedProjectId: "project-2",
				permissionMode: "full",
				selectedModel: "gpt-5.3-codex-spark",
				selectedReasoningEffort: "xhigh",
			});
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

test("RemoteCodeApi gets project git status from GET /v1/projects/:id/git/status", async () => {
	let method = "";
	let pathname = "";
	const restore = createMockFetch((url, init) => {
		method = (init?.method ?? "GET").toUpperCase();
		pathname = url.pathname;
		return jsonResponse({
			isRepo: true,
			currentBranch: "main",
			ahead: 2,
			behind: 0,
			changedFiles: 4,
			stagedFiles: 0,
			unstagedFiles: 1,
			untrackedFiles: 3,
			conflictedFiles: 0,
			isDetachedHead: false,
			added: 0,
			removed: 0,
		});
	});

	try {
		const client = RemoteCodeApi.createClient({
			baseUrl: "http://127.0.0.1:3001",
			token: "unit-token",
		});

		const status = await client.getProjectGitStatus("project-1");

		expect(method).toBe("GET");
		expect(pathname).toBe("/v1/projects/project-1/git/status");
		expect(status.currentBranch).toBe("main");
		expect(status.stagedFiles).toBe(0);
	} finally {
		restore();
	}
});

test("RemoteCodeApi lists project git branches from GET /v1/projects/:id/git/branches", async () => {
	let method = "";
	let pathname = "";
	const restore = createMockFetch((url, init) => {
		method = (init?.method ?? "GET").toUpperCase();
		pathname = url.pathname;
		return jsonResponse({
			currentBranch: "main",
			branches: ["main", "feature/ci"],
		});
	});

	try {
		const client = RemoteCodeApi.createClient({
			baseUrl: "http://127.0.0.1:3001",
			token: "unit-token",
		});

		const branches = await client.getProjectGitBranches("project-1");

		expect(method).toBe("GET");
		expect(pathname).toBe("/v1/projects/project-1/git/branches");
		expect(branches.branches).toHaveLength(2);
		expect(branches.currentBranch).toBe("main");
		expect(branches.branches[1]).toBe("feature/ci");
	} finally {
		restore();
	}
});

test("RemoteCodeApi checks out a git branch via POST /v1/projects/:id/git/branches/checkout", async () => {
	let method = "";
	let pathname = "";
	let body = "";
	const restore = createMockFetch((url, init) => {
		method = (init?.method ?? "GET").toUpperCase();
		pathname = url.pathname;
		body = String(init?.body ?? "");

		return jsonResponse({
			branch: "feature/ci",
			switched: true,
		});
	});

	try {
		const client = RemoteCodeApi.createClient({
			baseUrl: "http://127.0.0.1:3001",
			token: "unit-token",
		});

		const result = await client.checkoutProjectGitBranch("project-1", "feature/ci");

		expect(method).toBe("POST");
		expect(pathname).toBe("/v1/projects/project-1/git/branches/checkout");
		expect(body).toBe(JSON.stringify({ branch: "feature/ci" }));
		expect(result.switched).toBe(true);
		expect(result.branch).toBe("feature/ci");
	} finally {
		restore();
	}
});

test("RemoteCodeApi creates a git branch via POST /v1/projects/:id/git/branches/create", async () => {
	let method = "";
	let pathname = "";
	let body = "";
	const restore = createMockFetch((url, init) => {
		method = (init?.method ?? "GET").toUpperCase();
		pathname = url.pathname;
		body = String(init?.body ?? "");

		return jsonResponse({
			branch: "feature/new",
			created: true,
		});
	});

	try {
		const client = RemoteCodeApi.createClient({
			baseUrl: "http://127.0.0.1:3001",
			token: "unit-token",
		});

		const result = await client.createProjectGitBranch("project-1", "feature/new");

		expect(method).toBe("POST");
		expect(pathname).toBe("/v1/projects/project-1/git/branches/create");
		expect(body).toBe(JSON.stringify({ name: "feature/new" }));
		expect(result.created).toBe(true);
		expect(result.branch).toBe("feature/new");
	} finally {
		restore();
	}
});

test("RemoteCodeApi creates a commit via POST /v1/projects/:id/git/commit", async () => {
	let method = "";
	let pathname = "";
	let body = "";
	const restore = createMockFetch((url, init) => {
		method = (init?.method ?? "GET").toUpperCase();
		pathname = url.pathname;
		body = String(init?.body ?? "");

		return jsonResponse({
			commit: {
				branch: "main",
				commitHash: "a1b2c3d",
				commitMessage: "chore: commit all changes",
				pushed: true,
				pushedWithUpstream: false,
			},
		});
	});

	try {
		const client = RemoteCodeApi.createClient({
			baseUrl: "http://127.0.0.1:3001",
			token: "unit-token",
		});

		const result = await client.commitProject("project-1", {
			message: "chore: commit all changes",
			includeUnstaged: true,
			push: true,
		});

		expect(method).toBe("POST");
		expect(pathname).toBe("/v1/projects/project-1/git/commit");
		expect(body).toBe(
			JSON.stringify({
				message: "chore: commit all changes",
				includeUnstaged: true,
				push: true,
			}),
		);
		expect(result.commit.branch).toBe("main");
		expect(result.commit.pushed).toBe(true);
	} finally {
		restore();
	}
});

test("RemoteCodeApi throws RemoteCodeApiError on git branch list failure", async () => {
	let pathname = "";
	const restore = createMockFetch((url) => {
		pathname = url.pathname;
		return jsonResponse({ error: "failed to list branches" }, 500);
	});

	try {
		const client = RemoteCodeApi.createClient({
			baseUrl: "http://127.0.0.1:3001",
			token: "unit-token",
		});

		await expect(client.getProjectGitBranches("project-1")).rejects.toMatchObject({
			status: 500,
			code: "500",
			payload: {
				error: "failed to list branches",
			},
		});
		expect(pathname).toBe("/v1/projects/project-1/git/branches");
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
