/* eslint-disable @typescript-eslint/prefer-readonly-parameter-types */
/* eslint-disable perfectionist/sort-modules */
/* eslint-disable perfectionist/sort-interfaces */

import type { GitCheckoutRequest, GitCommitRequest, GitCreateBranchRequest } from "./git.input.model";
import type { GitBranch, GitBranchList, GitCommitResult, GitStatus } from "./git.output.model";

export interface GitProjectNotFoundError {
		type: "project_not_found";
}

export interface GitNotRepositoryError {
	type: "not_git_repository";
}

export interface GitValidationError {
	type: "validation_error";
	message: string;
}

export interface GitCommandError {
	type: "command_failed";
	action: string;
	message: string;
}

export type GitError =
	| GitProjectNotFoundError
	| GitNotRepositoryError
	| GitValidationError
	| GitCommandError;

export interface GitServiceContract {
	getStatus: (projectId: string) => Promise<GitStatus | GitError>;
	listBranches: (projectId: string) => Promise<GitBranchList | GitError>;
	checkoutBranch: (projectId: string, input: GitCheckoutRequest) => Promise<string | GitError>;
	createBranch: (projectId: string, input: GitCreateBranchRequest) => Promise<string | GitError>;
	commit: (projectId: string, input: GitCommitRequest) => Promise<GitCommitResult | GitError>;
}

export type { GitCheckoutRequest, GitCommitRequest, GitCreateBranchRequest };
export type { GitBranch, GitBranchList, GitCommitResult, GitStatus };
