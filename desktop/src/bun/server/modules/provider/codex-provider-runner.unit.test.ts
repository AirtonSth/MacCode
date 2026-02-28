import { expect, test } from "bun:test";

import { CodexProviderRunner, parseCodexJsonLine } from "./codex-provider-runner";

const toStream = (value: string): ReadableStream<Uint8Array> => {
	const encoder = new TextEncoder();
	return new ReadableStream<Uint8Array>({
		start(controller) {
			controller.enqueue(encoder.encode(value));
			controller.close();
		},
	});
};

test("parseCodexJsonLine captures thread id from thread.started", () => {
	const parsed = parseCodexJsonLine(
		JSON.stringify({
			thread_id: "thread-123",
			type: "thread.started",
		}),
	);

	expect(parsed).toEqual({
		threadId: "thread-123",
	});
});

test("parseCodexJsonLine emits friendly deltas for command start and completion", () => {
	const started = parseCodexJsonLine(
		JSON.stringify({
			item: {
				command: "/bin/zsh -lc ls",
				type: "command_execution",
			},
			type: "item.started",
		}),
	);
	const completed = parseCodexJsonLine(
		JSON.stringify({
			item: {
				aggregated_output: "file-1\nfile-2\n",
				exit_code: 0,
				type: "command_execution",
			},
			type: "item.completed",
		}),
	);

	expect(started?.delta).toContain("Running command:");
	expect(completed?.delta).toContain("Command output:");
	expect(completed?.delta).toContain("file-1 file-2");
});

test("parseCodexJsonLine extracts assistant final text from agent_message", () => {
	const parsed = parseCodexJsonLine(
		JSON.stringify({
			item: {
				text: "Final answer",
				type: "agent_message",
			},
			type: "item.completed",
		}),
	);

	expect(parsed).toEqual({
		assistantMessage: "Final answer",
		delta: "Final answer",
	});
});

test("parseCodexJsonLine maps reasoning completion into user-friendly status delta", () => {
	const parsed = parseCodexJsonLine(
		JSON.stringify({
			item: {
				text: "**Thinking**",
				type: "reasoning",
			},
			type: "item.completed",
		}),
	);

	expect(parsed).toEqual({
		delta: "Codex is thinking...\n",
	});
});

test("CodexProviderRunner returns failed when turn completes without final assistant message", async () => {
	const runner = new CodexProviderRunner(() => ({
		exitCode: 0,
		exited: Promise.resolve(0),
		stderr: toStream(""),
		stdout: toStream(
			[
				JSON.stringify({ thread_id: "thread-1", type: "thread.started" }),
				JSON.stringify({ type: "turn.started" }),
				JSON.stringify({ type: "turn.completed" }),
				"",
			].join("\n"),
		),
	}));

	const deltas: string[] = [];
	const result = await runner.run({
		chatId: "chat-1",
		onDelta: (delta) => {
			deltas.push(delta);
		},
		text: "hello",
		workspacePath: "/tmp",
	});

	expect(result.status).toBe("failed");
	expect(result.error).toBe("codex produced no final assistant message");
	expect(result.threadId).toBe("thread-1");
	expect(deltas).toEqual([]);
});

test("CodexProviderRunner uses resolved process exit code when subprocess fails", async () => {
	const runner = new CodexProviderRunner(() => ({
		exitCode: null,
		exited: Promise.resolve(7),
		stderr: toStream("simulated stderr failure"),
		stdout: toStream(""),
	}));

	const result = await runner.run({
		chatId: "chat-failure",
		onDelta: () => {
			// no-op
		},
		text: "hello",
		workspacePath: "/tmp",
	});

	expect(result.status).toBe("failed");
	expect(result.error).toContain("simulated stderr failure");
});
