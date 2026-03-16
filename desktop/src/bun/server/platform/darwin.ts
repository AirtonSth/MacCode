import { existsSync } from "node:fs";
import type { KillIntent, PlatformModule, Subprocess } from "./types";

const FALLBACK_SHELL = "/bin/zsh";
const SECONDARY_FALLBACK_SHELL = "/bin/sh";

export const resolveShell: PlatformModule["resolveShell"] = () => {
	const configured = process.env.SHELL?.trim();
	if (configured && existsSync(configured)) {
		return configured;
	}

	if (existsSync(FALLBACK_SHELL)) {
		return FALLBACK_SHELL;
	}

	if (existsSync(SECONDARY_FALLBACK_SHELL)) {
		return SECONDARY_FALLBACK_SHELL;
	}

	return FALLBACK_SHELL;
};

export const buildShellArgs: PlatformModule["buildShellArgs"] = (shell, command) => [shell, "-lc", command];

export const killProcess: PlatformModule["killProcess"] = (subprocess: Subprocess, intent: KillIntent) => {
	subprocess.kill(intent === "force" ? "SIGKILL" : "SIGTERM");
};

export const commandExtensions: PlatformModule["commandExtensions"] = () => [];
