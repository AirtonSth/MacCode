import type { CodexProviderResult, CodexProviderRunOptions } from "../../types";
import {
	DEFAULT_CODEX_PERMISSION_MODE,
	type CodexPermissionMode,
} from "../../../../shared/codex-permission-mode";
import type {
	AssistantStreamEvent,
	AssistantStreamItemState,
	AssistantStreamItemType,
} from "../../../../shared/assistant-stream-event";
import type { CodexReasoningEffort } from "../../../../shared/codex-model-config";
import { resolveCommand, resolveCommandInPath } from "../../platform/index";

interface ClaudeJsonEvent {
	event?: ClaudeStreamEventPayload;
	type?: string;
	subtype?: string;
	session_id?: string;
	message?: {
		id?: string;
		content?: ClaudeContentBlock[];
	};
	tool_use_id?: string;
	content?: unknown;
	result?: string;
	cost_usd?: number;
	duration_ms?: number;
	is_error?: boolean;
}

interface ClaudeStreamEventPayload {
	type?: string;
	index?: number;
	content_block?: ClaudeContentBlock;
	delta?: {
		type?: string;
		text?: string;
		thinking?: string;
		partial_json?: string;
		signature?: string;
	};
}

interface ClaudeContentBlock {
	type?: string;
	text?: string;
	thinking?: string;
	id?: string;
	name?: string;
	input?: unknown;
	tool_use_id?: string;
	content?: unknown;
	is_error?: boolean;
}

export interface ClaudeParsedEvent {
	command?: string;
	commandExitCode?: number | null;
	commandOutput?: string;
	error?: string;
	itemId?: string;
	itemType?: AssistantStreamItemType;
	source?: "assistant" | "result" | "stream" | "tool" | "user";
	streamIndex?: number;
	text?: string;
	threadId?: string;
	type:
		| "thread_started"
		| "turn_started"
		| "turn_completed"
		| "stream_message_started"
		| "stream_block_stopped"
		| "item_started"
		| "item_delta"
		| "item_completed"
		| "item_failed"
		| "error";
}

interface ClaudeRunnerState {
	activeItemByType: Partial<Record<AssistantStreamItemType, string>>;
	agentMessageDeltaText: string;
	assistantMessage?: string;
	commandByItemId: Map<string, string>;
	currentTurnId?: string;
	errorMessage?: string;
	hasSeenStreamEvents: boolean;
	itemSequence: number;
	lastStatusDelta?: string;
	startedItemIds: Set<string>;
	streamItemIdsByIndex: Map<number, string>;
	streamItemTypesByIndex: Map<number, AssistantStreamItemType>;
	streamedAgentMessageItemIds: Set<string>;
	threadId?: string;
	turnCompleted: boolean;
	turnCounter: number;
	pendingToolUseIds: Map<string, string>;
}

type ClaudeCommandInputPath = string | undefined;

const CLAUDE_COMMAND = "claude";

export const resolveClaudeCommand = (pathValue: ClaudeCommandInputPath = process.env.PATH): string =>
	pathValue === process.env.PATH ? resolveCommand(CLAUDE_COMMAND) : resolveCommandInPath(CLAUDE_COMMAND, pathValue);

interface ClaudeSpawnedProcess {
	exitCode: number | null;
	exited: Promise<number>;
	stderr: ReadableStream<Uint8Array> | null;
	stdout: ReadableStream<Uint8Array> | null;
}

type SpawnClaudeProcess = (input: {
	cmd: string[];
	cwd: string;
	env: Record<string, string>;
	signal?: AbortSignal;
}) => ClaudeSpawnedProcess;

const asString = (value: unknown): string | null => {
	if (typeof value !== "string") {
		return null;
	}

	const trimmed = value.trim();
	return trimmed.length > 0 ? trimmed : null;
};

const truncate = (value: string, maxLength: number): string => {
	if (value.length <= maxLength) {
		return value;
	}

	return `${value.slice(0, maxLength - 3)}...`;
};

const normalizeLine = (value: string): string => value.replace(/\s+/g, " ").trim();

const sanitizeStatusLabel = (value: string): string =>
	normalizeLine(value.replace(/[*_`#>~]/g, " ").replace(/\[(.*?)\]\((.*?)\)/g, "$1"));

const extractTextParts = (value: unknown): string[] => {
	if (typeof value === "string") {
		return [value];
	}

	if (!Array.isArray(value)) {
		return [];
	}

	return value
		.filter((entry): entry is { text?: unknown } => Boolean(entry) && typeof entry === "object")
		.map((entry) => (typeof entry.text === "string" ? entry.text : ""))
		.filter((entry) => entry.length > 0);
};

const parseJsonLine = (line: string): ClaudeJsonEvent | null => {
	const trimmed = line.trim();
	if (!trimmed) {
		return null;
	}

	try {
		return JSON.parse(trimmed) as ClaudeJsonEvent;
	} catch {
		return null;
	}
};

const buildStreamBlockItemId = (
	itemType: AssistantStreamItemType,
	streamIndex: number,
): string => `${itemType}-stream-${streamIndex}`;

const extractToolResultOutput = (block: ClaudeContentBlock): string => {
	if (typeof block.content === "string") {
		return block.content;
	}

	return extractTextParts(block.content).join("\n");
};

export const parseClaudeJsonEvents = (line: string): ClaudeParsedEvent[] => {
	const payload = parseJsonLine(line);
	if (!payload || !payload.type) {
		return [];
	}

	const events: ClaudeParsedEvent[] = [];

	if (payload.type === "system" && payload.subtype === "init") {
		const sessionId = asString(payload.session_id);
		if (sessionId) {
			events.push({
				type: "thread_started",
				threadId: sessionId,
			});
		}
		events.push({ type: "turn_started" });
		return events;
	}

	if (payload.type === "stream_event" && payload.event?.type) {
		const streamEvent = payload.event;
		if (streamEvent.type === "message_start") {
			events.push({
				type: "stream_message_started",
				source: "stream",
			});
			return events;
		}

		if (streamEvent.type === "content_block_start" && typeof streamEvent.index === "number") {
			const block = streamEvent.content_block;
			if (!block?.type) {
				return events;
			}

			if (block.type === "thinking") {
				events.push({
					type: "item_started",
					itemId: buildStreamBlockItemId("reasoning", streamEvent.index),
					itemType: "reasoning",
					source: "stream",
					streamIndex: streamEvent.index,
				});
				return events;
			}

			if (block.type === "text") {
				events.push({
					type: "item_started",
					itemId: buildStreamBlockItemId("assistant_message", streamEvent.index),
					itemType: "assistant_message",
					source: "stream",
					streamIndex: streamEvent.index,
				});
				return events;
			}

			if (block.type === "tool_use" && block.name) {
				events.push({
					type: "item_started",
					itemId: block.id ?? buildStreamBlockItemId("tool", streamEvent.index),
					itemType: "tool",
					command: block.name,
					source: "stream",
					streamIndex: streamEvent.index,
				});
				return events;
			}
		}

		if (streamEvent.type === "content_block_delta" && typeof streamEvent.index === "number") {
			const delta = streamEvent.delta;
			if (!delta?.type) {
				return events;
			}

			if (delta.type === "thinking_delta" && delta.thinking) {
				events.push({
					type: "item_delta",
					itemId: buildStreamBlockItemId("reasoning", streamEvent.index),
					itemType: "reasoning",
					source: "stream",
					streamIndex: streamEvent.index,
					text: delta.thinking,
				});
				return events;
			}

			if (delta.type === "text_delta" && delta.text) {
				events.push({
					type: "item_delta",
					itemId: buildStreamBlockItemId("assistant_message", streamEvent.index),
					itemType: "assistant_message",
					source: "stream",
					streamIndex: streamEvent.index,
					text: delta.text,
				});
				return events;
			}
		}

		if (streamEvent.type === "content_block_stop" && typeof streamEvent.index === "number") {
			events.push({
				type: "stream_block_stopped",
				source: "stream",
				streamIndex: streamEvent.index,
			});
			return events;
		}

		return events;
	}

	if (payload.type === "assistant" && payload.message?.content) {
		for (const block of payload.message.content) {
			if (!block.type) {
				continue;
			}

			if (block.type === "thinking" && block.thinking) {
				const itemId = block.id ?? `thinking-${Date.now()}`;
				events.push({
					type: "item_started",
					itemId,
					itemType: "reasoning",
					source: "assistant",
				});
				events.push({
					type: "item_delta",
					itemId,
					itemType: "reasoning",
					source: "assistant",
					text: block.thinking,
				});
				events.push({
					type: "item_completed",
					itemId,
					itemType: "reasoning",
					source: "assistant",
					text: block.thinking,
				});
			}

			if (block.type === "text" && block.text) {
				events.push({
					type: "item_delta",
					itemType: "assistant_message",
					source: "assistant",
					text: block.text,
				});
			}

			if (block.type === "tool_use" && block.name) {
				const toolItemId = block.id ?? `tool-${Date.now()}`;
				const commandLabel = typeof block.input === "object" && block.input !== null
					? `${block.name} ${JSON.stringify(block.input).slice(0, 100)}`
					: block.name;
				events.push({
					type: "item_started",
					itemId: toolItemId,
					itemType: "tool",
					command: commandLabel,
					source: "assistant",
				});
			}
		}

		return events;
	}

	if (payload.type === "user" && payload.message?.content) {
		for (const block of payload.message.content) {
			if (block.type !== "tool_result" || !block.tool_use_id) {
				continue;
			}

			events.push({
				type: "item_completed",
				itemId: block.tool_use_id,
				itemType: "tool",
				commandExitCode: block.is_error ? 1 : 0,
				commandOutput: extractToolResultOutput(block),
				source: "user",
			});
		}

		return events;
	}

	if (payload.type === "tool") {
		const toolUseId = asString(payload.tool_use_id);
		const output = typeof payload.content === "string"
			? payload.content
			: (Array.isArray(payload.content)
				? (payload.content as Array<{ text?: string }>)
					.filter((c) => typeof c.text === "string")
					.map((c) => c.text)
					.join("\n")
				: "");

		if (toolUseId) {
			events.push({
				type: "item_completed",
				itemId: toolUseId,
				itemType: "tool",
				commandOutput: output,
				commandExitCode: 0,
				source: "tool",
			});
		}

		return events;
	}

	if (payload.type === "result") {
		if (payload.subtype === "error" || payload.is_error) {
			events.push({
				type: "error",
				error: typeof payload.result === "string" ? payload.result : "claude code failed",
			});
		}

		if (payload.result && typeof payload.result === "string") {
			events.push({
				type: "item_completed",
				itemType: "assistant_message",
				source: "result",
				text: payload.result,
			});
		}

		events.push({ type: "turn_completed" });
		return events;
	}

	return events;
};

const emitStreamEvent = (
	callback: ((event: AssistantStreamEvent) => void) | undefined,
	event: AssistantStreamEvent,
): void => {
	if (!callback) {
		return;
	}

	callback(event);
};

const startTurn = (
	state: ClaudeRunnerState,
	onEvent: ((event: AssistantStreamEvent) => void) | undefined,
): string => {
	state.turnCounter += 1;
	const turnId = `turn-${state.turnCounter}`;
	state.currentTurnId = turnId;
	emitStreamEvent(onEvent, {
		type: "turn_started",
		turnId,
	});
	return turnId;
};

const ensureTurn = (
	state: ClaudeRunnerState,
	onEvent: ((event: AssistantStreamEvent) => void) | undefined,
): string => {
	if (state.currentTurnId) {
		return state.currentTurnId;
	}

	return startTurn(state, onEvent);
};

const resolveItemId = (
	state: ClaudeRunnerState,
	itemType: AssistantStreamItemType,
	rawItemId: string | undefined,
	streamIndex?: number,
): string => {
	if (rawItemId) {
		return rawItemId;
	}

	if (typeof streamIndex === "number") {
		const existing = state.streamItemIdsByIndex.get(streamIndex);
		if (existing) {
			return existing;
		}

		state.itemSequence += 1;
		const created = `${itemType}-stream-${state.itemSequence}`;
		state.streamItemIdsByIndex.set(streamIndex, created);
		return created;
	}

	const active = state.activeItemByType[itemType];
	if (active) {
		return active;
	}

	state.itemSequence += 1;
	return `${itemType}-${state.itemSequence}`;
};

const buildCommandStartSummary = (command: string | undefined): string => {
	if (!command) {
		return "Running command...";
	}

	return `Running: ${truncate(command, 140)}`;
};

const buildCommandCompletedSummary = (
	command: string | undefined,
	commandOutput: string | undefined,
	commandExitCode: number | null | undefined,
): string => {
	const commandLabel = command ? truncate(command, 140) : "command";
	const outputSummary = commandOutput ? truncate(normalizeLine(commandOutput), 220) : null;

	if (commandExitCode === 0) {
		return outputSummary
			? `Ran ${commandLabel} · ${outputSummary}`
			: `Ran ${commandLabel}`;
	}

	const exitLabel = commandExitCode === null || commandExitCode === undefined
		? "unknown"
		: String(commandExitCode);
	return outputSummary
		? `Command failed (${exitLabel}) · ${outputSummary}`
		: `Command failed (${exitLabel})`;
};

const applyParsedEvent = (
	state: ClaudeRunnerState,
	event: ClaudeParsedEvent,
	input: {
		onDelta: (delta: string) => void;
		onEvent?: (event: AssistantStreamEvent) => void;
	},
): void => {
	if (event.type === "thread_started" && event.threadId) {
		state.threadId = event.threadId;
		return;
	}

	if (event.type === "stream_message_started") {
		state.hasSeenStreamEvents = true;
		state.streamItemIdsByIndex.clear();
		state.streamItemTypesByIndex.clear();
		ensureTurn(state, input.onEvent);
		return;
	}

	if (event.type === "turn_started") {
		startTurn(state, input.onEvent);
		input.onDelta("Thinking...\n");
		return;
	}

	if (event.type === "turn_completed") {
		const turnId = ensureTurn(state, input.onEvent);
		emitStreamEvent(input.onEvent, {
			type: "turn_completed",
			turnId,
		});
		state.turnCompleted = true;
		state.currentTurnId = undefined;
		state.activeItemByType = {};
		state.streamItemIdsByIndex.clear();
		state.streamItemTypesByIndex.clear();
		return;
	}

	if (event.type === "stream_block_stopped") {
		const itemType = typeof event.streamIndex === "number"
			? state.streamItemTypesByIndex.get(event.streamIndex)
			: undefined;
		if (itemType !== "reasoning") {
			return;
		}

		const turnId = ensureTurn(state, input.onEvent);
		const itemId = resolveItemId(state, itemType, undefined, event.streamIndex);
		emitStreamEvent(input.onEvent, {
			type: "item_state",
			turnId,
			itemId,
			state: "completed",
		});
		emitStreamEvent(input.onEvent, {
			type: "item_completed",
			turnId,
			itemId,
			state: "completed",
		});
		delete state.activeItemByType.reasoning;
		return;
	}

	if (event.type === "error") {
		state.errorMessage = event.error || "provider failed";
		return;
	}

	if (!event.itemType) {
		return;
	}

	if (state.hasSeenStreamEvents && event.source === "assistant") {
		return;
	}

	const turnId = ensureTurn(state, input.onEvent);
	const itemId = resolveItemId(state, event.itemType, event.itemId, event.streamIndex);

	if (event.type === "item_started") {
		state.activeItemByType[event.itemType] = itemId;
		if (typeof event.streamIndex === "number") {
			state.streamItemIdsByIndex.set(event.streamIndex, itemId);
			state.streamItemTypesByIndex.set(event.streamIndex, event.itemType);
		}

		if (!state.startedItemIds.has(itemId)) {
			let summary: string | undefined;
			if (event.itemType === "reasoning") {
				summary = "Thinking...";
			}
			if (event.itemType === "assistant_message") {
				summary = "Writing response...";
			}
			if (event.itemType === "tool") {
				summary = buildCommandStartSummary(event.command);
			}

			emitStreamEvent(input.onEvent, {
				type: "item_started",
				turnId,
				itemId,
				itemType: event.itemType,
				state: "running",
				...(summary ? { summary } : {}),
			});
			state.startedItemIds.add(itemId);

			if (event.command) {
				state.commandByItemId.set(itemId, event.command);
			}

			if (event.itemType === "reasoning") {
				input.onDelta("Thinking...\n");
			}
			if (event.itemType === "tool") {
				input.onDelta(`Tool calling: ${truncate(event.command ?? "unknown", 140)}\n`);
			}
		}
		return;
	}

	if (event.type === "item_delta") {
		const deltaText = event.text ?? "";
		if (!deltaText) {
			return;
		}

		if (!state.startedItemIds.has(itemId)) {
			state.activeItemByType[event.itemType] = itemId;
			let summary: string | undefined;
			if (event.itemType === "assistant_message") {
				summary = "Writing response...";
			}
			if (event.itemType === "reasoning") {
				summary = "Thinking...";
			}

			emitStreamEvent(input.onEvent, {
				type: "item_started",
				turnId,
				itemId,
				itemType: event.itemType,
				state: "running",
				...(summary ? { summary } : {}),
			});
			state.startedItemIds.add(itemId);
		}

		if (event.itemType === "assistant_message") {
			state.streamedAgentMessageItemIds.add(itemId);
			state.agentMessageDeltaText += deltaText;
			emitStreamEvent(input.onEvent, {
				type: "item_delta",
				turnId,
				itemId,
				target: "body",
				delta: deltaText,
			});
			input.onDelta(deltaText);
			return;
		}

		if (event.itemType === "reasoning") {
			emitStreamEvent(input.onEvent, {
				type: "item_delta",
				turnId,
				itemId,
				target: "summary",
				delta: deltaText,
			});
			return;
		}

		emitStreamEvent(input.onEvent, {
			type: "item_delta",
			turnId,
			itemId,
			target: "output",
			delta: deltaText,
		});
		return;
	}

	if (event.type === "item_completed") {
		if (event.itemType === "tool") {
			if (event.commandOutput) {
				emitStreamEvent(input.onEvent, {
					type: "item_delta",
					turnId,
					itemId,
					target: "output",
					delta: event.commandOutput,
				});
			}

			const resolvedCommand = event.command ?? state.commandByItemId.get(itemId);
			const status: AssistantStreamItemState = event.commandExitCode === 0 ? "completed" : "failed";
			const summary = buildCommandCompletedSummary(
				resolvedCommand,
				event.commandOutput,
				event.commandExitCode,
			);

			emitStreamEvent(input.onEvent, {
				type: "item_state",
				turnId,
				itemId,
				state: status,
				summary,
			});
			emitStreamEvent(input.onEvent, {
				type: "item_completed",
				turnId,
				itemId,
				state: status,
				summary,
			});
			delete state.activeItemByType.tool;
			input.onDelta(`Tool finished: ${summary}\n`);
			return;
		}

		if (event.itemType === "reasoning") {
			const raw = event.text ? sanitizeStatusLabel(event.text) : "";
			const summary = raw ? `Thinking: ${truncate(raw, 180)}` : "Thinking...";
			emitStreamEvent(input.onEvent, {
				type: "item_state",
				turnId,
				itemId,
				state: "completed",
				summary,
			});
			emitStreamEvent(input.onEvent, {
				type: "item_completed",
				turnId,
				itemId,
				state: "completed",
				summary,
			});
			delete state.activeItemByType.reasoning;
			return;
		}

		const assistantMessage = event.text;
		if (assistantMessage && assistantMessage.length > 0) {
			state.assistantMessage = assistantMessage;
		}

		if (!state.startedItemIds.has(itemId)) {
			state.activeItemByType.assistant_message = itemId;
			emitStreamEvent(input.onEvent, {
				type: "item_started",
				turnId,
				itemId,
				itemType: "assistant_message",
				state: "running",
				summary: "Writing response...",
			});
			state.startedItemIds.add(itemId);
		}

		const hasStreamedDelta = state.streamedAgentMessageItemIds.has(itemId);
		if (assistantMessage && assistantMessage.length > 0 && !hasStreamedDelta) {
			state.agentMessageDeltaText += assistantMessage;
			emitStreamEvent(input.onEvent, {
				type: "item_delta",
				turnId,
				itemId,
				target: "body",
				delta: assistantMessage,
			});
			input.onDelta(assistantMessage);
		}

		emitStreamEvent(input.onEvent, {
			type: "item_state",
			turnId,
			itemId,
			state: "completed",
			summary: "Response completed",
		});
		emitStreamEvent(input.onEvent, {
			type: "item_completed",
			turnId,
			itemId,
			state: "completed",
			summary: "Response completed",
		});
		delete state.activeItemByType.assistant_message;
		return;
	}

	if (event.type === "item_failed") {
		emitStreamEvent(input.onEvent, {
			type: "item_state",
			turnId,
			itemId,
			state: "failed",
			summary: event.error || "Step failed",
		});
		emitStreamEvent(input.onEvent, {
			type: "item_completed",
			turnId,
			itemId,
			state: "failed",
			summary: event.error || "Step failed",
		});
		delete state.activeItemByType[event.itemType];
		state.errorMessage = event.error || state.errorMessage;
	}
};

const buildPermissionFlags = (permissionMode: CodexPermissionMode | undefined): string[] => {
	const mode = permissionMode ?? DEFAULT_CODEX_PERMISSION_MODE;

	if (mode === "full") {
		return ["--dangerously-skip-permissions"];
	}

	if (mode === "plan") {
		return ["--permission-mode", "plan"];
	}

	return ["--permission-mode", "default"];
};

const buildEffortFlags = (reasoningEffort: CodexReasoningEffort | undefined): string[] => {
	if (!reasoningEffort || reasoningEffort === "none" || reasoningEffort === "minimal") {
		return [];
	}

	const effort = reasoningEffort === "xhigh" ? "max" : reasoningEffort;
	return ["--effort", effort];
};

const buildCommand = (options: CodexProviderRunOptions): string[] => {
	const permissionFlags = buildPermissionFlags(options.permissionMode);
	const effortFlags = buildEffortFlags(options.reasoningEffort);
	const modelFlags = options.model ? ["--model", options.model] : [];
	const command = resolveClaudeCommand();

	const cmd = [command];

	if (options.threadId) {
		cmd.push("--resume", options.threadId);
	}

	cmd.push("-p", options.text);
	cmd.push("--output-format", "stream-json");
	cmd.push("--include-partial-messages");
	cmd.push("--verbose");
	cmd.push(...modelFlags);
	cmd.push(...effortFlags);
	cmd.push(...permissionFlags);

	return cmd;
};

const defaultSpawnProcess: SpawnClaudeProcess = ({ cmd, cwd, env, signal }) => {
	return Bun.spawn({
		cmd,
		cwd,
		env,
		signal,
		stderr: "pipe",
		stdout: "pipe",
	});
};

export interface ClaudeProviderRunnerContract {
	run: (options: CodexProviderRunOptions) => Promise<CodexProviderResult>;
}

export class ClaudeProviderRunner implements ClaudeProviderRunnerContract {
	constructor(private readonly spawnProcess: SpawnClaudeProcess = defaultSpawnProcess) {}

	async run(options: CodexProviderRunOptions): Promise<CodexProviderResult> {
		const command = buildCommand(options);
		const environment = Object.fromEntries(
			Object.entries(process.env).filter(([, v]) => v !== undefined)
		) as Record<string, string>;
		const buildCancelledResult = (assistantTextValue: string, threadId?: string): CodexProviderResult => ({
			assistantText: assistantTextValue,
			cancelled: true,
			diffAdded: assistantTextValue.length,
			diffRemoved: 0,
			error: "claude run cancelled by user",
			status: "failed",
			threadId,
		});

		let spawnedProcess: ClaudeSpawnedProcess;

		try {
			spawnedProcess = this.spawnProcess({
				cmd: command,
				cwd: options.workspacePath,
				env: environment,
				signal: options.signal,
			});
		} catch (error) {
			if (options.signal?.aborted) {
				return buildCancelledResult("", options.threadId);
			}

			return {
				assistantText: "",
				diffAdded: 0,
				diffRemoved: 0,
				error: `claude failed to start: ${error instanceof Error ? error.message : "unknown error"}`,
				status: "failed",
			};
		}

		const state: ClaudeRunnerState = {
			activeItemByType: {},
			agentMessageDeltaText: "",
			commandByItemId: new Map<string, string>(),
			currentTurnId: undefined,
			itemSequence: 0,
			hasSeenStreamEvents: false,
			startedItemIds: new Set<string>(),
			streamItemIdsByIndex: new Map<number, string>(),
			streamItemTypesByIndex: new Map<number, AssistantStreamItemType>(),
			streamedAgentMessageItemIds: new Set<string>(),
			threadId: options.threadId,
			turnCompleted: false,
			turnCounter: 0,
			pendingToolUseIds: new Map<string, string>(),
		};
		const decoder = new TextDecoder();
		let stdoutReader: ReadableStreamDefaultReader<Uint8Array> | null = null;
		let stderrText = "";
		let resolvedExitCode = 0;
		let executionError: unknown = null;
		let wasCancelled = Boolean(options.signal?.aborted);
		let abortListener: (() => void) | null = null;

		if (options.signal) {
			abortListener = () => {
				wasCancelled = true;
			};
			options.signal.addEventListener("abort", abortListener);
		}

		try {
			const stdoutTask = (async () => {
				if (!spawnedProcess.stdout) {
					return;
				}

				stdoutReader = spawnedProcess.stdout.getReader();
				let pending = "";

				while (true) {
					const { done, value } = await stdoutReader.read();

					if (done) {
						break;
					}

					pending += decoder.decode(value, { stream: true });
					const lines = pending.split("\n");
					pending = lines.pop() ?? "";

					for (const line of lines) {
						const parsedEvents = parseClaudeJsonEvents(line);
						for (const parsed of parsedEvents) {
							applyParsedEvent(state, parsed, {
								onDelta: options.onDelta,
								onEvent: options.onEvent,
							});
						}
					}
				}

				if (pending.trim().length > 0) {
					const parsedEvents = parseClaudeJsonEvents(pending);
					for (const parsed of parsedEvents) {
						applyParsedEvent(state, parsed, {
							onDelta: options.onDelta,
							onEvent: options.onEvent,
						});
					}
				}
			})();

			const stderrTask = spawnedProcess.stderr
				? new Response(spawnedProcess.stderr).text()
				: Promise.resolve("");

			try {
				const results = await Promise.all([
					stdoutTask,
					stderrTask,
					spawnedProcess.exited,
				]);
				const stderrOutput = results[1];
				const exitCode = results[2];

				resolvedExitCode = exitCode;
				stderrText = stderrOutput.trim();
			} catch (error) {
				executionError = error;
				if (options.signal?.aborted) {
					wasCancelled = true;
				}
			}
		} finally {
			if (options.signal && abortListener) {
				options.signal.removeEventListener("abort", abortListener);
			}

			if (stdoutReader) {
				try {
					(stdoutReader as ReadableStreamDefaultReader<Uint8Array>).releaseLock();
				} catch {
					// no-op on best effort cleanup
				}
			}

			if (spawnedProcess.stdout) {
				try {
					await spawnedProcess.stdout.cancel();
				} catch {
					// no-op on best effort cleanup
				}
			}

			if (spawnedProcess.stderr) {
				try {
					await spawnedProcess.stderr.cancel();
				} catch {
					// no-op on best effort cleanup
				}
			}
		}

		const assistantText = (state.assistantMessage ?? state.agentMessageDeltaText).trim();

		if (wasCancelled) {
			return buildCancelledResult(assistantText, state.threadId);
		}

		if (executionError) {
			return {
				assistantText,
				diffAdded: assistantText.length,
				diffRemoved: 0,
				error: executionError instanceof Error ? executionError.message : "provider failed",
				status: "failed",
				threadId: state.threadId,
			};
		}

		if (resolvedExitCode !== 0) {
			return {
				assistantText,
				diffAdded: assistantText.length,
				diffRemoved: 0,
				error: stderrText || state.errorMessage || `claude exited with code ${resolvedExitCode}`,
				status: "failed",
				threadId: state.threadId,
			};
		}

		if (state.errorMessage) {
			return {
				assistantText,
				diffAdded: assistantText.length,
				diffRemoved: 0,
				error: state.errorMessage,
				status: "failed",
				threadId: state.threadId,
			};
		}

		if (!state.turnCompleted) {
			return {
				assistantText,
				diffAdded: assistantText.length,
				diffRemoved: 0,
				error: "claude turn did not complete",
				status: "failed",
				threadId: state.threadId,
			};
		}

		if (!assistantText) {
			return {
				assistantText: "",
				diffAdded: 0,
				diffRemoved: 0,
				error: "claude produced no final assistant message",
				status: "failed",
				threadId: state.threadId,
			};
		}

		return {
			assistantText,
			diffAdded: assistantText.length,
			diffRemoved: 0,
			status: "completed",
			threadId: state.threadId,
		};
	}
}

export const buildClaudeCommand = buildCommand;
