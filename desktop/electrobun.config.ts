import type { ElectrobunConfig } from "electrobun";

const config: ElectrobunConfig = {
	app: {
		identifier: "remotecode-electrobun.local",
		name: "remotecode-electrobun",
		version: "0.0.1",
	},

	build: {
		// Vite builds to dist/, copy HTML and assets into electrobun views
		copy: {
			"dist/assets": "views/react/assets",
			"dist/index.html": "views/react/index.html",
		},


		linux: {
			bundleCEF: false,
		},

		mac: {
			bundleCEF: false,
		},


		// Ignore Vite output in watch mode; HMR process handles rebuilds
		watchIgnore: ["dist/**"],

		win: {
			bundleCEF: false,
		},
	},
};

export default config;
