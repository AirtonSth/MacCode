import { resolveShell, buildShellArgs } from "./index";

/**
 * macOS GUI apps inherit a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin).
 * This resolves the user's full shell PATH by spawning a login shell
 * and merges it into process.env.PATH so CLI tools like `claude` and
 * `codex` can be found.
 */
export const resolveShellPath = async (): Promise<void> => {
	if (process.platform === "win32") {
		return;
	}

	const currentPath = process.env.PATH ?? "";

	try {
		const shell = resolveShell();
		const args = buildShellArgs(shell, "echo $PATH");

		const proc = Bun.spawn({
			cmd: args,
			env: { ...process.env, PATH: currentPath },
			stderr: "pipe",
			stdout: "pipe",
		});

		const exitCode = await proc.exited;
		if (exitCode !== 0) {
			return;
		}

		const shellPath = (await new Response(proc.stdout).text()).trim();
		if (shellPath.length === 0) {
			return;
		}

		const merged = mergePaths(currentPath, shellPath);
		process.env.PATH = merged;
	} catch {
		// Non-fatal: keep the existing PATH
	}
};

const mergePaths = (existing: string, resolved: string): string => {
	const seen = new Set<string>();
	const result: string[] = [];

	for (const entry of resolved.split(":")) {
		const trimmed = entry.trim();
		if (trimmed.length > 0 && !seen.has(trimmed)) {
			seen.add(trimmed);
			result.push(trimmed);
		}
	}

	for (const entry of existing.split(":")) {
		const trimmed = entry.trim();
		if (trimmed.length > 0 && !seen.has(trimmed)) {
			seen.add(trimmed);
			result.push(trimmed);
		}
	}

	return result.join(":");
};
