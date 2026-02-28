import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { getCodexAvailability } from "./codex-test-gate";
import { CodexProviderRunner } from "./codex-provider-runner";

const codexAvailability = getCodexAvailability();
const codexTest = test.skipIf(!codexAvailability.available);
const skipReasonSuffix = codexAvailability.available ? "" : ` (skip: ${codexAvailability.reason})`;

codexTest(
	`CodexProviderRunner starts a new thread and returns assistant text${skipReasonSuffix}`,
	async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-codex-runner-start-"));
	const runner = new CodexProviderRunner();

	try {
		const result = await runner.run({
			chatId: "runner-start-chat",
			onDelta: () => {
				// no-op
			},
			text: "Respond with exactly: runner-start-ok",
			workspacePath: workspaceRoot,
		});

		expect(result.status).toBe("completed");
		expect(result.threadId).toEqual(expect.any(String));
		expect(result.assistantText.toLowerCase()).toContain("runner-start-ok");
	} finally {
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
	},
	120_000,
);

codexTest(
	`CodexProviderRunner resumes a thread and keeps conversation context${skipReasonSuffix}`,
	async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-codex-runner-resume-"));
	const runner = new CodexProviderRunner();
	const token = `resume-token-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;

	try {
		const firstTurn = await runner.run({
			chatId: "runner-resume-chat",
			onDelta: () => {
				// no-op
			},
			text: `Remember this token for this thread: ${token}. Reply exactly: STORED ${token}`,
			workspacePath: workspaceRoot,
		});

		expect(firstTurn.status).toBe("completed");
		expect(firstTurn.threadId).toEqual(expect.any(String));

		if (!firstTurn.threadId) {
			throw new Error("missing threadId on first codex turn");
		}

		const secondTurn = await runner.run({
			chatId: "runner-resume-chat",
			onDelta: () => {
				// no-op
			},
			text: "What token did I ask you to remember earlier? Reply with token only.",
			threadId: firstTurn.threadId,
			workspacePath: workspaceRoot,
		});

		expect(secondTurn.status).toBe("completed");
		expect(secondTurn.threadId).toBe(firstTurn.threadId);
		expect(secondTurn.assistantText).toContain(token);
	} finally {
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
	},
	120_000,
);

codexTest(
	`CodexProviderRunner enforces workspace path with --cd on first turn${skipReasonSuffix}`,
	async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-codex-workspace-"));
	const runner = new CodexProviderRunner();
	const token = `workspace-token-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;
	const tokenFile = join(workspaceRoot, "workspace-token.txt");

	writeFileSync(tokenFile, token, "utf8");

	try {
		const result = await runner.run({
			chatId: "runner-workspace-chat",
			onDelta: () => {
				// no-op
			},
			text: "Read ./workspace-token.txt and reply with the exact file content only.",
			workspacePath: workspaceRoot,
		});

		expect(result.status).toBe("completed");
		expect(result.assistantText).toContain(token);
	} finally {
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
	},
	120_000,
);
