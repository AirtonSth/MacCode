/* eslint-disable @typescript-eslint/consistent-type-assertions, @typescript-eslint/no-explicit-any, @typescript-eslint/prefer-readonly-parameter-types, compat/compat, functional/immutable-data, max-lines, max-statements */
import { expect, type Page, type Route, test } from "@playwright/test";

interface MessageFixture {
	chatId: string;
	content: string;
	createdAt: string;
	id: string;
	role: "assistant" | "user";
}

interface MessagePageFixture {
	hasMore: boolean;
	messages: MessageFixture[];
	nextBeforeMessageId: string | null;
	turns: [];
}

interface RequestLogEntry {
	method: string;
	path: string;
	search: string;
}

const buildMessageContent = (label: string): string =>
	`${label}\n${Array.from({ length: 24 }, (_, index) => `${label} line ${String(index + 1)}`).join("\n")}`;

const buildLatestPage = (startIndex: number): MessagePageFixture => ({
	hasMore: true,
	messages: Array.from({ length: 5 }, (_, offset) => {
		const index = startIndex + offset;
		return {
			chatId: "chat-1",
			content: buildMessageContent(`Latest message ${String(index)}`),
			createdAt: `2026-01-01T00:00:${String(index).padStart(2, "0")}.000Z`,
			id: `message-${String(index).padStart(2, "0")}`,
			role: index % 2 === 0 ? "assistant" : "user",
		};
	}),
	nextBeforeMessageId: `message-${String(startIndex).padStart(2, "0")}`,
	turns: [],
});

const olderPage: MessagePageFixture = {
	hasMore: true,
	messages: Array.from({ length: 5 }, (_, offset) => {
		const index = 3 + offset;
		return {
			chatId: "chat-1",
			content: buildMessageContent(`Older message ${String(index)}`),
			createdAt: `2026-01-01T00:00:${String(index).padStart(2, "0")}.000Z`,
			id: `message-${String(index).padStart(2, "0")}`,
			role: index % 2 === 0 ? "assistant" : "user",
		};
	}),
	nextBeforeMessageId: "message-03",
	turns: [],
};

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
					window.__wsInstances = window.__wsInstances || [];
					window.__wsSentPayloads = window.__wsSentPayloads || [];
					window.__wsInstances.push(this);
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

				send(payload) {
					window.__wsSentPayloads.push(payload);
				}

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
			window.__emitWsEvent = (payload) => {
				for (const socket of window.__wsInstances ?? []) {
					socket.emit("message", { data: JSON.stringify(payload) });
				}
			};
		})();
	`);
};

const createApiMock = (latestPages: MessagePageFixture[]) => {
	const requests: RequestLogEntry[] = [];
	let latestPageRequestCount = 0;

	const json = (body: unknown, status = 200) => ({
		body: JSON.stringify(body),
		contentType: "application/json",
		status,
	});

	const route = async (intercept: Route): Promise<void> => {
		const request = intercept.request();
		const method = request.method().toUpperCase();
		const url = new URL(request.url());
		const path = url.pathname.replace(/\/+$/, "");
		const search = url.search;

		requests.push({ method, path, search });

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
					selectedChatId: "chat-1",
					selectedModel: "gpt-5.3-codex",
					selectedProjectId: "project-1",
					selectedReasoningEffort: "medium",
				}),
			);
			return;
		}

		if (method === "PATCH" && path === "/v1/selection") {
			await intercept.fulfill(
				json({
					permissionMode: "default",
					selectedChatId: "chat-1",
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
					threads: [{
						id: "chat-1",
						isActive: false,
						title: "Paged Thread",
						updatedAt: "2026-01-01T00:00:12.000Z",
					}],
				}),
			);
			return;
		}

		if (method === "GET" && path === "/v1/chats/chat-1/context") {
			await intercept.fulfill(
				json({
					chat: {
						diffAdded: 0,
						diffRemoved: 0,
						id: "chat-1",
						isActive: false,
						projectId: "project-1",
						provider: "codex",
						status: "completed",
						title: "Paged Thread",
						updatedAt: "2026-01-01T00:00:12.000Z",
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
			const beforeMessageId = url.searchParams.get("beforeMessageId");
			if (beforeMessageId === "message-08") {
				await intercept.fulfill(json(olderPage));
				return;
			}

			const pageIndex = Math.min(latestPageRequestCount, latestPages.length - 1);
			latestPageRequestCount += 1;
			await intercept.fulfill(json(latestPages[pageIndex] ?? latestPages.at(-1) ?? buildLatestPage(8)));
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
						supportedReasoningEfforts: [
							{ description: "Medium", reasoningEffort: "medium" },
						],
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

		await intercept.fulfill(json({ error: `Unmocked route: ${method} ${path}${search}` }, 500));
	};

	return {
		requests,
		route,
	};
};

const countLatestPageRequests = (entries: RequestLogEntry[]): number =>
	entries.filter(
		(entry) =>
			entry.method === "GET"
			&& entry.path === "/v1/chats/chat-1/messages"
			&& entry.search === "?limit=25",
	).length;

const conversationRows = (page: Page) => page.locator('[data-testid^="conversation-message-row-"]');

const scrollConversationToTop = async (page: Page) => {
	await page.locator("[data-radix-scroll-area-viewport]").last().evaluate((node) => {
		node.scrollTop = 0;
		node.dispatchEvent(new Event("scroll", { bubbles: true }));
	});
};

const scrollConversationToBottom = async (page: Page) => {
	await page.locator("[data-radix-scroll-area-viewport]").last().evaluate((node) => {
		node.scrollTop = node.scrollHeight;
		node.dispatchEvent(new Event("scroll", { bubbles: true }));
	});
};

test("chat pagination keeps one rendered page and reloads latest only after leaving the older page", async ({ page }) => {
	const apiMock = createApiMock([
		buildLatestPage(8),
		buildLatestPage(10),
	]);

	await installMockWebSocket(page);
	await page.route("**/v1/**", apiMock.route);
	await page.goto("/");

	await expect(page.getByLabel("Open Paged Thread")).toBeVisible();
	await expect(page.getByText("Latest message 12")).toBeVisible();
	await expect(page.getByText("Older message 7")).toHaveCount(0);
	await expect(conversationRows(page)).toHaveCount(5);

	await expect.poll(() => countLatestPageRequests(apiMock.requests)).toBe(1);

	await scrollConversationToTop(page);

	await expect
		.poll(() =>
			apiMock.requests.some(
				(entry) =>
					entry.method === "GET"
					&& entry.path === "/v1/chats/chat-1/messages"
					&& entry.search.includes("beforeMessageId=message-08")
					&& entry.search.includes("limit=25"),
			),
		)
		.toBe(true);

	await expect(page.getByText("Older message 7")).toBeVisible();
	await expect(page.getByText("Latest message 12")).toHaveCount(0);
	await expect(page.getByTestId("conversation-window-mode")).toHaveText("older");
	await expect(conversationRows(page)).toHaveCount(5);

	await page.evaluate(() => {
		(window as typeof window & { __emitWsEvent?: (payload: unknown) => void }).__emitWsEvent?.({
			data: {
				chatId: "chat-1",
				diffAdded: 2,
				diffRemoved: 0,
				isActive: false,
				status: "completed",
				updatedAt: "2026-01-01T00:00:14.000Z",
			},
			event: "assistant_done",
		});
	});

	await expect(page.getByTestId("conversation-latest-dirty-indicator")).toBeVisible();
	await expect(conversationRows(page)).toHaveCount(5);
	expect(countLatestPageRequests(apiMock.requests)).toBe(1);

	await scrollConversationToBottom(page);

	await expect.poll(() => countLatestPageRequests(apiMock.requests)).toBe(2);
	await expect(page.getByText("Latest message 14")).toBeVisible();
	await expect(page.getByText("Older message 7")).toHaveCount(0);
	await expect(page.getByTestId("conversation-latest-dirty-indicator")).toHaveCount(0);
	await expect(page.getByTestId("conversation-window-mode")).toHaveText("latest");
	await expect(conversationRows(page)).toHaveCount(5);
});

test("optimistic send is replaced by assistant_done refresh without duplicating the user message", async ({ page }) => {
	const optimisticMessage = "Implement the pagination parity";
	const persistedLatestPage: MessagePageFixture = {
		hasMore: true,
		messages: [
			{
				chatId: "chat-1",
				content: buildMessageContent("Latest message 10"),
				createdAt: "2026-01-01T00:00:10.000Z",
				id: "message-10",
				role: "assistant",
			},
			{
				chatId: "chat-1",
				content: buildMessageContent("Latest message 11"),
				createdAt: "2026-01-01T00:00:11.000Z",
				id: "message-11",
				role: "user",
			},
			{
				chatId: "chat-1",
				content: buildMessageContent("Latest message 12"),
				createdAt: "2026-01-01T00:00:12.000Z",
				id: "message-12",
				role: "assistant",
			},
			{
				chatId: "chat-1",
				content: optimisticMessage,
				createdAt: "2026-01-01T00:00:13.000Z",
				id: "message-13",
				role: "user",
			},
			{
				chatId: "chat-1",
				content: "Assistant final reply",
				createdAt: "2026-01-01T00:00:14.000Z",
				id: "message-14",
				role: "assistant",
			},
		],
		nextBeforeMessageId: "message-10",
		turns: [],
	};
	const apiMock = createApiMock([
		buildLatestPage(8),
		persistedLatestPage,
	]);

	await installMockWebSocket(page);
	await page.route("**/v1/**", apiMock.route);
	await page.goto("/");

	await expect(page.getByLabel("Open Paged Thread")).toBeVisible();
	await expect(conversationRows(page)).toHaveCount(5);
	await expect.poll(() => countLatestPageRequests(apiMock.requests)).toBe(1);

	await page.getByLabel("Message input").fill(optimisticMessage);
	await page.getByLabel("Message input").press("Enter");

	await expect(page.getByText(optimisticMessage)).toHaveCount(1);
	await expect(conversationRows(page)).toHaveCount(6);

	await expect
		.poll(async () => {
			return await page.evaluate((expectedMessage) => {
				const payloads = ((window as typeof window & { __wsSentPayloads?: Array<string | object> }).__wsSentPayloads ?? [])
					.map((entry) => {
						try {
							return typeof entry === "string"
								? JSON.parse(entry) as { event?: string; data?: { text?: string } }
								: entry as { event?: string; data?: { text?: string } };
						} catch {
							return null;
						}
					})
					.filter((entry): entry is { event?: string; data?: { text?: string } } => entry !== null);
				return payloads.filter((entry) => entry.event === "user_message" && entry.data?.text === expectedMessage).length;
			}, optimisticMessage);
		})
		.toBe(1);

	await page.evaluate(() => {
		(window as typeof window & { __emitWsEvent?: (payload: unknown) => void }).__emitWsEvent?.({
			data: {
				chatId: "chat-1",
				diffAdded: 2,
				diffRemoved: 0,
				isActive: false,
				status: "completed",
				updatedAt: "2026-01-01T00:00:14.000Z",
			},
			event: "assistant_done",
		});
	});

	await expect.poll(() => countLatestPageRequests(apiMock.requests)).toBe(2);
	await expect(page.getByText(optimisticMessage)).toHaveCount(1);
	await expect(page.getByText("Assistant final reply")).toBeVisible();
	await expect(conversationRows(page)).toHaveCount(5);
});
