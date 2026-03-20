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

const createRouteApi = (selectedChatId: string | null = null) => {
	return async (intercept: Route): Promise<void> => {
		const request = intercept.request();
		const method = request.method().toUpperCase();
		const url = new URL(request.url());
		const path = url.pathname.replace(/\/+$/, "");

		if (method === "GET" && path === "/v1/projects/workspaces") {
			await intercept.fulfill(
				json({ workspaces: [{ id: "project-1", name: "Workspace 1", path: "/tmp/workspace-1" }] }),
			);
			return;
		}

		if (method === "GET" && path === "/v1/selection") {
			await intercept.fulfill(
				json({
					permissionMode: "default",
					selectedChatId,
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
					selectedChatId,
					selectedModel: "gpt-5.3-codex",
					selectedProjectId: "project-1",
					selectedReasoningEffort: "medium",
				}),
			);
			return;
		}

		if (method === "GET" && path === "/v1/projects/project-1/threads") {
			if (selectedChatId) {
				await intercept.fulfill(
					json({
						threads: [{
							id: selectedChatId,
							projectId: "project-1",
							title: "Test thread",
							createdAt: "2026-03-20T00:00:00Z",
							updatedAt: "2026-03-20T00:00:00Z",
							provider: "codex",
							providerThreadId: null,
						}],
					}),
				);
			} else {
				await intercept.fulfill(json({ threads: [] }));
			}
			return;
		}

		if (method === "GET" && /\/v1\/projects\/project-1\/threads\/[^/]+\/messages/.test(path)) {
			await intercept.fulfill(json({ messages: [], nextCursor: null }));
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
					added: 0, ahead: 0, behind: 0, changedFiles: 0, conflictedFiles: 0,
					currentBranch: null, isDetachedHead: false, isRepo: false,
					removed: 0, stagedFiles: 0, unstagedFiles: 0, untrackedFiles: 0,
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

// ─── Idle mode (no active thread) ───

test.describe("idle mode (no active thread)", () => {
	test.beforeEach(async ({ page }) => {
		await installMockWebSocket(page);
		await page.route("**/v1/**", createRouteApi(null));
	});

	test("sidebar has lava lamp with data-mode=idle", async ({ page }) => {
		await page.goto("/");
		await expect(page.getByLabel("Select Workspace 1")).toBeVisible();

		const lava = page.locator("aside.codex-sidebar .lava-lamp-container");
		await expect(lava).toBeVisible();
		await expect(lava).toHaveAttribute("data-mode", "idle");
	});

	test("only one lava lamp exists (sidebar only)", async ({ page }) => {
		await page.goto("/");
		await expect(page.getByLabel("Select Workspace 1")).toBeVisible();

		await expect(page.locator(".lava-lamp-container")).toHaveCount(1);
		await expect(page.locator("main .lava-lamp-container")).toHaveCount(0);
	});

	test("idle blobs have 10-15% opacity", async ({ page }) => {
		await page.goto("/");
		await expect(page.getByLabel("Select Workspace 1")).toBeVisible();

		const blobs = page.locator("aside.codex-sidebar .lava-blob");
		await expect(blobs).toHaveCount(5);

		for (let i = 0; i < 5; i++) {
			const opacity = await blobs.nth(i).evaluate(
				(el) => parseFloat(window.getComputedStyle(el).opacity),
			);
			expect(opacity).toBeGreaterThanOrEqual(0.08);
			expect(opacity).toBeLessThanOrEqual(0.18);
		}
	});

	test("idle blobs animate over time", async ({ page }) => {
		await page.goto("/");
		await expect(page.getByLabel("Select Workspace 1")).toBeVisible();

		const blob = page.locator("aside.codex-sidebar .lava-blob").first();
		const t1 = await blob.evaluate((el) => window.getComputedStyle(el).transform);
		await page.waitForTimeout(2000);
		const t2 = await blob.evaluate((el) => window.getComputedStyle(el).transform);

		expect(t2).not.toBe(t1);
	});

	test("pointer events pass through", async ({ page }) => {
		await page.goto("/");
		await expect(page.getByLabel("Select Workspace 1")).toBeVisible();

		const pe = await page.locator(".lava-lamp-container").evaluate(
			(el) => window.getComputedStyle(el).pointerEvents,
		);
		expect(pe).toBe("none");
	});
});

// ─── Active mode (thread selected) ───

test.describe("active mode (thread selected)", () => {
	test.beforeEach(async ({ page }) => {
		await installMockWebSocket(page);
		await page.route("**/v1/**", createRouteApi("thread-1"));
	});

	test("sidebar has lava lamp with data-mode=active", async ({ page }) => {
		await page.goto("/");
		await expect(page.getByLabel("Select Workspace 1")).toBeVisible();

		const lava = page.locator("aside.codex-sidebar .lava-lamp-container");
		await expect(lava).toBeVisible();
		await expect(lava).toHaveAttribute("data-mode", "active");
	});

	test("only one lava lamp exists (sidebar only, no main panel)", async ({ page }) => {
		await page.goto("/");
		await expect(page.getByLabel("Select Workspace 1")).toBeVisible();

		await expect(page.locator(".lava-lamp-container")).toHaveCount(1);
		await expect(page.locator("main .lava-lamp-container")).toHaveCount(0);
	});

	test("active blobs have 35-45% opacity", async ({ page }) => {
		await page.goto("/");
		await expect(page.getByLabel("Select Workspace 1")).toBeVisible();

		const lava = page.locator("aside.codex-sidebar .lava-lamp-container");
		await expect(lava).toHaveAttribute("data-mode", "active", { timeout: 5000 });

		const blobs = page.locator("aside.codex-sidebar .lava-blob");
		await expect(blobs).toHaveCount(5);

		// Wait for the 1.5s CSS opacity transition to complete after mode switch
		await page.waitForTimeout(2000);

		for (let i = 0; i < 5; i++) {
			const opacity = await blobs.nth(i).evaluate(
				(el) => parseFloat(window.getComputedStyle(el).opacity),
			);
			expect(opacity).toBeGreaterThanOrEqual(0.30);
			expect(opacity).toBeLessThanOrEqual(0.50);
		}
	});

	test("active blobs animate over time", async ({ page }) => {
		await page.goto("/");
		await expect(page.getByLabel("Select Workspace 1")).toBeVisible();

		const blob = page.locator("aside.codex-sidebar .lava-blob").first();
		const t1 = await blob.evaluate((el) => window.getComputedStyle(el).transform);
		await page.waitForTimeout(2000);
		const t2 = await blob.evaluate((el) => window.getComputedStyle(el).transform);

		expect(t2).not.toBe(t1);
	});

	test("screenshots differ over time", async ({ page }) => {
		await page.goto("/");
		await expect(page.getByLabel("Select Workspace 1")).toBeVisible();

		const sidebar = page.locator("aside.codex-sidebar");
		const s1 = await sidebar.screenshot();
		await page.waitForTimeout(2500);
		const s2 = await sidebar.screenshot();

		expect(Buffer.compare(s1, s2)).not.toBe(0);
	});
});

// ─── Accessibility ───

test("no lava lamp when prefers-reduced-motion (idle)", async ({ page }) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	await installMockWebSocket(page);
	await page.route("**/v1/**", createRouteApi(null));
	await page.goto("/");
	await expect(page.getByLabel("Select Workspace 1")).toBeVisible();

	await expect(page.locator(".lava-lamp-container")).toHaveCount(0);
});

test("no lava lamp when prefers-reduced-motion (active)", async ({ page }) => {
	await page.emulateMedia({ reducedMotion: "reduce" });
	await installMockWebSocket(page);
	await page.route("**/v1/**", createRouteApi("thread-1"));
	await page.goto("/");
	await expect(page.getByLabel("Select Workspace 1")).toBeVisible();

	await expect(page.locator(".lava-lamp-container")).toHaveCount(0);
});
