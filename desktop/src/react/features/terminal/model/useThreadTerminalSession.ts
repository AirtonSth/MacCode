import { useRef, useState } from "react";

import type {
	TerminalCommandDTO,
	TerminalEntryDTO,
	TerminalExecDTO,
	TerminalHistoryDTO,
} from "../../../shared/api/remotecode-http";

export interface TerminalDisplayItem {
	commandId: string;
	id: string;
	kind: "command" | "stdout" | "stderr";
	status?: TerminalCommandDTO["status"];
	text: string;
}

export interface ThreadTerminalChatState {
	cursor: number;
	entriesById: Record<number, TerminalEntryDTO>;
	commandsById: Record<string, TerminalCommandDTO>;
	error: string | null;
	isExecuting: boolean;
	isLoading: boolean;
	isOpen: boolean;
	items: TerminalDisplayItem[];
}

export interface ThreadTerminalState {
	chats: Record<string, ThreadTerminalChatState>;
}

export interface ThreadTerminalSessionDependencies {
	execCommand: (chatId: string, input: { command: string; timeoutMs?: number }) => Promise<TerminalExecDTO>;
	getHistory: (chatId: string, options?: { cursor?: number; limit?: number }) => Promise<TerminalHistoryDTO>;
	historyLimit?: number;
	onError?: (message: string) => void;
}

export interface ThreadTerminalSessionController {
	getState: () => ThreadTerminalState;
	subscribe: (listener: () => void) => () => void;
	setOpen: (chatId: string, open: boolean) => void;
	syncHistory: (chatId: string) => Promise<void>;
	runCommand: (chatId: string, command: string, options?: { timeoutMs?: number }) => Promise<void>;
}

const DEFAULT_HISTORY_LIMIT = 1_000;

const createEmptyChatState = (): ThreadTerminalChatState => ({
	cursor: 0,
	entriesById: {},
	commandsById: {},
	error: null,
	isExecuting: false,
	isLoading: false,
	isOpen: false,
	items: [],
});

const buildDisplayItems = (
	commandsById: Record<string, TerminalCommandDTO>,
	entriesById: Record<number, TerminalEntryDTO>,
): TerminalDisplayItem[] => {
	const commands = Object.values(commandsById).sort((a, b) => {
		if (a.startedAt === b.startedAt) {
			return a.id.localeCompare(b.id);
		}

		return a.startedAt.localeCompare(b.startedAt);
	});
	const entries = Object.values(entriesById).sort((a, b) => a.id - b.id);

	const byCommandId: Record<string, TerminalEntryDTO[]> = {};
	for (const entry of entries) {
		byCommandId[entry.commandId] = byCommandId[entry.commandId] ?? [];
		byCommandId[entry.commandId]?.push(entry);
	}

	const items: TerminalDisplayItem[] = [];
	for (const command of commands) {
		items.push({
			commandId: command.id,
			id: `cmd:${command.id}`,
			kind: "command",
			status: command.status,
			text: `$ ${command.command}`,
		});

		for (const entry of byCommandId[command.id] ?? []) {
			items.push({
				commandId: entry.commandId,
				id: `entry:${entry.id}`,
				kind: entry.stream,
				text: entry.data,
			});
		}
	}

	const knownCommandIds = new Set(commands.map((command) => command.id));
	for (const entry of entries) {
		if (knownCommandIds.has(entry.commandId)) {
			continue;
		}

		items.push({
			commandId: entry.commandId,
			id: `orphan:${entry.id}`,
			kind: entry.stream,
			text: entry.data,
		});
	}

	return items;
};

const mergeChatHistory = (chat: ThreadTerminalChatState, history: TerminalHistoryDTO): ThreadTerminalChatState => {
	const commandsById = { ...chat.commandsById };
	for (const command of history.commands) {
		commandsById[command.id] = command;
	}

	const entriesById = { ...chat.entriesById };
	let cursor = chat.cursor;
	for (const entry of history.entries) {
		entriesById[entry.id] = entry;
		cursor = Math.max(cursor, entry.id);
	}

	return {
		...chat,
		commandsById,
		cursor,
		entriesById,
		items: buildDisplayItems(commandsById, entriesById),
	};
};

export const createInitialThreadTerminalState = (): ThreadTerminalState => ({
	chats: {},
});

export const createThreadTerminalSessionController = (
	getDependencies: () => ThreadTerminalSessionDependencies,
	initialState: ThreadTerminalState = createInitialThreadTerminalState(),
): ThreadTerminalSessionController => {
	let state = initialState;
	const listeners = new Set<() => void>();
	const syncPromisesByChatId = new Map<string, Promise<void>>();

	const notify = () => {
		for (const listener of listeners) {
			listener();
		}
	};

	const getChat = (chatId: string): ThreadTerminalChatState => state.chats[chatId] ?? createEmptyChatState();

	const updateChat = (chatId: string, updater: (chat: ThreadTerminalChatState) => ThreadTerminalChatState) => {
		const current = getChat(chatId);
		const updated = updater(current);
		state = {
			...state,
			chats: {
				...state.chats,
				[chatId]: updated,
			},
		};
		notify();
	};

	return {
		getState: () => state,

		subscribe: (listener: () => void) => {
			listeners.add(listener);
			return () => {
				listeners.delete(listener);
			};
		},

		setOpen: (chatId: string, open: boolean) => {
			updateChat(chatId, (chat) => ({
				...chat,
				isOpen: open,
			}));
		},

		syncHistory: async (chatId: string) => {
			const pending = syncPromisesByChatId.get(chatId);
			if (pending) {
				return pending;
			}

			const task = (async () => {
				const dependencies = getDependencies();
				const current = getChat(chatId);
				updateChat(chatId, (chat) => ({
					...chat,
					error: null,
					isLoading: true,
				}));

				try {
					const history = await dependencies.getHistory(chatId, {
						cursor: current.cursor > 0 ? current.cursor : undefined,
						limit: dependencies.historyLimit ?? DEFAULT_HISTORY_LIMIT,
					});

					updateChat(chatId, (chat) => ({
						...mergeChatHistory(chat, history),
						error: null,
						isLoading: false,
					}));
				} catch (error) {
					const message = error instanceof Error ? error.message : "Unable to load terminal history";
					updateChat(chatId, (chat) => ({
						...chat,
						error: message,
						isLoading: false,
					}));
					dependencies.onError?.(message);
				}
			})();

			syncPromisesByChatId.set(chatId, task);
			await task.finally(() => {
				syncPromisesByChatId.delete(chatId);
			});
		},

		runCommand: async (chatId: string, command: string, options?: { timeoutMs?: number }) => {
			const trimmed = command.trim();
			if (!trimmed) {
				return;
			}

			const dependencies = getDependencies();
			const optimisticId = `optimistic:${Date.now().toString()}-${Math.random().toString(16).slice(2, 6)}`;
			updateChat(chatId, (chat) => ({
				...chat,
				error: null,
				isExecuting: true,
				items: [
					...chat.items,
					{
						commandId: optimisticId,
						id: optimisticId,
						kind: "command",
						status: "running",
						text: `$ ${trimmed}`,
					},
				],
			}));

			try {
				const executed = await dependencies.execCommand(chatId, {
					command: trimmed,
					timeoutMs: options?.timeoutMs,
				});

				updateChat(chatId, (chat) => {
					const merged = mergeChatHistory(chat, {
						commands: [executed.command],
						entries: executed.entries,
					});

					return {
						...merged,
						error: null,
						isExecuting: false,
						items: merged.items.filter((item) => item.id !== optimisticId),
					};
				});
			} catch (error) {
				const message = error instanceof Error ? error.message : "Unable to execute terminal command";
				updateChat(chatId, (chat) => ({
					...chat,
					error: message,
					isExecuting: false,
					items: chat.items.filter((item) => item.id !== optimisticId),
				}));
				dependencies.onError?.(message);
			}
		},
	};
};

export interface UseThreadTerminalSessionResult {
	state: ThreadTerminalState;
	setOpen: (chatId: string, open: boolean) => void;
	syncHistory: (chatId: string) => Promise<void>;
	runCommand: (chatId: string, command: string, options?: { timeoutMs?: number }) => Promise<void>;
}

export const useThreadTerminalSession = (
	dependencies: ThreadTerminalSessionDependencies,
): UseThreadTerminalSessionResult => {
	const dependenciesRef = useRef(dependencies);
	dependenciesRef.current = dependencies;

	const controllerRef = useRef<ThreadTerminalSessionController | null>(null);
	const [, forceRender] = useState(0);

	if (!controllerRef.current) {
		controllerRef.current = createThreadTerminalSessionController(() => dependenciesRef.current);
		controllerRef.current.subscribe(() => {
			forceRender((value) => value + 1);
		});
	}

	return {
		state: controllerRef.current.getState(),
		setOpen: controllerRef.current.setOpen,
		syncHistory: controllerRef.current.syncHistory,
		runCommand: controllerRef.current.runCommand,
	};
};
