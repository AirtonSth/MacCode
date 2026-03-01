import { ApplicationMenu, BrowserWindow, BrowserView, Updater, Utils } from "electrobun/bun";

import { createBackendServer } from "./server/app";
import { serverConfig } from "./server/config";

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
			showProjectInFinder: (projectPath: string) => {
				return Utils.showItemInFolder(projectPath);
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
				console.log("Backend is ready:", HEALTH_URL);
				return;
			}
		} catch {
			// wait for backend to finish booting
		}

		await wait(HEALTH_CHECK_INTERVAL_MS);
	}

	throw new Error(`Backend readiness timeout: ${serverConfig.port}`);
};

const installMacShortcutsMenu = () => {
	ApplicationMenu.setApplicationMenu([
		{
			label: "Remotecode",
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
			console.log(`HMR active: using Vite at ${DEV_SERVER_URL}`);

			return DEV_SERVER_URL;
		} catch {
			console.log("Vite dev server not found. Run 'bun run dev:hmr' for HMR.");
		}
	}

	return "views://react/index.html";
}

await createBackendServer({ port: serverConfig.port });
await waitForBackendReady();

installMacShortcutsMenu();

const url = await getMainViewUrl();

const mainWindow = new BrowserWindow({
	titleBarStyle: "hidden",
	transparent: true,
	frame: {
		height: 700,
		width: 1200,
		x: 200,
		y: 200,
	},
	title: "Remotecode + Electrobun",
	url,
	rpc: appRPC,
});
mainWindowRef = mainWindow;

const webview = mainWindow.webview;
webview.on("dom-ready", () => {
	webview.openDevTools();
});

void mainWindow;
console.log("Electrobun app started with React + Vite");
