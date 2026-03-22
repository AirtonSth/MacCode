import { resolveCommand } from "../../platform/index";

export interface CodexAvailability {
	available: boolean;
	reason: string;
}

let cachedAvailability: CodexAvailability | null = null;

const decodeOutput = (value: Uint8Array | null | undefined): string => {
	if (!value || value.byteLength === 0) {
		return "";
	}

	return new TextDecoder().decode(value).trim();
};

const runCommand = (command: string[]): { exitCode: number; stderr: string; stdout: string } => {
	try {
		const result = Bun.spawnSync({
			cmd: command,
			stderr: "pipe",
			stdout: "pipe",
		});

		return {
			exitCode: result.exitCode ?? 1,
			stderr: decodeOutput(result.stderr),
			stdout: decodeOutput(result.stdout),
		};
	} catch (error) {
		return {
			exitCode: 1,
			stderr: error instanceof Error ? error.message : "unknown command error",
			stdout: "",
		};
	}
};

const isLoggedIn = (value: string): boolean => {
	const normalized = value.toLowerCase();

	if (normalized.includes("not logged in")) {
		return false;
	}

	if (normalized.includes("logged out")) {
		return false;
	}

	return normalized.includes("logged in");
};

export const getCodexAvailability = (): CodexAvailability => {
	if (cachedAvailability) {
		return cachedAvailability;
	}

	const codexCommand = resolveCommand("codex");
	const versionResult = runCommand([codexCommand, "--version"]);

	if (versionResult.exitCode !== 0) {
		cachedAvailability = {
			available: false,
			reason: `codex CLI unavailable: ${versionResult.stderr || "command failed"}`,
		};

		return cachedAvailability;
	}

	const loginResult = runCommand([codexCommand, "login", "status"]);
	const loginOutput = `${loginResult.stdout}\n${loginResult.stderr}`.trim();

	if (loginResult.exitCode !== 0 || !isLoggedIn(loginOutput)) {
		cachedAvailability = {
			available: false,
			reason: "codex CLI is not authenticated (`codex login status`)",
		};

		return cachedAvailability;
	}

	cachedAvailability = {
		available: true,
		reason: "",
	};
	return cachedAvailability;
};
