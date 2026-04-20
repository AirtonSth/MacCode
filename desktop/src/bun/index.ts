import Electrobun, { ApplicationMenu, BrowserWindow, BrowserView, Updater, Utils } from "electrobun/bun";
import { mkdir } from "node:fs/promises";

import { createBackendServer } from "./server/app";
import { serverConfig } from "./server/config";
import { maskTokenForLogs, serverLogger } from "./server/shared/core/server-logger";
import { startMdnsBroadcast } from "./network/mdns";
import { checkForUpdates } from "./updater/check-update";
import { resolveShellPath } from "./server/platform/resolve-shell-path";

const APP_VERSION = "1.0.7";

let mainWindowRef: BrowserWindow | null = null;
let privateAccountServiceRef:
	| Awaited<ReturnType<typeof createBackendServer>>["privateAccountService"]
	| null = null;
const electrobunEvents = (Electrobun as unknown as {
	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	events?: { on: (event: string, handler: (payload: any) => void) => void };
}).events;

interface WindowBounds {
	x: number;
	y: number;
	width: number;
	height: number;
}

const WINDOW_BOUNDS_DIR = `${Utils.paths.home}/.config/remotecode`;
const WINDOW_BOUNDS_FILE = `${WINDOW_BOUNDS_DIR}/window-bounds.json`;

const loadWindowBounds = async (): Promise<WindowBounds | null> => {
	try {
		const text = await Bun.file(WINDOW_BOUNDS_FILE).text();
		return JSON.parse(text) as WindowBounds;
	} catch {
		return null;
	}
};

const saveWindowBounds = async (bounds: WindowBounds): Promise<void> => {
	try {
		await mkdir(WINDOW_BOUNDS_DIR, { recursive: true });
		await Bun.write(WINDOW_BOUNDS_FILE, JSON.stringify(bounds));
	} catch {
		// ignore
	}
};

const AUTH_COMPLETE_PATH = "/auth/complete";

const focusMainWindow = (): void => {
	const mainWindow = mainWindowRef;
	if (!mainWindow) {
		return;
	}

	mainWindow.show?.();
	mainWindow.focus?.();
};

const handleOpenUrl = async (rawUrl: string): Promise<void> => {
	const privateAccountService = privateAccountServiceRef;
	if (!privateAccountService) {
		return;
	}

	let parsed: URL;
	try {
		parsed = new URL(rawUrl);
	} catch {
		return;
	}

	const pathname = parsed.pathname.length > 0 ? parsed.pathname : `/${parsed.host}`;
	if (pathname !== AUTH_COMPLETE_PATH) {
		return;
	}

	const completionToken = parsed.searchParams.get("completionToken")?.trim() ?? "";
	if (completionToken.length === 0) {
		serverLogger.warn("desktop-bootstrap", "Ignored auth completion without token", { rawUrl });
		return;
	}

	try {
		await privateAccountService.completeBrowserReturn({
			...(parsed.searchParams.get("backendUrl")?.trim()
				? { backendUrl: parsed.searchParams.get("backendUrl")!.trim() }
				: {}),
			completionToken,
		});
		focusMainWindow();
		serverLogger.success("desktop-bootstrap", "Applied auth completion deeplink", {
			rawUrl,
		});
	} catch (error) {
		serverLogger.error("desktop-bootstrap", "Failed to apply auth completion deeplink", {
			rawUrl,
			...(error instanceof Error ? { message: error.message } : {}),
		});
	}
};

const isExternalHttpUrl = (value: string): boolean => {
	try {
		const url = new URL(value);
		return url.protocol === "http:" || url.protocol === "https:";
	} catch {
		return false;
	}
};

const openExternalUrl = async (url: string): Promise<void> => {
	if (!isExternalHttpUrl(url)) {
		throw new Error("Invalid external URL");
	}

	if (Utils.openURL) {
		await Utils.openURL(url);
		return;
	}

	const platform = process.platform;
	const command = platform === "darwin"
		? ["open", url]
		: platform === "win32"
			? ["cmd", "/c", "start", "", url]
			: ["xdg-open", url];
	const subprocess = Bun.spawn(command, {
		stderr: "pipe",
		stdout: "ignore",
	});
	const exitCode = await subprocess.exited;

	if (exitCode !== 0) {
		const stderr = await new Response(subprocess.stderr).text();
		throw new Error(stderr.trim() || "Unable to open external URL");
	}
};

const appRPC = (BrowserView as unknown as {
	defineRPC: <T>(config: {
		maxRequestTime?: number;
		handlers: {
			requests: Record<string, (...args: never[]) => unknown>;
			messages: Record<string, (...args: never[]) => void>;
		};
	}) => T;
}).defineRPC({
	maxRequestTime: 120_000,
	handlers: {
		requests: {
			openProjectDirectory: async () => {
				return Utils.openFileDialog({
					allowedFileTypes: "*",
					allowsMultipleSelection: false,
					canChooseDirectory: true,
					canChooseFiles: false,
					startingFolder: Utils.paths.home,
				});
			},
			openContextPaths: async () => {
				return Utils.openFileDialog({
					allowedFileTypes: "*",
					allowsMultipleSelection: true,
					canChooseDirectory: true,
					canChooseFiles: true,
					startingFolder: Utils.paths.home,
				});
			},
			showProjectInFinder: (projectPath: string) => {
				return Utils.showItemInFolder?.(projectPath);
			},
			openExternalUrl: async (url: string) => {
				await openExternalUrl(url);
			},
			checkForUpdates: async () => {
				return checkForUpdates(APP_VERSION);
			},
			closeWindow: () => {
				mainWindowRef?.close();
			},
			minimizeWindow: () => {
				mainWindowRef?.minimize();
			},
			toggleMaximizeWindow: () => {
				if (!mainWindowRef) {
					return;
				}

				if (mainWindowRef.isMaximized()) {
					mainWindowRef.unmaximize();
				} else {
					mainWindowRef.maximize();
				}
			},
		},
		messages: {},
	},
});

const DEV_SERVER_PORT = 5173;
const DEV_SERVER_URL = `http://localhost:${DEV_SERVER_PORT}`;
const HEALTH_URL = `http://127.0.0.1:${serverConfig.port}/v1/projects`;
const HEALTH_CHECK_TIMEOUT_MS = 30_000;
const HEALTH_CHECK_INTERVAL_MS = 250;

const wait = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

const waitForBackendReady = async () => {
	const start = Date.now();

	while (Date.now() - start < HEALTH_CHECK_TIMEOUT_MS) {
		try {
			const response = await fetch(HEALTH_URL, {
				headers: {
					authorization: `Bearer ${serverConfig.token}`,
				},
				method: "GET",
			});

			if (response.ok) {
				serverLogger.success("desktop-bootstrap", "Backend is ready", {
					durationMs: serverLogger.traceDurationMs(start),
					healthUrl: HEALTH_URL,
				});
				return;
			}
		} catch {
			// wait for backend to finish booting
		}

		await wait(HEALTH_CHECK_INTERVAL_MS);
	}

	throw new Error(`Backend readiness timeout: ${serverConfig.port}`);
};

interface DiscoveryMetadata {
	authMode: string;
	capabilitiesVersion: string;
	connectHints?: DiscoveryConnectHints;
	hostname: string;
	port: number;
	serverId: string;
	version: string;
}

interface DiscoveryConnectHints {
	addresses: string[];
	recommendedBaseUrls: string[];
	tailscaleAddresses: string[];
}

const logDiscoveryHints = (hints: DiscoveryConnectHints | undefined): void => {
	if (!hints) {
		return;
	}

	if (hints.recommendedBaseUrls.length > 0) {
		serverLogger.info("desktop-bootstrap", "Reachable server URLs", {
			urls: hints.recommendedBaseUrls.join(", "),
		});
	}

	if (hints.tailscaleAddresses.length > 0) {
		serverLogger.info("desktop-bootstrap", "Detected Tailscale addresses", {
			addresses: hints.tailscaleAddresses.join(", "),
		});
	}
};

const installMacShortcutsMenu = () => {
	ApplicationMenu.setApplicationMenu([
		{
			label: "RemoteCode",
			submenu: [{ role: "about" }, { type: "separator" }, { role: "quit" }],
		},
		{
			label: "Edit",
			submenu: [
				{ role: "undo" },
				{ role: "redo" },
				{ type: "separator" },
				{ role: "cut" },
				{ role: "copy" },
				{ role: "paste" },
				{ role: "selectAll" },
			],
		},
	]);
};

async function getMainViewUrl() {
	const channel = await Updater.localInfo.channel();

	if (channel === "dev") {
		try {
			await fetch(DEV_SERVER_URL, { method: "HEAD" });
			serverLogger.success("desktop-bootstrap", "HMR active", {
				viewUrl: DEV_SERVER_URL,
			});

			return DEV_SERVER_URL;
		} catch {
			serverLogger.warn("desktop-bootstrap", "Vite dev server not found", {
				hint: "Run 'bun run dev:hmr' for HMR.",
			});
		}
	}

	return "views://react/index.html";
}

serverLogger.banner("Desktop Server Boot", {
	backendUrl: serverConfig.privateBackendUrl,
	host: serverConfig.host,
	localToken: maskTokenForLogs(serverConfig.token),
	port: serverConfig.port,
});

await resolveShellPath();
serverLogger.info("desktop-bootstrap", "Shell PATH resolved", {
	path: (process.env.PATH ?? "").split(":").length + " entries",
});

const backendHandle = await createBackendServer({ port: serverConfig.port });
privateAccountServiceRef = backendHandle.privateAccountService;
const backendReadyPromise = waitForBackendReady();

electrobunEvents?.on("open-url", async ({ url }: { url: string }) => {
	await handleOpenUrl(url);
});

let stopMdns = () => {
	// no-op
};

const startMdnsAsync = async () => {
	try {
		await backendReadyPromise;
		const discoveryResponse = await fetch(`http://127.0.0.1:${serverConfig.port}/v1/discovery`, {
			method: "GET",
		});
		if (!discoveryResponse.ok) {
			return;
		}
		const discoveryMetadata = (await discoveryResponse.json()) as DiscoveryMetadata;
		logDiscoveryHints(discoveryMetadata.connectHints);
		stopMdns = await startMdnsBroadcast({
			capabilitiesVersion: discoveryMetadata.capabilitiesVersion,
			port: discoveryMetadata.port,
			serverId: discoveryMetadata.serverId,
			version: discoveryMetadata.version,
		});
	} catch {
		serverLogger.warn("desktop-bootstrap", "mDNS discovery broadcast unavailable");
	}
};
void startMdnsAsync();

process.on("exit", () => {
	stopMdns();
});

installMacShortcutsMenu();

const url = await getMainViewUrl();
const savedBounds = await loadWindowBounds();

const mainWindow = new BrowserWindow({
	titleBarStyle: "default",
	transparent: false,
	frame: savedBounds ?? {
		height: 700,
		width: 1200,
		x: 200,
		y: 200,
	},
	title: "RemoteCode.io",
	url,
	rpc: appRPC,
});
mainWindowRef = mainWindow;

let currentBounds: WindowBounds = savedBounds ?? { height: 700, width: 1200, x: 200, y: 200 };
let saveBoundsTimer: ReturnType<typeof setTimeout> | null = null;

const scheduleSave = (bounds: WindowBounds): void => {
	if (saveBoundsTimer) clearTimeout(saveBoundsTimer);
	saveBoundsTimer = setTimeout(() => void saveWindowBounds(bounds), 500);
};

const windowEventEmitter = electrobunEvents as unknown as {
	on: (event: string, handler: (event: { data: { id: number; x: number; y: number; width?: number; height?: number } }) => void) => void;
};

windowEventEmitter.on("resize", (event) => {
	if (event.data.id !== mainWindow.id) return;
	currentBounds = { x: event.data.x, y: event.data.y, width: event.data.width!, height: event.data.height! };
	scheduleSave(currentBounds);
});

windowEventEmitter.on("move", (event) => {
	if (event.data.id !== mainWindow.id) return;
	currentBounds = { ...currentBounds, x: event.data.x, y: event.data.y };
	scheduleSave(currentBounds);
});

void mainWindow;
serverLogger.success("desktop-bootstrap", "Electrobun app started", {
	windowTitle: "RemoteCode.io",
	workspaceViewUrl: url,
});
