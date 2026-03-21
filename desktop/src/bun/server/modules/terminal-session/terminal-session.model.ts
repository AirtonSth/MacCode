import type { ServerWsEvent, TerminalSessionSnapshotDTO, TerminalSessionStateDTO } from "../../types";

export interface TerminalViewport {
	cols?: number;
	rows?: number;
}

export interface TerminalSessionJoinResult {
	chatExists: boolean;
	projectExists: boolean;
	snapshot: TerminalSessionSnapshotDTO | null;
}

export interface TerminalSessionInputResult {
	chatExists: boolean;
	createdSnapshot: TerminalSessionSnapshotDTO | null;
	projectExists: boolean;
	state: "sent" | "session_exited";
}

export interface TerminalSessionActionResult {
	chatExists: boolean;
	projectExists: boolean;
	state: TerminalSessionStateDTO | null;
}

export type TerminalSessionSignal = "SIGINT" | "SIGTERM";

export type TerminalSessionServerEvent = Extract<
	ServerWsEvent,
	{ event: "terminal_output" | "terminal_session_snapshot" | "terminal_session_state" }
>;

export interface TerminalSessionServiceContract {
	cleanupChat: (chatId: string) => Promise<void>;
	getOrCreateSessionSnapshot: (chatId: string, viewport?: TerminalViewport) => Promise<TerminalSessionJoinResult>;
	restartSession: (chatId: string, viewport?: TerminalViewport) => Promise<TerminalSessionJoinResult>;
	sendInput: (chatId: string, data: string, viewport?: TerminalViewport) => Promise<TerminalSessionInputResult>;
	sendSignal: (chatId: string, signal: TerminalSessionSignal) => Promise<TerminalSessionActionResult>;
	setViewport: (chatId: string, viewport: Required<TerminalViewport>) => Promise<TerminalSessionActionResult>;
	shutdown: () => Promise<void>;
	subscribe: (listener: (event: TerminalSessionServerEvent) => void) => () => void;
}
