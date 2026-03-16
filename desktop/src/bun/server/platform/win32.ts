import type { KillIntent, PlatformModule, Subprocess } from "./types";

export const resolveShell: PlatformModule["resolveShell"] = () => {
	const comspec = process.env.COMSPEC?.trim();
	if (comspec) {
		return comspec;
	}

	return "cmd.exe";
};

export const buildShellArgs: PlatformModule["buildShellArgs"] = (shell, command) => {
	const lower = shell.toLowerCase();

	if (lower.includes("powershell") || lower.includes("pwsh")) {
		return [shell, "-NoProfile", "-Command", command];
	}

	return [shell, "/c", command];
};

export const killProcess: PlatformModule["killProcess"] = (subprocess: Subprocess, _intent: KillIntent) => {
	// On Windows, Bun's kill() without a signal argument uses TerminateProcess.
	// SIGKILL and SIGTERM are not available on Windows.
	subprocess.kill();
};

export const commandExtensions: PlatformModule["commandExtensions"] = () => [".exe", ".cmd", ".bat", ".com"];
