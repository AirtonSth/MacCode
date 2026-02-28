import { BrowserWindow, Updater } from "electrobun/bun";

import { createBackendServer } from "./server/app";
import { serverConfig } from "./server/config";

const DEV_SERVER_PORT = 5173;
const DEV_SERVER_URL = `http://localhost:${DEV_SERVER_PORT}`;

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

const url = await getMainViewUrl();

const mainWindow = new BrowserWindow({
	frame: {
		height: 700,
		width: 1200,
		x: 200,
		y: 200,
	},
	title: "Remotecode + Electrobun",
	url,
});

const webview = mainWindow.webview;
webview.on("dom-ready", () => {
	webview.openDevTools();
});

void mainWindow;
console.log("Electrobun app started with React + Vite");
