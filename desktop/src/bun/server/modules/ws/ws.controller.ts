import { Elysia, t } from "elysia";

import { parseCodexPermissionMode } from "../../../../shared/codex-permission-mode";
import { parseCodexReasoningEffort } from "../../../../shared/codex-model-config";
import { isValidToken, resolveWsToken } from "../../shared/auth/auth.service";
import { serverLogger } from "../../shared/core/server-logger";
import type { ChatProvider, ClientWsEvent, ServerWsEvent, TerminalSessionSnapshotDTO } from "../../types";
import type {
	TerminalSessionActionResult,
	TerminalSessionServerEvent,
	TerminalSessionServiceContract,
} from "../terminal-session/terminal-session.model";
import type { WorkspaceEventEnvelope, WorkspaceEventsServiceContract } from "../workspace-events/workspace-events.model";
import type { WsService } from "./ws.model";

interface BroadcastSocket extends WsLike {
	send: (message: unknown) => void;
}

interface WsLike {
	data: {
		request: Request;
	};
}

interface TerminalSocketSubscription {
	lastOutputSeq: number;
	pendingEvents: TerminalSessionServerEvent[];
	ready: boolean;
	sessionId: string | null;
}

const VALID_PROVIDERS = new Set<string>(["codex", "claude"]);
const VALID_TERMINAL_SIGNALS = new Set(["SIGINT", "SIGTERM"]);
const TERMINAL_WS_LOG_SCOPE = "terminal-ws";

const toErrorMessage = (error: unknown): string => {
	if (error instanceof Error && error.message.trim().length > 0) {
		return error.message;
	}

	return "terminal request failed";
};

const parseViewport = (
	data: Record<string, unknown>,
): { cols?: number; rows?: number } | null => {
	const cols = data.cols;
	const rows = data.rows;

	const parsedCols =
		typeof cols === "number" && Number.isFinite(cols) && cols > 0 ? Math.floor(cols) : undefined;
	const parsedRows =
		typeof rows === "number" && Number.isFinite(rows) && rows > 0 ? Math.floor(rows) : undefined;

	if ((cols !== undefined && parsedCols === undefined) || (rows !== undefined && parsedRows === undefined)) {
		return null;
	}

	return {
		cols: parsedCols,
		rows: parsedRows,
	};
};

export class WsController {
	static build(
		service: WsService,
		workspaceEvents?: WorkspaceEventsServiceContract,
		terminalSessions?: TerminalSessionServiceContract,
	) {
		return new WsController(service, workspaceEvents, terminalSessions).build();
	}

	private static isAssistantBroadcastEvent(
		event: ServerWsEvent,
	): event is ServerWsEvent & { event: "assistant_delta" | "assistant_done" | "assistant_event" | "assistant_snapshot" } {
		return (
			event.event === "assistant_delta"
			|| event.event === "assistant_done"
			|| event.event === "assistant_event"
			|| event.event === "assistant_snapshot"
		);
	}

	private static parseEventPayload(message: unknown): ClientWsEvent | null {
		if (message === null) {
			return null;
		}

		if (typeof message === "string") {
			try {
				return JSON.parse(message) as ClientWsEvent;
			} catch {
				return null;
			}
		}

		if (message instanceof ArrayBuffer) {
			return WsController.parseEventPayload(new TextDecoder().decode(message));
		}

		if (message instanceof Uint8Array) {
			return WsController.parseEventPayload(new TextDecoder().decode(message));
		}

		if (typeof message === "object") {
			const candidate = message as { data?: unknown; event?: unknown };

			if (typeof candidate.event === "string" && candidate.data && typeof candidate.data === "object") {
				return {
					event: candidate.event as ClientWsEvent["event"],
					data: candidate.data as ClientWsEvent["data"],
				} as ClientWsEvent;
			}

			const nested = candidate.data as { data?: unknown; event?: unknown } | undefined;
			if (nested && typeof nested.event === "string" && nested.data && typeof nested.data === "object") {
				return {
					event: nested.event as ClientWsEvent["event"],
					data: nested.data as ClientWsEvent["data"],
				} as ClientWsEvent;
			}

			if (typeof nested === "string") {
				return WsController.parseEventPayload(nested);
			}

			if (nested instanceof ArrayBuffer || nested instanceof Uint8Array) {
				return WsController.parseEventPayload(nested);
			}

			if (nested && typeof nested === "object") {
				return WsController.parseEventPayload(nested);
			}
		}

		return null;
	}

	private readonly subscriptions = new Map<string, Set<BroadcastSocket>>();
	private readonly terminalSubscriptions = new Map<string, Map<BroadcastSocket, TerminalSocketSubscription>>();
	private readonly workspaceSubscriptions = new Set<BroadcastSocket>();

	constructor(
		private readonly service: WsService,
		private readonly workspaceEvents?: WorkspaceEventsServiceContract,
		private readonly terminalSessions?: TerminalSessionServiceContract,
	) {
		this.workspaceEvents?.subscribe((event: WorkspaceEventEnvelope) => {
			this.broadcastWorkspaceEvent({
				data: event,
				event: "workspace_event",
			});
		});
		this.terminalSessions?.subscribe((event) => {
			this.broadcastTerminalEvent(event);
		});
	}

	private getOrCreateTerminalSubscription(chatId: string, socket: BroadcastSocket): TerminalSocketSubscription {
		let sockets = this.terminalSubscriptions.get(chatId);
		if (!sockets) {
			sockets = new Map();
			this.terminalSubscriptions.set(chatId, sockets);
		}

		let subscription = sockets.get(socket);
		if (!subscription) {
			subscription = {
				lastOutputSeq: 0,
				pendingEvents: [],
				ready: false,
				sessionId: null,
			};
			sockets.set(socket, subscription);
		}

		return subscription;
	}

	private joinChat(chatId: string, socket: BroadcastSocket): void {
		const previous = this.subscriptions.get(chatId);
		if (previous) {
			for (const existingSocket of previous) {
				if (existingSocket.data.request === socket.data.request) {
					return;
				}
			}

			previous.add(socket);
			return;
		}

		this.subscriptions.set(chatId, new Set([socket]));
	}

	private joinWorkspace(socket: BroadcastSocket): void {
		this.workspaceSubscriptions.add(socket);
	}

	private leaveSocket(socket: BroadcastSocket): void {
		for (const [chatId, sockets] of this.subscriptions.entries()) {
			if (!sockets.delete(socket)) {
				continue;
			}

			if (sockets.size === 0) {
				this.subscriptions.delete(chatId);
			}
		}

		for (const [chatId, sockets] of this.terminalSubscriptions.entries()) {
			if (!sockets.delete(socket)) {
				continue;
			}

			if (sockets.size === 0) {
				this.terminalSubscriptions.delete(chatId);
			}
		}

		this.workspaceSubscriptions.delete(socket);
	}

	private leaveTerminal(chatId: string, socket: BroadcastSocket): void {
		const sockets = this.terminalSubscriptions.get(chatId);
		if (!sockets) {
			return;
		}

		sockets.delete(socket);
		if (sockets.size === 0) {
			this.terminalSubscriptions.delete(chatId);
		}
	}

	private sendTerminalFailure(socket: BroadcastSocket, chatId: string, code: string, error: unknown): void {
		socket.send({
			data: {
				chatId,
				code,
				message: toErrorMessage(error),
			},
			event: "error",
		});
	}

	private broadcastToChat(chatId: string, event: ServerWsEvent): void {
		const targets = this.subscriptions.get(chatId);
		if (!targets) {
			return;
		}

		for (const socket of targets) {
			try {
				socket.send(event);
			} catch {
				// keep resilient and continue
			}
		}
	}

	private broadcastToChatAndWorkspace(chatId: string, event: ServerWsEvent): void {
		const targets = new Set<BroadcastSocket>();
		const chatTargets = this.subscriptions.get(chatId);
		if (chatTargets) {
			for (const socket of chatTargets) {
				targets.add(socket);
			}
		}
		for (const socket of this.workspaceSubscriptions) {
			targets.add(socket);
		}

		for (const socket of targets) {
			try {
				socket.send(event);
			} catch {
				// keep resilient and continue
			}
		}
	}

	private broadcastWorkspaceEvent(event: ServerWsEvent & { event: "workspace_event" }): void {
		for (const socket of this.workspaceSubscriptions) {
			try {
				socket.send(event);
			} catch {
				// keep resilient and continue
			}
		}
	}

	private broadcastTerminalSnapshot(chatId: string, snapshot: TerminalSessionSnapshotDTO, targetSocket?: BroadcastSocket): void {
		const targets = this.terminalSubscriptions.get(chatId);
		if (!targets) {
			if (targetSocket) {
				try {
					targetSocket.send({
						data: snapshot,
						event: "terminal_session_snapshot",
					});
				} catch {
					// keep resilient and continue
				}
			}
			return;
		}

		for (const [socket, subscription] of targets.entries()) {
			if (targetSocket && socket !== targetSocket) {
				continue;
			}

			subscription.lastOutputSeq = snapshot.seq;
			subscription.pendingEvents = [];
			subscription.ready = true;
			subscription.sessionId = snapshot.sessionId;

			try {
				socket.send({
					data: snapshot,
					event: "terminal_session_snapshot",
				});
			} catch {
				// keep resilient and continue
			}
		}
	}

	private broadcastTerminalEvent(event: TerminalSessionServerEvent): void {
		const chatId = event.data.chatId;
		const targets = this.terminalSubscriptions.get(chatId);
		if (!targets) {
			return;
		}
		if (event.event === "terminal_session_state") {
			serverLogger.info(TERMINAL_WS_LOG_SCOPE, "broadcast terminal state", {
				chatId,
				sessionId: event.data.sessionId,
				status: event.data.status,
				exitCode: event.data.exitCode,
			});
		}
		if (event.event === "terminal_output" && event.data.seq <= 3) {
			serverLogger.debug(TERMINAL_WS_LOG_SCOPE, "broadcast terminal output", {
				chatId,
				seq: event.data.seq,
				sessionId: event.data.sessionId,
				size: event.data.data.length,
				preview: event.data.data.slice(0, 120),
			});
		}

		for (const [socket, subscription] of targets.entries()) {
			if (!subscription.ready) {
				if (subscription.pendingEvents.length < 500) {
					subscription.pendingEvents.push(event);
				}
				continue;
			}

			if (event.event === "terminal_output") {
				if (
					(subscription.sessionId !== null && event.data.sessionId !== subscription.sessionId)
					|| event.data.seq <= subscription.lastOutputSeq
				) {
					continue;
				}

				subscription.lastOutputSeq = event.data.seq;
			}

			if (event.event === "terminal_session_state" && subscription.sessionId !== null) {
				if (event.data.sessionId !== subscription.sessionId) {
					continue;
				}
			}

			try {
				socket.send(event);
			} catch {
				// keep resilient and continue
			}
		}
	}

	private flushPendingTerminalEvents(subscription: TerminalSocketSubscription, socket: BroadcastSocket): void {
		const pending = subscription.pendingEvents;
		subscription.pendingEvents = [];

		for (const event of pending) {
			if (event.event === "terminal_output") {
				if (
					(subscription.sessionId !== null && event.data.sessionId !== subscription.sessionId)
					|| event.data.seq <= subscription.lastOutputSeq
				) {
					continue;
				}

				subscription.lastOutputSeq = event.data.seq;
			}

			if (event.event === "terminal_session_state" && subscription.sessionId !== null) {
				if (event.data.sessionId !== subscription.sessionId) {
					continue;
				}
			}

			try {
				socket.send(event);
			} catch {
				// keep resilient and continue
			}
		}
	}

	private sendValidationError(socket: BroadcastSocket, chatId: string | undefined, message: string): void {
		socket.send({
			data: {
				code: "validation_error",
				message: `validation error: ${message}`,
				...(chatId ? { chatId } : {}),
			},
			event: "error",
		});
	}

	private sendTerminalActionError(socket: BroadcastSocket, chatId: string, result: TerminalSessionActionResult): void {
		if (!result.chatExists) {
			socket.send({
				data: {
					chatId,
					code: "chat_not_found",
					message: "chat not found",
				},
				event: "error",
			});
			return;
		}

		if (!result.projectExists) {
			socket.send({
				data: {
					chatId,
					code: "project_not_found",
					message: "project not found",
				},
				event: "error",
			});
		}
	}

	private createChatEmitter(chatId: string) {
		return (event: ServerWsEvent) => {
			if (WsController.isAssistantBroadcastEvent(event)) {
				this.broadcastToChatAndWorkspace(chatId, event);
				return;
			}

			this.broadcastToChat(chatId, event);
		};
	}

	build() {
		return new Elysia({ name: "ws-controller" }).ws("/v1/ws", {
			body: t.Any(),

			close: (ws) => {
				this.leaveSocket(ws as BroadcastSocket);
			},

			message: (ws, message) => {
				void (async () => {
					const payload = WsController.parseEventPayload(message as unknown);
					const socket = ws as BroadcastSocket;

					if (!payload?.event || !payload.data) {
						socket.send({
							data: {
								code: "validation_error",
								message: "validation error: invalid websocket message format",
							},
							event: "error",
						});
						return;
					}

					if (payload.event === "join_chat") {
						const chatId = payload.data.chatId;
						if (!chatId) {
							socket.send({
								data: {
									code: "validation_error",
									message: "validation error: chatId is required",
								},
								event: "error",
							});
							return;
						}

						const chat = await this.service.getChatById(chatId);
						if (!chat) {
							socket.send({
								data: {
									chatId,
									code: "chat_not_found",
									message: "chat not found",
								},
								event: "error",
							});
							return;
						}

						this.joinChat(chatId, socket);
						if (chat.isActive && this.service.isChatRunning(chatId)) {
							const snapshot = await this.service.getChatStreamSnapshot(chatId);
							if (snapshot && snapshot.partialText.length > 0) {
								socket.send({
									data: {
										chatId: snapshot.chatId,
										partialText: snapshot.partialText,
										updatedAt: snapshot.updatedAt,
									},
									event: "assistant_snapshot",
								});
							}
						}
						return;
					}

					if (payload.event === "join_workspace") {
						this.joinWorkspace(socket);

						const rawLastSeq = (payload.data as { lastSeq?: unknown }).lastSeq;
						const lastSeq =
							typeof rawLastSeq === "number" && Number.isFinite(rawLastSeq) && rawLastSeq > 0
								? Math.floor(rawLastSeq)
								: 0;
						const replayEvents = this.service.listWorkspaceEventsAfter(lastSeq, { limit: 2_000 });

						for (const event of replayEvents) {
							socket.send({
								data: event,
								event: "workspace_event",
							});
						}

						return;
					}

					if (payload.event === "join_terminal_session") {
						if (!this.terminalSessions) {
							this.sendValidationError(socket, payload.data.chatId, "terminal sessions are unavailable");
							return;
						}

						const chatId = payload.data.chatId?.trim();
						if (!chatId) {
							this.sendValidationError(socket, undefined, "chatId is required");
							return;
						}

						const viewport = parseViewport(payload.data as Record<string, unknown>);
						if (viewport === null) {
							this.sendValidationError(socket, chatId, "invalid terminal viewport");
							return;
						}
						serverLogger.info(TERMINAL_WS_LOG_SCOPE, "join terminal session", {
							chatId,
							cols: viewport?.cols,
							rows: viewport?.rows,
						});

						const subscription = this.getOrCreateTerminalSubscription(chatId, socket);
						subscription.lastOutputSeq = 0;
						subscription.pendingEvents = [];
						subscription.ready = false;
						subscription.sessionId = null;

						let result;
						try {
							result = await this.terminalSessions.getOrCreateSessionSnapshot(chatId, viewport);
						} catch (error) {
							serverLogger.error(TERMINAL_WS_LOG_SCOPE, "join terminal session failed", {
								chatId,
								error: toErrorMessage(error),
							});
							this.leaveTerminal(chatId, socket);
							this.sendTerminalFailure(socket, chatId, "terminal_session_start_failed", error);
							return;
						}
						if (!result.chatExists) {
							this.leaveTerminal(chatId, socket);
							socket.send({
								data: {
									chatId,
									code: "chat_not_found",
									message: "chat not found",
								},
								event: "error",
							});
							return;
						}

						if (!result.projectExists || !result.snapshot) {
							this.leaveTerminal(chatId, socket);
							socket.send({
								data: {
									chatId,
									code: "project_not_found",
									message: "project not found",
								},
								event: "error",
							});
							return;
						}

						this.broadcastTerminalSnapshot(chatId, result.snapshot, socket);
						serverLogger.info(TERMINAL_WS_LOG_SCOPE, "terminal session snapshot sent", {
							chatId,
							seq: result.snapshot.seq,
							sessionId: result.snapshot.sessionId,
							status: result.snapshot.status,
						});
						const updatedSubscription = this.getOrCreateTerminalSubscription(chatId, socket);
						this.flushPendingTerminalEvents(updatedSubscription, socket);
						return;
					}

					if (payload.event === "leave_terminal_session") {
						const chatId = payload.data.chatId?.trim();
						if (!chatId) {
							this.sendValidationError(socket, undefined, "chatId is required");
							return;
						}

						this.leaveTerminal(chatId, socket);
						return;
					}

					if (payload.event === "terminal_input") {
						if (!this.terminalSessions) {
							this.sendValidationError(socket, payload.data.chatId, "terminal sessions are unavailable");
							return;
						}

						const chatId = payload.data.chatId?.trim();
						const data = typeof payload.data.data === "string" ? payload.data.data : "";
						if (!chatId) {
							this.sendValidationError(socket, undefined, "chatId is required");
							return;
						}

						if (data.length === 0) {
							this.sendValidationError(socket, chatId, "terminal input data is required");
							return;
						}
						serverLogger.debug(TERMINAL_WS_LOG_SCOPE, "terminal input event", {
							chatId,
							dataLength: data.length,
							preview: data.slice(0, 80),
						});

						let result;
						try {
							result = await this.terminalSessions.sendInput(chatId, data);
						} catch (error) {
							serverLogger.error(TERMINAL_WS_LOG_SCOPE, "terminal input failed", {
								chatId,
								error: toErrorMessage(error),
							});
							this.sendTerminalFailure(socket, chatId, "terminal_input_failed", error);
							return;
						}
						if (!result.chatExists) {
							socket.send({
								data: {
									chatId,
									code: "chat_not_found",
									message: "chat not found",
								},
								event: "error",
							});
							return;
						}

						if (!result.projectExists) {
							socket.send({
								data: {
									chatId,
									code: "project_not_found",
									message: "project not found",
								},
								event: "error",
							});
							return;
						}

						if (result.state === "session_exited") {
							socket.send({
								data: {
									chatId,
									code: "terminal_session_exited",
									message: "terminal session exited; restart is required",
								},
								event: "error",
							});
							return;
						}

						if (result.createdSnapshot) {
							this.broadcastTerminalSnapshot(chatId, result.createdSnapshot);
						}
						return;
					}

					if (payload.event === "terminal_resize") {
						if (!this.terminalSessions) {
							this.sendValidationError(socket, payload.data.chatId, "terminal sessions are unavailable");
							return;
						}

						const chatId = payload.data.chatId?.trim();
						if (!chatId) {
							this.sendValidationError(socket, undefined, "chatId is required");
							return;
						}

						const viewport = parseViewport(payload.data as Record<string, unknown>);
						if (!viewport?.cols || !viewport.rows) {
							this.sendValidationError(socket, chatId, "terminal resize requires cols and rows");
							return;
						}
						serverLogger.debug(TERMINAL_WS_LOG_SCOPE, "terminal resize event", {
							chatId,
							cols: viewport.cols,
							rows: viewport.rows,
						});

						let result;
						try {
							result = await this.terminalSessions.setViewport(chatId, {
								cols: viewport.cols,
								rows: viewport.rows,
							});
						} catch (error) {
							serverLogger.error(TERMINAL_WS_LOG_SCOPE, "terminal resize failed", {
								chatId,
								error: toErrorMessage(error),
							});
							this.sendTerminalFailure(socket, chatId, "terminal_resize_failed", error);
							return;
						}
						if (!result.state) {
							this.sendTerminalActionError(socket, chatId, result);
						}
						return;
					}

					if (payload.event === "terminal_signal") {
						if (!this.terminalSessions) {
							this.sendValidationError(socket, payload.data.chatId, "terminal sessions are unavailable");
							return;
						}

						const chatId = payload.data.chatId?.trim();
						const signal = payload.data.signal;
						if (!chatId) {
							this.sendValidationError(socket, undefined, "chatId is required");
							return;
						}

						if (!VALID_TERMINAL_SIGNALS.has(signal)) {
							this.sendValidationError(socket, chatId, "invalid terminal signal");
							return;
						}
						serverLogger.info(TERMINAL_WS_LOG_SCOPE, "terminal signal event", {
							chatId,
							signal,
						});

						let result;
						try {
							result = await this.terminalSessions.sendSignal(chatId, signal);
						} catch (error) {
							serverLogger.error(TERMINAL_WS_LOG_SCOPE, "terminal signal failed", {
								chatId,
								error: toErrorMessage(error),
							});
							this.sendTerminalFailure(socket, chatId, "terminal_signal_failed", error);
							return;
						}
						if (!result.state) {
							this.sendTerminalActionError(socket, chatId, result);
						}
						return;
					}

					if (payload.event === "terminal_restart") {
						if (!this.terminalSessions) {
							this.sendValidationError(socket, payload.data.chatId, "terminal sessions are unavailable");
							return;
						}

						const chatId = payload.data.chatId?.trim();
						if (!chatId) {
							this.sendValidationError(socket, undefined, "chatId is required");
							return;
						}

						const viewport = parseViewport(payload.data as Record<string, unknown>);
						if (viewport === null) {
							this.sendValidationError(socket, chatId, "invalid terminal viewport");
							return;
						}
						serverLogger.info(TERMINAL_WS_LOG_SCOPE, "terminal restart event", {
							chatId,
							cols: viewport?.cols,
							rows: viewport?.rows,
						});

						this.getOrCreateTerminalSubscription(chatId, socket);
						let result;
						try {
							result = await this.terminalSessions.restartSession(chatId, viewport);
						} catch (error) {
							serverLogger.error(TERMINAL_WS_LOG_SCOPE, "terminal restart failed", {
								chatId,
								error: toErrorMessage(error),
							});
							this.sendTerminalFailure(socket, chatId, "terminal_restart_failed", error);
							return;
						}
						if (!result.chatExists) {
							socket.send({
								data: {
									chatId,
									code: "chat_not_found",
									message: "chat not found",
								},
								event: "error",
							});
							return;
						}

						if (!result.projectExists || !result.snapshot) {
							socket.send({
								data: {
									chatId,
									code: "project_not_found",
									message: "project not found",
								},
								event: "error",
							});
							return;
						}

						this.broadcastTerminalSnapshot(chatId, result.snapshot);
						return;
					}

					if (payload.event === "user_message") {
						const chatId = payload.data.chatId;
						if (!chatId) {
							socket.send({
								data: {
									code: "validation_error",
									message: "validation error: chatId is required",
								},
								event: "error",
							});
							return;
						}

						const emit = this.createChatEmitter(chatId);
						const text = typeof payload.data.text === "string" ? payload.data.text.trim() : "";
						const requestId =
							typeof payload.data.requestId === "string" ? payload.data.requestId.trim() : "";
						if (!text) {
							socket.send({
								data: {
									chatId,
									code: "validation_error",
									message: "validation error: message text is required",
								},
								event: "error",
							});
							return;
						}
						if (!requestId) {
							socket.send({
								data: {
									chatId,
									code: "validation_error",
									message: "validation error: requestId is required",
								},
								event: "error",
							});
							return;
						}
						const rawPermissionMode = (payload.data as { permissionMode?: unknown }).permissionMode;
						const permissionMode = parseCodexPermissionMode(rawPermissionMode);
						if (rawPermissionMode !== undefined && permissionMode === null) {
							socket.send({
								data: {
									chatId,
									code: "validation_error",
									message: "validation error: invalid permission mode",
								},
								event: "error",
							});
							return;
						}
						const rawModel = (payload.data as { model?: unknown }).model;
						const model =
							typeof rawModel === "string" && rawModel.trim().length > 0 ? rawModel.trim() : null;
						if (rawModel !== undefined && model === null) {
							socket.send({
								data: {
									chatId,
									code: "validation_error",
									message: "validation error: invalid model",
								},
								event: "error",
							});
							return;
						}
						const rawReasoningEffort = (payload.data as { reasoningEffort?: unknown }).reasoningEffort;
						const reasoningEffort = parseCodexReasoningEffort(rawReasoningEffort);
						if (rawReasoningEffort !== undefined && reasoningEffort === null) {
							socket.send({
								data: {
									chatId,
									code: "validation_error",
									message: "validation error: invalid reasoning effort",
								},
								event: "error",
							});
							return;
						}
						const rawProjectId = (payload.data as { projectId?: unknown }).projectId;
						const projectId =
							typeof rawProjectId === "string" && rawProjectId.trim().length > 0
								? rawProjectId.trim()
								: null;
						if (rawProjectId !== undefined && projectId === null) {
							socket.send({
								data: {
									chatId,
									code: "validation_error",
									message: "validation error: invalid projectId",
								},
								event: "error",
							});
							return;
						}

						const rawProvider = (payload.data as { provider?: unknown }).provider;
						const provider =
							typeof rawProvider === "string" && VALID_PROVIDERS.has(rawProvider)
								? (rawProvider as ChatProvider)
								: null;
						if (rawProvider !== undefined && provider === null) {
							socket.send({
								data: {
									chatId,
									code: "validation_error",
									message: "validation error: invalid provider",
								},
								event: "error",
							});
							return;
						}

						this.joinChat(chatId, socket);
						await this.service.startUserMessage({
							chatId,
							clientId: typeof payload.data.clientId === "string" ? payload.data.clientId.trim() || undefined : undefined,
							emit,
							model: model ?? undefined,
							permissionMode: permissionMode ?? undefined,
							projectId: projectId ?? undefined,
							provider: provider ?? undefined,
							requestId,
							reasoningEffort: reasoningEffort ?? undefined,
							text,
						});
						return;
					}

					this.sendValidationError(socket, undefined, "unsupported event");
				})();
			},

			open: (ws) => {
				const token = resolveWsToken(ws.data.request);
				if (!isValidToken(token)) {
					ws.close(4401, "unauthorized");
				}
			},
		});
	}
}

export const createWsController = (
	service: WsService,
	workspaceEvents?: WorkspaceEventsServiceContract,
	terminalSessions?: TerminalSessionServiceContract,
) => WsController.build(service, workspaceEvents, terminalSessions);
