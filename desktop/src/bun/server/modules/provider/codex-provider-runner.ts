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

interface CodexCommandExecutionItem {
	aggregated_output?: unknown;
	command?: unknown;
	exit_code?: unknown;
	id?: unknown;
	status?: unknown;
	type?: unknown;
}

interface CodexEventItem {
	content?: unknown;
	delta?: unknown;
	id?: unknown;
	status?: unknown;
	text?: unknown;
	type?: unknown;
}

interface CodexJsonEvent {
	delta?: unknown;
	error?: unknown;
	item?: CodexEventItem | CodexCommandExecutionItem;
	message?: unknown;
	text?: unknown;
	thread_id?: unknown;
	type?: unknown;
}

type ParsedCodexEventType =
	| "thread_started"
	| "turn_started"
	| "turn_completed"
	| "item_started"
	| "item_delta"
	| "item_completed"
	| "item_failed"
	| "error";

export interface CodexParsedEvent {
	command?: string;
	commandExitCode?: number | null;
	commandOutput?: string;
	error?: string;
	itemId?: string;
	itemType?: AssistantStreamItemType;
	text?: string;
	threadId?: string;
	type: ParsedCodexEventType;
}

interface CodexSpawnedProcess {
	exitCode: number | null;
	exited: Promise<number>;
	stderr: ReadableStream<Uint8Array> | null;
	stdout: ReadableStream<Uint8Array> | null;
}

interface CodexRunnerState {
	activeItemByType: Partial<Record<AssistantStreamItemType, string>>;
	agentMessageDeltaText: string;
	assistantMessage?: string;
	commandByItemId: Map<string, string>;
	currentTurnId?: string;
	errorMessage?: string;
	itemIdByRawId: Map<string, string>;
	itemSequence: number;
	lastStatusDelta?: string;
	startedItemIds: Set<string>;
	streamedAgentMessageItemIds: Set<string>;
	threadId?: string;
	turnCompleted: boolean;
	turnCounter: number;
}

type SpawnCodexProcess = (input: {
	cmd: string[];
	env: Record<string, string>;
}) => CodexSpawnedProcess;

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

const summarizeCommandOutput = (output: string): string | null => {
	const normalized = normalizeLine(output);
	if (!normalized) {
		return null;
	}

	return truncate(normalized, 220);
};

const buildCommandStartDelta = (command: unknown): string => {
	const commandText = asString(command);
	if (!commandText) {
		return "Tool calling...\n";
	}

	return `Tool calling: ${truncate(commandText, 140)}\n`;
};

const buildCommandCompletedDelta = (
	commandOutput: unknown,
	commandExitCode: unknown,
): string => {
	const exitCode = typeof commandExitCode === "number" ? commandExitCode : null;
	const summary = summarizeCommandOutput(typeof commandOutput === "string" ? commandOutput : "");

	if (exitCode === 0) {
		return summary ? `Tool output: ${summary}\n` : "Tool finished.\n";
	}

	const exitLabel = exitCode === null ? "unknown" : String(exitCode);
	return summary
		? `Tool failed (exit ${exitLabel}): ${summary}\n`
		: `Tool failed (exit ${exitLabel}).\n`;
};

const extractTextContent = (value: unknown): string | null => {
	if (typeof value === "string") {
		return value;
	}

	if (!Array.isArray(value)) {
		return null;
	}

	const textParts: string[] = [];

	for (const entry of value) {
		if (!entry || typeof entry !== "object") {
			continue;
		}

		const textValue = (entry as { text?: unknown }).text;
		if (typeof textValue === "string" && textValue.length > 0) {
			textParts.push(textValue);
		}
	}

	if (textParts.length === 0) {
		return null;
	}

	return textParts.join("\n");
};

const extractCommandOutput = (value: unknown): string | null => {
	if (typeof value === "string") {
		return value;
	}

	return extractTextContent(value);
};

const buildThinkingSummary = (text: unknown): string => {
	const raw = extractTextContent(text);
	if (!raw) {
		return "Thinking...";
	}

	const normalized = sanitizeStatusLabel(raw);
	if (!normalized) {
		return "Thinking...";
	}

	return `Thinking: ${truncate(normalized, 180)}`;
};

const buildPlanSummary = (text: unknown): string => {
	const raw = extractTextContent(text);
	if (!raw) {
		return "Planning...";
	}

	const normalized = sanitizeStatusLabel(raw);
	if (!normalized) {
		return "Planning...";
	}

	return `Planning: ${truncate(normalized, 180)}`;
};

const buildCommandStartSummary = (command: string | undefined): string => {
	if (!command) {
		return "Running command...";
	}

	return `Running command: ${truncate(command, 140)}`;
};

const buildCommandCompletedSummary = (
	command: string | undefined,
	commandOutput: string | undefined,
	commandExitCode: number | null | undefined,
): string => {
	const commandLabel = command ? truncate(command, 140) : "command";
	const outputSummary = summarizeCommandOutput(commandOutput ?? "");

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

const extractAssistantText = (item: CodexEventItem | CodexCommandExecutionItem | undefined): string | null => {
	if (!item) {
		return null;
	}

	const fromText = extractTextContent((item as CodexEventItem).text);
	if (fromText) {
		return fromText;
	}

	return extractTextContent((item as CodexEventItem).content);
};

const parseJsonLine = (line: string): CodexJsonEvent | null => {
	const trimmed = line.trim();
	if (!trimmed) {
		return null;
	}

	try {
		return JSON.parse(trimmed) as CodexJsonEvent;
	} catch {
		return null;
	}
};

const parseProcessErrorMessage = (event: CodexJsonEvent): string | null => {
	return asString(event.message) || asString(event.error) || "provider failed";
};

const normalizeItemType = (value: unknown): AssistantStreamItemType | null => {
	const rawType = asString(value);
	if (!rawType) {
		return null;
	}

	if (rawType === "command_execution") {
		return "tool";
	}

	if (rawType === "reasoning") {
		return "reasoning";
	}

	if (rawType === "plan") {
		return "plan";
	}

	if (rawType === "agent_message") {
		return "assistant_message";
	}

	return null;
};

const toNullableNumber = (value: unknown): number | null => {
	return typeof value === "number" && Number.isFinite(value) ? value : null;
};

const emitLegacyDelta = (
	state: CodexRunnerState,
	onDelta: (delta: string) => void,
	delta: string,
	isStatusDelta = false,
): void => {
	let shouldEmit = true;

	if (isStatusDelta) {
		const normalizedStatus = normalizeLine(delta);
		if (normalizedStatus && state.lastStatusDelta === normalizedStatus) {
			shouldEmit = false;
		} else if (normalizedStatus) {
			state.lastStatusDelta = normalizedStatus;
		}
	}

	if (shouldEmit) {
		onDelta(delta);
	}
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
	state: CodexRunnerState,
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
	state: CodexRunnerState,
	onEvent: ((event: AssistantStreamEvent) => void) | undefined,
): string => {
	if (state.currentTurnId) {
		return state.currentTurnId;
	}

	return startTurn(state, onEvent);
};

const resolveItemId = (
	state: CodexRunnerState,
	itemType: AssistantStreamItemType,
	rawItemId: string | undefined,
): string => {
	if (rawItemId) {
		const existing = state.itemIdByRawId.get(rawItemId);
		if (existing) {
			return existing;
		}

		state.itemIdByRawId.set(rawItemId, rawItemId);
		return rawItemId;
	}

	const active = state.activeItemByType[itemType];
	if (active) {
		return active;
	}

	state.itemSequence += 1;
	return `${itemType}-${state.itemSequence}`;
};

const ensureItemStarted = (input: {
	state: CodexRunnerState;
	onEvent: ((event: AssistantStreamEvent) => void) | undefined;
	turnId: string;
	itemType: AssistantStreamItemType;
	rawItemId?: string;
	command?: string;
}): string => {
	const itemId = resolveItemId(input.state, input.itemType, input.rawItemId);

	input.state.activeItemByType[input.itemType] = itemId;
	if (input.rawItemId) {
		input.state.itemIdByRawId.set(input.rawItemId, itemId);
	}

	if (input.command) {
		input.state.commandByItemId.set(itemId, input.command);
	}

	if (input.state.startedItemIds.has(itemId)) {
		return itemId;
	}

	let summary: string | undefined;
	if (input.itemType === "reasoning") {
		summary = "Thinking...";
	}
	if (input.itemType === "assistant_message") {
		summary = "Writing response...";
	}
	if (input.itemType === "plan") {
		summary = "Planning...";
	}
	if (input.itemType === "tool") {
		summary = buildCommandStartSummary(input.command);
	}

	emitStreamEvent(input.onEvent, {
		type: "item_started",
		turnId: input.turnId,
		itemId,
		itemType: input.itemType,
		state: "running",
		...(summary ? { summary } : {}),
	});
	input.state.startedItemIds.add(itemId);

	return itemId;
};

const completeItem = (input: {
	state: CodexRunnerState;
	onEvent: ((event: AssistantStreamEvent) => void) | undefined;
	turnId: string;
	itemId: string;
	stateValue: AssistantStreamItemState;
	summary?: string;
}): void => {
	emitStreamEvent(input.onEvent, {
		type: "item_state",
		turnId: input.turnId,
		itemId: input.itemId,
		state: input.stateValue,
		...(input.summary ? { summary: input.summary } : {}),
	});
	emitStreamEvent(input.onEvent, {
		type: "item_completed",
		turnId: input.turnId,
		itemId: input.itemId,
		state: input.stateValue,
		...(input.summary ? { summary: input.summary } : {}),
	});
};

export const parseCodexJsonLine = (line: string): CodexParsedEvent | null => {
	const payload = parseJsonLine(line);
	if (!payload) {
		return null;
	}

	const type = asString(payload.type);
	if (!type) {
		return null;
	}

	if (type === "thread.started") {
		const threadId = asString(payload.thread_id);
		return threadId
			? {
					type: "thread_started",
					threadId,
				}
			: null;
	}

	if (type === "turn.started") {
		return {
			type: "turn_started",
		};
	}

	if (type === "turn.completed") {
		return {
			type: "turn_completed",
		};
	}

	if (type === "process.failed" || type === "turn.failed" || type === "error") {
		return {
			type: "error",
			error: parseProcessErrorMessage(payload) || "provider failed",
		};
	}

	const item = payload.item;
	const itemType = normalizeItemType(item?.type);
	const itemId = asString((item as CodexEventItem | CodexCommandExecutionItem | undefined)?.id) ?? undefined;

	if (!itemType) {
		return null;
	}

	if (type === "item.started") {
		return {
			type: "item_started",
			itemId,
			itemType,
			command: asString((item as CodexCommandExecutionItem).command) ?? undefined,
		};
	}

	if (type === "item.delta") {
		const delta = extractTextContent(
			(item as CodexEventItem).delta ??
				(item as CodexEventItem).text ??
				payload.delta ??
				payload.text,
		);
		if (!delta) {
			return null;
		}

		return {
			type: "item_delta",
			itemId,
			itemType,
			text: delta,
		};
	}

	if (type === "item.failed") {
		return {
			type: "item_failed",
			itemId,
			itemType,
			command: asString((item as CodexCommandExecutionItem).command) ?? undefined,
			commandExitCode: toNullableNumber((item as CodexCommandExecutionItem).exit_code),
			commandOutput: extractCommandOutput((item as CodexCommandExecutionItem).aggregated_output) ?? undefined,
			error: parseProcessErrorMessage(payload) ?? "item failed",
		};
	}

	if (type === "item.completed") {
		if (itemType === "assistant_message") {
			const assistantMessage = extractAssistantText(item);
			return {
				type: "item_completed",
				itemId,
				itemType,
				text: assistantMessage ?? undefined,
			};
		}

		if (itemType === "reasoning" || itemType === "plan") {
			return {
				type: "item_completed",
				itemId,
				itemType,
				text: extractTextContent((item as CodexEventItem).text ?? (item as CodexEventItem).content) ?? undefined,
			};
		}

		return {
			type: "item_completed",
			itemId,
			itemType,
			command: asString((item as CodexCommandExecutionItem).command) ?? undefined,
			commandExitCode: toNullableNumber((item as CodexCommandExecutionItem).exit_code),
			commandOutput: extractCommandOutput((item as CodexCommandExecutionItem).aggregated_output) ?? undefined,
		};
	}

	return null;
};

const applyParsedEvent = (
	state: CodexRunnerState,
	event: CodexParsedEvent,
	input: {
		onDelta: (delta: string) => void;
		onEvent?: (event: AssistantStreamEvent) => void;
	},
): void => {
	if (event.type === "thread_started" && event.threadId) {
		state.threadId = event.threadId;
		return;
	}

	if (event.type === "turn_started") {
		startTurn(state, input.onEvent);
		emitLegacyDelta(state, input.onDelta, "Thinking...\n", true);
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
		return;
	}

	if (event.type === "error") {
		state.errorMessage = event.error || "provider failed";
		return;
	}

	if (!event.itemType) {
		return;
	}

	const turnId = ensureTurn(state, input.onEvent);
	const itemId = ensureItemStarted({
		state,
		onEvent: input.onEvent,
		turnId,
		itemType: event.itemType,
		rawItemId: event.itemId,
		command: event.command,
	});

	if (event.type === "item_started") {
		if (event.itemType === "reasoning") {
			emitLegacyDelta(state, input.onDelta, "Thinking...\n", true);
		}
		if (event.itemType === "assistant_message") {
			emitLegacyDelta(state, input.onDelta, "Writing response...\n", true);
		}
		if (event.itemType === "tool") {
			emitLegacyDelta(state, input.onDelta, buildCommandStartDelta(event.command), true);
		}
		if (event.itemType === "plan") {
			emitLegacyDelta(state, input.onDelta, "Planning...\n", true);
		}
		return;
	}

	if (event.type === "item_delta") {
		const deltaText = event.text ?? "";
		if (!deltaText) {
			return;
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
			emitLegacyDelta(state, input.onDelta, deltaText, false);
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

		if (event.itemType === "plan") {
			emitStreamEvent(input.onEvent, {
				type: "item_delta",
				turnId,
				itemId,
				target: "body",
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

	if (event.type === "item_failed") {
		const failedSummary =
			event.itemType === "tool"
				? buildCommandCompletedSummary(
					event.command ?? state.commandByItemId.get(itemId),
					event.commandOutput,
					event.commandExitCode,
				)
				: event.error || "Step failed";
		completeItem({
			state,
			onEvent: input.onEvent,
			turnId,
			itemId,
			stateValue: "failed",
			summary: failedSummary,
		});
		delete state.activeItemByType[event.itemType];
		state.errorMessage = event.error || state.errorMessage;

		if (event.itemType === "tool") {
			emitLegacyDelta(
				state,
				input.onDelta,
				buildCommandCompletedDelta(event.commandOutput ?? "", event.commandExitCode),
				true,
			);
		}
		return;
	}

	if (event.type !== "item_completed") {
		return;
	}

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

		completeItem({
			state,
			onEvent: input.onEvent,
			turnId,
			itemId,
			stateValue: status,
			summary,
		});
		delete state.activeItemByType.tool;
		emitLegacyDelta(
			state,
			input.onDelta,
			buildCommandCompletedDelta(event.commandOutput ?? "", event.commandExitCode),
			true,
		);
		return;
	}

	if (event.itemType === "reasoning") {
		const summary = buildThinkingSummary(event.text);
		completeItem({
			state,
			onEvent: input.onEvent,
			turnId,
			itemId,
			stateValue: "completed",
			summary,
		});
		delete state.activeItemByType.reasoning;
		emitLegacyDelta(state, input.onDelta, `${summary}\n`, true);
		return;
	}

	if (event.itemType === "plan") {
		const summary = buildPlanSummary(event.text);
		completeItem({
			state,
			onEvent: input.onEvent,
			turnId,
			itemId,
			stateValue: "completed",
			summary,
		});
		delete state.activeItemByType.plan;
		emitLegacyDelta(state, input.onDelta, `${summary}\n`, true);
		return;
	}

	const assistantMessage = event.text;
	if (assistantMessage && assistantMessage.length > 0) {
		state.assistantMessage = assistantMessage;
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
		emitLegacyDelta(state, input.onDelta, assistantMessage, false);
	}

	completeItem({
		state,
		onEvent: input.onEvent,
		turnId,
		itemId,
		stateValue: "completed",
		summary: "Response completed",
	});
	delete state.activeItemByType.assistant_message;
};

const buildPermissionFlags = (permissionMode: CodexPermissionMode | undefined): string[] => {
	const mode = permissionMode ?? DEFAULT_CODEX_PERMISSION_MODE;

	if (mode === "plan") {
		return ["--sandbox", "read-only", "--ask-for-approval", "never"];
	}

	if (mode === "full") {
		return ["--dangerously-bypass-approvals-and-sandbox"];
	}

	return ["--sandbox", "workspace-write", "--ask-for-approval", "never"];
};

const buildCommand = (options: CodexProviderRunOptions): string[] => {
	const permissionFlags = buildPermissionFlags(options.permissionMode);
	const modelFlags = options.model ? ["-m", options.model] : [];
	const reasoningFlags = options.reasoningEffort
		? ["-c", `model_reasoning_effort="${options.reasoningEffort}"`]
		: [];

	if (options.threadId) {
		return [
			"codex",
			...permissionFlags,
			...modelFlags,
			...reasoningFlags,
			"exec",
			"resume",
			"--json",
			"--skip-git-repo-check",
			options.threadId,
			options.text,
		];
	}

	return [
		"codex",
		...permissionFlags,
		...modelFlags,
		...reasoningFlags,
		"exec",
		"--json",
		"--skip-git-repo-check",
		"--cd",
		options.workspacePath,
		options.text,
	];
};

const defaultSpawnProcess: SpawnCodexProcess = ({ cmd, env }) => {
	return Bun.spawn({
		cmd,
		env,
		stderr: "pipe",
		stdout: "pipe",
	});
};

export interface CodexProviderRunnerContract {
	run: (options: CodexProviderRunOptions) => Promise<CodexProviderResult>;
}

export class CodexProviderRunner implements CodexProviderRunnerContract {
	constructor(private readonly spawnProcess: SpawnCodexProcess = defaultSpawnProcess) {}

	async run(options: CodexProviderRunOptions): Promise<CodexProviderResult> {
		const command = buildCommand(options);
		const environment = {
			...process.env,
			RUST_LOG: "off",
		};

		let spawnedProcess: CodexSpawnedProcess;

		try {
			spawnedProcess = this.spawnProcess({
				cmd: command,
				env: environment,
			});
		} catch (error) {
			return {
				assistantText: "",
				diffAdded: 0,
				diffRemoved: 0,
				error: `codex failed to start: ${error instanceof Error ? error.message : "unknown error"}`,
				status: "failed",
			};
		}

		const state: CodexRunnerState = {
			activeItemByType: {},
			agentMessageDeltaText: "",
			commandByItemId: new Map<string, string>(),
			itemIdByRawId: new Map<string, string>(),
			itemSequence: 0,
			startedItemIds: new Set<string>(),
			streamedAgentMessageItemIds: new Set<string>(),
			threadId: options.threadId,
			turnCompleted: false,
			turnCounter: 0,
		};
		const decoder = new TextDecoder();
		let stdoutReader: ReadableStreamDefaultReader<Uint8Array> | null = null;
		let stderrText = "";
		let resolvedExitCode = 0;

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
						const parsed = parseCodexJsonLine(line);
						if (!parsed) {
							continue;
						}

						applyParsedEvent(state, parsed, {
							onDelta: options.onDelta,
							onEvent: options.onEvent,
						});
					}
				}

				if (pending.trim().length > 0) {
					const parsed = parseCodexJsonLine(pending);
					if (parsed) {
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

			const results = await Promise.all([
				stdoutTask,
				stderrTask,
				spawnedProcess.exited,
			]);
			const stderrOutput = results[1];
			const exitCode = results[2];

			resolvedExitCode = exitCode;
			stderrText = stderrOutput.trim();
		} finally {
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
		const exitCode = resolvedExitCode;

		if (exitCode !== 0) {
			return {
				assistantText,
				diffAdded: assistantText.length,
				diffRemoved: 0,
				error: stderrText || state.errorMessage || `codex exited with code ${exitCode}`,
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
				error: "codex turn did not complete",
				status: "failed",
				threadId: state.threadId,
			};
		}

		if (!assistantText) {
			return {
				assistantText: "",
				diffAdded: 0,
				diffRemoved: 0,
				error: "codex produced no final assistant message",
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

const defaultRunner = new CodexProviderRunner();

export const runCodexProvider = async (
	options: CodexProviderRunOptions,
): Promise<CodexProviderResult> => await defaultRunner.run(options);
