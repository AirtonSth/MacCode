/* eslint-disable @typescript-eslint/consistent-type-assertions, @typescript-eslint/no-explicit-any, @typescript-eslint/prefer-readonly-parameter-types, compat/compat, functional/immutable-data, max-lines, max-statements */
import { expect, type Page, type Route, test } from "@playwright/test";
import type { PrivateAccountStateDto, PrivateLoginRequestDto, PrivateRegisterRequestDto } from "@remotecode/contracts";

type PrivateAccountState = PrivateAccountStateDto;

interface RequestLogEntry {
	method: string;
	path: string;
}

interface ApiMockOptions {
	initialState: PrivateAccountState;
	loginState?: PrivateAccountState;
	loginStatus?: number;
	loginError?: string;
	logoutState?: PrivateAccountState;
	registerResponses?: Array<{
		error?: string;
		state?: PrivateAccountState;
		status?: number;
	}>;
	registerState?: PrivateAccountState;
	registerStatus?: number;
	registerError?: string;
}

const unauthenticatedState: PrivateAccountState = {
	authenticated: false,
	connector: null,
	connectorRelayState: "idle",
	errorMessage: null,
	qrPayload: null,
	user: null,
};

const connectedState = (email: string): PrivateAccountState => ({
	authenticated: true,
	connector: {
		claimedAt: "2026-01-01T00:00:10.000Z",
		hostname: "devbox.local",
		id: "con_1",
		isOnline: true,
		lastSeenAt: "2026-01-01T00:00:11.000Z",
		name: "Desktop Connector",
		relayCapabilitiesVersion: "1",
		relayVersion: "1.0.0",
		status: "online",
	},
	connectorRelayState: "connected",
	errorMessage: null,
	qrPayload: {
		backendUrl: "http://127.0.0.1:8787",
		connectorId: "con_1",
		connectorName: "Desktop Connector",
		type: "remotecode_private_mobile_connect",
		version: 1,
	},
	user: {
		daysRemaing: 30,
		daysRemaining: 30,
		email,
		id: "usr_1",
		subscribed: true,
	},
});

const unsubscribedState = (email: string): PrivateAccountState => ({
	...connectedState(email),
	qrPayload: null,
	user: {
		daysRemaing: 30,
		daysRemaining: 30,
		email,
		id: "usr_1",
		subscribed: false,
	},
});

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

const parseAuthRequest = (request: Route["request"]): PrivateLoginRequestDto | PrivateRegisterRequestDto => {
	const payload = request.postDataJSON() as Partial<PrivateLoginRequestDto> | null;
	if (!payload || typeof payload.email !== "string" || typeof payload.password !== "string") {
		throw new Error("private_account_auth_payload_invalid");
	}

	if (payload.email.trim().length === 0 || payload.password.trim().length === 0) {
		throw new Error("private_account_auth_payload_empty");
	}

	return {
		email: payload.email,
		password: payload.password,
	};
};

const createApiMock = (options: ApiMockOptions) => {
	const requests: RequestLogEntry[] = [];
	let privateAccountState = structuredClone(options.initialState);
	let registerRequestCount = 0;

	const json = (body: unknown, status = 200) => ({
		body: JSON.stringify(body),
		contentType: "application/json",
		status,
	});

	const route = async (intercept: Route): Promise<void> => {
		const request = intercept.request();
		const method = request.method().toUpperCase();
		const url = new URL(request.url());
		const path = url.pathname.replace(/\/+$/u, "");

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
					selectedChatId: null,
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

		if (method === "GET" && path === "/v1/private-account/state") {
			await intercept.fulfill(json(privateAccountState));
			return;
		}

		if (method === "POST" && path === "/v1/private-account/login") {
			parseAuthRequest(request);

			if ((options.loginStatus ?? 200) >= 400) {
				await intercept.fulfill(json({ error: options.loginError ?? "invalid_credentials" }, options.loginStatus));
				return;
			}

			privateAccountState = structuredClone(options.loginState ?? connectedState("dev@example.com"));
			await intercept.fulfill(json(privateAccountState));
			return;
		}

		if (method === "POST" && path === "/v1/private-account/register") {
			parseAuthRequest(request);

			const registerResponse = options.registerResponses?.[registerRequestCount] ?? {
				error: options.registerError,
				state: options.registerState,
				status: options.registerStatus,
			};
			registerRequestCount += 1;

			if ((registerResponse.status ?? 200) >= 400) {
				await intercept.fulfill(
					json({ error: registerResponse.error ?? "email_already_registered" }, registerResponse.status),
				);
				return;
			}

			privateAccountState = structuredClone(registerResponse.state ?? options.registerState ?? connectedState("founder@example.com"));
			await intercept.fulfill(json(privateAccountState));
			return;
		}

		if (method === "POST" && path === "/v1/private-account/logout") {
			privateAccountState = structuredClone(options.logoutState ?? unauthenticatedState);
			await intercept.fulfill(json(privateAccountState));
			return;
		}

		await intercept.fulfill(json({ error: "route not mocked" }, 501));
	};

	return { requests, route };
};

test("private account login renders connector state and logout resets the footer", async ({ page }) => {
	const apiMock = createApiMock({
		initialState: unauthenticatedState,
		loginState: connectedState("dev@example.com"),
		logoutState: unauthenticatedState,
	});

	await installMockWebSocket(page);
	await page.route("**/v1/**", apiMock.route);
	await page.goto("/");

	await expect(page.getByTestId("private-account-sidebar-footer")).toBeVisible();
	await expect(page.getByText("Log in or register")).toBeVisible();

	await page.getByRole("button", { name: /Log in or register/i }).click();
	const dialog = page.getByRole("dialog", { name: "Private account modal" });
	await expect(dialog).toBeVisible();

	await dialog.getByLabel("Email").fill("dev@example.com");
	await dialog.getByLabel("Password").fill("supersecret");
	await dialog.getByRole("button", { name: "Log in", exact: true }).last().click();

	await expect(dialog).toHaveCount(0);
	await expect(page.getByTestId("private-account-connector-card")).toBeVisible();
	await expect(page.getByText("dev@example.com")).toBeVisible();
	await expect(page.getByTestId("private-account-connector-card").getByText("Relay online")).toBeVisible();
	await expect(page.getByAltText("Private connect QR")).toBeVisible();

	await page.getByRole("button", { name: /dev@example.com/i }).click();
	const connectedDialog = page.getByRole("dialog", { name: "Private account modal" });
	await expect(connectedDialog.getByRole("heading", { name: "Account connected" })).toBeVisible();
	await connectedDialog.getByRole("button", { name: "Log out" }).click();

	await expect(page.getByTestId("private-account-connector-card")).toHaveCount(0);
	await expect(page.getByText("Log in or register")).toBeVisible();

	await expect
		.poll(() =>
			apiMock.requests.filter((entry) => entry.method === "POST" && entry.path === "/v1/private-account/logout").length,
		)
		.toBe(1);
});

test("private account login without subscription shows subscribe CTA instead of QR", async ({ page }) => {
	const apiMock = createApiMock({
		initialState: unauthenticatedState,
		loginState: unsubscribedState("maker@remotecode.io"),
	});

	await installMockWebSocket(page);
	await page.route("**/v1/**", apiMock.route);
	await page.goto("/");

	await page.getByRole("button", { name: /Log in or register/i }).click();
	const dialog = page.getByRole("dialog", { name: "Private account modal" });
	await dialog.getByLabel("Email").fill("maker@remotecode.io");
	await dialog.getByLabel("Password").fill("supersecret");
	await dialog.getByRole("button", { name: "Log in", exact: true }).last().click();

	await expect(page.getByTestId("private-account-subscribe-card")).toBeVisible();
	await expect(page.getByTestId("private-account-subscribe-link")).toHaveAttribute(
		"href",
		"https://remotecode.io/subscribe/maker%40remotecode.io",
	);
	await expect(page.getByAltText("Private connect QR")).toHaveCount(0);

	await page.getByRole("button", { name: /maker@remotecode.io/i }).click();
	const connectedDialog = page.getByRole("dialog", { name: "Private account modal" });
	await expect(connectedDialog.getByText("Subscription inactive")).toBeVisible();
	await expect(connectedDialog.getByText("Go to subscription")).toBeVisible();
	await expect(connectedDialog.getByAltText("Private connect QR enlarged")).toHaveCount(0);
});

test("private account login shows a friendly alert when credentials are invalid", async ({ page }) => {
	const apiMock = createApiMock({
		initialState: unauthenticatedState,
		loginError: "Incorrect email or password.",
		loginStatus: 401,
	});

	await installMockWebSocket(page);
	await page.route("**/v1/**", apiMock.route);
	await page.goto("/");

	await page.getByRole("button", { name: /Log in or register/i }).click();
	const dialog = page.getByRole("dialog", { name: "Private account modal" });
	await dialog.getByLabel("Email").fill("dev@example.com");
	await dialog.getByLabel("Password").fill("wrong-password");
	await dialog.getByRole("button", { name: "Log in", exact: true }).last().click();

	await expect(dialog).toBeVisible();
	await expect(page.getByTestId("private-account-error")).toContainText("Incorrect email or password.");
	await expect(page.getByTestId("private-account-toast")).toContainText("Incorrect email or password.");
	await expect(page.getByTestId("private-account-connector-card")).toHaveCount(0);
});

test("private account register flow surfaces backend errors and can recover", async ({ page }) => {
	const apiMock = createApiMock({
		initialState: unauthenticatedState,
		registerResponses: [
			{
				error: "An account with this email already exists.",
				status: 409,
			},
			{
				state: connectedState("founder@remotecode.io"),
				status: 200,
			},
		],
	});

	await installMockWebSocket(page);
	await page.route("**/v1/**", apiMock.route);
	await page.goto("/");

	await page.getByRole("button", { name: /Log in or register/i }).click();
	const dialog = page.getByRole("dialog", { name: "Private account modal" });
	await dialog.getByRole("button", { name: "Register", exact: true }).first().click();
	await dialog.getByLabel("Email").fill("founder@remotecode.io");
	await dialog.getByLabel("Password").fill("supersecret");
	await dialog.getByRole("button", { name: "Register", exact: true }).last().click();

	await expect
		.poll(() =>
			apiMock.requests.filter((entry) => entry.method === "POST" && entry.path === "/v1/private-account/register").length,
		)
		.toBe(1);
	await expect(dialog).toBeVisible();
	await expect(page.getByTestId("private-account-error")).toContainText("An account with this email already exists.");
	await expect(page.getByTestId("private-account-toast")).toContainText("An account with this email already exists.");
	await expect(page.getByTestId("private-account-connector-card")).toHaveCount(0);

	await dialog.getByRole("button", { name: "Register", exact: true }).last().click();

	await expect(dialog).toHaveCount(0);
	await expect(page.getByText("founder@remotecode.io")).toBeVisible();
	await expect(page.getByTestId("private-account-connector-card").getByText("Relay online")).toBeVisible();
	await expect(page.getByAltText("Private connect QR")).toBeVisible();
	await expect
		.poll(() =>
			apiMock.requests.filter((entry) => entry.method === "POST" && entry.path === "/v1/private-account/register").length,
		)
		.toBe(2);
});
