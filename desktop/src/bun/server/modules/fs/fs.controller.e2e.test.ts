import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { serverConfig } from "../../config";
import { createTestServer } from "../../shared/core/test-server";

const createAuthorizedRequest = async (input: {
	baseUrl: string;
	path: string;
}): Promise<Response> =>
	await fetch(`${input.baseUrl}${input.path}`, {
		headers: {
			authorization: `Bearer ${serverConfig.token}`,
		},
	});

test("GET /v1/fs/roots returns browseable root entries", async () => {
	const { baseUrl, cleanup } = await createTestServer();

	try {
		const response = await createAuthorizedRequest({
			baseUrl,
			path: "/v1/fs/roots",
		});
		const payload = await response.json() as {
			roots: Array<{ id: string; label: string; path: string }>;
		};

		expect(response.status).toBe(200);
		expect(payload.roots.length).toBeGreaterThan(0);
		for (const root of payload.roots) {
			expect(root.id).toBeTruthy();
			expect(root.label).toBeTruthy();
			expect(root.path).toBeTruthy();
		}
	} finally {
		await cleanup();
	}
});

test("GET /v1/fs/list returns sorted directory entries with parent path", async () => {
	const { baseUrl, cleanup } = await createTestServer();
	const root = mkdtempSync(join(tmpdir(), "remotecode-fs-list-"));
	const directoryPath = join(root, "a-folder");
	const filePath = join(root, "z-file.txt");

	try {
		mkdirSync(directoryPath);
		writeFileSync(filePath, "hello");

		const response = await createAuthorizedRequest({
			baseUrl,
			path: `/v1/fs/list?path=${encodeURIComponent(root)}`,
		});
		const payload = await response.json() as {
			entries: Array<{ name: string; path: string; type: "directory" | "file" }>;
			parentPath: string | null;
			path: string;
		};

		expect(response.status).toBe(200);
		expect(payload.path).toBe(root);
		expect(payload.parentPath).toBeTruthy();
		expect(payload.entries).toEqual([
			{
				name: "a-folder",
				path: directoryPath,
				type: "directory",
			},
			{
				name: "z-file.txt",
				path: filePath,
				type: "file",
			},
		]);
	} finally {
		rmSync(root, { force: true, recursive: true });
		await cleanup();
	}
});

test("GET /v1/fs/list rejects invalid relative paths", async () => {
	const { baseUrl, cleanup } = await createTestServer();

	try {
		const response = await createAuthorizedRequest({
			baseUrl,
			path: `/v1/fs/list?path=${encodeURIComponent("relative/path")}`,
		});
		const payload = await response.json() as { error: string };

		expect(response.status).toBe(404);
		expect(payload.error).toBe("not_found");
	} finally {
		await cleanup();
	}
});

test("GET /v1/fs/list returns 404 for missing directories", async () => {
	const { baseUrl, cleanup } = await createTestServer();
	const missingPath = join(tmpdir(), "remotecode-fs-missing", String(Date.now()));

	try {
		const response = await createAuthorizedRequest({
			baseUrl,
			path: `/v1/fs/list?path=${encodeURIComponent(missingPath)}`,
		});
		const payload = await response.json() as { error: string };

		expect(response.status).toBe(404);
		expect(payload.error).toBe("not_found");
	} finally {
		await cleanup();
	}
});

test("GET /v1/fs/list returns 400 for file paths", async () => {
	const { baseUrl, cleanup } = await createTestServer();
	const root = mkdtempSync(join(tmpdir(), "remotecode-fs-file-"));
	const filePath = join(root, "file.txt");

	try {
		writeFileSync(filePath, "hello");

		const response = await createAuthorizedRequest({
			baseUrl,
			path: `/v1/fs/list?path=${encodeURIComponent(filePath)}`,
		});
		const payload = await response.json() as { error: string };

		expect(response.status).toBe(400);
		expect(payload.error).toBe("not_directory");
	} finally {
		rmSync(root, { force: true, recursive: true });
		await cleanup();
	}
});
