/* eslint-disable @typescript-eslint/consistent-type-assertions, @typescript-eslint/prefer-destructuring, @typescript-eslint/prefer-readonly-parameter-types, compat/compat, complexity, func-style, functional/immutable-data, functional/no-let, max-lines, max-statements, sonarjs/cognitive-complexity, total-functions/no-partial-url-constructor, unicorn/consistent-function-scoping, unicorn/no-null */
import { expect, type Page, type Route, test } from "@playwright/test";

interface ApiMock {
	requests: RequestLogEntry[];
	route: (route: Route) => Promise<void>;
}

interface ChatConfig {
	id: string;
	isActive: boolean;
	status: "completed" | "failed" | "pending" | "running";
	title: string;
	updatedAt: string;
}

interface RequestLogEntry {
	headers: Record<string, string>;
	method: string;
	path: string;
	search: string;
}

const countRequests = (
	entries: RequestLogEntry[],
	method: string,
	path: string,
	search?: string,
): number =>
	entries.filter(
		(entry) =>
			entry.method === method
			&& entry.path === path
			&& (search === undefined || entry.search === search),
	).length;

const installMockWebSocket = async (page: Page) => {
	await page.addInitScript(`
		(() => {
			class MockWebSocket {
				static CONNECTING = 0;
				static OPEN = 1;
				static CLOSING = 2;
				static CLOSED = 3;

				constructor() {
					this.readyState = MockWebSocket.CONNECTING;
					this.listeners = new Map();
					setTimeout(() => {
						this.readyState = MockWebSocket.OPEN;
						this.emit("open", {});
					}, 0);
				}

				addEventListener(type, callback) {
					const current = this.listeners.get(type) ?? [];
					current.push(callback);
					this.listeners.set(type, current);
				}

				removeEventListener(type, callback) {
					const current = this.listeners.get(type) ?? [];
					this.listeners.set(type, current.filter((item) => item !== callback));
				}

				send() {}

				close() {
					this.readyState = MockWebSocket.CLOSED;
					this.emit("close", {});
				}

				emit(type, event) {
					for (const callback of this.listeners.get(type) ?? []) {
						callback(event);
					}
				}
			}

			window.WebSocket = MockWebSocket;
		})();
	`);
};

const createApiMock = (options: {
	chats: ChatConfig[];
	selectedChatId: string | null;
}): ApiMock => {
	const requests: RequestLogEntry[] = [];
	const chats = [...options.chats];
	let selectedChatId: string | null = options.selectedChatId;

	const json = (body: unknown, status = 200) => ({
		body: JSON.stringify(body),
		contentType: "application/json",
		status,
	});

	const route = async (intercept: Route): Promise<void> => {
		const request = intercept.request();
		const method = request.method().toUpperCase();
		const url = new URL(request.url());
		const path = url.pathname;
		const search = url.search;

		requests.push({
			headers: request.headers(),
			method,
			path,
			search,
		});

		if (method === "GET" && path === "/v1/projects/workspaces") {
			await intercept.fulfill(
				json({
					workspaces: [
						{
							id: "project-1",
							name: "Workspace 1",
							path: "/tmp/workspace-1",
						},
					],
				}),
			);

			return;
		}

		if (method === "GET" && path === "/v1/selection") {
			await intercept.fulfill(
				json({
					permissionMode: "default",
					selectedChatId,
					selectedModel: "gpt-5.3-codex",
					selectedProjectId: "project-1",
					selectedReasoningEffort: "medium",
				}),
			);

			return;
		}

		if (method === "PATCH" && path === "/v1/selection") {
			const payload = request.postDataJSON() as { selectedChatId?: string | null };

			if (Object.hasOwn(payload, "selectedChatId")) {
				selectedChatId = payload.selectedChatId ?? null;
			}

			await intercept.fulfill(
				json({
					permissionMode: "default",
					selectedChatId,
					selectedModel: "gpt-5.3-codex",
					selectedProjectId: "project-1",
					selectedReasoningEffort: "medium",
				}),
			);

			return;
		}

		if (method === "GET" && path === "/v1/projects/project-1/threads") {
			await intercept.fulfill(
				json({
					threads: chats.map((chat) => ({
						id: chat.id,
						isActive: chat.isActive,
						title: chat.title,
						updatedAt: chat.updatedAt,
					})),
				}),
			);

			return;
		}

		const contextMatch = /^\/v1\/chats\/([^/]+)\/context$/.exec(path);
		if (method === "GET" && contextMatch) {
			const chatId = contextMatch[1];
			const chat = chats.find((item) => item.id === chatId);

			if (!chat) {
				await intercept.fulfill(json({ error: "chat not found" }, 404));
				return;
			}

			await intercept.fulfill(
				json({
					chat: {
						diffAdded: 0,
						diffRemoved: 0,
						id: chat.id,
						isActive: chat.isActive,
						projectId: "project-1",
						provider: "codex",
						status: chat.status,
						title: chat.title,
						updatedAt: chat.updatedAt,
					},
					project: {
						id: "project-1",
						name: "Workspace 1",
						path: "/tmp/workspace-1",
					},
				}),
			);

			return;
		}

		const messagesMatch = /^\/v1\/chats\/([^/]+)\/messages$/.exec(path);
		if (method === "GET" && messagesMatch) {
			await intercept.fulfill(
				json({
					hasMore: false,
					messages: [],
					nextBeforeMessageId: null,
					turns: [],
				}),
			);

			return;
		}

		const streamEventsMatch = /^\/v1\/chats\/([^/]+)\/stream-events$/.exec(path);
		if (method === "GET" && streamEventsMatch) {
			await intercept.fulfill(json({ events: [], hasMore: false, nextAfterId: null }));

			return;
		}

		if (method === "GET" && path === "/v1/providers/codex/models") {
			await intercept.fulfill(
				json({
					models: [
						{
							defaultReasoningEffort: "medium",
							description: "Test model",
							displayName: "GPT-5.3 Codex",
							id: "gpt-5.3-codex",
							isDefault: true,
							model: "gpt-5.3-codex",

							supportedReasoningEfforts: [
								{ description: "Low", reasoningEffort: "low" },
								{ description: "Medium", reasoningEffort: "medium" },
							],
						},
					],

					nextCursor: null,
				}),
			);

			return;
		}

		if (method === "GET" && path === "/v1/projects/project-1/git/status") {
			await intercept.fulfill(
				json({
					added: 0,
					ahead: 0,
					behind: 0,
					changedFiles: 0,
					conflictedFiles: 0,
					currentBranch: null,
					isDetachedHead: false,
					isRepo: false,
					removed: 0,
					stagedFiles: 0,
					unstagedFiles: 0,
					untrackedFiles: 0,
				}),
			);

			return;
		}

		if (method === "GET" && path === "/v1/projects/project-1/git/branches") {
			await intercept.fulfill(json({ branches: [], currentBranch: null }));

			return;
		}

		await intercept.fulfill(json({ error: `Unmocked route: ${method} ${path}${search}` }, 500));
	};

	return {
		requests,
		route,
	};
};

test.describe("Desktop data minimization", () => {
	test("bootstraps completed chat with paged messages and no stream-events catch-up", async ({ page }) => {
		const apiMock = createApiMock({
			chats: [
				{ id: "chat-1", isActive: false, status: "completed", title: "Thread 1", updatedAt: "2026-01-01T00:00:00.000Z" },
				{ id: "chat-2", isActive: false, status: "completed", title: "Thread 2", updatedAt: "2026-01-01T00:00:01.000Z" },
			],
			selectedChatId: "chat-2",
		});

		await installMockWebSocket(page);
		await page.route("**/v1/**", apiMock.route);

		await page.goto("/");
		await expect(page.getByLabel("Open Thread 2")).toBeVisible();
		await expect(page.getByLabel("Message input")).toBeVisible();
		await page.waitForTimeout(200);

		expect(countRequests(apiMock.requests, "GET", "/v1/projects/workspaces")).toBe(1);
		expect(countRequests(apiMock.requests, "GET", "/v1/projects")).toBe(0);
		expect(countRequests(apiMock.requests, "GET", "/v1/projects/project-1/threads")).toBe(1);
		expect(countRequests(apiMock.requests, "GET", "/v1/projects/project-1/chats")).toBe(0);
		expect(countRequests(apiMock.requests, "GET", "/v1/chats/chat-2/context")).toBe(1);
		expect(countRequests(apiMock.requests, "GET", "/v1/chats/chat-2/messages", "?limit=25")).toBeGreaterThan(0);
		expect(countRequests(apiMock.requests, "GET", "/v1/chats/chat-2/messages", "")).toBe(0);
		expect(countRequests(apiMock.requests, "GET", "/v1/chats/chat-2/stream-events")).toBe(0);

		const messageRequest = apiMock.requests.find(
			(entry) => entry.method === "GET" && entry.path === "/v1/chats/chat-2/messages",
		);
		expect(messageRequest?.search).toBe("?limit=25");
		expect(messageRequest?.headers.authorization).toBe("Bearer remotecode.io-token");
		expect(messageRequest?.headers["x-remotecode-client-id"]).toBeTruthy();
		expect(messageRequest?.headers["x-remotecode-request-id"]).toBeTruthy();
	});

	test("switching completed thread keeps thread list cold and still uses paged chat endpoints", async ({ page }) => {
		const apiMock = createApiMock({
			chats: [
				{ id: "chat-1", isActive: false, status: "completed", title: "Thread 1", updatedAt: "2026-01-01T00:00:00.000Z" },
				{ id: "chat-2", isActive: false, status: "completed", title: "Thread 2", updatedAt: "2026-01-01T00:00:01.000Z" },
			],
			selectedChatId: "chat-2",
		});

		await installMockWebSocket(page);
		await page.route("**/v1/**", apiMock.route);

		await page.goto("/");
		await expect(page.getByLabel("Open Thread 1")).toBeVisible();
		await page.getByLabel("Open Thread 1").click();

		await expect.poll(() => countRequests(apiMock.requests, "GET", "/v1/chats/chat-1/context")).toBe(1);
		await expect
			.poll(() => countRequests(apiMock.requests, "GET", "/v1/chats/chat-1/messages", "?limit=25"))
			.toBeGreaterThan(0);
		expect(countRequests(apiMock.requests, "GET", "/v1/chats/chat-1/messages", "")).toBe(0);
		await expect.poll(() => countRequests(apiMock.requests, "GET", "/v1/chats/chat-1/stream-events")).toBe(0);

		expect(countRequests(apiMock.requests, "GET", "/v1/projects/project-1/threads")).toBe(1);
		expect(countRequests(apiMock.requests, "GET", "/v1/projects/project-1/chats")).toBe(0);
	});

	test("running chat performs one latest catch-up stream request only for the active thread", async ({ page }) => {
		const apiMock = createApiMock({
			chats: [
				{ id: "chat-1", isActive: false, status: "completed", title: "Thread 1", updatedAt: "2026-01-01T00:00:00.000Z" },
				{ id: "chat-2", isActive: true, status: "running", title: "Thread 2", updatedAt: "2026-01-01T00:00:01.000Z" },
			],
			selectedChatId: "chat-2",
		});

		await installMockWebSocket(page);
		await page.route("**/v1/**", apiMock.route);

		await page.goto("/");
		await expect(page.getByLabel("Open Thread 2")).toBeVisible();
		await expect(page.getByLabel("Message input")).toBeVisible();

		await expect
			.poll(() => countRequests(apiMock.requests, "GET", "/v1/chats/chat-2/messages", "?limit=25"))
			.toBeGreaterThan(0);
		expect(countRequests(apiMock.requests, "GET", "/v1/chats/chat-2/messages", "")).toBe(0);
		await expect
			.poll(() => countRequests(apiMock.requests, "GET", "/v1/chats/chat-2/stream-events", "?limit=500"))
			.toBeGreaterThan(0);
		expect(countRequests(apiMock.requests, "GET", "/v1/chats/chat-1/stream-events")).toBe(0);
	});
});
