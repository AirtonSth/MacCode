import type { ElectrobunConfig } from "electrobun";

const appIconPath = "assets/app-icon.png";
const macIconsetPath = "icon.iconset";

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
			bundleCEF: false,
		},

		mac: {
			icons: macIconsetPath,
			bundleCEF: false,
		},


		// Ignore Vite output in watch mode; HMR process handles rebuilds
		watchIgnore: ["dist/**"],

		win: {
			icon: appIconPath,
			bundleCEF: false,
		},
	},
};

export default config;
