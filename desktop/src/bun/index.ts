import { ApplicationMenu, BrowserWindow, BrowserView, Updater, Utils } from "electrobun/bun";

import { createBackendServer } from "./server/app";
import { serverConfig } from "./server/config";
import { maskTokenForLogs, serverLogger } from "./server/shared/core/server-logger";
import { startMdnsBroadcast } from "./network/mdns";

let mainWindowRef: BrowserWindow | null = null;

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

await createBackendServer({ port: serverConfig.port });
await waitForBackendReady();

let stopMdns = () => {
	// no-op
};
try {
	const discoveryResponse = await fetch(`http://127.0.0.1:${serverConfig.port}/v1/discovery`, {
		method: "GET",
	});
	if (discoveryResponse.ok) {
		const discoveryMetadata = (await discoveryResponse.json()) as DiscoveryMetadata;
		logDiscoveryHints(discoveryMetadata.connectHints);
		stopMdns = await startMdnsBroadcast({
			capabilitiesVersion: discoveryMetadata.capabilitiesVersion,
			port: discoveryMetadata.port,
			serverId: discoveryMetadata.serverId,
			version: discoveryMetadata.version,
		});
	}
} catch {
	// mDNS remains optional; keep app startup resilient
	serverLogger.warn("desktop-bootstrap", "mDNS discovery broadcast unavailable");
}

process.on("exit", () => {
	stopMdns();
});

installMacShortcutsMenu();

const url = await getMainViewUrl();

const mainWindow = new BrowserWindow({
	titleBarStyle: "default",
	transparent: false,
	frame: {
		height: 700,
		width: 1200,
		x: 200,
		y: 200,
	},
	title: "RemoteCode + Electrobun",
	url,
	rpc: appRPC,
});
mainWindowRef = mainWindow;

const webview = mainWindow.webview;
webview.on("dom-ready", () => {
	webview.openDevTools();
});

void mainWindow;
serverLogger.success("desktop-bootstrap", "Electrobun app started", {
	windowTitle: "RemoteCode + Electrobun",
	workspaceViewUrl: url,
});
