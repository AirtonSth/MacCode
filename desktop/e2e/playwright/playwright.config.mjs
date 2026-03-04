import path from "node:path";
import { fileURLToPath } from "node:url";

import { defineConfig } from "@playwright/test";

const configDirectory = path.dirname(fileURLToPath(import.meta.url));
const desktopRoot = path.resolve(configDirectory, "../..");

export default defineConfig({
	expect: {
		timeout: 10_000,
	},

	reporter: "list",
	testDir: path.resolve(configDirectory, "tests"),
	timeout: 60_000,

	use: {
		baseURL: "http://127.0.0.1:4174",
		headless: true,
	},

	webServer: {
		command: "bunx vite build && bunx vite preview --host 127.0.0.1 --port 4174 --strictPort",
		cwd: desktopRoot,
		reuseExistingServer: false,
		timeout: 300_000,
		url: "http://127.0.0.1:4174",
	},

	workers: 1,
});
