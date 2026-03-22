import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";

import { afterEach, describe, expect, test } from "bun:test";

import { collectResolvedPath, resolveCommand } from "./command";

const cleanupPaths: string[] = [];

const trackPath = (target: string): string => {
	cleanupPaths.push(target);
	return target;
};

afterEach(() => {
	while (cleanupPaths.length > 0) {
		const target = cleanupPaths.pop();
		if (!target) {
			continue;
		}

		rmSync(target, { force: true, recursive: true });
	}
});

const createExecutable = (directory: string, name: string): string => {
	mkdirSync(directory, { recursive: true });
	const executablePath = join(directory, name);
	writeFileSync(executablePath, "#!/usr/bin/env sh\nexit 0\n", "utf8");
	chmodSync(executablePath, 0o755);
	return executablePath;
};

const createFakeShell = (): string => {
	const shellDir = trackPath(mkdtempSync(join(tmpdir(), "remotecode-fake-shell-")));
	const shellPath = join(shellDir, "fake-shell");
	writeFileSync(
		shellPath,
		[
			"#!/bin/sh",
			"interactive=0",
			"for arg in \"$@\"; do",
			"\tif [ \"$arg\" = \"-i\" ]; then",
			"\t\tinteractive=1",
			"\tfi",
			"done",
			"if [ \"$interactive\" = \"1\" ]; then",
			"\tprintf '__REMOTE_CODE_PATH_START__%s__REMOTE_CODE_PATH_END__' \"${RC_FAKE_INTERACTIVE_PATH:-}\"",
			"\texit 0",
			"fi",
			"printf '__REMOTE_CODE_PATH_START__%s__REMOTE_CODE_PATH_END__' \"${RC_FAKE_LOGIN_PATH:-}\"",
			"exit 0",
			"",
		].join("\n"),
		"utf8",
	);
	chmodSync(shellPath, 0o755);
	return shellPath;
};

describe("resolveCommand e2e", () => {
	test("finds Claude in an interactive-shell-only PATH", () => {
		const shellPath = createFakeShell();
		const interactiveBinDir = trackPath(mkdtempSync(join(tmpdir(), "remotecode-claude-interactive-")));
		const claudePath = createExecutable(interactiveBinDir, "claude");

		const resolved = resolveCommand("claude", {
			env: {
				HOME: trackPath(mkdtempSync(join(tmpdir(), "remotecode-home-"))),
				PATH: "",
				RC_FAKE_INTERACTIVE_PATH: interactiveBinDir,
				RC_FAKE_LOGIN_PATH: "",
				SHELL: shellPath,
			},
			includeSystemInstallDirectories: false,
			shell: shellPath,
		});

		expect(resolved).toBe(claudePath);
	});

	test("finds Codex in an nvm-managed Node installation even when PATH is empty", () => {
		const shellPath = createFakeShell();
		const homeDir = trackPath(mkdtempSync(join(tmpdir(), "remotecode-home-")));
		const codexBinDir = join(homeDir, ".nvm", "versions", "node", "v20.19.3", "bin");
		const codexPath = createExecutable(codexBinDir, "codex");

		const resolved = resolveCommand("codex", {
			env: {
				HOME: homeDir,
				PATH: "",
				RC_FAKE_INTERACTIVE_PATH: "",
				RC_FAKE_LOGIN_PATH: "",
				SHELL: shellPath,
			},
			includeSystemInstallDirectories: false,
			shell: shellPath,
		});

		expect(resolved).toBe(codexPath);
	});

	test("collectResolvedPath merges login shell, interactive shell, and common install directories", () => {
		const shellPath = createFakeShell();
		const homeDir = trackPath(mkdtempSync(join(tmpdir(), "remotecode-home-")));
		const loginBinDir = trackPath(mkdtempSync(join(tmpdir(), "remotecode-login-bin-")));
		const interactiveBinDir = trackPath(mkdtempSync(join(tmpdir(), "remotecode-interactive-bin-")));
		const commonBinDir = join(homeDir, ".volta", "bin");

		createExecutable(loginBinDir, "claude");
		createExecutable(interactiveBinDir, "codex");
		createExecutable(commonBinDir, "codex");

		const resolvedPath = collectResolvedPath({
			env: {
				HOME: homeDir,
				PATH: "",
				RC_FAKE_INTERACTIVE_PATH: interactiveBinDir,
				RC_FAKE_LOGIN_PATH: loginBinDir,
				SHELL: shellPath,
			},
			includeSystemInstallDirectories: false,
			shell: shellPath,
		});
		const entries = resolvedPath.split(delimiter);

		expect(entries).toContain(loginBinDir);
		expect(entries).toContain(interactiveBinDir);
		expect(entries).toContain(commonBinDir);
	});
});
