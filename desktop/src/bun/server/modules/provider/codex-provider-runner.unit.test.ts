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

test("parseCodexJsonLine emits thinking status on turn.started", () => {
	const parsed = parseCodexJsonLine(
		JSON.stringify({
			type: "turn.started",
		}),
	);

	expect(parsed).toEqual({
		delta: "Thinking...\n",
		statusDelta: true,
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

	expect(started?.delta).toContain("Tool calling:");
	expect(started?.statusDelta).toBe(true);
	expect(completed?.delta).toContain("Tool output:");
	expect(completed?.delta).toContain("file-1 file-2");
	expect(completed?.statusDelta).toBe(true);
});

test("parseCodexJsonLine extracts assistant final text from agent_message", () => {
	const parsed = parseCodexJsonLine(
		JSON.stringify({
			item: {
				id: "msg-1",
				text: "Final answer",
				type: "agent_message",
			},
			type: "item.completed",
		}),
	);

	expect(parsed).toEqual({
		agentMessageCompleted: true,
		agentMessageItemId: "msg-1",
		assistantMessage: "Final answer",
		delta: "Final answer",
	});
});

test("parseCodexJsonLine maps reasoning completion into concise thinking delta", () => {
	const parsed = parseCodexJsonLine(
		JSON.stringify({
			item: {
				text: "**Running shell command with update**",
				type: "reasoning",
			},
			type: "item.completed",
		}),
	);

	expect(parsed?.statusDelta).toBe(true);
	expect(parsed?.delta).toContain("Thinking:");
	expect(parsed?.delta).toContain("Running shell command with update");
});

test("parseCodexJsonLine extracts agent_message token deltas from item.delta", () => {
	const parsed = parseCodexJsonLine(
		JSON.stringify({
			item: {
				delta: "Hello",
				id: "msg-2",
				type: "agent_message",
			},
			type: "item.delta",
		}),
	);

	expect(parsed).toEqual({
		agentMessageDelta: true,
		agentMessageItemId: "msg-2",
		delta: "Hello",
	});
});

test("CodexProviderRunner suppresses duplicate status deltas and keeps final assistant message only", async () => {
	const runner = new CodexProviderRunner(() => ({
		exitCode: 0,
		exited: Promise.resolve(0),
		stderr: toStream(""),
		stdout: toStream(
			[
				JSON.stringify({ thread_id: "thread-1", type: "thread.started" }),
				JSON.stringify({ type: "turn.started" }),
				JSON.stringify({ item: { type: "reasoning" }, type: "item.started" }),
				JSON.stringify({ item: { type: "agent_message" }, type: "item.started" }),
				JSON.stringify({ item: { type: "agent_message" }, type: "item.started" }),
				JSON.stringify({ item: { id: "msg-1", text: "Interim answer", type: "agent_message" }, type: "item.completed" }),
				JSON.stringify({ item: { id: "msg-2", text: "Final answer", type: "agent_message" }, type: "item.completed" }),
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

	expect(result.status).toBe("completed");
	expect(result.assistantText).toBe("Final answer");
	expect(deltas).toEqual(["Thinking...\n", "Writing response...\n", "Interim answer", "Final answer"]);
});

test("CodexProviderRunner does not duplicate final agent message when item.delta already streamed", async () => {
	const runner = new CodexProviderRunner(() => ({
		exitCode: 0,
		exited: Promise.resolve(0),
		stderr: toStream(""),
		stdout: toStream(
			[
				JSON.stringify({ type: "turn.started" }),
				JSON.stringify({ item: { delta: "Hel", id: "msg-1", type: "agent_message" }, type: "item.delta" }),
				JSON.stringify({ item: { delta: "lo", id: "msg-1", type: "agent_message" }, type: "item.delta" }),
				JSON.stringify({ item: { id: "msg-1", text: "Hello", type: "agent_message" }, type: "item.completed" }),
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

	expect(result.status).toBe("completed");
	expect(result.assistantText).toBe("Hello");
	expect(deltas).toEqual(["Thinking...\n", "Hel", "lo"]);
});

test("CodexProviderRunner completes with delta-only agent_message stream", async () => {
	const runner = new CodexProviderRunner(() => ({
		exitCode: 0,
		exited: Promise.resolve(0),
		stderr: toStream(""),
		stdout: toStream(
			[
				JSON.stringify({ type: "turn.started" }),
				JSON.stringify({ item: { delta: "delta-only ", id: "msg-1", type: "agent_message" }, type: "item.delta" }),
				JSON.stringify({ item: { delta: "answer", id: "msg-1", type: "agent_message" }, type: "item.delta" }),
				JSON.stringify({ type: "turn.completed" }),
				"",
			].join("\n"),
		),
	}));

	const result = await runner.run({
		chatId: "chat-1",
		onDelta: () => {
			// no-op
		},
		text: "hello",
		workspacePath: "/tmp",
	});

	expect(result.status).toBe("completed");
	expect(result.assistantText).toBe("delta-only answer");
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
	expect(deltas).toEqual(["Thinking...\n"]);
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

test("CodexProviderRunner builds plan mode command for fresh exec", async () => {
	let capturedCommand: string[] = [];
	const runner = new CodexProviderRunner((input) => {
		capturedCommand = input.cmd;
		return {
			exitCode: 0,
			exited: Promise.resolve(0),
			stderr: toStream(""),
			stdout: toStream(
				[
					JSON.stringify({ item: { id: "msg-1", text: "ok", type: "agent_message" }, type: "item.completed" }),
					JSON.stringify({ type: "turn.completed" }),
					"",
				].join("\n"),
			),
		};
	});

	const result = await runner.run({
		chatId: "chat-plan",
		model: "gpt-5.3-codex",
		onDelta: () => {
			// no-op
		},
		permissionMode: "plan",
		reasoningEffort: "high",
		text: "hello",
		workspacePath: "/tmp/workspace",
	});

	expect(result.status).toBe("completed");
	expect(capturedCommand).toEqual([
		"codex",
		"--sandbox",
		"read-only",
		"--ask-for-approval",
		"never",
		"-m",
		"gpt-5.3-codex",
		"-c",
		'model_reasoning_effort="high"',
		"exec",
		"--json",
		"--skip-git-repo-check",
		"--cd",
		"/tmp/workspace",
		"hello",
	]);
});

test("CodexProviderRunner defaults to workspace-write mode when permission mode is omitted", async () => {
	let capturedCommand: string[] = [];
	const runner = new CodexProviderRunner((input) => {
		capturedCommand = input.cmd;
		return {
			exitCode: 0,
			exited: Promise.resolve(0),
			stderr: toStream(""),
			stdout: toStream(
				[
					JSON.stringify({ item: { id: "msg-1", text: "ok", type: "agent_message" }, type: "item.completed" }),
					JSON.stringify({ type: "turn.completed" }),
					"",
				].join("\n"),
			),
		};
	});

	const result = await runner.run({
		chatId: "chat-default",
		onDelta: () => {
			// no-op
		},
		text: "hello",
		workspacePath: "/tmp/workspace",
	});

	expect(result.status).toBe("completed");
	expect(capturedCommand).toEqual([
		"codex",
		"--sandbox",
		"workspace-write",
		"--ask-for-approval",
		"never",
		"exec",
		"--json",
		"--skip-git-repo-check",
		"--cd",
		"/tmp/workspace",
		"hello",
	]);
});

test("CodexProviderRunner builds full access command for resume flow", async () => {
	let capturedCommand: string[] = [];
	const runner = new CodexProviderRunner((input) => {
		capturedCommand = input.cmd;
		return {
			exitCode: 0,
			exited: Promise.resolve(0),
			stderr: toStream(""),
			stdout: toStream(
				[
					JSON.stringify({ item: { id: "msg-1", text: "ok", type: "agent_message" }, type: "item.completed" }),
					JSON.stringify({ type: "turn.completed" }),
					"",
				].join("\n"),
			),
		};
	});

	const result = await runner.run({
		chatId: "chat-full",
		model: "gpt-5.3-codex-spark",
		onDelta: () => {
			// no-op
		},
		permissionMode: "full",
		reasoningEffort: "xhigh",
		text: "hello",
		threadId: "thread-1",
		workspacePath: "/tmp/workspace",
	});

	expect(result.status).toBe("completed");
	expect(capturedCommand).toEqual([
		"codex",
		"--dangerously-bypass-approvals-and-sandbox",
		"-m",
		"gpt-5.3-codex-spark",
		"-c",
		'model_reasoning_effort="xhigh"',
		"exec",
		"resume",
		"--json",
		"--skip-git-repo-check",
		"thread-1",
		"hello",
	]);
});
