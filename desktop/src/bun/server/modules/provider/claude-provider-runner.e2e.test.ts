import { describe, expect, test } from "bun:test";

import { ClaudeProviderRunner, parseClaudeJsonEvents } from "./claude-provider-runner";
import type { AssistantStreamEvent } from "../../../../shared/assistant-stream-event";

const createMockProcess = (lines: string[]) => {
	const mockStdout = new ReadableStream<Uint8Array>({
		start(controller) {
			const encoded = new TextEncoder().encode(lines.join("\n") + "\n");
			controller.enqueue(encoded);
			controller.close();
		},
	});

	return () => ({
		exitCode: 0,
		exited: Promise.resolve(0),
		stderr: new ReadableStream<Uint8Array>({ start(c) { c.close(); } }),
		stdout: mockStdout,
	});
};

const runWithMockProcess = async (lines: string[]) => {
	const deltas: string[] = [];
	const events: AssistantStreamEvent[] = [];

	const runner = new ClaudeProviderRunner(createMockProcess(lines));

	const result = await runner.run({
		chatId: "chat-1",
		onDelta: (delta) => { deltas.push(delta); },
		onEvent: (event) => { events.push(event); },
		text: "test",
		workspacePath: "/tmp",
	});

	return { result, deltas, events };
};

describe("parseClaudeJsonEvents – result event", () => {
	test("result event produces item_completed for assistant_message, not item_delta", () => {
		const events = parseClaudeJsonEvents(
			JSON.stringify({
				type: "result",
				subtype: "success",
				result: "Hello!",
				cost_usd: 0.01,
				duration_ms: 100,
			}),
		);

		const assistantEvents = events.filter((e) => e.itemType === "assistant_message");
		expect(assistantEvents).toHaveLength(1);
		expect(assistantEvents[0].type).toBe("item_completed");
		expect(assistantEvents[0].text).toBe("Hello!");

		expect(events.some((e) => e.type === "turn_completed")).toBe(true);
	});

	test("result event does not produce item_delta for assistant_message", () => {
		const events = parseClaudeJsonEvents(
			JSON.stringify({
				type: "result",
				subtype: "success",
				result: "Hello!",
			}),
		);

		const deltas = events.filter((e) => e.type === "item_delta");
		expect(deltas).toHaveLength(0);
	});
});

describe("Claude provider e2e – simple text response", () => {
	test("text is not duplicated between assistant and result events", async () => {
		const { result } = await runWithMockProcess([
			JSON.stringify({ type: "system", subtype: "init", session_id: "sess-1" }),
			JSON.stringify({
				type: "assistant",
				message: { id: "msg-1", content: [{ type: "text", text: "Olá!" }] },
			}),
			JSON.stringify({
				type: "result",
				subtype: "success",
				result: "Olá!",
				cost_usd: 0.001,
				duration_ms: 50,
			}),
		]);

		expect(result.status).toBe("completed");
		expect(result.assistantText).toBe("Olá!");
	});

	test("assistant_message item receives item_completed event", async () => {
		const { events } = await runWithMockProcess([
			JSON.stringify({ type: "system", subtype: "init", session_id: "sess-1" }),
			JSON.stringify({
				type: "assistant",
				message: { id: "msg-1", content: [{ type: "text", text: "Hello" }] },
			}),
			JSON.stringify({
				type: "result",
				subtype: "success",
				result: "Hello",
			}),
		]);

		const itemCompletedEvents = events.filter(
			(e) => e.type === "item_completed" && "itemId" in e,
		);
		const assistantCompleted = itemCompletedEvents.find(
			(e) => "itemId" in e && e.itemId?.startsWith("assistant_message"),
		);

		expect(assistantCompleted).toBeDefined();
		expect(assistantCompleted).toMatchObject({
			type: "item_completed",
			state: "completed",
			summary: "Response completed",
		});
	});

	test("assistant_message delta is emitted exactly once (from assistant event, not result)", async () => {
		const { events } = await runWithMockProcess([
			JSON.stringify({ type: "system", subtype: "init", session_id: "sess-1" }),
			JSON.stringify({
				type: "assistant",
				message: { id: "msg-1", content: [{ type: "text", text: "Hello" }] },
			}),
			JSON.stringify({
				type: "result",
				subtype: "success",
				result: "Hello",
			}),
		]);

		const bodyDeltas = events.filter(
			(e) => e.type === "item_delta" && "target" in e && e.target === "body",
		);

		expect(bodyDeltas).toHaveLength(1);
		expect("delta" in bodyDeltas[0] && bodyDeltas[0].delta).toBe("Hello");
	});

	test("legacy onDelta receives text exactly once", async () => {
		const { deltas } = await runWithMockProcess([
			JSON.stringify({ type: "system", subtype: "init", session_id: "sess-1" }),
			JSON.stringify({
				type: "assistant",
				message: { id: "msg-1", content: [{ type: "text", text: "Hello" }] },
			}),
			JSON.stringify({
				type: "result",
				subtype: "success",
				result: "Hello",
			}),
		]);

		const textDeltas = deltas.filter((d) => d === "Hello");
		expect(textDeltas).toHaveLength(1);
	});
});

describe("Claude provider e2e – partial stream_event output", () => {
	test("uses partial text deltas without duplicating the later assistant snapshot", async () => {
		const { result, events, deltas } = await runWithMockProcess([
			JSON.stringify({ type: "system", subtype: "init", session_id: "sess-1" }),
			JSON.stringify({
				type: "stream_event",
				event: {
					type: "message_start",
					message: { id: "msg-1" },
				},
			}),
			JSON.stringify({
				type: "stream_event",
				event: {
					type: "content_block_start",
					index: 0,
					content_block: { type: "thinking", thinking: "" },
				},
			}),
			JSON.stringify({
				type: "stream_event",
				event: {
					type: "content_block_delta",
					index: 0,
					delta: { type: "thinking_delta", thinking: "Working through the response" },
				},
			}),
			JSON.stringify({
				type: "stream_event",
				event: {
					type: "content_block_stop",
					index: 0,
				},
			}),
			JSON.stringify({
				type: "stream_event",
				event: {
					type: "content_block_start",
					index: 1,
					content_block: { type: "text", text: "" },
				},
			}),
			JSON.stringify({
				type: "stream_event",
				event: {
					type: "content_block_delta",
					index: 1,
					delta: { type: "text_delta", text: "Hello" },
				},
			}),
			JSON.stringify({
				type: "stream_event",
				event: {
					type: "content_block_delta",
					index: 1,
					delta: { type: "text_delta", text: " world" },
				},
			}),
			JSON.stringify({
				type: "assistant",
				message: {
					id: "msg-1",
					content: [{ type: "text", text: "Hello world" }],
				},
			}),
			JSON.stringify({
				type: "result",
				subtype: "success",
				result: "Hello world",
			}),
		]);

		expect(result.status).toBe("completed");
		expect(result.assistantText).toBe("Hello world");

		const bodyDeltas = events.filter(
			(event) => event.type === "item_delta" && "target" in event && event.target === "body",
		);
		expect(bodyDeltas).toHaveLength(2);
		expect(bodyDeltas).toEqual([
			expect.objectContaining({ delta: "Hello" }),
			expect.objectContaining({ delta: " world" }),
		]);

		expect(deltas.filter((delta) => delta === "Hello" || delta === " world")).toHaveLength(2);
		expect(events.some((event) => event.type === "turn_completed")).toBe(true);
	});
});

describe("Claude provider e2e – thinking + text response", () => {
	test("thinking and text are both processed without duplication", async () => {
		const { result, events } = await runWithMockProcess([
			JSON.stringify({ type: "system", subtype: "init", session_id: "sess-1" }),
			JSON.stringify({
				type: "assistant",
				message: {
					id: "msg-1",
					content: [
						{ type: "thinking", thinking: "The user said hello in Portuguese", id: "think-1" },
						{ type: "text", text: "Olá! Como posso ajudar?" },
					],
				},
			}),
			JSON.stringify({
				type: "result",
				subtype: "success",
				result: "Olá! Como posso ajudar?",
			}),
		]);

		expect(result.status).toBe("completed");
		expect(result.assistantText).toBe("Olá! Como posso ajudar?");

		// Verify thinking item lifecycle
		const thinkingStarted = events.find(
			(e) => e.type === "item_started" && "itemType" in e && e.itemType === "reasoning",
		);
		expect(thinkingStarted).toBeDefined();

		const thinkingDelta = events.find(
			(e) => e.type === "item_delta" && "target" in e && e.target === "summary" && "itemId" in e && e.itemId === "think-1",
		);
		expect(thinkingDelta).toBeDefined();

		const thinkingCompleted = events.find(
			(e) => e.type === "item_completed" && "itemId" in e && e.itemId === "think-1",
		);
		expect(thinkingCompleted).toBeDefined();

		// Verify assistant message lifecycle
		const assistantStarted = events.find(
			(e) => e.type === "item_started" && "itemType" in e && e.itemType === "assistant_message",
		);
		expect(assistantStarted).toBeDefined();

		const bodyDeltas = events.filter(
			(e) => e.type === "item_delta" && "target" in e && e.target === "body",
		);
		expect(bodyDeltas).toHaveLength(1);

		const assistantCompleted = events.filter(
			(e) => e.type === "item_completed" && "itemId" in e && (e as { itemId: string }).itemId?.startsWith("assistant_message"),
		);
		expect(assistantCompleted).toHaveLength(1);
	});

	test("event order matches expected lifecycle", async () => {
		const { events } = await runWithMockProcess([
			JSON.stringify({ type: "system", subtype: "init", session_id: "sess-1" }),
			JSON.stringify({
				type: "assistant",
				message: {
					id: "msg-1",
					content: [
						{ type: "thinking", thinking: "Let me think", id: "think-1" },
						{ type: "text", text: "Here is my response" },
					],
				},
			}),
			JSON.stringify({
				type: "result",
				subtype: "success",
				result: "Here is my response",
			}),
		]);

		const eventTypes = events.map((e) => e.type);

		expect(eventTypes).toEqual([
			"turn_started",
			// Thinking lifecycle
			"item_started",   // reasoning think-1
			"item_delta",     // reasoning summary
			"item_state",     // reasoning completed
			"item_completed", // reasoning completed
			// Assistant message lifecycle
			"item_started",   // assistant_message auto-started
			"item_delta",     // assistant_message body
			// Result triggers assistant_message completion
			"item_state",     // assistant_message completed
			"item_completed", // assistant_message completed
			// Turn ends
			"turn_completed",
		]);
	});
});

describe("Claude provider e2e – tool use flow", () => {
	test("tool use with result is processed correctly", async () => {
		const { result, events } = await runWithMockProcess([
			JSON.stringify({ type: "system", subtype: "init", session_id: "sess-1" }),
			JSON.stringify({
				type: "assistant",
				message: {
					id: "msg-1",
					content: [
						{ type: "thinking", thinking: "I need to read a file", id: "think-1" },
						{ type: "tool_use", id: "tool-1", name: "Read", input: { file_path: "/tmp/test.ts" } },
					],
				},
			}),
			JSON.stringify({
				type: "tool",
				tool_use_id: "tool-1",
				content: "const x = 1;",
			}),
			JSON.stringify({
				type: "assistant",
				message: {
					id: "msg-2",
					content: [
						{ type: "text", text: "The file contains a variable declaration." },
					],
				},
			}),
			JSON.stringify({
				type: "result",
				subtype: "success",
				result: "The file contains a variable declaration.",
			}),
		]);

		expect(result.status).toBe("completed");
		expect(result.assistantText).toBe("The file contains a variable declaration.");

		// Tool events
		const toolStarted = events.find(
			(e) => e.type === "item_started" && "itemType" in e && e.itemType === "tool",
		);
		expect(toolStarted).toBeDefined();

		const toolCompleted = events.find(
			(e) => e.type === "item_completed" && "itemId" in e && e.itemId === "tool-1",
		);
		expect(toolCompleted).toBeDefined();

		// Verify text is not duplicated
		const bodyDeltas = events.filter(
			(e) => e.type === "item_delta" && "target" in e && e.target === "body",
		);
		expect(bodyDeltas).toHaveLength(1);
	});
});

describe("Claude provider e2e – text-only result (no assistant event)", () => {
	test("handles case where text comes only from result event", async () => {
		const { result, events } = await runWithMockProcess([
			JSON.stringify({ type: "system", subtype: "init", session_id: "sess-1" }),
			JSON.stringify({
				type: "result",
				subtype: "success",
				result: "Quick response",
			}),
		]);

		expect(result.status).toBe("completed");
		expect(result.assistantText).toBe("Quick response");

		// Should still have proper event lifecycle
		const bodyDeltas = events.filter(
			(e) => e.type === "item_delta" && "target" in e && e.target === "body",
		);
		expect(bodyDeltas).toHaveLength(1);
		expect("delta" in bodyDeltas[0] && bodyDeltas[0].delta).toBe("Quick response");

		const assistantCompleted = events.find(
			(e) => e.type === "item_completed" && "itemId" in e && (e as { itemId: string }).itemId?.startsWith("assistant_message"),
		);
		expect(assistantCompleted).toBeDefined();
	});
});

describe("Claude provider e2e – error handling", () => {
	test("error result returns failed status", async () => {
		const { result } = await runWithMockProcess([
			JSON.stringify({ type: "system", subtype: "init", session_id: "sess-1" }),
			JSON.stringify({
				type: "result",
				subtype: "error",
				is_error: true,
				result: "Rate limit exceeded",
			}),
		]);

		expect(result.status).toBe("failed");
		expect(result.error).toContain("Rate limit exceeded");
	});

	test("non-zero exit code returns failed status with stderr", async () => {
		const deltas: string[] = [];
		const events: AssistantStreamEvent[] = [];

		const runner = new ClaudeProviderRunner(() => ({
			exitCode: 1,
			exited: Promise.resolve(1),
			stderr: new ReadableStream<Uint8Array>({
				start(c) {
					c.enqueue(new TextEncoder().encode("claude: authentication failed"));
					c.close();
				},
			}),
			stdout: new ReadableStream<Uint8Array>({ start(c) { c.close(); } }),
		}));

		const result = await runner.run({
			chatId: "chat-1",
			onDelta: (d) => deltas.push(d),
			onEvent: (e) => events.push(e),
			text: "test",
			workspacePath: "/tmp",
		});

		expect(result.status).toBe("failed");
		expect(result.error).toContain("authentication failed");
	});
});

describe("Claude provider e2e – full event stream matches codex format", () => {
	test("emits the same event types as codex provider for a simple response", async () => {
		const { events } = await runWithMockProcess([
			JSON.stringify({ type: "system", subtype: "init", session_id: "sess-1" }),
			JSON.stringify({
				type: "assistant",
				message: { id: "msg-1", content: [{ type: "text", text: "Hello" }] },
			}),
			JSON.stringify({
				type: "result",
				subtype: "success",
				result: "Hello",
			}),
		]);

		// Must have turn_started
		expect(events[0].type).toBe("turn_started");

		// Must have item_started for assistant_message
		const itemStarted = events.find(
			(e) => e.type === "item_started" && "itemType" in e && e.itemType === "assistant_message",
		);
		expect(itemStarted).toBeDefined();
		expect(itemStarted && "state" in itemStarted && itemStarted.state).toBe("running");

		// Must have item_delta with body target
		const itemDelta = events.find(
			(e) => e.type === "item_delta" && "target" in e && e.target === "body",
		);
		expect(itemDelta).toBeDefined();

		// Must have item_state with completed
		const itemState = events.find(
			(e) => e.type === "item_state" && "state" in e && e.state === "completed",
		);
		expect(itemState).toBeDefined();

		// Must have item_completed for assistant_message
		const itemCompleted = events.find(
			(e) => e.type === "item_completed" && "summary" in e && e.summary === "Response completed",
		);
		expect(itemCompleted).toBeDefined();

		// Must have turn_completed
		expect(events[events.length - 1].type).toBe("turn_completed");
	});

	test("threadId is properly extracted and returned", async () => {
		const { result } = await runWithMockProcess([
			JSON.stringify({ type: "system", subtype: "init", session_id: "my-session-id" }),
			JSON.stringify({
				type: "assistant",
				message: { id: "msg-1", content: [{ type: "text", text: "ok" }] },
			}),
			JSON.stringify({
				type: "result",
				subtype: "success",
				result: "ok",
			}),
		]);

		expect(result.threadId).toBe("my-session-id");
	});
});

describe("Claude provider e2e – streaming with incremental chunks", () => {
	test("handles stdout arriving in multiple chunks", async () => {
		const deltas: string[] = [];
		const events: AssistantStreamEvent[] = [];

		const line1 = JSON.stringify({ type: "system", subtype: "init", session_id: "sess-1" });
		const line2 = JSON.stringify({
			type: "assistant",
			message: { id: "msg-1", content: [{ type: "text", text: "Hello world" }] },
		});
		const line3 = JSON.stringify({ type: "result", subtype: "success", result: "Hello world" });

		const encoder = new TextEncoder();
		const mockStdout = new ReadableStream<Uint8Array>({
			start(controller) {
				// Send each line as a separate chunk to simulate real streaming
				controller.enqueue(encoder.encode(line1 + "\n"));
				controller.enqueue(encoder.encode(line2 + "\n"));
				controller.enqueue(encoder.encode(line3 + "\n"));
				controller.close();
			},
		});

		const runner = new ClaudeProviderRunner(() => ({
			exitCode: 0,
			exited: Promise.resolve(0),
			stderr: new ReadableStream<Uint8Array>({ start(c) { c.close(); } }),
			stdout: mockStdout,
		}));

		const result = await runner.run({
			chatId: "chat-1",
			onDelta: (d) => deltas.push(d),
			onEvent: (e) => events.push(e),
			text: "test",
			workspacePath: "/tmp",
		});

		expect(result.status).toBe("completed");
		expect(result.assistantText).toBe("Hello world");

		// Verify no duplication even with incremental chunks
		const bodyDeltas = events.filter(
			(e) => e.type === "item_delta" && "target" in e && e.target === "body",
		);
		expect(bodyDeltas).toHaveLength(1);
	});

	test("handles partial JSON lines split across chunks", async () => {
		const events: AssistantStreamEvent[] = [];

		const line1 = JSON.stringify({ type: "system", subtype: "init", session_id: "sess-1" });
		const line2 = JSON.stringify({
			type: "assistant",
			message: { id: "msg-1", content: [{ type: "text", text: "Split response" }] },
		});
		const line3 = JSON.stringify({ type: "result", subtype: "success", result: "Split response" });

		const fullOutput = line1 + "\n" + line2 + "\n" + line3 + "\n";
		const splitPoint = Math.floor(fullOutput.length / 2);

		const encoder = new TextEncoder();
		const mockStdout = new ReadableStream<Uint8Array>({
			start(controller) {
				controller.enqueue(encoder.encode(fullOutput.slice(0, splitPoint)));
				controller.enqueue(encoder.encode(fullOutput.slice(splitPoint)));
				controller.close();
			},
		});

		const runner = new ClaudeProviderRunner(() => ({
			exitCode: 0,
			exited: Promise.resolve(0),
			stderr: new ReadableStream<Uint8Array>({ start(c) { c.close(); } }),
			stdout: mockStdout,
		}));

		const result = await runner.run({
			chatId: "chat-1",
			onDelta: () => {},
			onEvent: (e) => events.push(e),
			text: "test",
			workspacePath: "/tmp",
		});

		expect(result.status).toBe("completed");
		expect(result.assistantText).toBe("Split response");
	});
});

describe("Claude provider e2e – real CLI output format", () => {
	test("handles actual Claude CLI stream-json output with hooks, separate thinking/text events, and rate_limit", async () => {
		const { result, events, deltas } = await runWithMockProcess([
			// Hook events (should be ignored)
			JSON.stringify({ type: "system", subtype: "hook_started", hook_id: "hook-1", hook_name: "SessionStart:startup", hook_event: "SessionStart", session_id: "sess-1" }),
			JSON.stringify({ type: "system", subtype: "hook_response", hook_id: "hook-1", hook_name: "SessionStart:startup", output: "", exit_code: 0, outcome: "success", session_id: "sess-1" }),
			// System init
			JSON.stringify({
				type: "system",
				subtype: "init",
				cwd: "/tmp/project",
				session_id: "sess-real-1",
				tools: ["Bash", "Read", "Write"],
				model: "claude-haiku-4-5-20251001",
				permissionMode: "default",
			}),
			// First assistant event: ONLY thinking
			JSON.stringify({
				type: "assistant",
				message: {
					model: "claude-haiku-4-5-20251001",
					id: "msg_01ABC",
					type: "message",
					role: "assistant",
					content: [
						{
							type: "thinking",
							thinking: "The user said hello in Portuguese. I should respond briefly.",
							signature: "EpwCCkYI...",
						},
					],
					stop_reason: null,
					usage: { input_tokens: 9, output_tokens: 3 },
				},
				parent_tool_use_id: null,
				session_id: "sess-real-1",
			}),
			// Second assistant event: ONLY text
			JSON.stringify({
				type: "assistant",
				message: {
					model: "claude-haiku-4-5-20251001",
					id: "msg_01ABC",
					type: "message",
					role: "assistant",
					content: [
						{
							type: "text",
							text: "Olá! Como posso te ajudar?",
						},
					],
					stop_reason: null,
					usage: { input_tokens: 9, output_tokens: 12 },
				},
				parent_tool_use_id: null,
				session_id: "sess-real-1",
			}),
			// Rate limit event (should be ignored)
			JSON.stringify({
				type: "rate_limit_event",
				rate_limit_info: { status: "allowed", resetsAt: 1773619200 },
				session_id: "sess-real-1",
			}),
			// Result event
			JSON.stringify({
				type: "result",
				subtype: "success",
				is_error: false,
				duration_ms: 5968,
				num_turns: 1,
				result: "Olá! Como posso te ajudar?",
				stop_reason: "end_turn",
				session_id: "sess-real-1",
				total_cost_usd: 0.02,
			}),
		]);

		expect(result.status).toBe("completed");
		expect(result.assistantText).toBe("Olá! Como posso te ajudar?");
		expect(result.threadId).toBe("sess-real-1");

		// Text should NOT be duplicated
		const bodyDeltas = events.filter(
			(e) => e.type === "item_delta" && "target" in e && e.target === "body",
		);
		expect(bodyDeltas).toHaveLength(1);
		expect("delta" in bodyDeltas[0] && bodyDeltas[0].delta).toBe("Olá! Como posso te ajudar?");

		// Thinking should be processed
		const thinkingStarted = events.find(
			(e) => e.type === "item_started" && "itemType" in e && e.itemType === "reasoning",
		);
		expect(thinkingStarted).toBeDefined();

		// turn_started and turn_completed should both be present
		expect(events[0].type).toBe("turn_started");
		expect(events[events.length - 1].type).toBe("turn_completed");

		// assistant_message should have item_completed
		const assistantCompleted = events.find(
			(e) => e.type === "item_completed" && "summary" in e && e.summary === "Response completed",
		);
		expect(assistantCompleted).toBeDefined();

		// Legacy deltas should include text exactly once
		const textDeltas = deltas.filter((d) => d.includes("Olá!"));
		expect(textDeltas).toHaveLength(1);
	});

	test("handles real CLI output where thinking has signature field", async () => {
		const events = parseClaudeJsonEvents(JSON.stringify({
			type: "assistant",
			message: {
				model: "claude-haiku-4-5-20251001",
				id: "msg_01ABC",
				type: "message",
				role: "assistant",
				content: [
					{
						type: "thinking",
						thinking: "Let me analyze this request",
						signature: "EpwCCkYICxgCKkDatECp4...",
					},
				],
				stop_reason: null,
			},
			parent_tool_use_id: null,
			session_id: "sess-1",
		}));

		expect(events).toHaveLength(3);
		expect(events[0]).toMatchObject({ type: "item_started", itemType: "reasoning" });
		expect(events[1]).toMatchObject({ type: "item_delta", itemType: "reasoning", text: "Let me analyze this request" });
		expect(events[2]).toMatchObject({ type: "item_completed", itemType: "reasoning" });
	});

	test("ignores system/hook_started and system/hook_response events", () => {
		expect(parseClaudeJsonEvents(JSON.stringify({
			type: "system", subtype: "hook_started", hook_id: "h1", session_id: "s1",
		}))).toEqual([]);

		expect(parseClaudeJsonEvents(JSON.stringify({
			type: "system", subtype: "hook_response", hook_id: "h1", output: "", exit_code: 0, session_id: "s1",
		}))).toEqual([]);
	});

	test("ignores rate_limit_event", () => {
		expect(parseClaudeJsonEvents(JSON.stringify({
			type: "rate_limit_event",
			rate_limit_info: { status: "allowed" },
			session_id: "s1",
		}))).toEqual([]);
	});
});

describe("Claude provider e2e – multi-turn with tool use", () => {
	test("complete multi-turn flow: thinking → tool → thinking → response", async () => {
		const { result, events } = await runWithMockProcess([
			JSON.stringify({ type: "system", subtype: "init", session_id: "sess-1" }),
			// First assistant turn: thinking + tool use
			JSON.stringify({
				type: "assistant",
				message: {
					id: "msg-1",
					content: [
						{ type: "thinking", thinking: "I need to check the file", id: "think-1" },
						{ type: "tool_use", id: "toolu-1", name: "Read", input: { file_path: "/src/main.ts" } },
					],
				},
			}),
			// Tool result
			JSON.stringify({
				type: "tool",
				tool_use_id: "toolu-1",
				content: "export const main = () => console.log('hello');",
			}),
			// Second assistant turn: thinking + final response
			JSON.stringify({
				type: "assistant",
				message: {
					id: "msg-2",
					content: [
						{ type: "thinking", thinking: "The file exports a main function that logs hello", id: "think-2" },
						{ type: "text", text: "The file exports a `main` function that prints 'hello'." },
					],
				},
			}),
			JSON.stringify({
				type: "result",
				subtype: "success",
				result: "The file exports a `main` function that prints 'hello'.",
			}),
		]);

		expect(result.status).toBe("completed");
		expect(result.assistantText).toBe("The file exports a `main` function that prints 'hello'.");

		// Verify all items exist
		const itemTypes = events
			.filter((e) => e.type === "item_started" && "itemType" in e)
			.map((e) => ("itemType" in e ? e.itemType : null));

		expect(itemTypes).toContain("reasoning");
		expect(itemTypes).toContain("tool");
		expect(itemTypes).toContain("assistant_message");

		// Verify thinking items are completed
		const thinkingCompleted = events.filter(
			(e) => e.type === "item_completed" && "itemId" in e &&
				typeof (e as { itemId: string }).itemId === "string" &&
				(e as { itemId: string }).itemId.startsWith("think"),
		);
		expect(thinkingCompleted.length).toBe(2);

		// Verify tool is completed
		const toolCompleted = events.find(
			(e) => e.type === "item_completed" && "itemId" in e && e.itemId === "toolu-1",
		);
		expect(toolCompleted).toBeDefined();

		// Verify response text not duplicated
		const bodyDeltas = events.filter(
			(e) => e.type === "item_delta" && "target" in e && e.target === "body",
		);
		expect(bodyDeltas).toHaveLength(1);
	});
});
