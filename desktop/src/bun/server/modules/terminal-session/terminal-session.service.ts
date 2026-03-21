import { spawn as spawnChildProcess, type ChildProcessByStdio } from "node:child_process";
import { randomUUID } from "node:crypto";
import { accessSync, chmodSync, constants, existsSync, mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { constants as osConstants, tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import type { Readable, Writable } from "node:stream";
import { fileURLToPath } from "node:url";

import { SerializeAddon } from "@xterm/addon-serialize";
import { Terminal } from "@xterm/headless";

import { killProcess, resolveShell } from "../../platform";
import { resolveCommandInPath } from "../../platform";
import { serverLogger } from "../../shared/core/server-logger";
import type { TerminalSessionSnapshotDTO, TerminalSessionStateDTO } from "../../types";
import type { ChatRepository } from "../chat/chat.repository";
import type { ProjectRepository } from "../project/project.repository";
import type {
	TerminalSessionActionResult,
	TerminalSessionInputResult,
	TerminalSessionJoinResult,
	TerminalSessionServerEvent,
	TerminalSessionServiceContract,
	TerminalSessionSignal,
	TerminalViewport,
} from "./terminal-session.model";
import type { TerminalSessionRepository } from "./terminal-session.repository";

const DEFAULT_COLS = 80;
const DEFAULT_ROWS = 24;
const DEFAULT_SCROLLBACK = 5_000;
const PYTHON_BRIDGE_CANDIDATE_PATH = join(dirname(fileURLToPath(import.meta.url)), "pty_session_bridge.py");
const TERMINAL_LOG_SCOPE = "terminal-session";
const PYTHON_BRIDGE_SOURCE = `#!/usr/bin/env python3

import base64
import json
import os
import pty
import resource
import select
import signal
import struct
import subprocess
import sys
import termios
from fcntl import ioctl


def send_event(event: str, **payload: object) -> None:
    sys.stdout.write(json.dumps({"event": event, **payload}) + "\\n")
    sys.stdout.flush()


def decode_config(raw: str) -> dict[str, object]:
    return json.loads(base64.b64decode(raw).decode("utf-8"))


def set_window_size(fd: int, rows: int, cols: int) -> None:
    try:
        ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except OSError:
        pass


def attach_controlling_terminal(slave_fd: int) -> None:
    os.setsid()

    try:
        ioctl(slave_fd, termios.TIOCSCTTY, 0)
    except OSError:
        pass

    try:
        os.tcsetpgrp(slave_fd, os.getpgrp())
    except OSError:
        pass


def resolve_signal(name: object) -> int:
    if not isinstance(name, str):
        return signal.SIGTERM

    return int(getattr(signal, name, signal.SIGTERM))


def kill_terminal_group(child_pid: int, signum: int) -> None:
    try:
        target_group = os.getpgid(child_pid)
    except ProcessLookupError:
        return

    try:
        os.killpg(target_group, signum)
    except ProcessLookupError:
        pass


def close_extra_fds() -> None:
    try:
        _, hard_limit = resource.getrlimit(resource.RLIMIT_NOFILE)
    except (OSError, ValueError):
        hard_limit = 256

    max_fd = 256 if hard_limit in (-1, resource.RLIM_INFINITY) else int(min(hard_limit, 4096))
    try:
        os.closerange(3, max_fd)
    except OSError:
        pass


def main() -> int:
    if len(sys.argv) < 2:
        print("missing terminal bridge config", file=sys.stderr)
        return 1

    config = decode_config(sys.argv[1])
    argv = config.get("argv")
    cwd = config.get("cwd")
    env = config.get("env")
    cols = int(config.get("cols", 80))
    rows = int(config.get("rows", 24))

    if not isinstance(argv, list) or not argv or not all(isinstance(entry, str) for entry in argv):
        print("invalid argv", file=sys.stderr)
        return 1

    if not isinstance(cwd, str) or not cwd:
        print("invalid cwd", file=sys.stderr)
        return 1

    if not isinstance(env, dict):
        print("invalid env", file=sys.stderr)
        return 1

    master_fd, slave_fd = pty.openpty()
    set_window_size(slave_fd, rows, cols)
    child = subprocess.Popen(
        argv,
        cwd=cwd,
        env={str(key): str(value) for key, value in env.items()},
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
        preexec_fn=lambda: attach_controlling_terminal(slave_fd),
    )
    child_pid = child.pid
    os.close(slave_fd)

    os.set_blocking(master_fd, False)
    os.set_blocking(sys.stdin.fileno(), False)

    def forward_signal(signum: int, _frame: object) -> None:
        kill_terminal_group(child_pid, signum)

    signal.signal(signal.SIGTERM, forward_signal)
    signal.signal(signal.SIGINT, forward_signal)

    send_event("ready", pid=child_pid)

    stdin_buffer = bytearray()
    stdin_closed = False

    while True:
        child_status = child.poll()

        watched_fds: list[int] = []
        if not stdin_closed:
            watched_fds.append(sys.stdin.fileno())
        if master_fd >= 0:
            watched_fds.append(master_fd)

        if child_status is not None and master_fd < 0:
            break

        readable, _, _ = select.select(watched_fds, [], [], 0.05)
        for fd in readable:
            if fd == master_fd:
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError:
                    chunk = b""

                if chunk:
                    send_event("output", data=base64.b64encode(chunk).decode("ascii"))
                    continue

                try:
                    os.close(master_fd)
                except OSError:
                    pass
                master_fd = -1
                continue

            try:
                incoming = os.read(sys.stdin.fileno(), 4096)
            except BlockingIOError:
                incoming = b""

            if not incoming:
                stdin_closed = True
                continue

            stdin_buffer.extend(incoming)
            while True:
                newline_index = stdin_buffer.find(b"\\n")
                if newline_index < 0:
                    break

                raw_line = bytes(stdin_buffer[:newline_index])
                del stdin_buffer[: newline_index + 1]
                if not raw_line:
                    continue

                try:
                    command = json.loads(raw_line.decode("utf-8"))
                except json.JSONDecodeError:
                    continue

                event = command.get("event")
                if event == "write" and master_fd >= 0:
                    try:
                        payload = base64.b64decode(str(command.get("data", "")))
                        if payload:
                            os.write(master_fd, payload)
                    except OSError:
                        pass
                    continue

                if event == "resize" and master_fd >= 0:
                    set_window_size(master_fd, int(command.get("rows", rows)), int(command.get("cols", cols)))
                    continue

                if event == "signal":
                    kill_terminal_group(child_pid, resolve_signal(command.get("signal")))
                    continue

                if event == "close":
                    kill_terminal_group(child_pid, signal.SIGHUP)
                    if master_fd >= 0:
                        try:
                            os.close(master_fd)
                        except OSError:
                            pass
                        master_fd = -1

    exit_code = child.wait()

    send_event("exit", exitCode=exit_code)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
`;
let cachedPythonBridgePath: string | null = null;

const isExecutableFile = (candidate: string | null | undefined): candidate is string => {
	if (!candidate) {
		return false;
	}

	try {
		accessSync(candidate, constants.X_OK);
		return true;
	} catch {
		return false;
	}
};

const isUsableDirectory = (candidate: string | null | undefined): candidate is string => {
	if (!candidate) {
		return false;
	}

	try {
		return statSync(candidate).isDirectory();
	} catch {
		return false;
	}
};

const listPythonCommandCandidates = (): string[] => {
	const candidates = [
		process.env.PYTHON3?.trim(),
		process.env.PYTHON?.trim(),
		"/usr/bin/python3",
		resolveCommandInPath("python3"),
		"/opt/homebrew/bin/python3",
		"/usr/local/bin/python3",
		resolveCommandInPath("python"),
		"/usr/bin/python",
	];

	const unique: string[] = [];
		for (const candidate of candidates) {
		if (!isExecutableFile(candidate) || unique.includes(candidate)) {
			continue;
		}

		unique.push(candidate);
	}

	return unique;
};

const resolveLauncherCwd = (): string => {
	const candidates = [
		process.cwd(),
		process.env.HOME?.trim(),
		"/tmp",
		"/",
	];

	for (const candidate of candidates) {
		if (isUsableDirectory(candidate)) {
			return candidate;
		}
	}

	return "/";
};

const buildTerminalEnvironment = (shell: string): NodeJS.ProcessEnv => {
	const env: NodeJS.ProcessEnv = {
		HOME: process.env.HOME?.trim() || "/",
		PATH: process.env.PATH?.trim() || "/usr/bin:/bin:/usr/sbin:/sbin",
		NODE_ENV: process.env.NODE_ENV ?? "development",
		SHELL: shell,
		TERM: "xterm-256color",
	};

	for (const key of ["USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "COLORTERM"]) {
		const value = process.env[key]?.trim();
		if (value) {
			env[key] = value;
		}
	}

	return env;
};

const ensurePythonBridgePath = (): string => {
	if (cachedPythonBridgePath && existsSync(cachedPythonBridgePath)) {
		return cachedPythonBridgePath;
	}

	if (existsSync(PYTHON_BRIDGE_CANDIDATE_PATH)) {
		cachedPythonBridgePath = PYTHON_BRIDGE_CANDIDATE_PATH;
		return cachedPythonBridgePath;
	}

	const bridgeDirectory = join(tmpdir(), "remotecode-terminal-bridge");
	const bridgePath = join(bridgeDirectory, "pty_session_bridge.py");
	mkdirSync(bridgeDirectory, { recursive: true });

	const existingSource = existsSync(bridgePath) ? readFileSync(bridgePath, "utf8") : null;
	if (existingSource !== PYTHON_BRIDGE_SOURCE) {
		writeFileSync(bridgePath, PYTHON_BRIDGE_SOURCE, "utf8");
		chmodSync(bridgePath, 0o755);
	}

	cachedPythonBridgePath = bridgePath;
	return bridgePath;
};

export const terminalSessionBridgeTestHarness = {
	clearCachedBridgePath() {
		cachedPythonBridgePath = null;
	},
	getCandidateBridgePath() {
		return PYTHON_BRIDGE_CANDIDATE_PATH;
	},
	getEmbeddedBridgeSource() {
		return PYTHON_BRIDGE_SOURCE;
	},
	resolvePythonBridgePath() {
		return ensurePythonBridgePath();
	},
};

const isExitedSnapshot = (snapshot: TerminalSessionSnapshotDTO): boolean => snapshot.status === "exited";

const normalizeViewport = (viewport?: TerminalViewport): Required<TerminalViewport> => ({
	cols:
		typeof viewport?.cols === "number" && Number.isFinite(viewport.cols) && viewport.cols > 0
			? Math.floor(viewport.cols)
			: DEFAULT_COLS,
	rows:
		typeof viewport?.rows === "number" && Number.isFinite(viewport.rows) && viewport.rows > 0
			? Math.floor(viewport.rows)
			: DEFAULT_ROWS,
});

const buildInteractiveShellArgs = (shell: string): string[] => {
	const shellName = basename(shell).toLowerCase();
	if (shellName.includes("zsh")) {
		return [shell, "-fi"];
	}

	if (shellName.includes("bash")) {
		return [shell, "--noprofile", "--norc", "-i"];
	}

	if (shellName.includes("ksh")) {
		return [shell, "-i"];
	}

	return [shell, "-i"];
};

const writeToHeadless = (terminal: Terminal, data: string): Promise<void> =>
	new Promise((resolve) => {
		terminal.write(data, () => {
			resolve();
		});
	});

const readLinuxProcessCwd = (pid: number): string | null => {
	try {
		return realpathSync(`/proc/${pid}/cwd`);
	} catch {
		return null;
	}
};

const readDarwinProcessCwd = (pid: number): string | null => {
	try {
		const result = Bun.spawnSync({
			cmd: ["lsof", "-a", "-d", "cwd", "-Fn", "-p", String(pid)],
			stderr: "ignore",
			stdout: "pipe",
		});
		if (result.exitCode !== 0) {
			return null;
		}

		const output = new TextDecoder().decode(result.stdout);
		const entry = output
			.split("\n")
			.map((line) => line.trim())
			.find((line) => line.startsWith("n"));

		return entry ? entry.slice(1) || null : null;
	} catch {
		return null;
	}
};

const readProcessCwd = (pid: number, fallback: string): string => {
	if (!Number.isFinite(pid) || pid <= 0) {
		return fallback;
	}

	if (process.platform === "linux") {
		return readLinuxProcessCwd(pid) ?? fallback;
	}

	if (process.platform === "darwin") {
		return readDarwinProcessCwd(pid) ?? fallback;
	}

	return fallback;
};

type TerminalBridgeServerEvent =
	| {
			event: "exit";
			exitCode?: number | null;
	  }
	| {
			data?: string;
			event: "output";
	  }
	| {
			event: "ready";
			pid?: number;
	  };

type TerminalBridgeClientCommand =
	| {
			data: string;
			event: "write";
	  }
	| {
			event: "close";
	  }
	| {
			event: "resize";
			cols: number;
			rows: number;
	  }
	| {
			event: "signal";
			signal: TerminalSessionSignal | "SIGKILL";
	  };

const parseBridgeServerEvent = (line: string): TerminalBridgeServerEvent | null => {
	if (!line) {
		return null;
	}

	try {
		const payload = JSON.parse(line) as Record<string, unknown>;
		if (payload.event === "ready") {
			return {
				event: "ready",
				pid: typeof payload.pid === "number" && Number.isFinite(payload.pid) ? Math.floor(payload.pid) : undefined,
			};
		}

		if (payload.event === "output") {
			return {
				data: typeof payload.data === "string" ? payload.data : undefined,
				event: "output",
			};
		}

		if (payload.event === "exit") {
			return {
				event: "exit",
				exitCode:
					typeof payload.exitCode === "number" && Number.isFinite(payload.exitCode)
						? Math.floor(payload.exitCode)
						: null,
			};
		}

		return null;
	} catch {
		return null;
	}
};

const waitForProcessExit = (subprocess: ChildProcessByStdio<Writable, Readable, Readable>): Promise<number | null> =>
	new Promise((resolve, reject) => {
		const handleExit = (code: number | null, signal: NodeJS.Signals | null) => {
			cleanup();
			if (typeof code === "number") {
				resolve(code);
				return;
			}

			if (signal) {
				const signalNumber = osConstants.signals[signal];
				resolve(typeof signalNumber === "number" ? 128 + signalNumber : null);
				return;
			}

			resolve(null);
		};
		const handleError = (error: Error) => {
			cleanup();
			reject(error);
		};
		const cleanup = () => {
			subprocess.off("error", handleError);
			subprocess.off("exit", handleExit);
		};

		subprocess.once("error", handleError);
		subprocess.once("exit", handleExit);
	});

interface ActiveTerminalSession {
	cols: number;
	controlQueue: Promise<void>;
	cwd: string;
	exitCode: number | null;
	exitPromise: Promise<number | null>;
	exitedAt: string | null;
	finalizePromise: Promise<void>;
	helperStderrBuffer: string;
	helperStdoutBuffer: string;
	hasReportedReady: boolean;
	isFinalized: boolean;
	lastKnownShellPid: number | null;
	outputPumpPromise: Promise<void>;
	persistOnExit: boolean;
	readyPromise: Promise<void>;
	reportedExitCode: number | null;
	resolveReady: (() => void) | null;
	screen: Terminal;
	serializeAddon: SerializeAddon;
	seq: number;
	sessionId: string;
	shell: string;
	startedAt: string;
	status: "running" | "exited";
	subprocess: ChildProcessByStdio<Writable, Readable, Readable>;
	writeQueue: Promise<void>;
}

export class TerminalSessionService implements TerminalSessionServiceContract {
	private readonly activeSessions = new Map<string, ActiveTerminalSession>();
	private readonly listeners = new Set<(event: TerminalSessionServerEvent) => void>();

	constructor(
		private readonly chatRepository: ChatRepository,
		private readonly projectRepository: ProjectRepository,
		private readonly terminalSessionRepository: TerminalSessionRepository,
	) {}

	private emit(event: TerminalSessionServerEvent): void {
		for (const listener of this.listeners) {
			listener(event);
		}
	}

	private async resolveProjectContext(chatId: string): Promise<{
		chatExists: boolean;
		cwd: string | null;
		projectExists: boolean;
	}> {
		const chat = await this.chatRepository.findChatById(chatId);
		if (!chat) {
			return { chatExists: false, cwd: null, projectExists: false };
		}

		const project = await this.projectRepository.findProjectById(chat.projectId);
		if (!project) {
			serverLogger.warn(TERMINAL_LOG_SCOPE, "project missing for terminal chat", { chatId });
			return { chatExists: true, cwd: null, projectExists: false };
		}

		if (!isUsableDirectory(project.path)) {
			serverLogger.warn(TERMINAL_LOG_SCOPE, "project path unavailable for terminal session", {
				chatId,
				projectId: project.id,
				projectPath: project.path,
			});
			return { chatExists: true, cwd: null, projectExists: false };
		}

		return { chatExists: true, cwd: project.path, projectExists: true };
	}

	private toSnapshotDto(
		chatId: string,
		session: ActiveTerminalSession,
		snapshot: string,
	): TerminalSessionSnapshotDTO {
		return {
			chatId,
			cols: session.cols,
			cwd: session.cwd,
			exitCode: session.exitCode,
			exitedAt: session.exitedAt,
			rows: session.screen.rows,
			seq: session.seq,
			sessionId: session.sessionId,
			shell: session.shell,
			snapshot,
			startedAt: session.startedAt,
			status: session.status,
		};
	}

	private toStateDto(chatId: string, session: ActiveTerminalSession): TerminalSessionStateDTO {
		return {
			chatId,
			cols: session.cols,
			cwd: session.cwd,
			exitCode: session.exitCode,
			exitedAt: session.exitedAt,
			rows: session.screen.rows,
			seq: session.seq,
			sessionId: session.sessionId,
			shell: session.shell,
			startedAt: session.startedAt,
			status: session.status,
		};
	}

	private async refreshSessionCwd(session: ActiveTerminalSession): Promise<boolean> {
		const nextCwd = readProcessCwd(session.lastKnownShellPid ?? session.subprocess.pid ?? 0, session.cwd);
		if (nextCwd === session.cwd) {
			return false;
		}

		session.cwd = nextCwd;
		return true;
	}

	private sendBridgeCommand(session: ActiveTerminalSession, command: TerminalBridgeClientCommand): Promise<void> {
		if (session.isFinalized || !session.subprocess.stdin) {
			return Promise.resolve();
		}

		const payload = `${JSON.stringify(command)}\n`;
		session.controlQueue = session.controlQueue.then(async () => {
			await new Promise<void>((resolve, reject) => {
				session.subprocess.stdin.write(payload, (error) => {
					if (error) {
						reject(error);
						return;
					}

					resolve();
				});
			});
		});
		return session.controlQueue;
	}

	private handleBridgeServerEvent(chatId: string, session: ActiveTerminalSession, event: TerminalBridgeServerEvent): void {
		if (event.event === "ready") {
			serverLogger.info(TERMINAL_LOG_SCOPE, "terminal bridge ready", {
				chatId,
				pid: event.pid,
				sessionId: session.sessionId,
			});
			session.hasReportedReady = true;
			if (typeof event.pid === "number" && Number.isFinite(event.pid) && event.pid > 0) {
				session.lastKnownShellPid = event.pid;
				void this.refreshSessionCwd(session);
			}
			session.resolveReady?.();
			session.resolveReady = null;
			return;
		}

		if (event.event === "output") {
			if (!event.data) {
				return;
			}

			try {
				const chunk = Buffer.from(event.data, "base64").toString("utf8");
				if (session.seq < 3) {
					serverLogger.debug(TERMINAL_LOG_SCOPE, "terminal output chunk", {
						chatId,
						preview: chunk.slice(0, 160),
						sessionId: session.sessionId,
						size: chunk.length,
					});
				}
				this.emitTerminalOutput(chatId, session, chunk);
			} catch {
				serverLogger.warn(TERMINAL_LOG_SCOPE, "malformed bridge output ignored", {
					chatId,
					sessionId: session.sessionId,
				});
				// ignore malformed bridge output
			}
			return;
		}

		serverLogger.info(TERMINAL_LOG_SCOPE, "terminal bridge exit reported", {
			chatId,
			exitCode: event.exitCode ?? null,
			sessionId: session.sessionId,
		});
		session.reportedExitCode = event.exitCode ?? null;
	}

	private consumeBridgeStdout(chatId: string, session: ActiveTerminalSession): Promise<void> {
		const stdout = session.subprocess.stdout;
		if (!stdout) {
			return Promise.resolve();
		}
		const decoder = new TextDecoder();


		return new Promise<void>((resolve) => {
			const flushBuffer = (finalChunk = false) => {
				if (finalChunk) {
					session.helperStdoutBuffer += decoder.decode();
				}

				while (true) {
					const newlineIndex = session.helperStdoutBuffer.indexOf("\n");
					if (newlineIndex < 0) {
						break;
					}

					const line = session.helperStdoutBuffer.slice(0, newlineIndex).trim();
					session.helperStdoutBuffer = session.helperStdoutBuffer.slice(newlineIndex + 1);
					const event = parseBridgeServerEvent(line);
					if (event) {
						this.handleBridgeServerEvent(chatId, session, event);
					} else if (!session.hasReportedReady && line.length > 0) {
						serverLogger.warn(TERMINAL_LOG_SCOPE, "unparsed terminal bridge stdout line before ready", {
							chatId,
							line,
							sessionId: session.sessionId,
						});
					}
				}

				if (!finalChunk) {
					return;
				}

				const trailing = session.helperStdoutBuffer.trim();
				if (trailing) {
					const event = parseBridgeServerEvent(trailing);
					if (event) {
						this.handleBridgeServerEvent(chatId, session, event);
					} else if (!session.hasReportedReady) {
						serverLogger.warn(TERMINAL_LOG_SCOPE, "unparsed terminal bridge trailing stdout before ready", {
							chatId,
							sessionId: session.sessionId,
							trailing,
						});
					}
				}
				session.helperStdoutBuffer = "";
			};

			const handleData = (chunk: string | Buffer) => {
				const value = typeof chunk === "string" ? chunk : decoder.decode(chunk, { stream: true });
				session.helperStdoutBuffer += value;
				flushBuffer();
			};
			const handleStderr = (chunk: string | Buffer) => {
				const value = typeof chunk === "string" ? chunk : Buffer.from(chunk).toString("utf8");
				session.helperStderrBuffer = `${session.helperStderrBuffer}${value}`.slice(-8_192);
			};
			const handleClose = () => {
				cleanup();
				flushBuffer(true);
				if (!session.hasReportedReady) {
					serverLogger.warn(TERMINAL_LOG_SCOPE, "terminal bridge stdout closed before ready", {
						chatId,
						sessionId: session.sessionId,
					});
				}
				resolve();
			};
			const cleanup = () => {
				stdout.off("data", handleData);
				stdout.off("close", handleClose);
				stdout.off("end", handleClose);
				stdout.off("error", handleClose);
				session.subprocess.stderr.off("data", handleStderr);
			};

			stdout.on("data", handleData);
			stdout.once("close", handleClose);
			stdout.once("end", handleClose);
			stdout.once("error", handleClose);
			session.subprocess.stderr.on("data", handleStderr);
		});
	}

	private scheduleCwdRefresh(chatId: string, session: ActiveTerminalSession): void {
		const refresh = async () => {
			if (session.isFinalized) {
				return;
			}

			const changed = await this.refreshSessionCwd(session);
			if (!changed) {
				return;
			}

			this.emit({
				data: this.toStateDto(chatId, session),
				event: "terminal_session_state",
			});
		};

		void refresh();
		setTimeout(() => {
			void refresh();
		}, 150);
		setTimeout(() => {
			void refresh();
		}, 600);
	}

	private async captureSnapshot(chatId: string, session: ActiveTerminalSession): Promise<TerminalSessionSnapshotDTO> {
		await session.writeQueue;
		await this.refreshSessionCwd(session);
		return this.toSnapshotDto(chatId, session, session.serializeAddon.serialize());
	}

	private emitTerminalOutput(
		chatId: string,
		session: ActiveTerminalSession,
		data: string,
	): void {
		if (!data || data.length === 0 || session.isFinalized) {
			return;
		}

		session.seq += 1;
		session.writeQueue = session.writeQueue.then(() => writeToHeadless(session.screen, data));
		this.emit({
			data: {
				chatId,
				data,
				seq: session.seq,
				sessionId: session.sessionId,
			},
			event: "terminal_output",
		});
	}

	private async finalizeSession(
		chatId: string,
		session: ActiveTerminalSession,
		exitCode: number | null,
	): Promise<void> {
		if (session.isFinalized) {
			return;
		}

		session.isFinalized = true;
		session.status = "exited";
		session.exitCode = session.reportedExitCode ?? exitCode;
		session.exitedAt = new Date().toISOString();
		serverLogger.info(TERMINAL_LOG_SCOPE, "terminal session finalizing", {
			chatId,
			cwd: session.cwd,
			exitCode: session.exitCode,
			persistOnExit: session.persistOnExit,
			sessionId: session.sessionId,
		});

		try {
			await session.outputPumpPromise.catch(() => undefined);
			await session.writeQueue;
			const snapshot = await this.captureSnapshot(chatId, session);
			if (session.persistOnExit) {
				this.terminalSessionRepository.saveSnapshot(snapshot);
			}

			this.emit({
				data: this.toStateDto(chatId, session),
				event: "terminal_session_state",
			});
		} finally {
			this.activeSessions.delete(chatId);
		}
	}

	private async createSession(chatId: string, cwd: string, viewport?: TerminalViewport): Promise<ActiveTerminalSession> {
		const size = normalizeViewport(viewport);
		const launcherCwd = resolveLauncherCwd();
		const pythonCandidates = listPythonCommandCandidates();
		const pythonBridgePath = ensurePythonBridgePath();
		const shell = resolveShell();
		const shellArgs = buildInteractiveShellArgs(shell);
		const terminalEnv = buildTerminalEnvironment(shell);
		serverLogger.info(TERMINAL_LOG_SCOPE, "creating terminal session", {
			chatId,
			cwd,
			launcherCwd,
			pythonCandidates: pythonCandidates.join(", "),
			pythonBridgePath,
			rows: size.rows,
			shell,
			cols: size.cols,
		});
		const screen = new Terminal({
			allowProposedApi: true,
			cols: size.cols,
			rows: size.rows,
			scrollback: DEFAULT_SCROLLBACK,
		});
		const serializeAddon = new SerializeAddon();
		screen.loadAddon(serializeAddon);

		const session: ActiveTerminalSession = {
			cols: size.cols,
			controlQueue: Promise.resolve(),
			cwd,
			exitCode: null,
			exitPromise: Promise.resolve(null),
			exitedAt: null,
			finalizePromise: Promise.resolve(),
			helperStderrBuffer: "",
			helperStdoutBuffer: "",
			hasReportedReady: false,
			isFinalized: false,
			lastKnownShellPid: null,
			outputPumpPromise: Promise.resolve(),
			persistOnExit: true,
			readyPromise: Promise.resolve(),
			reportedExitCode: null,
			resolveReady: null,
			screen,
			serializeAddon,
			seq: 0,
			sessionId: randomUUID(),
			shell,
			startedAt: new Date().toISOString(),
			status: "running",
			subprocess: {} as ChildProcessByStdio<Writable, Readable, Readable>,
			writeQueue: Promise.resolve(),
		};
		session.readyPromise = new Promise<void>((resolve) => {
			session.resolveReady = resolve;
		});

		const bridgeConfig = Buffer.from(
			JSON.stringify({
				argv: shellArgs,
				cols: size.cols,
				cwd,
				env: terminalEnv,
				rows: size.rows,
			}),
		).toString("base64");

		let subprocess: ChildProcessByStdio<Writable, Readable, Readable> | null = null;
		const spawnErrors: string[] = [];

		for (const pythonCommand of pythonCandidates) {
			session.helperStderrBuffer = "";
			session.helperStdoutBuffer = "";
			session.hasReportedReady = false;
			session.reportedExitCode = null;
			session.readyPromise = new Promise<void>((resolve) => {
				session.resolveReady = resolve;
			});

			try {
				serverLogger.debug(TERMINAL_LOG_SCOPE, "spawning terminal bridge candidate", {
					chatId,
					launcherCwd,
					pythonCommand,
					sessionCwd: cwd,
				});
				const candidateProcess = spawnChildProcess(
					pythonCommand,
					[pythonBridgePath, bridgeConfig],
					{
						cwd: launcherCwd,
						env: terminalEnv,
						stdio: ["pipe", "pipe", "pipe"],
					},
				);

				session.subprocess = candidateProcess;
				session.exitPromise = waitForProcessExit(candidateProcess);
				session.outputPumpPromise = this.consumeBridgeStdout(chatId, session);

				const readiness = await Promise.race([
					session.readyPromise.then(() => "ready" as const),
					session.exitPromise.then(() => "exited" as const),
					new Promise<"timeout">((resolve) => {
						setTimeout(() => {
							resolve("timeout");
						}, 1_500);
					}),
				]);

				if (readiness === "ready") {
					serverLogger.success(TERMINAL_LOG_SCOPE, "terminal bridge candidate started", {
						chatId,
						pythonCommand,
						sessionId: session.sessionId,
					});
					subprocess = candidateProcess;
					break;
				}

				try {
					killProcess(candidateProcess, "force");
				} catch {
					// ignore failed candidate cleanup
				}
				await session.exitPromise.catch(() => undefined);
				await session.outputPumpPromise.catch(() => undefined);
				const stderrText = session.helperStderrBuffer.trim();
				serverLogger.warn(TERMINAL_LOG_SCOPE, "terminal bridge candidate failed readiness", {
					chatId,
					launcherCwd,
					pythonCommand,
					readiness,
					sessionCwd: cwd,
					stderr: stderrText || undefined,
				});
				spawnErrors.push(
					`${pythonCommand}: ${readiness} (launcherCwd=${launcherCwd}, sessionCwd=${cwd})${stderrText ? ` (${stderrText})` : ""}`,
				);
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				serverLogger.warn(TERMINAL_LOG_SCOPE, "terminal bridge candidate spawn threw", {
					chatId,
					launcherCwd,
					pythonCommand,
					sessionCwd: cwd,
					error: message,
				});
				spawnErrors.push(`${pythonCommand}: ${message} (launcherCwd=${launcherCwd}, sessionCwd=${cwd})`);
			}
		}

		if (!subprocess) {
			serverLogger.error(TERMINAL_LOG_SCOPE, "unable to start terminal bridge", {
				chatId,
				cwd,
				errors: spawnErrors.join(" | "),
				launcherCwd,
				pythonCandidates: pythonCandidates.join(", "),
			});
			throw new Error(
				`unable to start terminal bridge python process. Tried: ${pythonCandidates.join(", ")}. Errors: ${spawnErrors.join(" | ")}`,
			);
		}

		session.subprocess = subprocess;
		session.exitPromise = waitForProcessExit(subprocess);
		session.finalizePromise = session.exitPromise.then(async (exitCode) => {
			await this.finalizeSession(chatId, session, exitCode);
		}).catch(async () => {
			await this.finalizeSession(chatId, session, null);
		});

		this.activeSessions.set(chatId, session);
		this.terminalSessionRepository.deleteByChatId(chatId);
		this.emit({
			data: this.toStateDto(chatId, session),
			event: "terminal_session_state",
		});

		return session;
	}

	private async getActiveOrCreate(
		chatId: string,
		viewport?: TerminalViewport,
	): Promise<{ chatExists: boolean; created: boolean; projectExists: boolean; session: ActiveTerminalSession | null }> {
		const active = this.activeSessions.get(chatId);
		if (active) {
			if (viewport) {
				await this.applyViewport(chatId, active, normalizeViewport(viewport));
			}

			return { chatExists: true, created: false, projectExists: true, session: active };
		}

		const context = await this.resolveProjectContext(chatId);
		if (!context.chatExists || !context.projectExists || !context.cwd) {
			return {
				chatExists: context.chatExists,
				created: false,
				projectExists: context.projectExists,
				session: null,
			};
		}

		return {
			chatExists: true,
			created: true,
			projectExists: true,
			session: await this.createSession(chatId, context.cwd, viewport),
		};
	}

	private async applyViewport(
		chatId: string,
		session: ActiveTerminalSession,
		viewport: Required<TerminalViewport>,
	): Promise<TerminalSessionStateDTO> {
		session.cols = viewport.cols;
		session.screen.resize(viewport.cols, viewport.rows);
		await session.readyPromise;
		await this.sendBridgeCommand(session, {
			cols: viewport.cols,
			event: "resize",
			rows: viewport.rows,
		});
		const state = this.toStateDto(chatId, session);
		this.emit({
			data: state,
			event: "terminal_session_state",
		});
		return state;
	}

	private async terminateSession(session: ActiveTerminalSession, intent: "force" | "graceful"): Promise<void> {
		try {
			await session.readyPromise;
			await this.sendBridgeCommand(session, {
				event: "signal",
				signal: intent === "force" ? "SIGKILL" : "SIGTERM",
			});
			await this.sendBridgeCommand(session, { event: "close" });
		} catch {
			// ignore bridge shutdown failures
		}

		try {
			killProcess(session.subprocess, intent);
		} catch {
			// ignore cleanup failures
		}
	}

	async cleanupChat(chatId: string): Promise<void> {
		const session = this.activeSessions.get(chatId);
		if (session) {
			session.persistOnExit = false;
			await this.terminateSession(session, "graceful");
			await session.finalizePromise.catch(() => undefined);
		}

		this.terminalSessionRepository.deleteByChatId(chatId);
	}

	async getOrCreateSessionSnapshot(chatId: string, viewport?: TerminalViewport): Promise<TerminalSessionJoinResult> {
		serverLogger.debug(TERMINAL_LOG_SCOPE, "join terminal session requested", {
			chatId,
			cols: viewport?.cols,
			rows: viewport?.rows,
		});
		const active = this.activeSessions.get(chatId);
		if (active) {
			if (viewport) {
				await this.applyViewport(chatId, active, normalizeViewport(viewport));
			}

			return {
				chatExists: true,
				projectExists: true,
				snapshot: await this.captureSnapshot(chatId, active),
			};
		}

		const persisted = this.terminalSessionRepository.findSnapshotByChatId(chatId);
		if (persisted) {
			if (isExitedSnapshot(persisted)) {
				serverLogger.warn(TERMINAL_LOG_SCOPE, "discarding exited terminal snapshot before fresh join", {
					chatId,
					exitCode: persisted.exitCode,
					exitedAt: persisted.exitedAt,
					seq: persisted.seq,
					sessionId: persisted.sessionId,
				});
				this.terminalSessionRepository.deleteByChatId(chatId);
			} else {
				return {
					chatExists: true,
					projectExists: true,
					snapshot: persisted,
				};
			}
		}

		const result = await this.getActiveOrCreate(chatId, viewport);
		if (!result.chatExists || !result.projectExists || !result.session) {
			return {
				chatExists: result.chatExists,
				projectExists: result.projectExists,
				snapshot: null,
			};
		}

		return {
			chatExists: true,
			projectExists: true,
			snapshot: await this.captureSnapshot(chatId, result.session),
		};
	}

	async restartSession(chatId: string, viewport?: TerminalViewport): Promise<TerminalSessionJoinResult> {
		await this.cleanupChat(chatId);
		return await this.getOrCreateSessionSnapshot(chatId, viewport);
	}

	async sendInput(chatId: string, data: string, viewport?: TerminalViewport): Promise<TerminalSessionInputResult> {
		serverLogger.debug(TERMINAL_LOG_SCOPE, "terminal input requested", {
			chatId,
			dataLength: data.length,
			hasNewline: data.includes("\n") || data.includes("\r"),
			preview: data.slice(0, 80),
		});
		if (!this.activeSessions.has(chatId) && this.terminalSessionRepository.findSnapshotByChatId(chatId)) {
			return {
				chatExists: true,
				createdSnapshot: null,
				projectExists: true,
				state: "session_exited",
			};
		}

		const result = await this.getActiveOrCreate(chatId, viewport);
		if (!result.chatExists || !result.projectExists || !result.session) {
			return {
				chatExists: result.chatExists,
				createdSnapshot: null,
				projectExists: result.projectExists,
				state: "session_exited",
			};
		}

		await result.session.readyPromise;
		await this.sendBridgeCommand(result.session, {
			data: Buffer.from(data, "utf8").toString("base64"),
			event: "write",
		});
		if (data.includes("\n") || data.includes("\r")) {
			this.scheduleCwdRefresh(chatId, result.session);
		}

		return {
			chatExists: true,
			createdSnapshot: result.created ? await this.captureSnapshot(chatId, result.session) : null,
			projectExists: true,
			state: "sent",
		};
	}

	async sendSignal(chatId: string, signal: TerminalSessionSignal): Promise<TerminalSessionActionResult> {
		serverLogger.info(TERMINAL_LOG_SCOPE, "terminal signal requested", {
			chatId,
			signal,
		});
		const session = this.activeSessions.get(chatId);
		if (!session) {
			const context = await this.resolveProjectContext(chatId);
			return {
				chatExists: context.chatExists,
				projectExists: context.projectExists,
				state: null,
			};
		}

		await session.readyPromise;
		await this.sendBridgeCommand(session, {
			event: "signal",
			signal,
		});

		this.scheduleCwdRefresh(chatId, session);

		return {
			chatExists: true,
			projectExists: true,
			state: this.toStateDto(chatId, session),
		};
	}

	async setViewport(chatId: string, viewport: Required<TerminalViewport>): Promise<TerminalSessionActionResult> {
		const active = this.activeSessions.get(chatId);
		if (active) {
			return {
				chatExists: true,
				projectExists: true,
				state: await this.applyViewport(chatId, active, viewport),
			};
		}

		const persisted = this.terminalSessionRepository.findSnapshotByChatId(chatId);
		if (persisted) {
			return {
				chatExists: true,
				projectExists: true,
				state: this.terminalSessionRepository.toStateDto({
					...persisted,
					cols: viewport.cols,
					rows: viewport.rows,
				}),
			};
		}

		const context = await this.resolveProjectContext(chatId);
		return {
			chatExists: context.chatExists,
			projectExists: context.projectExists,
			state: null,
		};
	}

	async shutdown(): Promise<void> {
		await Promise.all(
			Array.from(this.activeSessions.values()).map(async (session) => {
				await this.terminateSession(session, "force");
				await session.finalizePromise.catch(() => undefined);
			}),
		);
	}

	subscribe(listener: (event: TerminalSessionServerEvent) => void): () => void {
		this.listeners.add(listener);
		return () => {
			this.listeners.delete(listener);
		};
	}
}

export const createTerminalSessionService = (repositories: {
	chat: ChatRepository;
	project: ProjectRepository;
	terminalSession: TerminalSessionRepository;
}) => new TerminalSessionService(repositories.chat, repositories.project, repositories.terminalSession);
