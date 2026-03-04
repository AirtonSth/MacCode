/* eslint-disable @typescript-eslint/consistent-type-assertions, @typescript-eslint/prefer-destructuring, @typescript-eslint/prefer-readonly-parameter-types, compat/compat, complexity, func-style, functional/immutable-data, functional/no-let, max-lines, max-statements, sonarjs/cognitive-complexity, total-functions/no-partial-url-constructor, unicorn/consistent-function-scoping, unicorn/no-null */
import { expect, type Page, type Route,test } from "@playwright/test";

interface ApiMock {
	requests: RequestLogEntry[];
	route: (route: Route) => Promise<void>;
}

interface RequestLogEntry {
	method: string;
	path: string;
}

const countRequests = (entries: RequestLogEntry[], method: string, path: string): number =>
	entries.filter((entry) => entry.method === method && entry.path === path).length;

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

const createApiMock = (initialSelectionChatId: string): ApiMock => {
	const requests: RequestLogEntry[] = [];

	let selectedChatId: string | null = initialSelectionChatId;

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

		requests.push({ method, path });

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
					threads: [
						{ id: "chat-1", title: "Thread 1", updatedAt: "2026-01-01T00:00:00.000Z" },
						{ id: "chat-2", title: "Thread 2", updatedAt: "2026-01-01T00:00:01.000Z" },
					],
				}),
			);

			return;
		}

		if (method === "GET" && path === "/v1/chats/chat-1/context") {
			await intercept.fulfill(
				json({
					chat: {
						diffAdded: 1,
						diffRemoved: 0,
						id: "chat-1",
						projectId: "project-1",
						provider: "codex",
						status: "completed",
						title: "Thread 1",
						updatedAt: "2026-01-01T00:00:00.000Z",
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

		if (method === "GET" && path === "/v1/chats/chat-2/context") {
			await intercept.fulfill(
				json({
					chat: {
						diffAdded: 0,
						diffRemoved: 0,
						id: "chat-2",
						projectId: "project-1",
						provider: "codex",
						status: "pending",
						title: "Thread 2",
						updatedAt: "2026-01-01T00:00:01.000Z",
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

		if (method === "GET" && path === "/v1/chats/chat-1/messages") {
			await intercept.fulfill(json({ messages: [] }));

			return;
		}

		if (method === "GET" && path === "/v1/chats/chat-2/messages") {
			await intercept.fulfill(json({ messages: [] }));

			return;
		}

		if (method === "GET" && path === "/v1/chats/chat-1/stream-events") {
			await intercept.fulfill(json({ events: [], hasMore: false, nextAfterId: null }));

			return;
		}

		if (method === "GET" && path === "/v1/chats/chat-2/stream-events") {
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

		await intercept.fulfill(json({ error: `Unmocked route: ${method} ${path}` }, 500));
	};

	return {
		requests,
		route,
	};
};

test.describe("Desktop data minimization", () => {
	test("bootstraps with lightweight endpoints and avoids legacy heavy routes", async ({ page }) => {
		const apiMock = createApiMock("chat-2");

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
		expect(countRequests(apiMock.requests, "GET", "/v1/chats/chat-2/messages")).toBe(1);
		expect(countRequests(apiMock.requests, "GET", "/v1/chats/chat-2/stream-events")).toBe(1);
	});

	test("switching thread loads only chat-scoped endpoints without reloading thread list", async ({ page }) => {
		const apiMock = createApiMock("chat-2");

		await installMockWebSocket(page);
		await page.route("**/v1/**", apiMock.route);

		await page.goto("/");
		await expect(page.getByLabel("Open Thread 1")).toBeVisible();
		await page.getByLabel("Open Thread 1").click();

		await expect.poll(() => countRequests(apiMock.requests, "GET", "/v1/chats/chat-1/context")).toBe(1);
		await expect.poll(() => countRequests(apiMock.requests, "GET", "/v1/chats/chat-1/messages")).toBe(1);
		await expect.poll(() => countRequests(apiMock.requests, "GET", "/v1/chats/chat-1/stream-events")).toBe(1);

		expect(countRequests(apiMock.requests, "GET", "/v1/projects/project-1/threads")).toBe(1);
		expect(countRequests(apiMock.requests, "GET", "/v1/projects/project-1/chats")).toBe(0);
	});
});
