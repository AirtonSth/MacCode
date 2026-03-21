/* eslint-disable functional/no-let, max-lines */
import type {
	ServerWsEvent,
	TerminalSessionSnapshotDto,
	TerminalSessionStateDto,
	TerminalSessionStatus,
} from "./protocol";

export interface TerminalViewport {
	cols: number;
	rows: number;
}

export interface TerminalSessionOutputChunk {
	data: string;
	id: string;
	seq: number;
	sessionId: string;
}

export interface TerminalSessionChatState {
	cols: number;
	cwd: string | null;
	error: string | null;
	exitCode: number | null;
	exitedAt: string | null;
	isOpen: boolean;
	lastOutput: TerminalSessionOutputChunk | null;
	rows: number;
	sessionId: string | null;
	shell: string | null;
	snapshot: string;
	snapshotSeq: number;
	startedAt: string | null;
	status: "idle" | "joining" | TerminalSessionStatus;
}

export interface TerminalSessionState {
	chats: Record<string, TerminalSessionChatState>;
}

export interface TerminalSessionControllerDependencies {
	join: (chatId: string, viewport?: TerminalViewport) => void;
	leave: (chatId: string) => void;
	restart: (chatId: string, viewport?: TerminalViewport) => void;
	sendInput: (chatId: string, data: string) => void;
	sendResize: (chatId: string, viewport: TerminalViewport) => void;
	sendSignal: (chatId: string, signal: "SIGINT" | "SIGTERM") => void;
}

export interface TerminalSessionController {
	applyServerEvent: (event: ServerWsEvent) => void;
	getState: () => TerminalSessionState;
	join: (chatId: string, viewport?: TerminalViewport) => void;
	leave: (chatId: string) => void;
	restart: (chatId: string, viewport?: TerminalViewport) => void;
	sendInput: (chatId: string, data: string) => void;
	sendResize: (chatId: string, viewport: TerminalViewport) => void;
	sendSignal: (chatId: string, signal: "SIGINT" | "SIGTERM") => void;
	setOpen: (chatId: string, open: boolean, viewport?: TerminalViewport) => void;
	subscribe: (listener: () => void) => () => void;
}

const defaultCols = 120;
const defaultRows = 32;
const minViewportCols = 20;
const minViewportRows = 8;

const normalizeViewport = (viewport?: TerminalViewport): TerminalViewport | undefined => {
	if (!viewport) {
		return undefined;
	}

	const cols = Math.max(minViewportCols, Math.floor(viewport.cols));
	const rows = Math.max(minViewportRows, Math.floor(viewport.rows));

	if (!Number.isFinite(cols) || !Number.isFinite(rows)) {
		return undefined;
	}

	return { cols, rows };
};

const createEmptyChatState = (): TerminalSessionChatState => ({
	cols: defaultCols,
	cwd: null,
	error: null,
	exitCode: null,
	exitedAt: null,
	isOpen: false,
	lastOutput: null,
	rows: defaultRows,
	sessionId: null,
	shell: null,
	snapshot: "",
	snapshotSeq: 0,
	startedAt: null,
	status: "idle",
});

const applySessionMetadata = (
	current: TerminalSessionChatState,
	payload: Pick<
		TerminalSessionStateDto,
		"cols" | "cwd" | "exitCode" | "exitedAt" | "rows" | "seq" | "sessionId" | "shell" | "startedAt" | "status"
	>,
): TerminalSessionChatState => ({
	...current,
	cols: payload.cols,
	cwd: payload.cwd,
	error: null,
	exitCode: payload.exitCode,
	exitedAt: payload.exitedAt,
	rows: payload.rows,
	sessionId: payload.sessionId,
	shell: payload.shell,
	snapshotSeq: Math.max(current.snapshotSeq, payload.seq),
	startedAt: payload.startedAt,
	status: payload.status,
});

const applySnapshot = (
	current: TerminalSessionChatState,
	payload: TerminalSessionSnapshotDto,
): TerminalSessionChatState => ({
	...applySessionMetadata(current, payload),
	lastOutput: null,
	snapshot: payload.snapshot,
	snapshotSeq: payload.seq,
	status: payload.status,
});

export const createInitialTerminalSessionState = (): TerminalSessionState => ({
	chats: {},
});

export const createTerminalSessionController = (
	getDependencies: () => TerminalSessionControllerDependencies,
	initialState: TerminalSessionState = createInitialTerminalSessionState(),
): TerminalSessionController => {
	let state = initialState;

	const listeners = new Set<() => void>();

	const notify = () => {
		listeners.forEach((listener) => {
			listener();
		});
	};

	const getChat = (chatId: string): TerminalSessionChatState => state.chats[chatId] ?? createEmptyChatState();

	const updateChat = (chatId: string, updater: (current: TerminalSessionChatState) => TerminalSessionChatState) => {
		state = {
			...state,

			chats: {
				...state.chats,
				[chatId]: updater(getChat(chatId)),
			},
		};
		notify();
	};

	return {
		applyServerEvent: (event: ServerWsEvent) => {
			if (event.event === "terminal_session_snapshot") {
				updateChat(event.data.chatId, (current) => applySnapshot(current, event.data));

				return;
			}

			if (event.event === "terminal_session_state") {
				updateChat(event.data.chatId, (current) => applySessionMetadata(current, event.data));

				return;
			}

			if (event.event !== "terminal_output") {
				return;
			}

			updateChat(event.data.chatId, (current) => {
				if (current.sessionId && current.sessionId !== event.data.sessionId) {
					return current;
				}

				if (event.data.seq <= current.snapshotSeq) {
					return current;
				}

				return {
					...current,
					error: null,

					lastOutput: {
						data:
							current.lastOutput && current.lastOutput.sessionId === event.data.sessionId
								? `${current.lastOutput.data}${event.data.data}`
								: event.data.data,

						id: `${event.data.sessionId}:${String(event.data.seq)}`,
						seq: event.data.seq,
						sessionId: event.data.sessionId,
					},

					sessionId: event.data.sessionId,
					snapshotSeq: event.data.seq,
					status: current.status === "idle" ? "running" : current.status,
				};
			});
		},

		getState: () => state,

		join: (chatId: string, viewport?: TerminalViewport) => {
			const normalizedViewport = normalizeViewport(viewport);
			const current = getChat(chatId);

			updateChat(chatId, () => ({
				...current,
				error: null,
				isOpen: true,
				status: current.status === "idle" || current.status === "exited" ? "joining" : current.status,
			}));

			if (current.status === "exited") {
				getDependencies().restart(chatId, normalizedViewport);

				return;
			}

			getDependencies().join(chatId, normalizedViewport);
		},

		leave: (chatId: string) => {
			updateChat(chatId, (current) => ({
				...current,
				isOpen: false,
			}));
			getDependencies().leave(chatId);
		},

		restart: (chatId: string, viewport?: TerminalViewport) => {
			const normalizedViewport = normalizeViewport(viewport);

			updateChat(chatId, (current) => ({
				...current,
				error: null,
				lastOutput: null,
				snapshot: "",
				snapshotSeq: 0,
				status: "joining",
			}));
			getDependencies().restart(chatId, normalizedViewport);
		},

		sendInput: (chatId: string, data: string) => {
			if (data.length === 0) {
				return;
			}

			getDependencies().sendInput(chatId, data);
		},

		sendResize: (chatId: string, viewport: TerminalViewport) => {
			const normalizedViewport = normalizeViewport(viewport);

			if (!normalizedViewport) {
				return;
			}

			updateChat(chatId, (current) => ({
				...current,
				cols: normalizedViewport.cols,
				rows: normalizedViewport.rows,
			}));
			getDependencies().sendResize(chatId, normalizedViewport);
		},

		sendSignal: (chatId: string, signal: "SIGINT" | "SIGTERM") => {
			getDependencies().sendSignal(chatId, signal);
		},

		setOpen: (chatId: string, isOpen: boolean, viewport?: TerminalViewport) => {
			const current = getChat(chatId);
			const normalizedViewport = normalizeViewport(viewport);

			if (isOpen) {
				if (current.status === "exited") {
					getDependencies().restart(chatId, normalizedViewport);
				} else {
					getDependencies().join(chatId, normalizedViewport);
				}
			} else {
				getDependencies().leave(chatId);
			}

			updateChat(chatId, () => ({
				...current,
				error: null,
				isOpen,
				status: isOpen && (current.status === "idle" || current.status === "exited") ? "joining" : current.status,
			}));
		},

		subscribe: (listener: () => void) => {
			listeners.add(listener);

			return () => {
				listeners.delete(listener);
			};
		},
	};
};
