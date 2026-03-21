import { chmodSync, existsSync, readFileSync, renameSync } from "node:fs";

import { expect, test } from "bun:test";

import { terminalSessionBridgeTestHarness } from "./terminal-session.service";

test("terminal session bridge path falls back to extracted temp script when bundled neighbor file is missing", () => {
	const candidatePath = terminalSessionBridgeTestHarness.getCandidateBridgePath();
	if (!existsSync(candidatePath)) {
		throw new Error(`expected bridge candidate to exist at ${candidatePath}`);
	}

	const backupPath = `${candidatePath}.bak-test`;
	renameSync(candidatePath, backupPath);
	try {
		terminalSessionBridgeTestHarness.clearCachedBridgePath();
		const resolvedPath = terminalSessionBridgeTestHarness.resolvePythonBridgePath();

		expect(resolvedPath).not.toBe(candidatePath);
		expect(existsSync(resolvedPath)).toBe(true);
		expect(readFileSync(resolvedPath, "utf8")).toBe(terminalSessionBridgeTestHarness.getEmbeddedBridgeSource());
	} finally {
		terminalSessionBridgeTestHarness.clearCachedBridgePath();
		renameSync(backupPath, candidatePath);
		chmodSync(candidatePath, 0o755);
	}
});
