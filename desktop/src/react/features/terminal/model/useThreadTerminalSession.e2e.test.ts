import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { expect, test } from "bun:test";

import { createTestServer } from "../../../../bun/server/shared/core/test-server";
import { RemoteCodeApi } from "../../../shared/api/remotecode-http";
import { createThreadTerminalSessionController } from "./useThreadTerminalSession";

const waitForCondition = async (predicate: () => boolean, timeoutMs = 15_000): Promise<void> => {
	await new Promise<void>((resolve, reject) => {
		const startedAt = performance.now();
		const timer = setInterval(() => {
			if (predicate()) {
				clearInterval(timer);
				resolve();
				return;
			}

			if (performance.now() - startedAt >= timeoutMs) {
				clearInterval(timer);
				reject(new Error("timed out waiting for frontend terminal condition"));
			}
		}, 25);
	});
};

const countOccurrences = (value: string, token: string): number => {
	if (!token) {
		return 0;
	}

	return value.split(token).length - 1;
};

test("frontend terminal e2e (REST-only) runs command and replays without duplication", async () => {
	const workspaceRoot = mkdtempSync(join(tmpdir(), "remotecode-frontend-terminal-rest-e2e-"));
	const { baseUrl, cleanup } = await createTestServer();
	const token = `front-rest-${Date.now()}-${Math.random().toString(16).slice(2, 6)}`;
	const api = RemoteCodeApi.createClient({
		baseUrl,
		token: "local-dev-token",
	});

	try {
		const project = await api.createProject({
			name: "Frontend terminal rest e2e",
			path: workspaceRoot,
		});
		const chat = await api.createChat(project.id, "Terminal frontend rest e2e");

		const controller = createThreadTerminalSessionController(() => ({
			execCommand: async (chatId, input) => {
				return await api.execTerminalCommand(chatId, input);
			},
			getHistory: async (chatId, options) => {
				return await api.getTerminalHistory(chatId, options);
			},
			historyLimit: 1000,
		}));

		controller.setOpen(chat.id, true);
		await controller.syncHistory(chat.id);

		await controller.runCommand(chat.id, `printf '${token}\\n'`);

		await waitForCondition(() => {
			const chatState = controller.getState().chats[chat.id];
			if (!chatState) {
				return false;
			}

			const transcript = chatState.items.map((item) => item.text).join("\n");
			return transcript.includes(token);
		}, 10_000);

		const beforeReopenTranscript = controller
			.getState()
			.chats[chat.id]
			?.items.map((item) => item.text)
			.join("\n") ?? "";
		const beforeReopenCount = countOccurrences(beforeReopenTranscript, token);
		expect(beforeReopenCount).toBeGreaterThan(0);

		controller.setOpen(chat.id, false);
		controller.setOpen(chat.id, true);
		await controller.syncHistory(chat.id);

		const afterReopenTranscript = controller
			.getState()
			.chats[chat.id]
			?.items.map((item) => item.text)
			.join("\n") ?? "";
		const afterReopenCount = countOccurrences(afterReopenTranscript, token);
		expect(afterReopenCount).toBe(beforeReopenCount);

		await controller.runCommand(chat.id, `export REST_ONLY_TEST_TOKEN="${token}"`);
		await controller.runCommand(chat.id, "printf '__rest_terminal_token__%s__\\n' \"$REST_ONLY_TEST_TOKEN\"");

		const isolationTranscript = controller
			.getState()
			.chats[chat.id]
			?.items.map((item) => item.text)
			.join("\n") ?? "";
		expect(isolationTranscript).toContain("__rest_terminal_token____");
		expect(isolationTranscript).not.toContain(`__rest_terminal_token__${token}__`);
		expect(isolationTranscript).not.toContain("24;108t");
	} finally {
		await cleanup();
		rmSync(workspaceRoot, { force: true, recursive: true });
	}
}, 45_000);
