import { existsSync } from "node:fs";

import type { ChatRepository } from "../chat/chat.repository";
import type { ProjectRepository } from "../project/project.repository";
import type { TerminalCommandStatus, TerminalEntryDTO } from "../../types";
import type {
	TerminalExecInput,
	TerminalExecResult,
	TerminalHistoryQuery,
	TerminalHistoryResult,
	TerminalServiceContract,
} from "./terminal.model";
import type { TerminalRepository } from "./terminal.repository";

const DEFAULT_TIMEOUT_MS = 30_000;
const MAX_TIMEOUT_MS = 120_000;
const MAX_CAPTURED_OUTPUT_BYTES = 256 * 1024;
const FALLBACK_SHELL = "/bin/zsh";
const SECONDARY_FALLBACK_SHELL = "/bin/sh";
const TRUNCATION_NOTICE = `\n[output truncated: ${MAX_CAPTURED_OUTPUT_BYTES} byte limit reached]\n`;

const ANSI_OSC_SEQUENCE = /\u001B\][\s\S]*?(?:\u0007|\u001B\\)/g;
const ANSI_DCS_SEQUENCE = /\u001B[P^_][\s\S]*?\u001B\\/g;
const ANSI_CSI_SEQUENCE = /\u001B\[[0-?]*[ -/]*[@-~]/g;
const ANSI_SINGLE_SEQUENCE = /\u001B[@-Z\\-_]/g;
const INVALID_CONTROL_SEQUENCE = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g;

interface CapturedProcessOutput {
	stderr: string;
	stdout: string;
	truncated: boolean;
}

const normalizeTimeoutMs = (timeoutMs: number | undefined): number => {
	if (typeof timeoutMs !== "number" || !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
		return DEFAULT_TIMEOUT_MS;
	}

	return Math.min(MAX_TIMEOUT_MS, Math.floor(timeoutMs));
};

const resolveShell = (): string => {
	const configuredShell = process.env.SHELL?.trim();

	if (configuredShell && existsSync(configuredShell)) {
		return configuredShell;
	}

	if (existsSync(FALLBACK_SHELL)) {
		return FALLBACK_SHELL;
	}

	if (existsSync(SECONDARY_FALLBACK_SHELL)) {
		return SECONDARY_FALLBACK_SHELL;
	}

	return FALLBACK_SHELL;
};

export const sanitizeTerminalOutput = (raw: string): string => {
	if (!raw) {
		return "";
	}

	return raw
		.replace(/\r\n/g, "\n")
		.replace(/\r/g, "\n")
		.replace(ANSI_OSC_SEQUENCE, "")
		.replace(ANSI_DCS_SEQUENCE, "")
		.replace(ANSI_CSI_SEQUENCE, "")
		.replace(ANSI_SINGLE_SEQUENCE, "")
		.replace(INVALID_CONTROL_SEQUENCE, "");
};

const captureStream = async (
	stream: ReadableStream<Uint8Array> | null,
	state: { capturedBytes: number; maxBytes: number; truncated: boolean },
): Promise<string> => {
	if (!stream) {
		return "";
	}

	const decoder = new TextDecoder();
	const reader = stream.getReader();
	let output = "";

	try {
		while (true) {
			const { done, value } = await reader.read();
			if (done) {
				break;
			}

			if (!value || value.byteLength === 0) {
				continue;
			}

			const remainingBytes = Math.max(0, state.maxBytes - state.capturedBytes);
			if (remainingBytes <= 0) {
				state.truncated = true;
				continue;
			}

			if (value.byteLength <= remainingBytes) {
				state.capturedBytes += value.byteLength;
				output += decoder.decode(value, { stream: true });
				continue;
			}

			state.capturedBytes += remainingBytes;
			state.truncated = true;
			output += decoder.decode(value.slice(0, remainingBytes), { stream: true });
		}

		output += decoder.decode();
		return output;
	} finally {
		reader.releaseLock();
	}
};

const captureProcessOutput = async (
	stdout: ReadableStream<Uint8Array> | null,
	stderr: ReadableStream<Uint8Array> | null,
): Promise<CapturedProcessOutput> => {
	const state = {
		capturedBytes: 0,
		maxBytes: MAX_CAPTURED_OUTPUT_BYTES,
		truncated: false,
	};

	const [stdoutCaptured, stderrCaptured] = await Promise.all([
		captureStream(stdout, state),
		captureStream(stderr, state),
	]);

	return {
		stderr: stderrCaptured,
		stdout: stdoutCaptured,
		truncated: state.truncated,
	};
};

const resolveCommandStatus = (input: {
	exitCode: number | null;
	timedOut: boolean;
}): Extract<TerminalCommandStatus, "completed" | "failed" | "timeout"> => {
	if (input.timedOut) {
		return "timeout";
	}

	return input.exitCode === 0 ? "completed" : "failed";
};

interface ExecuteCommandResult {
	exitCode: number | null;
	stderr: string;
	status: Extract<TerminalCommandStatus, "completed" | "failed" | "timeout">;
	stdout: string;
}

const executeCommand = async (input: {
	command: string;
	cwd: string;
	shell: string;
	timeoutMs: number;
}): Promise<ExecuteCommandResult> => {
	const subprocess = Bun.spawn({
		cmd: [input.shell, "-lc", input.command],
		cwd: input.cwd,
		env: process.env,
		stderr: "pipe",
		stdin: "ignore",
		stdout: "pipe",
	});

	let timedOut = false;
	const timeout = setTimeout(() => {
		timedOut = true;
		try {
			subprocess.kill("SIGKILL");
		} catch {
			// Process may already be gone.
		}
	}, input.timeoutMs);

	try {
		const [{ stderr, stdout, truncated }, processExitCode] = await Promise.all([
			captureProcessOutput(subprocess.stdout, subprocess.stderr),
			subprocess.exited.catch(() => null),
		]);

		const sanitizedStdout = sanitizeTerminalOutput(stdout);
		let sanitizedStderr = sanitizeTerminalOutput(stderr);
		if (truncated) {
			sanitizedStderr = `${sanitizedStderr}${TRUNCATION_NOTICE}`;
		}

		const exitCode = timedOut ? null : processExitCode;

		return {
			exitCode,
			stderr: sanitizedStderr,
			status: resolveCommandStatus({
				exitCode,
				timedOut,
			}),
			stdout: sanitizedStdout,
		};
	} finally {
		clearTimeout(timeout);
	}
};

export class TerminalService implements TerminalServiceContract {
	constructor(
		private readonly chatRepository: ChatRepository,
		private readonly projectRepository: ProjectRepository,
		private readonly terminalRepository: TerminalRepository,
		private readonly execute: typeof executeCommand = executeCommand,
	) {}

	async getHistoryByChatId(chatId: string, query?: TerminalHistoryQuery): Promise<TerminalHistoryResult> {
		const chat = await this.chatRepository.findChatById(chatId);
		if (!chat) {
			return {
				chatExists: false,
				commands: [],
				entries: [],
			};
		}

		const commands = this.terminalRepository.listCommandsByChatId(chatId, {
			limit: query?.limit,
		});
		const entries = this.terminalRepository.listEntriesByChatId(chatId, {
			cursor: query?.cursor,
			limit: query?.limit,
		});

		return {
			chatExists: true,
			commands,
			entries,
		};
	}

	async execCommand(input: TerminalExecInput): Promise<TerminalExecResult> {
		const chat = await this.chatRepository.findChatById(input.chatId);
		if (!chat) {
			return {
				chatExists: false,
				command: null,
				entries: [],
				projectExists: false,
			};
		}

		const project = await this.projectRepository.findProjectById(chat.projectId);
		if (!project) {
			return {
				chatExists: true,
				command: null,
				entries: [],
				projectExists: false,
			};
		}

		const timeoutMs = normalizeTimeoutMs(input.timeoutMs);
		const shell = resolveShell();
		const commandText = input.command.trim();
		const command = this.terminalRepository.createCommand({
			chatId: input.chatId,
			command: commandText,
			cwd: project.path,
			shell,
		});

		const startedAtMs = Date.now();
		let executionOutput: ExecuteCommandResult;
		try {
			executionOutput = await this.execute({
				command: commandText,
				cwd: project.path,
				shell,
				timeoutMs,
			});
		} catch (error) {
			const failedAt = new Date().toISOString();
			const finalized = this.terminalRepository.setCommandResult(command.id, {
				durationMs: Math.max(0, Date.now() - startedAtMs),
				exitCode: null,
				finishedAt: failedAt,
				status: "failed",
			});

			const errorMessage = sanitizeTerminalOutput(
				error instanceof Error ? error.message : "terminal execution failed",
			);
			const entries = errorMessage
				? this.terminalRepository.appendEntries(command.id, input.chatId, "stderr", `${errorMessage}\n`)
				: [];

			return {
				chatExists: true,
				command: finalized,
				entries,
				projectExists: true,
			};
		}

		const persistedEntries: TerminalEntryDTO[] = [];
		if (executionOutput.stdout) {
			persistedEntries.push(
				...this.terminalRepository.appendEntries(command.id, input.chatId, "stdout", executionOutput.stdout),
			);
		}
		if (executionOutput.stderr) {
			persistedEntries.push(
				...this.terminalRepository.appendEntries(command.id, input.chatId, "stderr", executionOutput.stderr),
			);
		}

		const finishedAt = new Date().toISOString();
		const finalized = this.terminalRepository.setCommandResult(command.id, {
			durationMs: Math.max(0, Date.now() - startedAtMs),
			exitCode: executionOutput.exitCode,
			finishedAt,
			status: executionOutput.status,
		});

		return {
			chatExists: true,
			command: finalized,
			entries: persistedEntries,
			projectExists: true,
		};
	}
}

export const createTerminalService = (repositories: {
	chat: ChatRepository;
	project: ProjectRepository;
	terminal: TerminalRepository;
}) => new TerminalService(repositories.chat, repositories.project, repositories.terminal);
