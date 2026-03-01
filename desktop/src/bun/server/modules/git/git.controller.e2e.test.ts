import { rmSync, writeFileSync } from "node:fs";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { createTestServer } from "../../shared/core/test-server";

const requestJson = async (input: {
	baseUrl: string;
	method: "GET" | "POST";
	path: string;
	body?: Record<string, unknown>;
}) => {
	const response = await fetch(`${input.baseUrl}${input.path}`, {
		body: input.body ? JSON.stringify(input.body) : undefined,
		headers: {
			authorization: "Bearer local-dev-token",
			...(input.body ? { "content-type": "application/json" } : {}),
		},
		method: input.method,
	});

	return {
		body: (await response.json()) as Record<string, unknown>,
		status: response.status,
	};
};

const decoder = new TextDecoder();
const runGit = (cwd: string, args: string[]) => {
	const process = Bun.spawnSync({
		cmd: ["git", ...args],
		cwd,
		stderr: "pipe",
		stdout: "pipe",
	});

	const stderr = process.stderr ? decoder.decode(process.stderr) : "";
	if (process.exitCode !== 0) {
		throw new Error(`git ${args.join(" ")} failed: ${stderr.trim()}`);
	}

	return process.stdout ? decoder.decode(process.stdout) : "";
};

const normalizeError = (value: unknown): string | null =>
	typeof value === "object" && value !== null && "error" in value && typeof value.error === "string"
		? value.error
		: null;

test("GET /v1/projects/:id/git/status returns clear state for non-repository", async () => {
	const { baseUrl, cleanup, client } = await createTestServer();
	const projectRoot = mkdtempSync(join(tmpdir(), "remotecode-git-e2e-nonrepo-"));

	try {
		const createResult = await client.v1.projects.post({
			path: projectRoot,
		});
		const projectId = (createResult.data as { project: { id: string } }).project.id;

		const response = await requestJson({
			baseUrl,
			method: "GET",
			path: `/v1/projects/${projectId}/git/status`,
		});

		expect(response.status).toBe(200);
		expect(normalizeError(response.body)).toBeNull();
		expect(response.body).toMatchObject({
			isRepo: false,
			currentBranch: null,
		});
	} finally {
		await cleanup();
		rmSync(projectRoot, { force: true, recursive: true });
	}
});

test("Branch endpoints list local branches, create, and checkout", async () => {
	const { baseUrl, cleanup, client } = await createTestServer();
	const projectPath = mkdtempSync(join(tmpdir(), "remotecode-git-e2e-branches-"));

	try {
		runGit(projectPath, ["init", "-b", "main"]);
		runGit(projectPath, ["config", "user.name", "Local Tester"]);
		runGit(projectPath, ["config", "user.email", "local@test.invalid"]);
		writeFileSync(join(projectPath, "README.md"), "initial");
		runGit(projectPath, ["add", "README.md"]);
		runGit(projectPath, ["commit", "-m", "Initial commit"]);

		const createResult = await client.v1.projects.post({ path: projectPath });
		const projectId = (createResult.data as { project: { id: string } }).project.id;

		const listBefore = await requestJson({
			baseUrl,
			method: "GET",
			path: `/v1/projects/${projectId}/git/branches`,
		});
		expect(listBefore.status).toBe(200);
		expect((listBefore.body as { branches: unknown[] }).branches).toContain("main");

		const createResponse = await requestJson({
			baseUrl,
			method: "POST",
			body: { name: "feature/workflow" },
			path: `/v1/projects/${projectId}/git/branches/create`,
		});
		expect(createResponse.status).toBe(200);
		expect((createResponse.body as { branch: unknown; created: boolean }).created).toBe(true);
		expect((createResponse.body as { branch: string }).branch).toBe("feature/workflow");

		const checkoutResponse = await requestJson({
			baseUrl,
			method: "POST",
			body: { branch: "main" },
			path: `/v1/projects/${projectId}/git/branches/checkout`,
		});
		expect(checkoutResponse.status).toBe(200);
		expect((checkoutResponse.body as { branch: string }).branch).toBe("main");
		expect((checkoutResponse.body as { switched: boolean }).switched).toBe(true);

		const listAfter = await requestJson({
			baseUrl,
			method: "GET",
			path: `/v1/projects/${projectId}/git/branches`,
		});
		expect(listAfter.status).toBe(200);
		expect((listAfter.body as { branches: string[] }).branches).toContain("feature/workflow");
	} finally {
		await cleanup();
		rmSync(projectPath, { force: true, recursive: true });
	}
});

test("Commit endpoint supports includeUnstaged and push with upstream", async () => {
	const { baseUrl, cleanup, client } = await createTestServer();
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-git-e2e-commit-"));
	const remoteRoot = mkdtempSync(join(tmpdir(), "remotecode-git-e2e-remote-push-"));
	const bareRemote = join(remoteRoot, "remote.git");

	try {
		runGit(workspaceRoot, ["init", "-b", "main"]);
		runGit(workspaceRoot, ["config", "user.name", "Local Tester"]);
		runGit(workspaceRoot, ["config", "user.email", "local@test.invalid"]);
		runGit(workspaceRoot, ["init", "--bare", bareRemote]);
		runGit(workspaceRoot, ["remote", "add", "origin", bareRemote]);
		writeFileSync(join(workspaceRoot, "CHANGELOG.md"), "v1");
		const createResult = await client.v1.projects.post({ path: workspaceRoot });
		const projectId = (createResult.data as { project: { id: string } }).project.id;

		const commitResponse = await requestJson({
			baseUrl,
			method: "POST",
			body: {
				includeUnstaged: true,
				message: "chore: update changelog",
				push: true,
			},
			path: `/v1/projects/${projectId}/git/commit`,
		});
		expect(commitResponse.status).toBe(200);

		const commitBody = commitResponse.body as {
			commit: {
				pushed: boolean;
				pushedWithUpstream: boolean;
			};
		};
		expect(commitBody.commit.pushed).toBe(true);
		expect(commitBody.commit.pushedWithUpstream).toBe(true);

		const remoteRefs = runGit(workspaceRoot, ["ls-remote", "--heads", "origin"]);
		expect(remoteRefs).toContain("refs/heads/main");
	} finally {
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
		rmSync(remoteRoot, { force: true, recursive: true });
	}
});

export {};
