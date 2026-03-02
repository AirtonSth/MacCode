import { existsSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, normalize, resolve } from "node:path";

export interface FsRootDTO {
	id: string;
	label: string;
	path: string;
}

export interface FsEntryDTO {
	type: "directory" | "file";
	name: string;
	path: string;
}

export interface FsListResult {
	entries: FsEntryDTO[];
	parentPath: string | null;
	path: string;
}

export interface FsListError {
	type: "invalid_path" | "not_directory" | "not_found";
}

export interface FsServiceContract {
	listRoots: () => FsRootDTO[];
	listPath: (path: string) => FsListError | FsListResult;
}

const normalizePath = (value: string): string => normalize(resolve(value));

const listWindowsRoots = (): FsRootDTO[] => {
	const roots: FsRootDTO[] = [];

	for (let code = 65; code <= 90; code += 1) {
		const drive = String.fromCharCode(code);
		const path = `${drive}:\\`;
		if (!existsSync(path)) {
			continue;
		}

		roots.push({
			id: path,
			label: `${drive}:`,
			path,
		});
	}

	return roots;
};

const listUnixRoots = (): FsRootDTO[] => {
	const home = homedir();
	const roots: FsRootDTO[] = [
		{
			id: "/",
			label: "Root",
			path: "/",
		},
	];

	if (home && existsSync(home)) {
		roots.push({
			id: home,
			label: "Home",
			path: home,
		});
	}

	const parent = dirname(home);
	if (parent && parent !== "/" && existsSync(parent)) {
		roots.push({
			id: parent,
			label: "Users",
			path: parent,
		});
	}

	return roots;
};

export class FsService implements FsServiceContract {
	listRoots(): FsRootDTO[] {
		if (process.platform === "win32") {
			return listWindowsRoots();
		}

		return listUnixRoots();
	}

	listPath(path: string): FsListError | FsListResult {
		const trimmed = path.trim();
		if (!trimmed) {
			return { type: "invalid_path" };
		}

		const normalized = normalizePath(trimmed);
		if (!isAbsolute(normalized)) {
			return { type: "invalid_path" };
		}

		if (!existsSync(normalized)) {
			return { type: "not_found" };
		}

		const stats = statSync(normalized);
		if (!stats.isDirectory()) {
			return { type: "not_directory" };
		}

		const entries = readdirSync(normalized, { withFileTypes: true })
			.map((entry) => {
				const entryPath = join(normalized, entry.name);
				return {
					type: entry.isDirectory() ? "directory" : "file",
					name: entry.name,
					path: entryPath,
				} satisfies FsEntryDTO;
			})
			.sort((left, right) => {
				if (left.type !== right.type) {
					return left.type === "directory" ? -1 : 1;
				}

				return left.name.localeCompare(right.name);
			});

		return {
			entries,
			parentPath: normalized === "/" ? null : dirname(normalized),
			path: normalized,
		};
	}
}

export const createFsService = () => new FsService();
