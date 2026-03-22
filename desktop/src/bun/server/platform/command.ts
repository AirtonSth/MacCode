import path from "node:path";
import { accessSync, constants, existsSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";

import * as darwin from "./darwin";
import * as linux from "./linux";
import * as win32 from "./win32";

const SHELL_PATH_START_MARKER = "__REMOTE_CODE_PATH_START__";
const SHELL_PATH_END_MARKER = "__REMOTE_CODE_PATH_END__";
const platformModules: Record<string, typeof linux> = { darwin, linux, win32 };
const currentPlatformModule = platformModules[process.platform] ?? linux;

const isExecutable = (candidate: string): boolean => {
	try {
		accessSync(candidate, constants.X_OK);
		const stats = statSync(candidate);
		return stats.isFile() || stats.isFIFO();
	} catch {
		return false;
	}
};

const isNodeModulesBinDirectory = (directory: string): boolean => {
	const normalized = directory.replace(/\\+/g, "/");
	return normalized.endsWith("/node_modules/.bin");
};

const sanitizeEnv = (env: Record<string, string | undefined>): Record<string, string> =>
	Object.fromEntries(Object.entries(env).filter(([, value]) => value !== undefined)) as Record<string, string>;

const splitPathEntries = (pathValue: string | undefined): string[] =>
	(pathValue ?? "")
		.split(path.delimiter)
		.map((entry) => entry.trim())
		.filter(Boolean);

export const mergePathEntries = (...pathValues: Array<string | undefined>): string => {
	const seen = new Set<string>();
	const result: string[] = [];

	for (const pathValue of pathValues) {
		for (const entry of splitPathEntries(pathValue)) {
			if (seen.has(entry)) {
				continue;
			}

			seen.add(entry);
			result.push(entry);
		}
	}

	return result.join(path.delimiter);
};

const getCandidates = (name: string): string[] => {
	const extensions = currentPlatformModule.commandExtensions();
	if (extensions.length === 0) {
		return [name];
	}

	return [...extensions.map((ext: string) => `${name}${ext}`), name];
};

const resolveInDirectories = (name: string, directories: string[]): string => {
	const candidates = getCandidates(name);
	const nonShadowed = directories.filter((directory) => !isNodeModulesBinDirectory(directory));
	const shadowed = directories.filter((directory) => isNodeModulesBinDirectory(directory));

	const tryResolve = (candidateDirectories: string[]): string | null => {
		for (const directory of candidateDirectories) {
			for (const candidate of candidates) {
				const fullPath = path.join(directory, candidate);
				if (isExecutable(fullPath)) {
					return fullPath;
				}
			}
		}

		return null;
	};

	return tryResolve(nonShadowed) ?? tryResolve(shadowed) ?? name;
};

const extractShellPath = (output: string): string | null => {
	const startIndex = output.indexOf(SHELL_PATH_START_MARKER);
	const endIndex = output.indexOf(SHELL_PATH_END_MARKER);

	if (startIndex < 0 || endIndex <= startIndex) {
		return null;
	}

	const pathValue = output
		.slice(startIndex + SHELL_PATH_START_MARKER.length, endIndex)
		.trim();

	return pathValue.length > 0 ? pathValue : null;
};

const buildShellPathProbeArgs = (shell: string, interactive: boolean): string[] => {
	if (process.platform === "win32") {
		const lower = shell.toLowerCase();
		if (lower.includes("powershell") || lower.includes("pwsh")) {
			return [
				shell,
				"-NoProfile",
				"-Command",
				`Write-Output '${SHELL_PATH_START_MARKER}'; Write-Output $env:PATH; Write-Output '${SHELL_PATH_END_MARKER}'`,
			];
		}

		return [
			shell,
			"/c",
			`echo ${SHELL_PATH_START_MARKER} && echo %PATH% && echo ${SHELL_PATH_END_MARKER}`,
		];
	}

	const args = [shell, "-l"];
	if (interactive) {
		args.push("-i");
	}
	args.push("-c", `printf '${SHELL_PATH_START_MARKER}'; printenv PATH; printf '${SHELL_PATH_END_MARKER}'`);
	return args;
};

const readShellPath = (input: {
	env: Record<string, string | undefined>;
	interactive: boolean;
	shell?: string;
}): string | null => {
	const shell = input.shell?.trim() || input.env.SHELL?.trim() || currentPlatformModule.resolveShell();
	if (!shell) {
		return null;
	}

	try {
		const result = Bun.spawnSync({
			cmd: buildShellPathProbeArgs(shell, input.interactive),
			env: sanitizeEnv(input.env),
			stderr: "pipe",
			stdout: "pipe",
		});

		if ((result.exitCode ?? 1) !== 0) {
			return null;
		}

		const stdout = new TextDecoder().decode(result.stdout ?? new Uint8Array());
		return extractShellPath(stdout);
	} catch {
		return null;
	}
};

const existingDirectories = (directories: string[]): string[] => {
	const seen = new Set<string>();
	const result: string[] = [];

	for (const directory of directories) {
		const trimmed = directory.trim();
		if (!trimmed || seen.has(trimmed) || !existsSync(trimmed)) {
			continue;
		}

		seen.add(trimmed);
		result.push(trimmed);
	}

	return result;
};

const collectVersionedBinDirectories = (root: string): string[] => {
	if (!existsSync(root)) {
		return [];
	}

	try {
		return readdirSync(root)
			.sort((left, right) => right.localeCompare(left))
			.map((entry) => path.join(root, entry, "bin"))
			.filter((directory) => existsSync(directory));
	} catch {
		return [];
	}
};

const collectCommonInstallDirectories = (
	env: Record<string, string | undefined>,
	options: {
		includeSystemInstallDirectories?: boolean;
	} = {},
): string[] => {
	const home = env.HOME?.trim() || env.USERPROFILE?.trim() || homedir();
	const appData = env.APPDATA?.trim();
	const localAppData = env.LOCALAPPDATA?.trim();
	const nvmHome = env.NVM_HOME?.trim();
	const nvmVersionsRoot = home ? path.join(home, ".nvm", "versions", "node") : "";
	const systemUnixCandidates = [
		"/opt/homebrew/bin",
		"/usr/local/bin",
	];
	const userUnixCandidates = home
		? [
			path.join(home, ".local", "bin"),
			path.join(home, "bin"),
			path.join(home, ".bun", "bin"),
			path.join(home, ".volta", "bin"),
			path.join(home, ".asdf", "shims"),
			path.join(home, ".npm-global", "bin"),
			path.join(home, ".yarn", "bin"),
			path.join(home, "Library", "pnpm"),
		]
		: [];
	const windowsCandidates = [
		appData ? path.join(appData, "npm") : "",
		localAppData ? path.join(localAppData, "Programs", "nodejs") : "",
		localAppData ? path.join(localAppData, "Microsoft", "WinGet", "Links") : "",
		nvmHome ?? "",
		home ? path.join(home, "scoop", "shims") : "",
	];

	return existingDirectories([
		...(process.platform === "win32"
			? windowsCandidates
			: [
				...(options.includeSystemInstallDirectories === false ? [] : systemUnixCandidates),
				...userUnixCandidates,
			]),
		...(nvmVersionsRoot ? collectVersionedBinDirectories(nvmVersionsRoot) : []),
	]);
};

export const resolveCommandInPath = (
	name: string,
	pathValue: string | undefined = process.env.PATH,
): string => {
	return resolveInDirectories(name, splitPathEntries(pathValue));
};

export const collectResolvedPath = (input: {
	env?: Record<string, string | undefined>;
	includeSystemInstallDirectories?: boolean;
	pathValue?: string;
	shell?: string;
} = {}): string => {
	const env = input.env ?? process.env;
	const basePath = input.pathValue ?? env.PATH;
	const loginShellPath = readShellPath({
		env: {
			...env,
			PATH: basePath,
		},
		interactive: false,
		shell: input.shell,
	});
	const interactiveShellPath = readShellPath({
		env: {
			...env,
			PATH: mergePathEntries(basePath, loginShellPath ?? undefined),
		},
		interactive: true,
		shell: input.shell,
	});
	const commonInstallDirectories = collectCommonInstallDirectories(env, {
		includeSystemInstallDirectories: input.includeSystemInstallDirectories,
	});

	return mergePathEntries(
		basePath,
		loginShellPath ?? undefined,
		interactiveShellPath ?? undefined,
		commonInstallDirectories.join(path.delimiter),
	);
};

export const resolveCommand = (
	name: string,
	input: {
		env?: Record<string, string | undefined>;
		includeSystemInstallDirectories?: boolean;
		pathValue?: string;
		shell?: string;
	} = {},
): string => {
	const env = input.env ?? process.env;
	const basePath = input.pathValue ?? env.PATH;
	const direct = resolveCommandInPath(name, basePath);

	if (direct !== name || input.pathValue !== undefined) {
		return direct;
	}

	return resolveCommandInPath(name, collectResolvedPath(input));
};
