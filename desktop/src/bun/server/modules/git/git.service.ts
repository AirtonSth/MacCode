import type {
	GitBranch,
	GitBranchList,
	GitCheckoutRequest,
	GitCommitRequest,
	GitCommitResult,
	GitCreateBranchRequest,
	GitError,
	GitNotRepositoryError,
	GitProjectNotFoundError,
	GitServiceContract,
	GitStatus,
} from "./git.model";
import type { ProjectDTO } from "../../types";

type GitProjectLookup = {
	getProjectById: (projectId: string) => Promise<ProjectDTO | null> | ProjectDTO | null;
};

const DEFAULT_COMMIT_PUSH = false;
const GIT_NOT_REPOSITORY_MARKERS = [
	"not a git repository",
	"not a git work tree",
	"must be run in a work tree",
];

interface GitCommandResult {
	exitCode: number;
	stderr: string;
	stdout: string;
}

type GitExecutor = (input: { cwd: string; args: string[] }) => Promise<GitCommandResult>;

const readStreamText = async (
	stream: ReadableStream<Uint8Array> | null,
): Promise<string> => {
	if (!stream) {
		return "";
	}

	const decoder = new TextDecoder();
	const reader = stream.getReader();
	let output = "";

	try {
		while (true) {
			const { done, value } = await reader.read();

			if (done) {
				break;
			}

			if (!value || value.byteLength === 0) {
				continue;
			}

			output += decoder.decode(value, { stream: true });
		}

		output += decoder.decode();
		return output.trimEnd();
	} finally {
		reader.releaseLock();
	}
};

const defaultRunGitCommand: GitExecutor = async ({ cwd, args }) => {
	try {
		const process = Bun.spawn({
			cmd: ["git", ...args],
			cwd,
			stderr: "pipe",
			stdout: "pipe",
		});

		const [stdout, stderr, exitCode] = await Promise.all([
			readStreamText(process.stdout),
			readStreamText(process.stderr),
			process.exited,
		]);

		return {
			exitCode: exitCode ?? 1,
			stderr,
			stdout,
		};
	} catch (error) {
		return {
			exitCode: 1,
			stderr: error instanceof Error ? error.message : "failed to execute git command",
			stdout: "",
		};
	}
};

const isNotGitRepositoryError = (output: string): boolean => {
	const text = output.toLowerCase();
	return GIT_NOT_REPOSITORY_MARKERS.some((marker) => text.includes(marker));
};

const parseStatus = (raw: string): GitStatus => {
	let currentBranch: string | null = null;
	let isDetachedHead = false;
	let ahead = 0;
	let behind = 0;
	let stagedFiles = 0;
	let unstagedFiles = 0;
	let untrackedFiles = 0;
	let conflictedFiles = 0;
	let changedFiles = 0;
	let added = 0;
	let removed = 0;

	const lines = raw.split(/\r?\n/);

	for (const line of lines) {
		if (!line) {
			continue;
		}

		if (line.startsWith("## ")) {
			const branchLine = line.slice(3).trim();
			let branchToken = branchLine;
			let statusMetadata = "";
			const metadataStart = branchLine.lastIndexOf(" [");

			if (metadataStart > -1 && branchLine.endsWith("]")) {
				branchToken = branchLine.slice(0, metadataStart).trim();
				statusMetadata = branchLine.slice(metadataStart + 1, -1);
			}

			const aheadMatch = /ahead (\d+)/i.exec(statusMetadata);
			const behindMatch = /behind (\d+)/i.exec(statusMetadata);
			ahead = aheadMatch ? Number.parseInt(aheadMatch[1] as string, 10) : 0;
			behind = behindMatch ? Number.parseInt(behindMatch[1] as string, 10) : 0;

			if (branchToken.startsWith("HEAD")) {
				currentBranch = null;
				isDetachedHead = true;
			} else if (branchToken.startsWith("No commits yet on ")) {
				currentBranch = branchToken.replace(/^No commits yet on\s+/i, "").trim();
			} else if (branchToken.includes("...")) {
				currentBranch = branchToken.split("...")[0]?.trim() ?? null;
			} else {
				currentBranch = branchToken || null;
			}
			continue;
		}

		const leftStatus = line[0];
		const rightStatus = line[1];

		if (leftStatus === "?" && rightStatus === "?") {
			changedFiles++;
			untrackedFiles++;
			continue;
		}

		if (leftStatus !== " ") {
			stagedFiles++;
		}

		if (rightStatus !== " ") {
			unstagedFiles++;
		}

		if (leftStatus === "U" || rightStatus === "U") {
			conflictedFiles++;
		}

		if (leftStatus === "A" || rightStatus === "A") {
			added++;
		}

		if (leftStatus === "D" || rightStatus === "D") {
			removed++;
		}

		changedFiles++;
	}

	return {
		added,
		ahead,
		behind,
		changedFiles,
		conflictedFiles,
		isRepo: true,
		currentBranch,
		removed,
		isDetachedHead,
		stagedFiles,
		unstagedFiles,
		untrackedFiles,
	};
};

const parseShortStat = (raw: string): { added: number; removed: number } => {
	const normalized = raw.trim();
	if (!normalized) {
		return { added: 0, removed: 0 };
	}

	const addedMatch = /(\d+)\s+insertions?\(\+\)/i.exec(normalized);
	const removedMatch = /(\d+)\s+deletions?\(-\)/i.exec(normalized);

	return {
		added: addedMatch ? Number.parseInt(addedMatch[1] as string, 10) : 0,
		removed: removedMatch ? Number.parseInt(removedMatch[1] as string, 10) : 0,
	};
};

const parseCommitHash = (stdout: string): string | null => {
	const match = /\[[^\s]+\s+([0-9a-f]{7,40})\]/i.exec(stdout);

	return match?.[1] ?? null;
};

const parseNotRepositoryStatus = (): GitStatus => ({
	added: 0,
	ahead: 0,
	behind: 0,
	changedFiles: 0,
	conflictedFiles: 0,
	currentBranch: null,
	isDetachedHead: false,
	isRepo: false,
	removed: 0,
	stagedFiles: 0,
	unstagedFiles: 0,
	untrackedFiles: 0,
});

const buildBranches = (raw: string): GitBranch[] =>
	raw
		.split(/\r?\n/)
		.map((line) => line.trim())
		.filter((line) => line.length > 0)
		.map((line) => {
			return line.startsWith("* ") ? line.slice(2).trim() : line;
		});

const firstError = (message: string): GitError => ({
	type: "command_failed",
	action: "git",
	message,
});

const toNotRepositoryError = (): GitNotRepositoryError => ({ type: "not_git_repository" });

export class GitService implements GitServiceContract {
	constructor(
		private readonly projectService: GitProjectLookup,
		private readonly executeGit: GitExecutor = defaultRunGitCommand,
	) {}

	private static toGitErrorMessage(stdout: string, stderr: string): string {
		const combined = `${stdout}\n${stderr}`.trim();
		return combined || "git command failed";
	}

	private async resolveProject(projectId: string): Promise<ProjectDTO | GitProjectNotFoundError> {
		const project = await this.projectService.getProjectById(projectId);
		if (!project) {
			return { type: "project_not_found" };
		}

		return project;
	}

	private async isGitRepository(path: string): Promise<boolean> {
		const statusResult = await this.executeGit({ args: ["rev-parse", "--is-inside-work-tree"], cwd: path });

		if (statusResult.exitCode !== 0) {
			return false;
		}

		return statusResult.stdout.trim() === "true";
	}

	private async getCurrentBranch(path: string): Promise<string | null> {
		const result = await this.executeGit({ args: ["branch", "--show-current"], cwd: path });
		if (result.exitCode !== 0) {
			return null;
		}

		const branch = result.stdout.trim();
		return branch.length ? branch : null;
	}

	private async getCurrentCommitHash(path: string): Promise<string | null> {
		const result = await this.executeGit({ args: ["rev-parse", "HEAD"], cwd: path });
		if (result.exitCode !== 0) {
			return null;
		}

		const hash = result.stdout.trim();
		return hash.length ? hash : null;
	}

	private async hasUpstream(path: string): Promise<boolean> {
		const result = await this.executeGit({
			args: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
			cwd: path,
		});

		return result.exitCode === 0 && result.stdout.trim().length > 0;
	}

	private async getUncommittedLineStats(path: string): Promise<{ added: number; removed: number }> {
		const [unstagedResult, stagedResult] = await Promise.all([
			this.executeGit({ args: ["diff", "--shortstat"], cwd: path }),
			this.executeGit({ args: ["diff", "--cached", "--shortstat"], cwd: path }),
		]);

		const unstaged = unstagedResult.exitCode === 0 ? parseShortStat(unstagedResult.stdout) : { added: 0, removed: 0 };
		const staged = stagedResult.exitCode === 0 ? parseShortStat(stagedResult.stdout) : { added: 0, removed: 0 };

		return {
			added: unstaged.added + staged.added,
			removed: unstaged.removed + staged.removed,
		};
	}

	async getStatus(projectId: string): Promise<GitStatus | GitProjectNotFoundError | GitError> {
		const project = await this.resolveProject(projectId);
		if ("type" in project) {
			return project;
		}

		const result = await this.executeGit({
			args: ["status", "--branch", "--short", "--untracked-files=all"],
			cwd: project.path,
		});

		if (result.exitCode !== 0) {
			const combined = `${result.stdout}\n${result.stderr}`.trim();
			if (isNotGitRepositoryError(combined)) {
				return parseNotRepositoryStatus();
			}

			return firstError(`failed to get git status: ${GitService.toGitErrorMessage(result.stdout, result.stderr)}`);
		}

		const parsedStatus = parseStatus(result.stdout);
		const lineStats = await this.getUncommittedLineStats(project.path);

		return {
			...parsedStatus,
			added: lineStats.added,
			removed: lineStats.removed,
		};
	}

	async listBranches(projectId: string): Promise<GitBranchList | GitProjectNotFoundError | GitError> {
		const project = await this.resolveProject(projectId);
		if ("type" in project) {
			return project;
		}

		const isRepo = await this.isGitRepository(project.path);
		if (!isRepo) {
			return {
				currentBranch: null,
				branches: [],
			};
		}

		const currentBranch = await this.getCurrentBranch(project.path);
		const result = await this.executeGit({ args: ["branch"], cwd: project.path });
		if (result.exitCode !== 0) {
			return firstError(`failed to list branches: ${GitService.toGitErrorMessage(result.stdout, result.stderr)}`);
		}

		const branches = buildBranches(result.stdout);

		return {
			branches,
			currentBranch,
		};
	}

	async checkoutBranch(
		projectId: string,
		input: GitCheckoutRequest,
	): Promise<GitBranch | GitProjectNotFoundError | GitError> {
		const project = await this.resolveProject(projectId);
		if ("type" in project) {
			return project;
		}

		const branch = input.branch?.trim();
		if (!branch) {
			return {
				type: "validation_error",
				message: "branch is required",
			};
		}

		const isRepo = await this.isGitRepository(project.path);
		if (!isRepo) {
			return toNotRepositoryError();
		}

		const result = await this.executeGit({
			args: ["checkout", branch],
			cwd: project.path,
		});
		if (result.exitCode !== 0) {
			const combined = `${result.stdout}\n${result.stderr}`.trim();
			if (isNotGitRepositoryError(combined)) {
				return toNotRepositoryError();
			}

			return firstError(`failed to checkout branch: ${GitService.toGitErrorMessage(result.stdout, result.stderr)}`);
		}

		const currentBranch = await this.getCurrentBranch(project.path);
		return currentBranch ?? branch;
	}

	async createBranch(
		projectId: string,
		input: GitCreateBranchRequest,
	): Promise<GitBranch | GitProjectNotFoundError | GitError> {
		const project = await this.resolveProject(projectId);
		if ("type" in project) {
			return project;
		}

		const name = input.name?.trim();
		if (!name) {
			return {
				type: "validation_error",
				message: "branch name is required",
			};
		}

		const isRepo = await this.isGitRepository(project.path);
		if (!isRepo) {
			return toNotRepositoryError();
		}

		const createResult = await this.executeGit({ args: ["branch", name], cwd: project.path });
		if (createResult.exitCode !== 0) {
			return firstError(`failed to create branch: ${GitService.toGitErrorMessage(createResult.stdout, createResult.stderr)}`);
		}

		const checkoutResult = await this.executeGit({
			args: ["checkout", name],
			cwd: project.path,
		});
		if (checkoutResult.exitCode !== 0) {
			return firstError(
				`failed to checkout branch after creation: ${GitService.toGitErrorMessage(
					checkoutResult.stdout,
					checkoutResult.stderr,
				)}`,
			);
		}

		return name;
	}

	async commit(
		projectId: string,
		input: GitCommitRequest,
	): Promise<GitCommitResult | GitProjectNotFoundError | GitError> {
		const project = await this.resolveProject(projectId);
		if ("type" in project) {
			return project;
		}

		const message = input.message?.trim();
		if (!message) {
			return {
				type: "validation_error",
				message: "commit message is required",
			};
		}

		const includeUnstaged = input.includeUnstaged ?? false;
		const pushEnabled = input.push ?? DEFAULT_COMMIT_PUSH;

		const isRepo = await this.isGitRepository(project.path);
		if (!isRepo) {
			return toNotRepositoryError();
		}

		if (includeUnstaged) {
			const stageResult = await this.executeGit({
				args: ["add", "--all"],
				cwd: project.path,
			});
			if (stageResult.exitCode !== 0) {
				return firstError(`failed to stage commit changes: ${GitService.toGitErrorMessage(stageResult.stdout, stageResult.stderr)}`);
			}
		}

		const commitResult = await this.executeGit({ args: ["commit", "-m", message], cwd: project.path });
		if (commitResult.exitCode !== 0) {
			return firstError(`failed to create commit: ${GitService.toGitErrorMessage(commitResult.stdout, commitResult.stderr)}`);
		}

		const branch = await this.getCurrentBranch(project.path);
		let pushed = false;
		let pushedWithUpstream = false;

		if (pushEnabled) {
			if (!branch) {
				return {
					type: "validation_error",
					message: "cannot push commit while HEAD is detached",
				};
			}

			const upstreamAvailable = await this.hasUpstream(project.path);
			if (upstreamAvailable) {
				const pushResult = await this.executeGit({ args: ["push"], cwd: project.path });
				if (pushResult.exitCode !== 0) {
					return firstError(`failed to push commit: ${GitService.toGitErrorMessage(pushResult.stdout, pushResult.stderr)}`);
				}
			} else {
				const remoteResult = await this.executeGit({
					args: ["remote"],
					cwd: project.path,
				});
				if (remoteResult.exitCode !== 0) {
					return firstError(`failed to detect origin remote: ${GitService.toGitErrorMessage(remoteResult.stdout, remoteResult.stderr)}`);
				}

				const hasOrigin = remoteResult.stdout
					.split(/\r?\n/)
					.map((item) => item.trim())
					.includes("origin");
				if (!hasOrigin) {
					return {
						type: "validation_error",
						message: "origin remote is required for upstream push",
					};
				}

				const pushResult = await this.executeGit({
					args: ["push", "--set-upstream", "origin", branch],
					cwd: project.path,
				});
				if (pushResult.exitCode !== 0) {
					return firstError(`failed to push commit with upstream: ${GitService.toGitErrorMessage(pushResult.stdout, pushResult.stderr)}`);
				}
				pushedWithUpstream = true;
			}

			pushed = true;
		}

		return {
			branch,
			commitHash: parseCommitHash(commitResult.stdout) ?? (await this.getCurrentCommitHash(project.path)),
			commitMessage: message,
			pushed,
			pushedWithUpstream,
		};
	}
}

export const createGitService = (projectService: GitProjectLookup) => new GitService(projectService);
