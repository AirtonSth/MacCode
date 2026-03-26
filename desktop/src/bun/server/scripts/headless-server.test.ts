import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type { PrivateAccountStateDto } from "@remotecode/contracts";

import {
	bootstrapHeadlessServer,
	parseHeadlessServerArgs,
	validateHeadlessServerArgs,
} from "./headless-server";

const decoder = new TextDecoder();
const desktopRoot = "/Users/samuelfajreldines/Desenvolvimento/remotecode/remotecode.io/desktop";
const spawnedUserDataRoots: string[] = [];

interface MockBackendState {
	closeCalls: number;
	loginCalls: Array<{ email: string; password: string }>;
	stopCalls: number;
}

interface StreamCollector {
	buffer: string;
	done: Promise<void>;
}

const createPrivateState = (
	overrides?: Partial<PrivateAccountStateDto>,
): PrivateAccountStateDto => ({
	authenticated: true,
	connector: {
		claimedAt: new Date().toISOString(),
		hostname: "vps.example.com",
		id: "con_headless",
		isOnline: true,
		lastSeenAt: new Date().toISOString(),
		name: "Headless Connector",
		relayCapabilitiesVersion: "1",
		relayVersion: "1.0.0",
		status: "online",
	},
	connectorRelayState: "connected",
	errorMessage: null,
	user: {
		daysRemaing: 30,
		daysRemaining: 30,
		email: "dev@example.com",
		id: "usr_headless",
		subscribed: true,
	},
	...overrides,
});

const createMockBackend = (options?: {
	getStateSequence?: PrivateAccountStateDto[];
	loginError?: Error;
}): {
	backend: {
		app: {
			stop: (force?: boolean) => Promise<void>;
		};
		db: {
			close: () => Promise<void>;
		};
		privateAccountService: {
			getState: () => Promise<PrivateAccountStateDto>;
			login: (input: { email: string; password: string }) => Promise<PrivateAccountStateDto>;
		};
		server: {
			port: number;
		};
	};
	state: MockBackendState;
} => {
	const state: MockBackendState = {
		closeCalls: 0,
		loginCalls: [],
		stopCalls: 0,
	};
	const getStateSequence = options?.getStateSequence ?? [createPrivateState()];
	let getStateIndex = 0;

	return {
		backend: {
			app: {
				stop: async () => {
					state.stopCalls += 1;
				},
			},
			db: {
				close: async () => {
					state.closeCalls += 1;
				},
			},
			privateAccountService: {
				getState: async () => {
					const nextIndex = Math.min(getStateIndex, getStateSequence.length - 1);
					const value = getStateSequence[nextIndex];
					getStateIndex += 1;
					return value;
				},
				login: async (input) => {
					state.loginCalls.push(input);
					if (options?.loginError) {
						throw options.loginError;
					}

					return getStateSequence[0] ?? createPrivateState();
				},
			},
			server: {
				port: 9123,
			},
		},
		state,
	};
};

const collectStream = (stream: ReadableStream<Uint8Array> | null): StreamCollector => {
	if (!stream) {
		return {
			buffer: "",
			done: Promise.resolve(),
		};
	}

	const collector: StreamCollector = {
		buffer: "",
		done: Promise.resolve(),
	};
	const reader = stream.getReader();
	collector.done = (async () => {
		while (true) {
			const result = await reader.read();
			if (result.done) {
				break;
			}

			collector.buffer += decoder.decode(result.value, { stream: true });
		}

		collector.buffer += decoder.decode();
	})();

	return collector;
};

const waitForMatch = async (
	collector: StreamCollector,
	pattern: RegExp,
	timeoutMs = 15_000,
): Promise<RegExpMatchArray> => {
	const startedAt = Date.now();

	while (Date.now() - startedAt <= timeoutMs) {
		const match = collector.buffer.match(pattern);
		if (match) {
			return match;
		}

		await Bun.sleep(25);
	}

	throw new Error(`Timed out waiting for pattern ${pattern.toString()}\nOutput:\n${collector.buffer}`);
};

const stopProcess = async (processHandle: Bun.Subprocess<"ignore", "pipe", "pipe">): Promise<number> => {
	processHandle.kill("SIGTERM");
	return await processHandle.exited;
};

const createSpawnUserDataPath = (): string => {
	const path = mkdtempSync(join(tmpdir(), "remotecode-headless-test-"));
	spawnedUserDataRoots.push(path);
	return path;
};

const createMockPrivateBackend = (options?: {
	acceptLogin?: boolean;
	sendConnectorAuth?: boolean;
}) => {
	let relayConnected = false;
	const acceptLogin = options?.acceptLogin ?? true;
	const sendConnectorAuth = options?.sendConnectorAuth ?? true;

	const server = Bun.serve({
		fetch: async (request, serverInstance) => {
			const url = new URL(request.url);

			if (url.pathname === "/v1/private/connectors/socket") {
				if (serverInstance.upgrade(request)) {
					return;
				}

				return new Response("upgrade_failed", { status: 500 });
			}

			if (url.pathname === "/v1/private/auth/login" && request.method === "POST") {
				const body = await request.json() as { email?: string; password?: string };
				if (!acceptLogin || body.email !== "dev@example.com" || body.password !== "super-secret") {
					return Response.json({
						error: "invalid_credentials",
					}, {
						status: 401,
					});
				}

				return Response.json({
					accessToken: "access-token",
					refreshToken: "refresh-token",
					user: {
						daysRemaing: 30,
						daysRemaining: 30,
						email: "dev@example.com",
						id: "usr_headless",
						subscribed: true,
					},
				});
			}

			if (url.pathname === "/v1/private/me" && request.method === "GET") {
				return Response.json({
					user: {
						daysRemaing: 30,
						daysRemaining: 30,
						email: "dev@example.com",
						id: "usr_headless",
						subscribed: true,
					},
				});
			}

			if (url.pathname === "/v1/private/connectors/bootstrap" && request.method === "POST") {
				return Response.json({
					connector: {
						id: "con_headless",
						name: "Headless Connector",
					},
					expiresAt: new Date(Date.now() + 60_000).toISOString(),
					pairing: {
						code: "PAIR-HEADLESS",
						id: "pair_headless",
						pollToken: "poll_headless",
					},
				});
			}

			if (url.pathname === "/v1/private/pairing/claim" && request.method === "POST") {
				return Response.json({
					claimedAt: new Date().toISOString(),
					connectorId: "con_headless",
					status: "claimed",
				});
			}

			if (
				url.pathname === "/v1/private/connectors/bootstrap/pair_headless/status"
				&& request.method === "GET"
			) {
				return Response.json({
					connector: {
						accessToken: "connector-token",
						id: "con_headless",
					},
					expiresAt: new Date(Date.now() + 60_000).toISOString(),
					status: "claimed",
				});
			}

			if (url.pathname === "/v1/private/connectors" && request.method === "GET") {
				return Response.json({
					connectors: [
						{
							claimedAt: new Date().toISOString(),
							hostname: "vps.example.com",
							id: "con_headless",
							isOnline: relayConnected,
							lastSeenAt: new Date().toISOString(),
							name: "Headless Connector",
							relayCapabilitiesVersion: "1",
							relayVersion: "1.0.0",
							status: relayConnected ? "online" : "claimed",
						},
					],
				});
			}

			return new Response("not_found", { status: 404 });
		},
		port: 0,
		websocket: {
			close() {
				relayConnected = false;
			},
			message() {
				// Heartbeats are expected. No response required.
			},
			open(websocket) {
				relayConnected = true;
				if (sendConnectorAuth) {
					websocket.send(JSON.stringify({
						type: "connector_auth",
					}));
				}
			},
		},
	});

	return {
		baseUrl: `http://127.0.0.1:${String(server.port)}`,
		stop: () => {
			server.stop(true);
		},
	};
};

afterEach(() => {
	delete process.env.REMOTECODE_PRIVATE_BACKEND_URL;
	delete process.env.REMOTECODE_SERVER_PORT;
	delete process.env.REMOTECODE_LOCAL_TOKEN;
	delete process.env.REMOTECODE_USER_DATA_PATH;

	while (spawnedUserDataRoots.length > 0) {
		const root = spawnedUserDataRoots.pop();
		if (!root) {
			continue;
		}

		rmSync(root, { force: true, recursive: true });
	}
});

test("parseHeadlessServerArgs returns null credentials when omitted", () => {
	expect(parseHeadlessServerArgs([])).toEqual({
		login: null,
		password: null,
	});
});

test("parseHeadlessServerArgs accepts equals and split flag forms", () => {
	expect(parseHeadlessServerArgs(["--login=dev@example.com", "--password", "super-secret"])).toEqual({
		login: "dev@example.com",
		password: "super-secret",
	});
});

test("validateHeadlessServerArgs rejects partial credentials", () => {
	expect(() => validateHeadlessServerArgs({
		login: "dev@example.com",
		password: null,
	})).toThrow("Both --login and --password must be provided with non-empty values.");
});

test("validateHeadlessServerArgs rejects empty credential values", () => {
	expect(() => validateHeadlessServerArgs({
		login: "",
		password: "super-secret",
	})).toThrow("Both --login and --password must be provided with non-empty values.");
});

test("bootstrapHeadlessServer starts without private login when credentials are omitted", async () => {
	const mock = createMockBackend();

	const runtime = await bootstrapHeadlessServer({
		args: {
			login: null,
			password: null,
		},
		createBackendServer: async () => mock.backend as never,
	});

	expect(runtime.localBaseUrl).toBe("http://127.0.0.1:9123");
	expect(mock.state.loginCalls).toHaveLength(0);

	await runtime.stop();
	expect(mock.state.stopCalls).toBe(1);
	expect(mock.state.closeCalls).toBe(1);
});

test("bootstrapHeadlessServer waits for the private relay to become connected", async () => {
	const mock = createMockBackend({
		getStateSequence: [
			createPrivateState({
				connector: null,
				connectorRelayState: "idle",
			}),
			createPrivateState({
				connectorRelayState: "connecting",
			}),
			createPrivateState({
				connectorRelayState: "connected",
			}),
		],
	});

	const runtime = await bootstrapHeadlessServer({
		args: {
			login: "dev@example.com",
			password: "super-secret",
		},
		createBackendServer: async () => mock.backend as never,
		pollIntervalMs: 0,
		sleep: async () => undefined,
		timeoutMs: 25,
	});

	expect(mock.state.loginCalls).toEqual([
		{
			email: "dev@example.com",
			password: "super-secret",
		},
	]);

	await runtime.stop();
});

test("bootstrapHeadlessServer cleans up when private login fails", async () => {
	const mock = createMockBackend({
		loginError: new Error("invalid_credentials"),
	});

	await expect(bootstrapHeadlessServer({
		args: {
			login: "dev@example.com",
			password: "super-secret",
		},
		createBackendServer: async () => mock.backend as never,
	})).rejects.toThrow("invalid_credentials");

	expect(mock.state.stopCalls).toBe(1);
	expect(mock.state.closeCalls).toBe(1);
});

test("bootstrapHeadlessServer cleans up when the private relay never becomes ready", async () => {
	const mock = createMockBackend({
		getStateSequence: [
			createPrivateState({
				connectorRelayState: "connecting",
			}),
		],
	});

	await expect(bootstrapHeadlessServer({
		args: {
			login: "dev@example.com",
			password: "super-secret",
		},
		createBackendServer: async () => mock.backend as never,
		pollIntervalMs: 1,
		sleep: async (ms) => {
			await Bun.sleep(ms);
		},
		timeoutMs: 5,
	})).rejects.toThrow("Private relay did not become ready");

	expect(mock.state.stopCalls).toBe(1);
	expect(mock.state.closeCalls).toBe(1);
});

test("headless start-server script serves discovery and shuts down cleanly", async () => {
	const userDataPath = createSpawnUserDataPath();
	const processHandle = Bun.spawn(
		[process.execPath, "run", "./src/bun/server/scripts/start-server.ts"],
		{
			cwd: desktopRoot,
			env: {
				...process.env,
				REMOTECODE_LOCAL_TOKEN: "headless-local-token",
				REMOTECODE_SERVER_PORT: "0",
				REMOTECODE_USER_DATA_PATH: userDataPath,
			},
			stderr: "pipe",
			stdout: "pipe",
		},
	);
	const stdout = collectStream(processHandle.stdout);
	const stderr = collectStream(processHandle.stderr);

	try {
		const match = await waitForMatch(
			stdout,
			/localBaseUrl:\s(http:\/\/127\.0\.0\.1:\d+)/,
		);
		const baseUrl = match[1];
		const response = await fetch(`${baseUrl}/v1/discovery`);
		const payload = await response.json() as { serverId: string };

		expect(response.status).toBe(200);
		expect(payload.serverId).toBeTruthy();

		const exitCode = await stopProcess(processHandle);
		expect(exitCode).toBe(0);
		await stdout.done;
		await stderr.done;
		expect(stdout.buffer).toContain("Headless server stopped");
	} finally {
		processHandle.kill("SIGKILL");
	}
}, 15_000);

test("headless start-server script connects private relay when login credentials are provided", async () => {
	const privateBackend = createMockPrivateBackend();
	const userDataPath = createSpawnUserDataPath();
	const processHandle = Bun.spawn(
		[
			process.execPath,
			"run",
			"./src/bun/server/scripts/start-server.ts",
			"--login=dev@example.com",
			"--password=super-secret",
		],
		{
			cwd: desktopRoot,
			env: {
				...process.env,
				REMOTECODE_LOCAL_TOKEN: "headless-private-token",
				REMOTECODE_PRIVATE_BACKEND_URL: privateBackend.baseUrl,
				REMOTECODE_SERVER_PORT: "0",
				REMOTECODE_USER_DATA_PATH: userDataPath,
			},
			stderr: "pipe",
			stdout: "pipe",
		},
	);
	const stdout = collectStream(processHandle.stdout);
	const stderr = collectStream(processHandle.stderr);

	try {
		const readyMatch = await waitForMatch(
			stdout,
			/Private relay ready/,
		);
		expect(readyMatch[0]).toContain("Private relay ready");

		const baseUrlMatch = await waitForMatch(
			stdout,
			/localBaseUrl:\s(http:\/\/127\.0\.0\.1:\d+)/,
		);
		const baseUrl = baseUrlMatch[1];

		const response = await fetch(`${baseUrl}/v1/discovery`);
		const payload = await response.json() as {
			serverId: string;
			server: {
				serverId: string;
			};
		};

		expect(response.status).toBe(200);
		expect(payload.serverId).toBeTruthy();

		const exitCode = await stopProcess(processHandle);
		expect(exitCode).toBe(0);
		await stdout.done;
		await stderr.done;
	} finally {
		processHandle.kill("SIGKILL");
		privateBackend.stop();
	}
}, 15_000);

test("headless start-server script exits non-zero when private login fails", async () => {
	const privateBackend = createMockPrivateBackend({
		acceptLogin: false,
	});
	const userDataPath = createSpawnUserDataPath();
	const processHandle = Bun.spawn(
		[
			process.execPath,
			"run",
			"./src/bun/server/scripts/start-server.ts",
			"--login=dev@example.com",
			"--password=wrong-password",
		],
		{
			cwd: desktopRoot,
			env: {
				...process.env,
				REMOTECODE_PRIVATE_BACKEND_URL: privateBackend.baseUrl,
				REMOTECODE_SERVER_PORT: "0",
				REMOTECODE_USER_DATA_PATH: userDataPath,
			},
			stderr: "pipe",
			stdout: "pipe",
		},
	);
	const stdout = collectStream(processHandle.stdout);
	const stderr = collectStream(processHandle.stderr);

	try {
		const exitCode = await processHandle.exited;
		await stdout.done;
		await stderr.done;

		expect(exitCode).toBe(1);
		expect(stdout.buffer).toContain("Headless server failed to start");
		expect(stdout.buffer).toContain("invalid_credentials");
	} finally {
		processHandle.kill("SIGKILL");
		privateBackend.stop();
	}
}, 15_000);
