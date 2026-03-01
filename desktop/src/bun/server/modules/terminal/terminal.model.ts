import type { TerminalCommandDTO, TerminalEntryDTO } from "../../types";

export interface TerminalHistoryQuery {
	cursor?: number;
	limit?: number;
}

export interface TerminalHistoryResult {
	chatExists: boolean;
	commands: TerminalCommandDTO[];
	entries: TerminalEntryDTO[];
}

export interface TerminalExecInput {
	chatId: string;
	command: string;
	timeoutMs?: number;
}

export interface TerminalExecResult {
	chatExists: boolean;
	command: TerminalCommandDTO | null;
	entries: TerminalEntryDTO[];
	projectExists: boolean;
}

export interface TerminalServiceContract {
	execCommand: (input: TerminalExecInput) => Promise<TerminalExecResult>;
	getHistoryByChatId: (chatId: string, query?: TerminalHistoryQuery) => Promise<TerminalHistoryResult>;
}
