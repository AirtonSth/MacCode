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
	`${label}\n${Array.from({ length: 8 }, (_, index) => `${label} line ${String(index + 1)}`).join("\n")}`;

const buildLatestPage = (
	startIndex: number,
	overrides?: { finalAssistantMessage?: MessageFixture },
): MessagePageFixture => {
	const messages = Array.from({ length: 5 }, (_, offset) => {
		const index = startIndex + offset;
		return {
			chatId: "chat-1",
			content: buildMessageContent(`Latest message ${String(index)}`),
			createdAt: `2026-01-01T00:00:${String(index).padStart(2, "0")}.000Z`,
			id: `message-${String(index).padStart(2, "0")}`,
			role: index % 2 === 0 ? "assistant" : "user",
		} satisfies MessageFixture;
	});

	if (overrides?.finalAssistantMessage) {
		messages[messages.length - 1] = overrides.finalAssistantMessage;
	}

	return {
		hasMore: true,
		messages,
		nextBeforeMessageId: `message-${String(startIndex).padStart(2, "0")}`,
		turns: [],
	};
};

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
		} satisfies MessageFixture;
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

				send() {}

				close() {
					if (this.readyState === MockWebSocket.CLOSED) {
						return;
					}
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
					if (socket.readyState === MockWebSocket.OPEN) {
						socket.emit("message", { data: JSON.stringify(payload) });
					}
				}
			};
			window.__closeLatestWs = () => {
				const instances = window.__wsInstances ?? [];
				const latest = instances[instances.length - 1];
				latest?.close();
			};
		})();
	`);
};

const json = (body: unknown, status = 200) => ({
	body: JSON.stringify(body),
	contentType: "application/json",
	status,
});

const countRequests = (
	entries: RequestLogEntry[],
	method: string,
	path: string,
	search?: string,
): number =>
	entries.filter((entry) =>
		entry.method === method &&
		entry.path === path &&
		(search === undefined || entry.search === search)
	).length;

const countLatestPageRequests = (entries: RequestLogEntry[]): number =>
	countRequests(entries, "GET", "/v1/chats/chat-1/messages", "?limit=25");

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

const emitWsEvent = async (page: Page, payload: unknown) => {
	await page.evaluate((nextPayload) => {
		(window as Window & { __emitWsEvent?: (value: unknown) => void }).__emitWsEvent?.(nextPayload);
	}, payload);
};

const closeLatestWs = async (page: Page) => {
	await page.evaluate(() => {
		(window as Window & { __closeLatestWs?: () => void }).__closeLatestWs?.();
	});
};

const createApiMock = (input?: {
	active?: boolean;
	latestPages?: MessagePageFixture[];
	streamEventsAfterReconnect?: Array<{ event: unknown; id: number }>;
}) => {
	const requests: RequestLogEntry[] = [];
	let latestPageRequestCount = 0;
	let reconnectStreamEventsDelivered = false;

	const latestPages = input?.latestPages ?? [buildLatestPage(8)];
	const isActive = input?.active ?? false;
	const streamEventsAfterReconnect = input?.streamEventsAfterReconnect ?? [];

	const route = async (intercept: Route): Promise<void> => {
		const request = intercept.request();
		const method = request.method().toUpperCase();
		const url = new URL(request.url());
		const path = url.pathname.replace(/\/+$/, "");
		const search = url.search;

		requests.push({ method, path, search });

		if (method === "GET" && path === "/v1/private-account/state") {
			await intercept.fulfill(json({
				authenticated: false,
				connector: null,
				connectorRelayState: "idle",
				errorMessage: null,
				user: null,
			}));
			return;
		}

		if (method === "GET" && path === "/v1/projects/workspaces") {
			await intercept.fulfill(json({
				workspaces: [{ id: "project-1", name: "Workspace 1", path: "/tmp/workspace-1" }],
			}));
			return;
		}

		if (method === "GET" && path === "/v1/selection") {
			await intercept.fulfill(json({
				permissionMode: "default",
				selectedChatId: "chat-1",
				selectedModel: "gpt-5.3-codex",
				selectedProjectId: "project-1",
				selectedReasoningEffort: "medium",
			}));
			return;
		}

		if (method === "PATCH" && path === "/v1/selection") {
			await intercept.fulfill(json({
				permissionMode: "default",
				selectedChatId: "chat-1",
				selectedModel: "gpt-5.3-codex",
				selectedProjectId: "project-1",
				selectedReasoningEffort: "medium",
			}));
			return;
		}

		if (method === "GET" && path === "/v1/projects/project-1/threads") {
			await intercept.fulfill(json({
				threads: [{
					id: "chat-1",
					isActive,
					title: "Stream Thread",
					updatedAt: "2026-01-01T00:00:12.000Z",
				}],
			}));
			return;
		}

		if (method === "GET" && path === "/v1/chats/chat-1/context") {
			const chat = {
				diffAdded: 0,
				diffRemoved: 0,
				id: "chat-1",
				isActive,
				projectId: "project-1",
				provider: "codex",
				status: isActive ? "running" : "completed",
				title: "Stream Thread",
				updatedAt: "2026-01-01T00:00:12.000Z",
			};
			await intercept.fulfill(json({
				chat,
				project: {
					id: "project-1",
					name: "Workspace 1",
					path: "/tmp/workspace-1",
				},
			}));
			return;
		}

		if (method === "POST" && path === "/v1/chats/chat-1/read") {
			await intercept.fulfill(json({
				diffAdded: 0,
				diffRemoved: 0,
				finishedAt: null,
				hasUnreadFinished: false,
				id: "chat-1",
				isActive,
				lastReadAt: "2026-01-01T00:00:12.500Z",
				projectId: "project-1",
				provider: "codex",
				status: isActive ? "running" : "completed",
				title: "Stream Thread",
				updatedAt: "2026-01-01T00:00:12.000Z",
			}));
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

		if (method === "GET" && path === "/v1/chats/chat-1/stream-events") {
			const afterId = Number(url.searchParams.get("afterId") ?? "0");
			if (
				isActive &&
				afterId >= 2 &&
				!reconnectStreamEventsDelivered &&
				streamEventsAfterReconnect.length > 0
			) {
				reconnectStreamEventsDelivered = true;
				await intercept.fulfill(json({
					events: streamEventsAfterReconnect,
					hasMore: false,
					nextAfterId: null,
				}));
				return;
			}

			await intercept.fulfill(json({
				events: [],
				hasMore: false,
				nextAfterId: null,
			}));
			return;
		}

		if (method === "GET" && path === "/v1/providers/codex/models") {
			await intercept.fulfill(json({
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
			}));
			return;
		}

		if (method === "GET" && path === "/v1/projects/project-1/git/status") {
			await intercept.fulfill(json({
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
			}));
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

test("assistant_event catch-up dedupes reconnect history and preserves one structured timeline", async ({ page }) => {
	const apiMock = createApiMock({
		active: true,
		streamEventsAfterReconnect: [
			{ event: { turnId: "turn-1", type: "turn_started" }, id: 1 },
			{
				event: {
					itemId: "plan-1",
					itemType: "plan",
					summary: "Plan work",
					turnId: "turn-1",
					type: "item_started",
				},
				id: 2,
			},
			{
				event: {
					itemId: "tool-1",
					itemType: "tool",
					summary: "Run ls",
					turnId: "turn-1",
					type: "item_started",
				},
				id: 3,
			},
		],
	});

	await installMockWebSocket(page);
	await page.route("**/v1/**", apiMock.route);
	await page.goto("/");

	await expect(page.getByLabel("Open Stream Thread")).toBeVisible();
	await expect(page.getByText("Latest message 12")).toBeVisible();

	await emitWsEvent(page, {
		data: {
			chatId: "chat-1",
			event: { turnId: "turn-1", type: "turn_started" },
			eventId: 1,
		},
		event: "assistant_event",
	});
	await emitWsEvent(page, {
		data: {
			chatId: "chat-1",
			event: {
				itemId: "plan-1",
				itemType: "plan",
				summary: "Plan work",
				turnId: "turn-1",
				type: "item_started",
			},
			eventId: 2,
		},
		event: "assistant_event",
	});

	await expect(page.getByText("Plan work")).toHaveCount(1);

	await closeLatestWs(page);

	await expect
		.poll(() => countRequests(apiMock.requests, "GET", "/v1/chats/chat-1/stream-events", "?afterId=2&limit=500"))
		.toBeGreaterThan(0);

	await expect(page.getByText("Plan work")).toHaveCount(1);
	await expect(page.getByText("Run ls")).toHaveCount(1);
});

test("workspace message_created appends directly into the visible latest page without refetching", async ({ page }) => {
	const apiMock = createApiMock({
		latestPages: [buildLatestPage(8)],
	});

	await installMockWebSocket(page);
	await page.route("**/v1/**", apiMock.route);
	await page.goto("/");

	await expect(page.getByLabel("Open Stream Thread")).toBeVisible();
	await expect(conversationRows(page)).toHaveCount(5);
	await expect.poll(() => countLatestPageRequests(apiMock.requests)).toBe(1);

	await emitWsEvent(page, {
		data: {
			originClientId: null,
			payload: {
				message: {
					chatId: "chat-1",
					content: "Workspace appended assistant reply",
					createdAt: "2026-01-01T00:00:13.000Z",
					id: "message-13",
					role: "assistant",
				},
			},
			requestId: null,
			seq: 10,
			ts: "2026-01-01T00:00:13.500Z",
			type: "message_created",
		},
		event: "workspace_event",
	});

	await expect(page.getByText("Workspace appended assistant reply")).toBeVisible();
	await expect(conversationRows(page)).toHaveCount(6);
	expect(countLatestPageRequests(apiMock.requests)).toBe(1);
});

test("workspace message_created keeps older page pinned until the user returns to latest", async ({ page }) => {
	const apiMock = createApiMock({
		latestPages: [
			buildLatestPage(8),
			buildLatestPage(10, {
				finalAssistantMessage: {
					chatId: "chat-1",
					content: "Workspace newest assistant reply",
					createdAt: "2026-01-01T00:00:14.000Z",
					id: "message-14",
					role: "assistant",
				},
			}),
		],
	});

	await installMockWebSocket(page);
	await page.route("**/v1/**", apiMock.route);
	await page.goto("/");

	await expect(page.getByLabel("Open Stream Thread")).toBeVisible();
	await expect.poll(() => countLatestPageRequests(apiMock.requests)).toBe(1);

	await scrollConversationToTop(page);

	await expect
		.poll(() =>
			apiMock.requests.some((entry) =>
				entry.method === "GET" &&
				entry.path === "/v1/chats/chat-1/messages" &&
				entry.search.includes("beforeMessageId=message-08") &&
				entry.search.includes("limit=25")
			),
		)
		.toBe(true);

	await expect(page.getByText("Older message 7")).toBeVisible();
	await expect(page.getByTestId("conversation-window-mode")).toHaveText("older");

	await emitWsEvent(page, {
		data: {
			originClientId: null,
			payload: {
				message: {
					chatId: "chat-1",
					content: "Workspace newest assistant reply",
					createdAt: "2026-01-01T00:00:14.000Z",
					id: "message-14",
					role: "assistant",
				},
			},
			requestId: null,
			seq: 11,
			ts: "2026-01-01T00:00:14.500Z",
			type: "message_created",
		},
		event: "workspace_event",
	});

	await expect(page.getByText("Workspace newest assistant reply")).toHaveCount(0);
	await expect(page.getByTestId("conversation-latest-dirty-indicator")).toBeVisible();
	expect(countLatestPageRequests(apiMock.requests)).toBe(1);

	await scrollConversationToBottom(page);

	await expect.poll(() => countLatestPageRequests(apiMock.requests)).toBe(2);
	await expect(page.getByText("Workspace newest assistant reply")).toBeVisible();
	await expect(page.getByTestId("conversation-window-mode")).toHaveText("latest");
});
