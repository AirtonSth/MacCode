import { existsSync } from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const desktopRoot = path.resolve(scriptDir, "..");

const isWindows = process.platform === "win32";
const defaultElectrobunExecutable = path.resolve(
	desktopRoot,
	"node_modules",
	".bin",
	isWindows ? "electrobun.cmd" : "electrobun",
);

const electrobunExecutable =
	process.env.ELECTROBUN_EXECUTABLE_PATH ?? defaultElectrobunExecutable;
const port = process.env.PLAYWRIGHT_MCP_PORT ?? "8931";
const mcpPackage = process.env.PLAYWRIGHT_MCP_PACKAGE ?? "@hotnsoursoup/playwright-mcp-electron@latest";

if (!existsSync(electrobunExecutable)) {
	console.error(`Could not find Electrobun executable at: ${electrobunExecutable}`);
	console.error("Set ELECTROBUN_EXECUTABLE_PATH to a valid path and try again.");
	process.exit(1);
}

const child = spawn(
	"bunx",
	[
		"--bun",
		mcpPackage,
		"--browser",
		"electron",
		"--executable-path",
		electrobunExecutable,
		"--port",
		port,
	],
	{
		cwd: desktopRoot,
		stdio: "inherit",
	},
);

child.on("error", (error) => {
	console.error("Failed to start playwright-mcp-electron:", error.message);
	process.exit(1);
});

child.on("exit", (code, signal) => {
	if (signal) {
		process.exit(0);
	}
	process.exit(code ?? 0);
});
