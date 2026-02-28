import type { CodexProviderResult, CodexProviderRunOptions } from "../../types";

interface CodexCommandExecutionItem {
	aggregated_output?: unknown;
	command?: unknown;
	exit_code?: unknown;
	type?: unknown;
}

interface CodexEventItem {
	content?: unknown;
	text?: unknown;
	type?: unknown;
}

interface CodexJsonEvent {
	error?: unknown;
	item?: CodexEventItem | CodexCommandExecutionItem;
	message?: unknown;
	thread_id?: unknown;
	type?: unknown;
}

export interface CodexParsedEvent {
	assistantMessage?: string;
	delta?: string;
	error?: string;
	threadId?: string;
	turnCompleted?: boolean;
}

interface CodexSpawnedProcess {
	exitCode: number | null;
	exited: Promise<number>;
	stderr: ReadableStream<Uint8Array> | null;
	stdout: ReadableStream<Uint8Array> | null;
}

interface CodexRunnerState {
	assistantMessages: string[];
	errorMessage?: string;
	threadId?: string;
	turnCompleted: boolean;
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
		return "Running command...\n";
	}

	return `Running command: ${truncate(commandText, 140)}\n`;
};

const buildCommandCompletedDelta = (
	commandOutput: unknown,
	commandExitCode: unknown,
): string => {
	const exitCode = typeof commandExitCode === "number" ? commandExitCode : null;
	const summary = summarizeCommandOutput(typeof commandOutput === "string" ? commandOutput : "");

	if (exitCode === 0) {
		return summary ? `Command output: ${summary}\n` : "Command finished.\n";
	}

	const exitLabel = exitCode === null ? "unknown" : String(exitCode);
	return summary
		? `Command failed (exit ${exitLabel}): ${summary}\n`
		: `Command failed (exit ${exitLabel}).\n`;
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
		return threadId ? { threadId } : null;
	}

	if (type === "turn.completed") {
		return { turnCompleted: true };
	}

	if (type === "process.failed" || type === "turn.failed" || type === "error") {
		return {
			error: parseProcessErrorMessage(payload) || "provider failed",
		};
	}

	const item = payload.item;
	const itemType = asString(item?.type);

	if (type === "item.started" && itemType === "command_execution") {
		return {
			delta: buildCommandStartDelta((item as CodexCommandExecutionItem).command),
		};
	}

	if (type === "item.completed" && itemType === "command_execution") {
		const commandItem = item as CodexCommandExecutionItem;
		return {
			delta: buildCommandCompletedDelta(commandItem.aggregated_output, commandItem.exit_code),
		};
	}

	if (type === "item.completed" && itemType === "reasoning") {
		return {
			delta: "Codex is thinking...\n",
		};
	}

	if (type === "item.completed" && itemType === "agent_message") {
		const assistantMessage = extractAssistantText(item);
		if (!assistantMessage) {
			return null;
		}

		return {
			assistantMessage,
			delta: assistantMessage,
		};
	}

	return null;
};

const applyParsedEvent = (
	state: CodexRunnerState,
	event: CodexParsedEvent,
	onDelta: (delta: string) => void,
): void => {
	if (event.threadId) {
		state.threadId = event.threadId;
	}

	if (event.delta) {
		onDelta(event.delta);
	}

	if (event.assistantMessage) {
		state.assistantMessages.push(event.assistantMessage);
	}

	if (event.turnCompleted) {
		state.turnCompleted = true;
	}

	if (event.error) {
		state.errorMessage = event.error;
	}
};

const buildCommand = (options: CodexProviderRunOptions): string[] => {
	if (options.threadId) {
		return [
			"codex",
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
			assistantMessages: [],
			threadId: options.threadId,
			turnCompleted: false,
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

						applyParsedEvent(state, parsed, options.onDelta);
					}
				}

				if (pending.trim().length > 0) {
					const parsed = parseCodexJsonLine(pending);
					if (parsed) {
						applyParsedEvent(state, parsed, options.onDelta);
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
					stdoutReader.releaseLock();
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

		const assistantText = state.assistantMessages.join("\n\n").trim();
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
