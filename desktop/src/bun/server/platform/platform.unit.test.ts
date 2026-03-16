import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import * as darwin from "./darwin";
import * as linux from "./linux";
import * as win32 from "./win32";
import { resolveCommandInPath } from "./command";

// ─── darwin ───────────────────────────────────────────────────

describe("platform/darwin", () => {
	test("resolveShell returns a non-empty string", () => {
		const shell = darwin.resolveShell();
		expect(shell.length).toBeGreaterThan(0);
	});

	test("buildShellArgs produces [shell, '-lc', command]", () => {
		const args = darwin.buildShellArgs("/bin/zsh", "echo hello");
		expect(args).toEqual(["/bin/zsh", "-lc", "echo hello"]);
	});

	test("killProcess calls subprocess.kill with SIGKILL for force", () => {
		const calls: (string | number | undefined)[] = [];
		const sub = { kill: (signal?: string | number) => { calls.push(signal); } };
		darwin.killProcess(sub, "force");
		expect(calls).toEqual(["SIGKILL"]);
	});

	test("killProcess calls subprocess.kill with SIGTERM for graceful", () => {
		const calls: (string | number | undefined)[] = [];
		const sub = { kill: (signal?: string | number) => { calls.push(signal); } };
		darwin.killProcess(sub, "graceful");
		expect(calls).toEqual(["SIGTERM"]);
	});

	test("commandExtensions returns empty array", () => {
		expect(darwin.commandExtensions()).toEqual([]);
	});
});

// ─── linux ────────────────────────────────────────────────────

describe("platform/linux", () => {
	test("resolveShell returns a non-empty string", () => {
		const shell = linux.resolveShell();
		expect(shell.length).toBeGreaterThan(0);
	});

	test("buildShellArgs produces [shell, '-lc', command]", () => {
		const args = linux.buildShellArgs("/bin/bash", "ls -la");
		expect(args).toEqual(["/bin/bash", "-lc", "ls -la"]);
	});

	test("killProcess calls subprocess.kill with SIGKILL for force", () => {
		const calls: (string | number | undefined)[] = [];
		const sub = { kill: (signal?: string | number) => { calls.push(signal); } };
		linux.killProcess(sub, "force");
		expect(calls).toEqual(["SIGKILL"]);
	});

	test("killProcess calls subprocess.kill with SIGTERM for graceful", () => {
		const calls: (string | number | undefined)[] = [];
		const sub = { kill: (signal?: string | number) => { calls.push(signal); } };
		linux.killProcess(sub, "graceful");
		expect(calls).toEqual(["SIGTERM"]);
	});

	test("commandExtensions returns empty array", () => {
		expect(linux.commandExtensions()).toEqual([]);
	});
});

// ─── win32 ────────────────────────────────────────────────────

describe("platform/win32", () => {
	test("resolveShell returns COMSPEC or cmd.exe", () => {
		const shell = win32.resolveShell();
		expect(shell.length).toBeGreaterThan(0);
		// Either returns $COMSPEC or cmd.exe
		if (process.env.COMSPEC) {
			expect(shell).toBe(process.env.COMSPEC.trim());
		} else {
			expect(shell).toBe("cmd.exe");
		}
	});

	test("buildShellArgs produces [cmd, '/c', command] for cmd.exe", () => {
		const args = win32.buildShellArgs("cmd.exe", "dir");
		expect(args).toEqual(["cmd.exe", "/c", "dir"]);
	});

	test("buildShellArgs produces [cmd, '/c', command] for C:\\Windows\\system32\\cmd.exe", () => {
		const args = win32.buildShellArgs("C:\\Windows\\system32\\cmd.exe", "dir");
		expect(args).toEqual(["C:\\Windows\\system32\\cmd.exe", "/c", "dir"]);
	});

	test("buildShellArgs uses -NoProfile -Command for powershell", () => {
		const args = win32.buildShellArgs("powershell.exe", "Get-Process");
		expect(args).toEqual(["powershell.exe", "-NoProfile", "-Command", "Get-Process"]);
	});

	test("buildShellArgs uses -NoProfile -Command for pwsh", () => {
		const args = win32.buildShellArgs("C:\\Program Files\\PowerShell\\7\\pwsh.exe", "ls");
		expect(args).toEqual(["C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NoProfile", "-Command", "ls"]);
	});

	test("killProcess calls subprocess.kill without arguments (TerminateProcess)", () => {
		const calls: (string | number | undefined)[] = [];
		const sub = { kill: (signal?: string | number) => { calls.push(signal); } };
		win32.killProcess(sub, "force");
		expect(calls).toEqual([undefined]);
	});

	test("killProcess graceful also calls kill without arguments on Windows", () => {
		const calls: (string | number | undefined)[] = [];
		const sub = { kill: (signal?: string | number) => { calls.push(signal); } };
		win32.killProcess(sub, "graceful");
		expect(calls).toEqual([undefined]);
	});

	test("commandExtensions returns Windows extensions", () => {
		const exts = win32.commandExtensions();
		expect(exts).toContain(".exe");
		expect(exts).toContain(".cmd");
		expect(exts).toContain(".bat");
		expect(exts).toContain(".com");
	});
});

// ─── resolveCommandInPath ─────────────────────────────────────

describe("resolveCommandInPath", () => {
	test("returns bare command name when not found in PATH", () => {
		const result = resolveCommandInPath("nonexistent-tool-xyz", "/tmp/does-not-exist");
		expect(result).toBe("nonexistent-tool-xyz");
	});

	test("finds executable in PATH", () => {
		const dir = mkdtempSync(join(tmpdir(), "cmd-resolve-"));
		const binary = join(dir, "mytool");
		writeFileSync(binary, "#!/bin/sh\nexit 0\n");
		chmodSync(binary, 0o755);

		try {
			const result = resolveCommandInPath("mytool", dir);
			expect(result).toBe(binary);
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	});

	test("prefers non-node_modules directory over node_modules/.bin", () => {
		const goodDir = mkdtempSync(join(tmpdir(), "cmd-good-"));
		const shadowBase = mkdtempSync(join(tmpdir(), "cmd-shadow-"));
		const shadowDir = join(shadowBase, "node_modules", ".bin");
		mkdirSync(shadowDir, { recursive: true });

		const goodBinary = join(goodDir, "codex");
		const shadowBinary = join(shadowDir, "codex");
		writeFileSync(goodBinary, "#!/bin/sh\nexit 0\n");
		writeFileSync(shadowBinary, "#!/bin/sh\nexit 0\n");
		chmodSync(goodBinary, 0o755);
		chmodSync(shadowBinary, 0o755);

		const delimiter = process.platform === "win32" ? ";" : ":";

		try {
			const result = resolveCommandInPath("codex", `${shadowDir}${delimiter}${goodDir}`);
			expect(result).toBe(goodBinary);
		} finally {
			rmSync(goodDir, { recursive: true, force: true });
			rmSync(shadowBase, { recursive: true, force: true });
		}
	});

	test("falls back to node_modules/.bin when no other candidate exists", () => {
		const shadowBase = mkdtempSync(join(tmpdir(), "cmd-shadow-only-"));
		const shadowDir = join(shadowBase, "node_modules", ".bin");
		mkdirSync(shadowDir, { recursive: true });

		const shadowBinary = join(shadowDir, "codex");
		writeFileSync(shadowBinary, "#!/bin/sh\nexit 0\n");
		chmodSync(shadowBinary, 0o755);

		try {
			const result = resolveCommandInPath("codex", shadowDir);
			expect(result).toBe(shadowBinary);
		} finally {
			rmSync(shadowBase, { recursive: true, force: true });
		}
	});

	test("uses process.env.PATH when no path argument is given", () => {
		const result = resolveCommandInPath("git");
		// git should be found on most systems
		expect(result.length).toBeGreaterThan(0);
		expect(result).not.toBe("git"); // Should resolve to full path if git is installed
	});
});
