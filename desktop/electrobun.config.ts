import type { ElectrobunConfig } from "electrobun";

const appIconPath = "assets/app-icon.png";
const macIconsetPath = "icon.iconset";

const isCdpEnabled = ["1", "true", "yes"].includes(
	(process.env.ELECTROBUN_CDP ?? "").toLowerCase(),
);
const cdpPort = process.env.ELECTROBUN_CDP_PORT ?? "9333";
const chromiumFlags = isCdpEnabled
	? {
			"remote-debugging-address": "127.0.0.1",
			"remote-debugging-port": cdpPort,
		}
	: undefined;

const runtimeConfig = {
	bundleCEF: isCdpEnabled,
	defaultRenderer: isCdpEnabled ? ("cef" as const) : ("native" as const),
	chromiumFlags,
};

const config: ElectrobunConfig = {
	app: {
		identifier: "remotecode-electrobun.local",
		name: "RemoteCode",
		version: "0.0.1",
	},

	build: {
		// Vite builds to dist/, copy HTML and assets into electrobun views
		copy: {
			"dist/assets": "views/react/assets",
			"dist/index.html": "views/react/index.html",
		},

		linux: {
			icon: appIconPath,
			...runtimeConfig,
		},

		mac: {
			icons: macIconsetPath,
			...runtimeConfig,
		},

		// Ignore Vite output in watch mode; HMR process handles rebuilds
		watchIgnore: ["dist/**"],

		win: {
			icon: appIconPath,
			...runtimeConfig,
		},
	},
};

export default config;
