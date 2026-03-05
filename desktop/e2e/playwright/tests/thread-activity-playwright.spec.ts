/* eslint-disable @typescript-eslint/consistent-type-assertions, @typescript-eslint/no-explicit-any, @typescript-eslint/prefer-readonly-parameter-types, compat/compat, functional/immutable-data, max-lines, max-statements */
import { expect, type Page, type Route, test } from "@playwright/test";

interface ChatState {
	id: string;
	isActive: boolean;
	status: "pending" | "running" | "completed" | "failed";
	title: string;
	updatedAt: string;
}

interface ApiMock {
	requests: Array<{ method: string; path: string }>;
	route: (route: Route) => Promise<void>;
}

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
					window.__wsSentPayloads = window.__wsSentPayloads || [];
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
		})();
	`);
};

const createApiMock = (options: {
	chats: ChatState[];
	selectedChatId: string | null;
}): ApiMock => {
	const requests: Array<{ method: string; path: string }> = [];
	const chats = [...options.chats];
	let selectedChatId = options.selectedChatId;
	let chatCounter = 0;

	const json = (body: unknown, status = 200) => ({
		body: JSON.stringify(body),
		contentType: "application/json",
		status,
	});

	const parsePath = (url: URL): string => url.pathname.replace(/\/+$/, "");

	const route = async (intercept: Route): Promise<void> => {
		const request = intercept.request();
		const method = request.method().toUpperCase();
		const url = new URL(request.url());
		const path = parsePath(url);

		requests.push({ method, path });

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

		if (method === "POST" && path === "/v1/projects/project-1/chats") {
			const payload = (request.postDataJSON() as { title?: string }) ?? {};
			chatCounter += 1;
			const now = new Date(Date.now() + chatCounter).toISOString();
			const created: ChatState = {
				id: `chat-created-${String(chatCounter)}`,
				isActive: false,
				status: "pending",
				title: payload.title ?? "New thread",
				updatedAt: now,
			};
			chats.unshift(created);

			await intercept.fulfill(
				json(
					{
						chat: {
							diffAdded: 0,
							diffRemoved: 0,
							id: created.id,
							isActive: false,
							projectId: "project-1",
							provider: "codex",
							status: "pending",
							title: created.title,
							updatedAt: created.updatedAt,
						},
					},
					201,
				),
			);
			return;
		}

		const chatContextMatch = /^\/v1\/chats\/([^/]+)\/context$/.exec(path);
		if (method === "GET" && chatContextMatch) {
			const chatId = chatContextMatch[1];
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
			await intercept.fulfill(json({ messages: [] }));
			return;
		}

		const stopMatch = /^\/v1\/chats\/([^/]+)\/stop$/.exec(path);
		if (method === "POST" && stopMatch) {
			const chatId = stopMatch[1];
			const chat = chats.find((item) => item.id === chatId);
			if (!chat) {
				await intercept.fulfill(json({ error: "chat not found" }, 404));
				return;
			}

			chat.isActive = false;
			chat.status = "failed";
			chat.updatedAt = new Date().toISOString();

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
					state: "stale_cleared",
					stopped: true,
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
							displayName: "GPT-5.3 Codex",
							id: "gpt-5.3-codex",
							isDefault: true,
							model: "gpt-5.3-codex",
							supportedReasoningEfforts: [{ reasoningEffort: "medium" }],
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

		await intercept.fulfill(json({ error: "route not mocked" }, 501));
	};

	return { requests, route };
};

const getThreadOrderLabels = async (page: Page): Promise<string[]> =>
	await page.locator('.codex-sidebar [aria-label^="Open "]').evaluateAll((nodes) =>
		nodes
			.map((node) => node.getAttribute("aria-label") ?? "")
			.filter((label) => label.length > 0 && label !== "Open project folder"),
	);

test("active thread shows Force Stop and issues stop request", async ({ page }) => {
	const apiMock = createApiMock({
		chats: [
			{
				id: "chat-active",
				isActive: true,
				status: "running",
				title: "Active Thread",
				updatedAt: "2026-01-01T00:00:03.000Z",
			},
			{
				id: "chat-idle",
				isActive: false,
				status: "completed",
				title: "Idle Thread",
				updatedAt: "2026-01-01T00:00:02.000Z",
			},
		],
		selectedChatId: "chat-active",
	});

	await installMockWebSocket(page);
	await page.route("**/v1/**", apiMock.route);
	await page.goto("/");

	await expect(page.getByLabel("Open Active Thread")).toBeVisible();
	await expect(page.getByTestId("conversation-working-indicator")).toBeVisible();
	await expect(page.getByRole("button", { name: "Force Stop" })).toBeVisible();
	await page.getByRole("button", { name: "Force Stop" }).click();

	await expect
		.poll(() =>
			apiMock.requests.some(
				(entry) => entry.method === "POST" && entry.path === "/v1/chats/chat-active/stop",
			),
		)
		.toBe(true);
	await expect(page.getByRole("button", { name: "Send" })).toBeVisible();
	await expect(page.getByText("Active", { exact: true })).toHaveCount(0);
});

test("sending from an older idle thread moves it to top immediately", async ({ page }) => {
	const apiMock = createApiMock({
		chats: [
			{
				id: "chat-active",
				isActive: true,
				status: "running",
				title: "Active Thread",
				updatedAt: "2026-01-01T00:00:03.000Z",
			},
			{
				id: "chat-idle-top",
				isActive: false,
				status: "completed",
				title: "Idle Top",
				updatedAt: "2026-01-01T00:00:02.000Z",
			},
			{
				id: "chat-idle-bottom",
				isActive: false,
				status: "completed",
				title: "Idle Bottom",
				updatedAt: "2026-01-01T00:00:01.000Z",
			},
		],
		selectedChatId: "chat-active",
	});

	await installMockWebSocket(page);
	await page.route("**/v1/**", apiMock.route);
	await page.goto("/");
	await expect(page.getByLabel("Open Active Thread")).toBeVisible();
	await expect(page.getByLabel("Open Idle Bottom")).toBeVisible();

	const initialOrder = await getThreadOrderLabels(page);
	expect(initialOrder[0]).toBe("Open Active Thread");
	expect(initialOrder.at(-1)).toBe("Open Idle Bottom");

	await page.getByLabel("Open Idle Bottom").click();
	await page.getByLabel("Message input").fill("Reorder this thread");
	await page.getByRole("button", { name: "Send" }).click();

	await expect
		.poll(async () => (await getThreadOrderLabels(page))[0])
		.toBe("Open Idle Bottom");
});

test("create-and-send from draft creates one chat and does not surface chat-not-found", async ({ page }) => {
	const apiMock = createApiMock({
		chats: [],
		selectedChatId: null,
	});

	await installMockWebSocket(page);
	await page.route("**/v1/**", apiMock.route);
	await page.goto("/");

	await page.getByLabel("Message input").fill("First message in new draft");
	await page.getByRole("button", { name: "Send" }).click();

	await expect
		.poll(() =>
			apiMock.requests.filter(
				(entry) => entry.method === "POST" && entry.path === "/v1/projects/project-1/chats",
			).length,
		)
		.toBe(1);

	await expect(page.getByText("chat not found", { exact: false })).toHaveCount(0);
	await expect
		.poll(async () => (await getThreadOrderLabels(page)).filter((label) => label.startsWith("Open ")).length)
		.toBe(1);
});
