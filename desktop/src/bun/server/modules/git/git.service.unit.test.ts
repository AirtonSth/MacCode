import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import type { ProjectDTO } from "../../types";
import { GitService } from "./git.service";

const createProject = (id: string, path: string): ProjectDTO => ({
	createdAt: new Date().toISOString(),
	id,
	isFavorite: false,
	name: `project-${id}`,
	path,
	updatedAt: new Date().toISOString(),
});

type MockCommand = {
	args: string[];
	exitCode: number;
	stderr?: string;
	stdout?: string;
};

const createGitExecutor = (commands: MockCommand[]) => {
	let cursor = 0;
	return async (input: { args: string[] }) => {
		const command = commands[cursor];
		expect(command).toBeDefined();
		cursor += 1;

		expect(input.args).toEqual(command?.args);
		return {
			exitCode: command?.exitCode ?? 1,
			stderr: command?.stderr ?? "",
			stdout: command?.stdout ?? "",
		};
	};
};

const createProjectService = () => ({
	getProjectById: async (projectId: string) => {
		if (projectId === "project-id") {
			return createProject("project-id", "/tmp/remotecode");
		}

		return null;
	},
});

test("getStatus returns not-repo state when project is not a git repository", async () => {
	const service = new GitService(
		createProjectService(),
		createGitExecutor([
			{
				args: ["status", "--branch", "--short", "--untracked-files=all"],
				exitCode: 1,
				stderr: "fatal: not a git repository (or any of the parent directories): .git",
			},
		]),
	);

	try {
		const result = await service.getStatus("project-id");
		expect(result).toEqual({
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
	} finally {
		// no-op
	}
});

test("listBranches returns empty local branches when project is not a git repository", async () => {
	const service = new GitService(
		createProjectService(),
		createGitExecutor([
			{
				args: ["rev-parse", "--is-inside-work-tree"],
				exitCode: 1,
			},
		]),
	);

	const result = await service.listBranches("project-id");
	expect(result).toEqual({ currentBranch: null, branches: [] });
});

test("listBranches returns local branch list for repository", async () => {
	const service = new GitService(
		createProjectService(),
		createGitExecutor([
			{
				args: ["rev-parse", "--is-inside-work-tree"],
				exitCode: 0,
				stdout: "true",
			},
			{
				args: ["branch", "--show-current"],
				exitCode: 0,
				stdout: "main",
			},
			{
				args: ["branch"],
				exitCode: 0,
				stdout: "* main\n  feature/one\n",
			},
		]),
	);

	const result = await service.listBranches("project-id");
	expect(result).toEqual({
		currentBranch: "main",
		branches: ["main", "feature/one"],
	});
});

test("checkoutBranch validates branch input", async () => {
	const service = new GitService(createProjectService(), createGitExecutor([]));
	const result = await service.checkoutBranch("project-id", { branch: "  " });

	expect(result).toEqual({
		message: "branch is required",
		type: "validation_error",
	});
});

test("createBranch validates name input", async () => {
	const service = new GitService(createProjectService(), createGitExecutor([]));
	const result = await service.createBranch("project-id", { name: "   " });

	expect(result).toEqual({
		message: "branch name is required",
		type: "validation_error",
	});
});

test("commit validates message before running git commands", async () => {
	const service = new GitService(
		createProjectService(),
		createGitExecutor([
			{
				args: ["rev-parse", "--is-inside-work-tree"],
				exitCode: 0,
				stdout: "true",
			},
		]),
	);

	const blank = await service.commit("project-id", { message: "   " });
	expect(blank).toEqual({
		message: "commit message is required",
		type: "validation_error",
	});
});

test("commit creates and pushes with upstream when remote exists", async () => {
	const service = new GitService(
		createProjectService(),
		createGitExecutor([
			{
				args: ["rev-parse", "--is-inside-work-tree"],
				exitCode: 0,
				stdout: "true",
			},
			{
				args: ["add", "--all"],
				exitCode: 0,
			},
			{
				args: ["commit", "-m", "chore: commit all changes"],
				exitCode: 0,
				stdout: "[main abcdef12] chore: commit all changes",
			},
			{
				args: ["branch", "--show-current"],
				exitCode: 0,
				stdout: "main",
			},
			{
				args: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
				exitCode: 1,
				stderr: "",
			},
			{
				args: ["remote"],
				exitCode: 0,
				stdout: "origin\n",
			},
			{
				args: ["push", "--set-upstream", "origin", "main"],
				exitCode: 0,
			},
		]),
	);

	const result = await service.commit("project-id", {
		includeUnstaged: true,
		message: "chore: commit all changes",
		push: true,
	});

	expect(result).toEqual({
		branch: "main",
		commitHash: "abcdef12",
		commitMessage: "chore: commit all changes",
		pushed: true,
		pushedWithUpstream: true,
	});
});

test("service uses real temporary path operations when needed", async () => {
	const projectPath = mkdtempSync(join(tmpdir(), "remotecode-git-service-unit-"));

	const projectService = {
		getProjectById: async (projectId: string) =>
			projectId === "project-id" ? createProject("project-id", projectPath) : null,
	};

	const service = new GitService(
		projectService,
		createGitExecutor([
			{
				args: ["rev-parse", "--is-inside-work-tree"],
				exitCode: 0,
				stdout: "false",
			},
		]),
	);

	try {
		const result = await service.listBranches("project-id");
		expect(result).toEqual({ currentBranch: null, branches: [] });
	} finally {
		rmSync(projectPath, { force: true, recursive: true });
	}
});

export {};
