import type { PrivateAccountStateDto } from "@remotecode/contracts";

import { type BackendHandle, createBackendServer } from "../app";
import { serverConfig } from "../config";
import {
	maskEmailForLogs,
	maskTokenForLogs,
	serverLogger,
	toLogErrorDetails,
} from "../shared/core/server-logger";

const PRIVATE_READY_TIMEOUT_MS = 15_000;
const PRIVATE_READY_POLL_INTERVAL_MS = 250;

export interface HeadlessServerCliArgs {
	login: string | null;
	password: string | null;
}

interface BootstrapHeadlessServerOptions {
	args: HeadlessServerCliArgs;
	createBackendServer?: typeof createBackendServer;
	pollIntervalMs?: number;
	sleep?: (ms: number) => Promise<void>;
	timeoutMs?: number;
}

export interface HeadlessServerRuntime {
	backend: BackendHandle;
	localBaseUrl: string;
	stop: () => Promise<void>;
}

const toPort = (server: unknown): number => {
	if (!server || typeof server !== "object") {
		throw new Error("Headless server did not expose a listening port.");
	}

	const port = (server as { port?: unknown }).port;
	if (typeof port !== "number" || !Number.isFinite(port) || port <= 0) {
		throw new Error("Headless server did not expose a valid listening port.");
	}

	return port;
};

const readFlagValue = (rawValue: string | undefined): string => rawValue?.trim() ?? "";

const summarizePrivateState = (state: PrivateAccountStateDto): string => {
	const connectorId = state.connector?.id ?? "none";
	const connectorStatus = state.connector?.status ?? "none";
	const errorMessage = state.errorMessage ?? "none";
	return `relayState=${state.connectorRelayState}, connectorId=${connectorId}, connectorStatus=${connectorStatus}, error=${errorMessage}`;
};

const isReadyForPrivateWebAccess = (state: PrivateAccountStateDto): boolean =>
	state.connector !== null && state.connectorRelayState === "connected";

export const parseHeadlessServerArgs = (argv: string[]): HeadlessServerCliArgs => {
	let login: string | null = null;
	let password: string | null = null;

	for (let index = 0; index < argv.length; index += 1) {
		const argument = argv[index];

		if (argument === "--login") {
			login = readFlagValue(argv[index + 1]);
			index += 1;
			continue;
		}

		if (argument === "--password") {
			password = readFlagValue(argv[index + 1]);
			index += 1;
			continue;
		}

		if (argument.startsWith("--login=")) {
			login = readFlagValue(argument.slice("--login=".length));
			continue;
		}

		if (argument.startsWith("--password=")) {
			password = readFlagValue(argument.slice("--password=".length));
			continue;
		}

		throw new Error(`Unknown argument: ${argument}`);
	}

	return { login, password };
};

export const validateHeadlessServerArgs = (args: HeadlessServerCliArgs): void => {
	const hasLogin = args.login !== null;
	const hasPassword = args.password !== null;

	if (!hasLogin && !hasPassword) {
		return;
	}

	if (!hasLogin || !hasPassword || !args.login || !args.password) {
		throw new Error("Both --login and --password must be provided with non-empty values.");
	}
};

export const stopBackendHandle = async (backend: Pick<BackendHandle, "app" | "db">): Promise<void> => {
	try {
		await backend.app.stop(true);
	} finally {
		await backend.db.close();
	}
};

export const waitForPrivateRelayReady = async (
	service: Pick<BackendHandle["privateAccountService"], "getState">,
	options?: {
		pollIntervalMs?: number;
		sleep?: (ms: number) => Promise<void>;
		timeoutMs?: number;
	},
): Promise<PrivateAccountStateDto> => {
	const sleep = options?.sleep ?? Bun.sleep;
	const timeoutMs = options?.timeoutMs ?? PRIVATE_READY_TIMEOUT_MS;
	const pollIntervalMs = options?.pollIntervalMs ?? PRIVATE_READY_POLL_INTERVAL_MS;
	const startedAt = Date.now();
	let latestState = await service.getState();

	while (Date.now() - startedAt <= timeoutMs) {
		if (isReadyForPrivateWebAccess(latestState)) {
			return latestState;
		}

		await sleep(pollIntervalMs);
		latestState = await service.getState();
	}

	throw new Error(
		`Private relay did not become ready within ${String(timeoutMs)}ms (${summarizePrivateState(latestState)}).`,
	);
};

export const bootstrapHeadlessServer = async (
	options: BootstrapHeadlessServerOptions,
): Promise<HeadlessServerRuntime> => {
	validateHeadlessServerArgs(options.args);

	const startServer = options.createBackendServer ?? createBackendServer;
	let backend: BackendHandle | null = null;

	try {
		backend = await startServer();
		const localBaseUrl = `http://127.0.0.1:${String(toPort(backend.server))}`;

		serverLogger.success("headless-server", "Headless server listening", {
			bindHost: serverConfig.host,
			localBaseUrl,
			token: maskTokenForLogs(serverConfig.token),
		});

		if (options.args.login && options.args.password) {
			serverLogger.info("headless-server", "Authenticating private account", {
				login: maskEmailForLogs(options.args.login),
				privateBackendUrl: serverConfig.privateBackendUrl,
			});
			await backend.privateAccountService.login({
				email: options.args.login,
				password: options.args.password,
			});
			const state = await waitForPrivateRelayReady(backend.privateAccountService, {
				pollIntervalMs: options.pollIntervalMs,
				sleep: options.sleep,
				timeoutMs: options.timeoutMs,
			});
			serverLogger.success("headless-server", "Private relay ready", {
				connectorId: state.connector?.id ?? null,
				connectorStatus: state.connector?.status ?? null,
				login: maskEmailForLogs(state.user?.email ?? null),
				relayState: state.connectorRelayState,
			});
		}

		const runningBackend = backend;

		return {
			backend: runningBackend,
			localBaseUrl,
			stop: async () => {
				await stopBackendHandle(runningBackend);
			},
		};
	} catch (error) {
		if (backend) {
			await stopBackendHandle(backend);
		}

		throw error;
	}
};

export const runHeadlessServerCli = async (argv: string[]): Promise<HeadlessServerRuntime> =>
	await bootstrapHeadlessServer({
		args: parseHeadlessServerArgs(argv),
	});

export const logHeadlessServerError = (error: unknown): void => {
	serverLogger.error("headless-server", "Headless server failed to start", {
		...toLogErrorDetails(error),
	});
};
