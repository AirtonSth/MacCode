/* eslint-disable functional/immutable-data, compat/compat */
import { expect, test } from "@playwright/test";
import { promises as fs } from "node:fs";
import path from "node:path";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";

interface TerminalE2EState {
	baseUrl: string;
	chatId: string;
	expectedInitialCwd: string;
	expectedParentCwd: string;
	projectId: string;
	token: string;
}

const desktopRoot = process.cwd();
const statePath = path.resolve(desktopRoot, "e2e/playwright/.terminal-e2e-state.json");

let backendProcess: ChildProcessWithoutNullStreams | null = null;
let terminalState: TerminalE2EState | null = null;
const liveSockets = new Map<string, WebSocket>();

const waitFor = async (predicate: () => Promise<boolean>, timeoutMs: number, label: string) => {
	const startedAt = Date.now();

	while (Date.now() - startedAt < timeoutMs) {
		if (await predicate()) {
			return;
		}

		await new Promise((resolve) => {
			setTimeout(resolve, 250);
		});
	}

	throw new Error(`Timed out waiting for ${label}`);
};

const startBackend = async (): Promise<TerminalE2EState> => {
	await fs.rm(statePath, { force: true });
	backendProcess = spawn("bun", ["run", "./e2e/playwright/start-terminal-e2e-backend.ts"], {
		cwd: desktopRoot,
		env: {
			...process.env,
			RC_E2E_TOKEN: "remotecode.io-token",
		},
		stdio: "pipe",
	});

	backendProcess.stdout.on("data", (chunk) => {
		process.stdout.write(chunk);
	});
	backendProcess.stderr.on("data", (chunk) => {
		process.stderr.write(chunk);
	});

	await waitFor(async () => {
		try {
			await fs.access(statePath);
			return true;
		} catch {
			return false;
		}
	}, 30_000, "desktop terminal state file");

	const state = JSON.parse(await fs.readFile(statePath, "utf8")) as TerminalE2EState;

	await waitFor(async () => {
		try {
			const response = await fetch(`${state.baseUrl}/v1/auth/verify`, {
				body: JSON.stringify({}),
				headers: {
					authorization: `Bearer ${state.token}`,
					"content-type": "application/json",
				},
				method: "POST",
			});
			return response.ok;
		} catch {
			return false;
		}
	}, 30_000, "desktop terminal backend health");

	return state;
};

const stopBackend = async () => {
	if (!backendProcess) {
		return;
	}

	if (backendProcess.exitCode !== null) {
		backendProcess = null;
		return;
	}

	backendProcess.kill("SIGTERM");
	await new Promise<void>((resolve) => {
		backendProcess?.once("exit", () => {
			resolve();
		});
	});
	backendProcess = null;
};

const installWebSocketBridge = async (
	page: import("@playwright/test").Page,
	options: { baseUrl: string },
) => {
	const normalizedBaseUrl = options.baseUrl.replace(/\/+$/u, "");
	const normalizedWsBaseUrl = normalizedBaseUrl.replace(/^http/u, "ws");
	const rewriteHttpUrl = (value: string): string =>
		value
			.replace("http://127.0.0.1:8835", normalizedBaseUrl)
			.replace("http://localhost:8835", normalizedBaseUrl);
	const rewriteWsUrl = (value: string): string =>
		value
			.replace("ws://127.0.0.1:8835", normalizedWsBaseUrl)
			.replace("ws://localhost:8835", normalizedWsBaseUrl);

	for (const socket of liveSockets.values()) {
		try {
			socket.close();
		} catch {
			// ignore stale sockets from previous retries
		}
	}
	liveSockets.clear();

	await page.route("http://127.0.0.1:8835/**", async (route) => {
		await route.continue({ url: rewriteHttpUrl(route.request().url()) });
	});
	await page.route("http://localhost:8835/**", async (route) => {
		await route.continue({ url: rewriteHttpUrl(route.request().url()) });
	});

	await page.exposeBinding("__pwMockWsCreate", async ({ page: bindingPage }, payload: { id: string; url: string }) => {
		const rewrittenUrl = rewriteWsUrl(payload.url);
		console.log(`[pw-ws] create ${payload.id} ${rewrittenUrl}`);
		const socket = new WebSocket(rewrittenUrl);
		liveSockets.set(payload.id, socket);

		const dispatch = async (event: Record<string, unknown>) => {
			try {
				await bindingPage.evaluate(
					([id, nextEvent]) => {
						const dispatcher = (window as typeof window & {
							__pwDispatchWsEvent?: (socketId: string, payload: Record<string, unknown>) => void;
						}).__pwDispatchWsEvent;
						dispatcher?.(id, nextEvent);
					},
					[payload.id, event] as const,
				);
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				if (
					message.includes("Target page, context or browser has been closed") ||
					message.includes("Execution context was destroyed")
				) {
					return;
				}
				throw error;
			}
		};

		socket.addEventListener("open", () => {
			console.log(`[pw-ws] open ${payload.id}`);
			void dispatch({ type: "open" });
		});
		socket.addEventListener("message", (event) => {
			const data = typeof event.data === "string" ? event.data : String(event.data);
			if (data.includes("terminal") || data.includes("\"error\"")) {
				console.log(`[pw-ws] message ${payload.id} ${data.slice(0, 240)}`);
			}
			void dispatch({
				data,
				type: "message",
			});
		});
		socket.addEventListener("close", (event) => {
			console.log(`[pw-ws] close ${payload.id} ${event.code} ${event.reason}`);
			liveSockets.delete(payload.id);
			void dispatch({
				code: event.code,
				reason: event.reason,
				type: "close",
				wasClean: event.wasClean,
			});
		});
		socket.addEventListener("error", () => {
			console.log(`[pw-ws] error ${payload.id}`);
			void dispatch({ type: "error" });
		});
	});

	await page.exposeBinding("__pwMockWsSend", async (_source, payload: { data: string; id: string }) => {
		console.log(`[pw-ws] send ${payload.id} ${payload.data.slice(0, 120)}`);
		liveSockets.get(payload.id)?.send(payload.data);
	});

	await page.exposeBinding("__pwMockWsClose", async (_source, payload: { code?: number; id: string; reason?: string }) => {
		console.log(`[pw-ws] close-request ${payload.id} ${payload.code ?? ""} ${payload.reason ?? ""}`);
		const socket = liveSockets.get(payload.id);
		if (!socket) {
			return;
		}

		socket.close(payload.code, payload.reason);
		liveSockets.delete(payload.id);
	});

	await page.addInitScript(() => {
		const sockets = new Map<string, EventTarget & {
			binaryType: string;
			bufferedAmount: number;
			extensions: string;
			onclose: ((event: CloseEvent) => void) | null;
			onerror: ((event: Event) => void) | null;
			onmessage: ((event: MessageEvent<string>) => void) | null;
			onopen: ((event: Event) => void) | null;
			protocol: string;
			readyState: number;
			url: string;
		}>();

		const dispatchEventToSocket = (
			socket: EventTarget & {
				onclose: ((event: CloseEvent) => void) | null;
				onerror: ((event: Event) => void) | null;
				onmessage: ((event: MessageEvent<string>) => void) | null;
				onopen: ((event: Event) => void) | null;
			},
			type: string,
			event: Event,
		) => {
			socket.dispatchEvent(event);
			if (type === "open") {
				socket.onopen?.(event);
				return;
			}
			if (type === "message") {
				socket.onmessage?.(event as MessageEvent<string>);
				return;
			}
			if (type === "close") {
				socket.onclose?.(event as CloseEvent);
				return;
			}
			socket.onerror?.(event);
		};

		class MockWebSocket extends EventTarget {
			static readonly CONNECTING = 0;
			static readonly OPEN = 1;
			static readonly CLOSING = 2;
			static readonly CLOSED = 3;

			readonly binaryType = "blob";
			readonly bufferedAmount = 0;
			readonly extensions = "";
			readonly protocol = "";
			readonly url: string;
			readyState = MockWebSocket.CONNECTING;
			onclose: ((event: CloseEvent) => void) | null = null;
			onerror: ((event: Event) => void) | null = null;
			onmessage: ((event: MessageEvent<string>) => void) | null = null;
			onopen: ((event: Event) => void) | null = null;
			private readonly id: string;

			constructor(url: string | URL) {
				super();
				this.url = typeof url === "string" ? url : url.toString();
				this.id = `mock-ws-${crypto.randomUUID()}`;
				sockets.set(this.id, this as never);
				void (window as typeof window & {
					__pwMockWsCreate: (payload: { id: string; url: string }) => Promise<void>;
				}).__pwMockWsCreate({
					id: this.id,
					url: this.url,
				}).catch(() => {
					this.readyState = MockWebSocket.CLOSED;
					dispatchEventToSocket(this, "error", new Event("error"));
				});
			}

			send(data: string) {
				void (window as typeof window & {
					__pwMockWsSend: (payload: { data: string; id: string }) => Promise<void>;
				}).__pwMockWsSend({
					data,
					id: this.id,
				});
			}

			close(code?: number, reason?: string) {
				if (this.readyState === MockWebSocket.CLOSED) {
					return;
				}
				this.readyState = MockWebSocket.CLOSING;
				void (window as typeof window & {
					__pwMockWsClose: (payload: { code?: number; id: string; reason?: string }) => Promise<void>;
				}).__pwMockWsClose({
					code,
					id: this.id,
					reason,
				});
			}
		}

		(window as typeof window & {
			__pwDispatchWsEvent?: (socketId: string, payload: Record<string, unknown>) => void;
		}).__pwDispatchWsEvent = (socketId, payload) => {
			const socket = sockets.get(socketId);
			if (!socket) {
				return;
			}

			const type = typeof payload.type === "string" ? payload.type : "error";
			if (type === "open") {
				socket.readyState = MockWebSocket.OPEN;
				dispatchEventToSocket(socket, type, new Event("open"));
				return;
			}

			if (type === "message") {
				const data = typeof payload.data === "string" ? payload.data : "";
				dispatchEventToSocket(socket, type, new MessageEvent("message", { data }));
				return;
			}

			if (type === "close") {
				socket.readyState = MockWebSocket.CLOSED;
				sockets.delete(socketId);
				dispatchEventToSocket(
					socket,
					type,
					new CloseEvent("close", {
						code: typeof payload.code === "number" ? payload.code : 1000,
						reason: typeof payload.reason === "string" ? payload.reason : "",
						wasClean: Boolean(payload.wasClean),
					}),
				);
				return;
			}

			dispatchEventToSocket(socket, type, new Event("error"));
		};

		Object.defineProperty(window, "WebSocket", {
			configurable: true,
			value: MockWebSocket,
		});
	});
};

const openTerminal = async (page: import("@playwright/test").Page) => {
	await page.goto("/");
	await expect(page.getByRole("button", { name: "Open Terminal Session" })).toBeVisible({ timeout: 30_000 });
	await page.getByRole("button", { name: "Open Terminal Session" }).click();
	await expect(page.getByRole("heading", { name: "Terminal Session" })).toBeVisible();
	await expect(page.getByTestId("desktop-terminal-toggle")).toBeVisible();
	await page.getByTestId("desktop-terminal-toggle").click();
	await expect(page.getByTestId("thread-terminal-panel")).toBeVisible();
};

const sendTerminalCommand = async (page: import("@playwright/test").Page, command: string) => {
	const input = page.getByTestId("thread-terminal-keyboard-input");
	await input.click();
	await input.pressSequentially(command);
	await input.press("Enter");
};

const interruptTerminalWithKeyboard = async (page: import("@playwright/test").Page) => {
	const input = page.getByTestId("thread-terminal-keyboard-input");
	await input.click();
	await input.press("Control+C");
};

const normalizeTerminalText = (value: string) => value.replace(/\s+/gu, "");

const readTerminalSurfaceText = async (page: import("@playwright/test").Page) =>
	await page.getByTestId("thread-terminal-surface").evaluate((node) => {
		const bufferText = node.getAttribute("data-terminal-buffer-text");
		if (bufferText && bufferText.trim().length > 0) {
			return bufferText.trim();
		}
		const accessibilityTree = node.querySelector(".xterm-accessibility-tree");
		if (accessibilityTree) {
			const lines = [...accessibilityTree.querySelectorAll("[role='listitem']")]
				.map((element) => element.textContent ?? "")
				.join("\n")
				.trim();
			if (lines.length > 0) {
				return lines;
			}
		}
		const rows = node.querySelector(".xterm-rows");
		return rows?.textContent?.trim() ?? "";
	});

test.beforeAll(async () => {
	terminalState = await startBackend();
});

test.afterAll(async () => {
	for (const socket of liveSockets.values()) {
		try {
			socket.close();
		} catch {
			// ignore teardown races
		}
	}
	liveSockets.clear();
	await stopBackend();
});

test("desktop terminal preserves cwd, streams output, survives keyboard interrupt and restores after reconnect", async ({ page }) => {
	if (!terminalState) {
		throw new Error("desktop terminal state was not initialized");
	}

	await installWebSocketBridge(page, { baseUrl: terminalState.baseUrl });
	await openTerminal(page);
	await expect(page.getByTestId("thread-terminal-cwd")).toHaveText(terminalState.expectedInitialCwd);

	await sendTerminalCommand(page, "cd ..");
	await sendTerminalCommand(page, "pwd");
	await expect(page.getByTestId("thread-terminal-cwd")).toHaveText(terminalState.expectedParentCwd);
	await expect
		.poll(async () => normalizeTerminalText(await readTerminalSurfaceText(page)))
		.toContain(normalizeTerminalText(terminalState.expectedParentCwd));

	await sendTerminalCommand(page, "while true; do printf 'RC_DESKTOP_TICK\\n'; sleep 1; done");
	await expect.poll(async () => await readTerminalSurfaceText(page)).toContain("RC_DESKTOP_TICK");

	await interruptTerminalWithKeyboard(page);
	await sendTerminalCommand(page, "echo RC_DESKTOP_AFTER_INTERRUPT");
	await expect.poll(async () => await readTerminalSurfaceText(page)).toContain("RC_DESKTOP_AFTER_INTERRUPT");

	await page.getByTestId("desktop-terminal-toggle").click();
	await expect(page.getByTestId("thread-terminal-panel")).toHaveCount(0);
	await page.getByTestId("desktop-terminal-toggle").click();
	await expect(page.getByTestId("thread-terminal-panel")).toBeVisible();
	await expect
		.poll(async () => normalizeTerminalText(await readTerminalSurfaceText(page)))
		.toContain(normalizeTerminalText(terminalState.expectedParentCwd));
	await expect.poll(async () => await readTerminalSurfaceText(page)).toContain("RC_DESKTOP_AFTER_INTERRUPT");

	await page.reload();
	await expect(page.getByTestId("desktop-terminal-toggle")).toBeVisible();
	await page.getByTestId("desktop-terminal-toggle").click();
	await expect(page.getByTestId("thread-terminal-panel")).toBeVisible();
	await expect
		.poll(async () => normalizeTerminalText(await readTerminalSurfaceText(page)))
		.toContain(normalizeTerminalText(terminalState.expectedParentCwd));
	await expect.poll(async () => await readTerminalSurfaceText(page)).toContain("RC_DESKTOP_AFTER_INTERRUPT");

	await page.getByTestId("thread-terminal-restart").click();
	await expect(page.getByTestId("thread-terminal-cwd")).toHaveText(terminalState.expectedInitialCwd);
	await sendTerminalCommand(page, "echo RC_DESKTOP_AFTER_RESTART");
	await expect.poll(async () => await readTerminalSurfaceText(page)).toContain("RC_DESKTOP_AFTER_RESTART");
});
