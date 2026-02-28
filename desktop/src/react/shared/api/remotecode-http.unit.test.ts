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

	globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
		const url = new URL(input as string);

		return Promise.resolve(handler(url, init));
	};

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
	const restore = createMockFetch((url, init) => {
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
