import path from "node:path";
import { accessSync, constants, statSync } from "node:fs";
import { commandExtensions } from "./index";

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

const getCandidates = (name: string): string[] => {
	const extensions = commandExtensions();
	if (extensions.length === 0) {
		return [name];
	}

	return [...extensions.map((ext) => `${name}${ext}`), name];
};

export const resolveCommandInPath = (
	name: string,
	pathValue: string | undefined = process.env.PATH,
): string => {
	const entries = (pathValue ?? "")
		.split(path.delimiter)
		.map((entry) => entry.trim())
		.filter(Boolean);

	const candidates = getCandidates(name);

	const tryResolve = (directories: string[]): string | null => {
		for (const directory of directories) {
			for (const candidate of candidates) {
				const fullPath = path.join(directory, candidate);
				if (isExecutable(fullPath)) {
					return fullPath;
				}
			}
		}

		return null;
	};

	const nonShadowed = entries.filter((d) => !isNodeModulesBinDirectory(d));
	const shadowed = entries.filter((d) => isNodeModulesBinDirectory(d));

	return tryResolve(nonShadowed) ?? tryResolve(shadowed) ?? name;
};
