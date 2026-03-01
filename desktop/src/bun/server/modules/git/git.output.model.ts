export interface GitStatus {
	isRepo: boolean;
	currentBranch: string | null;
	ahead: number;
	behind: number;
	stagedFiles: number;
	unstagedFiles: number;
	untrackedFiles: number;
	conflictedFiles: number;
	changedFiles: number;
	added: number;
	removed: number;
	isDetachedHead: boolean;
}

export type GitBranch = string;

export interface GitBranchList {
	currentBranch: string | null;
	branches: GitBranch[];
}

export interface GitCommitResult {
	branch: string | null;
	commitHash: string | null;
	commitMessage: string;
	pushed: boolean;
	pushedWithUpstream: boolean;
}
