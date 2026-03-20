/* eslint-disable @typescript-eslint/consistent-type-assertions, @typescript-eslint/no-explicit-any, @typescript-eslint/prefer-readonly-parameter-types, compat/compat, functional/immutable-data */
import { expect, type Locator, type Page, type Route, test } from "@playwright/test";

interface ChatState {
	id: string;
	isActive: boolean;
	projectId: string;
	status: "pending" | "running" | "completed" | "failed";
	title: string;
	updatedAt: string;
}

interface ApiMock {
	readonly route: (route: Route) => Promise<void>;
}

const BASE_URL = "http://127.0.0.1:4174";
const DEFAULT_PROJECT = {
	id: "project-1",
	name: "Workspace 1",
	path: "/tmp/workspace-1",
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
	chats: ChatState[];
	selectedChatId: string | null;
	selectedProjectId?: string;
}) => {
	const chats = [...options.chats];
	let nextChatCounter = 0;
	let selectedChatId = options.selectedChatId;
	let selectedProjectId = options.selectedProjectId ?? DEFAULT_PROJECT.id;

	const json = (body: unknown, status = 200) => ({
		body: JSON.stringify(body),
		contentType: "application/json",
		status,
	});

	const toChatDto = (chat: ChatState) => ({
		diffAdded: 0,
		diffRemoved: 0,
		id: chat.id,
		isActive: chat.isActive,
		projectId: chat.projectId,
		provider: "codex",
		status: chat.status,
		title: chat.title,
		updatedAt: chat.updatedAt,
	});

	const route = async (intercept: Route): Promise<void> => {
		const request = intercept.request();
		const method = request.method().toUpperCase();
		const url = new URL(request.url());
		const path = url.pathname.replace(/\/+$/, "");

		if (method === "GET" && path === "/v1/projects/workspaces") {
			await intercept.fulfill(json({ workspaces: [DEFAULT_PROJECT] }));
			return;
		}

		if (method === "GET" && path === "/v1/selection") {
			await intercept.fulfill(
				json({
					permissionMode: "default",
					selectedChatId,
					selectedModel: "gpt-5.3-codex",
					selectedProjectId,
					selectedProvider: "codex",
					selectedReasoningEffort: "medium",
				}),
			);
			return;
		}

		if (method === "PATCH" && path === "/v1/selection") {
			const payload = request.postDataJSON() as {
				selectedChatId?: string | null;
				selectedProjectId?: string | null;
			};
			if (Object.hasOwn(payload, "selectedChatId")) {
				selectedChatId = payload.selectedChatId ?? null;
			}
			if (typeof payload.selectedProjectId === "string") {
				selectedProjectId = payload.selectedProjectId;
			}

			await intercept.fulfill(
				json({
					permissionMode: "default",
					selectedChatId,
					selectedModel: "gpt-5.3-codex",
					selectedProjectId,
					selectedProvider: "codex",
					selectedReasoningEffort: "medium",
				}),
			);
			return;
		}

		if (method === "GET" && path === `/v1/projects/${DEFAULT_PROJECT.id}/threads`) {
			await intercept.fulfill(
				json({
					threads: chats
						.filter((chat) => chat.projectId === DEFAULT_PROJECT.id)
						.map((chat) => ({
							id: chat.id,
							isActive: chat.isActive,
							title: chat.title,
							updatedAt: chat.updatedAt,
						})),
				}),
			);
			return;
		}

		if (method === "POST" && path === `/v1/projects/${DEFAULT_PROJECT.id}/chats`) {
			nextChatCounter += 1;
			const createdAt = new Date(Date.now() + nextChatCounter).toISOString();
			const createdChat: ChatState = {
				id: `chat-created-${String(nextChatCounter)}`,
				isActive: false,
				projectId: DEFAULT_PROJECT.id,
				status: "pending",
				title: "New thread",
				updatedAt: createdAt,
			};
			chats.unshift(createdChat);

			await intercept.fulfill(json({ chat: toChatDto(createdChat) }, 201));
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
					chat: toChatDto(chat),
					project: DEFAULT_PROJECT,
				}),
			);
			return;
		}

		const messagesMatch = /^\/v1\/chats\/([^/]+)\/messages$/.exec(path);
		if (method === "GET" && messagesMatch) {
			await intercept.fulfill(json({
				hasMore: false,
				messages: [],
				nextBeforeMessageId: null,
				turns: [],
			}));
			return;
		}

		const streamEventsMatch = /^\/v1\/chats\/([^/]+)\/stream-events$/.exec(path);
		if (method === "GET" && streamEventsMatch) {
			await intercept.fulfill(json({ events: [], hasMore: false, nextAfterId: null }));
			return;
		}

		const readMatch = /^\/v1\/chats\/([^/]+)\/read$/.exec(path);
		if (method === "POST" && readMatch) {
			const chatId = readMatch[1];
			const chat = chats.find((item) => item.id === chatId);
			if (!chat) {
				await intercept.fulfill(json({ error: "chat not found" }, 404));
				return;
			}

			await intercept.fulfill(json({ chat: toChatDto(chat) }));
			return;
		}

		if (method === "GET" && path === "/v1/providers/codex/models") {
			await intercept.fulfill(
				json({
					models: [{
						defaultReasoningEffort: "medium",
						displayName: "GPT-5.3 Codex",
						id: "gpt-5.3-codex",
						isDefault: true,
						model: "gpt-5.3-codex",
						supportedReasoningEfforts: [{ reasoningEffort: "medium" }],
					}],
					nextCursor: null,
				}),
			);
			return;
		}

		if (method === "GET" && path === "/v1/providers/claude/models") {
			await intercept.fulfill(json({ models: [], nextCursor: null }));
			return;
		}

		if (method === "GET" && path === `/v1/projects/${DEFAULT_PROJECT.id}/git/status`) {
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

		if (method === "GET" && path === `/v1/projects/${DEFAULT_PROJECT.id}/git/branches`) {
			await intercept.fulfill(json({ branches: [], currentBranch: null }));
			return;
		}

		await intercept.fulfill(json({ error: `unmocked route: ${method} ${path}` }, 500));
	};

	return { route };
};

const mountApp = async (page: Page, apiMock: ApiMock) => {
	await installMockWebSocket(page);
	await page.route("**/v1/**", apiMock.route);
	await page.goto("/");
	await expect(page.getByLabel(`Select ${DEFAULT_PROJECT.name}`)).toBeVisible();
};

const composeDeadKeySequence = async (textarea: Locator) => {
	await textarea.evaluate((element) => {
		const input = element as HTMLTextAreaElement;
		const commit = (nextValue: string) => {
			input.value = nextValue;
			input.dispatchEvent(new Event("input", { bubbles: true }));
		};

		input.focus();
		commit("N");
		input.dispatchEvent(new CompositionEvent("compositionstart", {
			bubbles: true,
			data: "~",
		}));
		commit("N˜");
		commit("N˜ã");
		input.dispatchEvent(new CompositionEvent("compositionend", {
			bubbles: true,
			data: "ã",
		}));
	});
};

test("[D-65] workspace plus creates and selects a new thread without expanding hidden history", async ({ page }) => {
	const apiMock = createApiMock({
		chats: [
			{ id: "chat-1", isActive: false, projectId: DEFAULT_PROJECT.id, status: "pending", title: "Alpha", updatedAt: "2026-03-20T10:00:00.000Z" },
			{ id: "chat-2", isActive: false, projectId: DEFAULT_PROJECT.id, status: "pending", title: "Beta", updatedAt: "2026-03-20T09:00:00.000Z" },
			{ id: "chat-3", isActive: false, projectId: DEFAULT_PROJECT.id, status: "pending", title: "Gamma", updatedAt: "2026-03-20T08:00:00.000Z" },
			{ id: "chat-4", isActive: false, projectId: DEFAULT_PROJECT.id, status: "pending", title: "Hidden thread", updatedAt: "2026-03-20T07:00:00.000Z" },
		],
		selectedChatId: "chat-2",
	});

	await mountApp(page, apiMock);

	await expect(page.getByRole("button", { name: "Show more threads" })).toBeVisible();
	await expect(page.getByLabel("Open Hidden thread")).toHaveCount(0);

	await page.getByLabel(`Select ${DEFAULT_PROJECT.name}`).hover();
	await page.getByLabel(`New thread in ${DEFAULT_PROJECT.name}`).click();

	await expect(page.getByRole("heading", { level: 2, name: "New thread" })).toBeVisible();
	await expect(page.getByLabel("Open New thread")).toBeVisible();
	await expect(page.getByRole("button", { name: "Show more threads" })).toBeVisible();
	await expect(page.getByLabel("Open Hidden thread")).toHaveCount(0);
});

test("[D-66] clicking a thread focuses the composer and paste lands directly in the textarea", async ({ page, browserName }) => {
	await page.context().grantPermissions(["clipboard-read", "clipboard-write"], { origin: BASE_URL });
	const apiMock = createApiMock({
		chats: [
			{ id: "chat-1", isActive: false, projectId: DEFAULT_PROJECT.id, status: "pending", title: "Alpha", updatedAt: "2026-03-20T10:00:00.000Z" },
			{ id: "chat-2", isActive: false, projectId: DEFAULT_PROJECT.id, status: "pending", title: "Portuguese thread", updatedAt: "2026-03-20T09:00:00.000Z" },
		],
		selectedChatId: "chat-1",
	});

	await mountApp(page, apiMock);

	const textarea = page.getByLabel("Message input");
	const clipboardText = browserName === "webkit" ? "colar direto" : "colar direto";

	await page.evaluate(async (text) => {
		await navigator.clipboard.writeText(text);
	}, clipboardText);

	await page.getByLabel("Open Portuguese thread").click();

	await expect(textarea).toBeFocused();
	await page.keyboard.press(process.platform === "darwin" ? "Meta+V" : "Control+V");
	await expect(textarea).toHaveValue(clipboardText);
});

test("[D-67] clicking the already selected thread returns focus to the composer", async ({ page }) => {
	const apiMock = createApiMock({
		chats: [
			{ id: "chat-1", isActive: false, projectId: DEFAULT_PROJECT.id, status: "pending", title: "Alpha", updatedAt: "2026-03-20T10:00:00.000Z" },
			{ id: "chat-2", isActive: false, projectId: DEFAULT_PROJECT.id, status: "pending", title: "Beta", updatedAt: "2026-03-20T09:00:00.000Z" },
		],
		selectedChatId: "chat-1",
	});

	await mountApp(page, apiMock);

	const textarea = page.getByLabel("Message input");
	await textarea.click();
	await expect(textarea).toBeFocused();

	await page.getByLabel("Open Alpha").click();

	await expect(textarea).toBeFocused();
});

test("[D-68] dead-key composition does not duplicate the standalone accent in the composer", async ({ page }) => {
	const apiMock = createApiMock({
		chats: [
			{ id: "chat-1", isActive: false, projectId: DEFAULT_PROJECT.id, status: "pending", title: "Portuguese thread", updatedAt: "2026-03-20T10:00:00.000Z" },
		],
		selectedChatId: "chat-1",
	});

	await mountApp(page, apiMock);

	const textarea = page.getByLabel("Message input");
	await page.getByLabel("Open Portuguese thread").click();
	await expect(textarea).toBeFocused();

	await composeDeadKeySequence(textarea);
	await page.keyboard.type("o");

	await expect(textarea).toHaveValue("Não");
});
