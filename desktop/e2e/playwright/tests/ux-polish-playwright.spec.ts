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

const routeApi = async (intercept: Route): Promise<void> => {
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
				selectedChatId: null,
				selectedModel: null,
				selectedProjectId: "project-1",
				selectedReasoningEffort: null,
			}),
		);
		return;
	}

	if (method === "PATCH" && path === "/v1/selection") {
		await intercept.fulfill(
			json({
				permissionMode: "default",
				selectedChatId: null,
				selectedModel: "gpt-5.3-codex",
				selectedProjectId: "project-1",
				selectedReasoningEffort: "medium",
			}),
		);
		return;
	}

	if (method === "GET" && path === "/v1/projects/project-1/threads") {
		await intercept.fulfill(json({ threads: [] }));
		return;
	}

	if (method === "GET" && path === "/v1/providers/codex/models") {
		await new Promise((resolve) => {
			setTimeout(resolve, 1_000);
		});
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

test.beforeEach(async ({ page }) => {
	await installMockWebSocket(page);
	await page.route("**/v1/**", routeApi);
});

test("[D-56] model select shows a loading label instead of an empty state", async ({ page }) => {
	await page.goto("/");

	await expect(page.getByLabel("Select Workspace 1")).toBeVisible();

	const modelSelect = page.getByLabel("Model");
	await expect(modelSelect.locator("option").first()).toHaveText("Loading models...");
	await expect(modelSelect.locator("option", { hasText: "No models" })).toHaveCount(0);

	await expect
		.poll(async () =>
			await modelSelect.evaluate((element) =>
				Array.from((element as HTMLSelectElement).options).map((option) => option.textContent ?? ""),
			),
		)
		.toContain("GPT-5.3 Codex");
});

test("[D-50] sidebar resize shows and clears the overlay during drag", async ({ page }) => {
	await page.goto("/");

	await expect(page.getByLabel("Select Workspace 1")).toBeVisible();

	const resizer = page.getByLabel("Resize sidebar");
	const box = await resizer.boundingBox();
	if (!box) {
		throw new Error("sidebar_resizer_not_found");
	}

	await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
	await page.mouse.down();
	await page.mouse.move(box.x + 48, box.y + box.height / 2);
	await expect(page.getByTestId("sidebar-resize-overlay")).toBeVisible();
	await page.mouse.up();
	await expect(page.getByTestId("sidebar-resize-overlay")).toHaveCount(0);
});

test("[D-58] sidebar drag avoids root rerenders on pointer move", async ({ page }) => {
	await page.goto("/");

	await expect(page.getByLabel("Select Workspace 1")).toBeVisible();

	const modelSelect = page.getByLabel("Model");
	await expect
		.poll(async () =>
			await modelSelect.evaluate((element) =>
				Array.from((element as HTMLSelectElement).options).map((option) => option.textContent ?? ""),
			),
		)
		.toContain("GPT-5.3 Codex");

	await page.waitForFunction(() => {
		type RenderStats = {
			getCounts: () => Record<string, number>;
			reset: () => void;
		};

		return Boolean((window as Window & { __RC_RENDER_STATS__?: RenderStats }).__RC_RENDER_STATS__);
	});

	await page.evaluate(() => {
		type RenderStats = {
			getCounts: () => Record<string, number>;
			reset: () => void;
		};

		(window as Window & { __RC_RENDER_STATS__?: RenderStats }).__RC_RENDER_STATS__?.reset();
	});

	const resizer = page.getByLabel("Resize sidebar");
	const box = await resizer.boundingBox();
	if (!box) {
		throw new Error("sidebar_resizer_not_found");
	}

	await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
	await page.mouse.down();
	await page.mouse.move(box.x + 24, box.y + box.height / 2);
	await page.mouse.move(box.x + 48, box.y + box.height / 2);
	await page.mouse.move(box.x + 72, box.y + box.height / 2);
	await page.mouse.up();

	const renderCounts = await page.evaluate(() => {
		type RenderStats = {
			getCounts: () => Record<string, number>;
			reset: () => void;
		};

		return (window as Window & { __RC_RENDER_STATS__?: RenderStats }).__RC_RENDER_STATS__?.getCounts() ?? {};
	});

	expect(renderCounts["app-root"] ?? 0).toBeLessThanOrEqual(2);
});
