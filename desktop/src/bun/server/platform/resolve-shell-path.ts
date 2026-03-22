import { collectResolvedPath } from "./command";

/**
 * macOS and Linux GUI apps inherit a minimal PATH when launched from
 * the desktop environment. This resolves the user's full shell PATH
 * by spawning a login shell and merges it into process.env.PATH so
 * CLI tools like `claude` and `codex` can be found.
 *
 * Windows is skipped because GUI apps inherit the full system+user
 * PATH from the registry.
 */
export const resolveShellPath = (): void => {
	try {
		const resolvedPath = collectResolvedPath();
		if (resolvedPath.length > 0) {
			process.env.PATH = resolvedPath;
		}
	} catch {
		// Non-fatal: keep the existing PATH
	}
};
