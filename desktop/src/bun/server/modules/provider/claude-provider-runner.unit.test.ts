import { describe, expect, test } from "bun:test";

import { parseClaudeJsonEvents, ClaudeProviderRunner, buildClaudeCommand } from "./claude-provider-runner";
import type { CodexProviderRunOptions } from "../../types";
import type { AssertionError } from "bun:test";

describe("parseClaudeJsonEvents", () => {
	test("parses system init event into thread_started and turn_started", () => {
		const events = parseClaudeJsonEvents(
			JSON.stringify({ type: "system", subtype: "init", session_id: "sess-123", tools: [] }),
		);

		expect(events).toHaveLength(2);
		expect(events[0]).toEqual({ type: "thread_started", threadId: "sess-123" });
		expect(events[1]).toEqual({ type: "turn_started" });
	});

	test("parses assistant text content into item_delta", () => {
		const events = parseClaudeJsonEvents(
			JSON.stringify({
				type: "assistant",
				message: {
					id: "msg-1",
					content: [{ type: "text", text: "Hello world" }],
				},
			}),
		);

		expect(events).toHaveLength(1);
		expect(events[0]).toMatchObject({
			type: "item_delta",
			itemType: "assistant_message",
			text: "Hello world",
		});
	});

	test("parses assistant thinking content into reasoning items", () => {
		const events = parseClaudeJsonEvents(
			JSON.stringify({
				type: "assistant",
				message: {
					id: "msg-1",
					content: [{ type: "thinking", thinking: "Let me think...", id: "think-1" }],
				},
			}),
		);

		expect(events).toHaveLength(3);
		expect(events[0]).toMatchObject({ type: "item_started", itemId: "think-1", itemType: "reasoning" });
		expect(events[1]).toMatchObject({ type: "item_delta", itemId: "think-1", itemType: "reasoning", text: "Let me think..." });
		expect(events[2]).toMatchObject({ type: "item_completed", itemId: "think-1", itemType: "reasoning" });
	});

	test("parses assistant tool_use into tool item_started", () => {
		const events = parseClaudeJsonEvents(
			JSON.stringify({
				type: "assistant",
				message: {
					id: "msg-1",
					content: [{ type: "tool_use", id: "tool-1", name: "Read", input: { file_path: "/tmp/test.ts" } }],
				},
			}),
		);

		expect(events).toHaveLength(1);
		expect(events[0]).toMatchObject({
			type: "item_started",
			itemId: "tool-1",
			itemType: "tool",
		});
		expect(events[0].command).toContain("Read");
	});

	test("parses tool result into item_completed", () => {
		const events = parseClaudeJsonEvents(
			JSON.stringify({
				type: "tool",
				tool_use_id: "tool-1",
				content: "file contents here",
			}),
		);

		expect(events).toHaveLength(1);
		expect(events[0]).toMatchObject({
			type: "item_completed",
			itemId: "tool-1",
			itemType: "tool",
			commandOutput: "file contents here",
			commandExitCode: 0,
		});
	});

	test("parses result success into turn_completed", () => {
		const events = parseClaudeJsonEvents(
			JSON.stringify({
				type: "result",
				subtype: "success",
				result: "Done!",
				cost_usd: 0.01,
				duration_ms: 1234,
			}),
		);

		expect(events.some((e) => e.type === "turn_completed")).toBe(true);
	});

	test("parses result error into error event", () => {
		const events = parseClaudeJsonEvents(
			JSON.stringify({
				type: "result",
				subtype: "error",
				is_error: true,
				result: "Something went wrong",
			}),
		);

		expect(events.some((e) => e.type === "error" && e.error === "Something went wrong")).toBe(true);
	});

	test("returns empty array for invalid JSON", () => {
		expect(parseClaudeJsonEvents("not valid json")).toEqual([]);
	});

	test("returns empty array for empty line", () => {
		expect(parseClaudeJsonEvents("")).toEqual([]);
		expect(parseClaudeJsonEvents("  ")).toEqual([]);
	});
});

describe("buildClaudeCommand", () => {
	const baseOptions: CodexProviderRunOptions = {
		chatId: "chat-1",
		onDelta: () => {},
		text: "Hello",
		workspacePath: "/tmp/project",
	};

	test("builds basic command with -p and stream-json", () => {
		const cmd = buildClaudeCommand(baseOptions);

		expect(cmd[0]).toBe("claude");
		expect(cmd).toContain("-p");
		expect(cmd).toContain("Hello");
		expect(cmd).toContain("--output-format");
		expect(cmd).toContain("stream-json");
		expect(cmd).toContain("--verbose");
	});

	test("includes --model flag when model is specified", () => {
		const cmd = buildClaudeCommand({ ...baseOptions, model: "opus" });

		const modelIdx = cmd.indexOf("--model");
		expect(modelIdx).toBeGreaterThan(-1);
		expect(cmd[modelIdx + 1]).toBe("opus");
	});

	test("includes --continue when threadId is specified", () => {
		const cmd = buildClaudeCommand({ ...baseOptions, threadId: "session-abc" });

		const continueIdx = cmd.indexOf("--continue");
		expect(continueIdx).toBeGreaterThan(-1);
		expect(cmd[continueIdx + 1]).toBe("session-abc");
	});

	test("includes --dangerouslySkipPermissions for full mode", () => {
		const cmd = buildClaudeCommand({ ...baseOptions, permissionMode: "full" });

		expect(cmd).toContain("--dangerouslySkipPermissions");
	});

	test("does not include --dangerouslySkipPermissions for plan mode", () => {
		const cmd = buildClaudeCommand({ ...baseOptions, permissionMode: "plan" });

		expect(cmd).not.toContain("--dangerouslySkipPermissions");
	});
});

describe("ClaudeProviderRunner", () => {
	test("returns cancelled result when signal is already aborted", async () => {
		const controller = new AbortController();
		controller.abort();

		const runner = new ClaudeProviderRunner(() => {
			throw new Error("aborted");
		});

		const result = await runner.run({
			chatId: "chat-1",
			onDelta: () => {},
			signal: controller.signal,
			text: "Hello",
			workspacePath: "/tmp",
		});

		expect(result.cancelled).toBe(true);
		expect(result.status).toBe("failed");
	});

	test("completes with streamed text deltas from a mock process", async () => {
		const deltas: string[] = [];
		const events: AssistantStreamEvent[] = [];

		const mockStdout = new ReadableStream<Uint8Array>({
			start(controller) {
				const lines = [
					JSON.stringify({ type: "system", subtype: "init", session_id: "sess-42" }),
					JSON.stringify({
						type: "assistant",
						message: { id: "msg-1", content: [{ type: "text", text: "Hello from Claude" }] },
					}),
					JSON.stringify({
						type: "result",
						subtype: "success",
						result: "Hello from Claude",
						cost_usd: 0.001,
						duration_ms: 100,
					}),
				];

				const encoded = new TextEncoder().encode(lines.join("\n") + "\n");
				controller.enqueue(encoded);
				controller.close();
			},
		});

		const runner = new ClaudeProviderRunner(() => ({
			exitCode: 0,
			exited: Promise.resolve(0),
			stderr: new ReadableStream({ start(c) { c.close(); } }),
			stdout: mockStdout,
		}));

		const result = await runner.run({
			chatId: "chat-1",
			onDelta: (delta) => { deltas.push(delta); },
			onEvent: (event) => { events.push(event); },
			text: "Hello",
			workspacePath: "/tmp",
		});

		expect(result.status).toBe("completed");
		expect(result.threadId).toBe("sess-42");
		expect(result.assistantText).toContain("Hello from Claude");
		expect(deltas.length).toBeGreaterThan(0);
		expect(events.some((e) => e.type === "turn_started")).toBe(true);
		expect(events.some((e) => e.type === "turn_completed")).toBe(true);
	});

	test("returns failed result when process exits with non-zero", async () => {
		const runner = new ClaudeProviderRunner(() => ({
			exitCode: 1,
			exited: Promise.resolve(1),
			stderr: new ReadableStream({
				start(c) {
					c.enqueue(new TextEncoder().encode("claude: command not found"));
					c.close();
				},
			}),
			stdout: new ReadableStream({ start(c) { c.close(); } }),
		}));

		const result = await runner.run({
			chatId: "chat-1",
			onDelta: () => {},
			text: "Hello",
			workspacePath: "/tmp",
		});

		expect(result.status).toBe("failed");
		expect(result.error).toContain("claude");
	});
});
