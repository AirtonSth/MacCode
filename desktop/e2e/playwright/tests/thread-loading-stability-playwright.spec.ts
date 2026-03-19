/* eslint-disable @typescript-eslint/consistent-type-assertions, @typescript-eslint/no-explicit-any, @typescript-eslint/prefer-readonly-parameter-types, compat/compat, functional/immutable-data */
import { expect, type Page, type Route, test } from "@playwright/test";

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

const json = (body: unknown, status = 200) => ({
	body: JSON.stringify(body),
	contentType: "application/json",
	status,
});

const wait = async (ms: number) => {
	await new Promise((resolve) => setTimeout(resolve, ms));
};

const createRouteApi = () => {
	const messageRequestsByChat: Record<string, number> = {};

	return async (intercept: Route): Promise<void> => {
		const request = intercept.request();
		const method = request.method().toUpperCase();
		const url = new URL(request.url());
		const path = url.pathname.replace(/\/+$/, "");

		if (method === "GET" && path === "/v1/projects/workspaces") {
			await intercept.fulfill(
				json({
					workspaces: [{ id: "project-1", name: "Workspace 1", path: "/tmp/workspace-1" }],
				}),
			);
			return;
		}

		if (method === "GET" && path === "/v1/selection") {
			await intercept.fulfill(
				json({
					permissionMode: "default",
					selectedChatId: "chat-a",
					selectedModel: "gpt-5.3-codex",
					selectedProjectId: "project-1",
					selectedReasoningEffort: "medium",
				}),
			);
			return;
		}

		if (method === "PATCH" && path === "/v1/selection") {
			const payload = request.postDataJSON() as { selectedChatId?: string | null };
			await intercept.fulfill(
				json({
					permissionMode: "default",
					selectedChatId: payload.selectedChatId ?? "chat-a",
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
						{
							id: "chat-a",
							isActive: false,
							title: "Thread A",
							updatedAt: "2026-01-01T00:00:02.000Z",
						},
						{
							id: "chat-b",
							isActive: false,
							title: "Thread B",
							updatedAt: "2026-01-01T00:00:01.000Z",
						},
					],
				}),
			);
			return;
		}

		const chatContextMatch = /^\/v1\/chats\/([^/]+)\/context$/.exec(path);
		if (method === "GET" && chatContextMatch) {
			const chatId = chatContextMatch[1];
			await intercept.fulfill(
				json({
					chat: {
						diffAdded: 0,
						diffRemoved: 0,
						id: chatId,
						isActive: false,
						projectId: "project-1",
						provider: "codex",
						status: "completed",
						title: chatId === "chat-a" ? "Thread A" : "Thread B",
						updatedAt: chatId === "chat-a"
							? "2026-01-01T00:00:02.000Z"
							: "2026-01-01T00:00:01.000Z",
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
			const chatId = messagesMatch[1];
			messageRequestsByChat[chatId] = (messageRequestsByChat[chatId] ?? 0) + 1;

			if (chatId === "chat-b" && messageRequestsByChat[chatId] === 2) {
				await wait(700);
			}

			await intercept.fulfill(
				json({
					hasMore: false,
					messages: [{
						chatId,
						content: chatId === "chat-a" ? "Alpha message" : "Beta message",
						createdAt: "2026-01-01T00:00:00.000Z",
						id: chatId === "chat-a" ? "message-a-1" : "message-b-1",
						role: "assistant",
					}],
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
					models: [{
						defaultReasoningEffort: "medium",
						description: "Test model",
						displayName: "GPT-5.3 Codex",
						id: "gpt-5.3-codex",
						isDefault: true,
						model: "gpt-5.3-codex",
						supportedReasoningEfforts: [{ description: "Medium", reasoningEffort: "medium" }],
					}],
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
};

test("reopening a cached thread keeps the previous message visible during a slow reload", async ({ page }) => {
	await installMockWebSocket(page);
	await page.route("**/v1/**", createRouteApi());
	await page.goto("/");

	await expect(page.getByTestId("conversation-message-row-message-a-1")).toBeVisible();

	await page.getByLabel("Open Thread B").click();
	await expect(page.getByTestId("conversation-message-row-message-b-1")).toBeVisible();

	await page.getByLabel("Open Thread A").click();
	await expect(page.getByTestId("conversation-message-row-message-a-1")).toBeVisible();

	await page.getByLabel("Open Thread B").click();

	await expect(page.getByTestId("conversation-message-row-message-b-1")).toBeVisible();
	await expect(page.getByText("No messages yet. Send your first message.")).toHaveCount(0);

	await expect(page.getByTestId("conversation-message-row-message-b-1")).toBeVisible();
	await expect(page.getByText("No messages yet. Send your first message.")).toHaveCount(0);
});
