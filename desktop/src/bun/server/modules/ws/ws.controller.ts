import { Elysia, t } from "elysia";

import { serverConfig } from "../../config";
import { resolveWsToken } from "../../shared/auth/auth.service";
import { parseCodexPermissionMode } from "../../../../shared/codex-permission-mode";
import { parseCodexReasoningEffort } from "../../../../shared/codex-model-config";
import type { ClientWsEvent, ServerWsEvent } from "../../types";
import type { WsService } from "./ws.model";

interface BroadcastSocket extends WsLike {
	send: (message: unknown) => void;
}

interface WsLike {
	data: {
		request: Request;
	};
}

export class WsController {
	static build(service: WsService) {
		return new WsController(service).build();
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

	constructor(private readonly service: WsService) {}

	private joinChat(chatId: string, socket: BroadcastSocket) {
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

	private leaveSocket(socket: BroadcastSocket) {
		for (const [chatId, sockets] of this.subscriptions.entries()) {
			if (!sockets.delete(socket)) {
				continue;
			}

			if (sockets.size === 0) {
				this.subscriptions.delete(chatId);
			}
		}
	}

	private broadcastToChat(chatId: string, event: ServerWsEvent) {
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

	private sendValidationError(socket: BroadcastSocket, chatId: string, message: string) {
		socket.send({
			data: {
				chatId,
				code: "validation_error",
				message: `validation error: ${message}`,
			},
			event: "error",
		});
	}

	private createChatEmitter(chatId: string) {
		return (event: ServerWsEvent) => {
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

					if (!payload?.data.chatId) {
						(ws as BroadcastSocket).send({
							data: {
								code: "validation_error",
								message: "validation error: invalid websocket message format",
							},
							event: "error",
						});
						return;
					}

					const chatId = payload.data.chatId;
					const emit = this.createChatEmitter(chatId);

					if (payload.event === "join_chat") {
						const chat = await this.service.getChatById(chatId);

						if (!chat) {
							(ws as BroadcastSocket).send({
								data: {
									chatId,
									code: "chat_not_found",
									message: "chat not found",
								},
								event: "error",
							});
							return;
						}

						this.joinChat(chatId, ws as BroadcastSocket);
						return;
					}

					if (payload.event === "user_message") {
						const text = typeof payload.data.text === "string" ? payload.data.text.trim() : "";
						if (!text) {
							(ws as BroadcastSocket).send({
								data: {
									chatId,
									code: "validation_error",
									message: "validation error: message text is required",
								},
								event: "error",
							});
							return;
						}
						const rawPermissionMode = (payload.data as { permissionMode?: unknown }).permissionMode;
						const permissionMode = parseCodexPermissionMode(rawPermissionMode);
						if (rawPermissionMode !== undefined && permissionMode === null) {
							(ws as BroadcastSocket).send({
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
							typeof rawModel === "string" && rawModel.trim().length > 0
								? rawModel.trim()
								: null;
						if (rawModel !== undefined && model === null) {
							(ws as BroadcastSocket).send({
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
							(ws as BroadcastSocket).send({
								data: {
									chatId,
									code: "validation_error",
									message: "validation error: invalid reasoning effort",
								},
								event: "error",
							});
							return;
						}

						this.joinChat(chatId, ws as BroadcastSocket);
						await this.service.startUserMessage({
							chatId,
							emit,
							model: model ?? undefined,
							permissionMode: permissionMode ?? undefined,
							reasoningEffort: reasoningEffort ?? undefined,
							text,
						});
						return;
					}

					this.sendValidationError(ws as BroadcastSocket, chatId, "unsupported event");
				})();
			},

			open: (ws) => {
				const token = resolveWsToken(ws.data.request);
				if (!token || token !== serverConfig.token) {
					ws.close(4401, "unauthorized");
				}
			},
		});
	}
}

export const createWsController = (service: WsService) => WsController.build(service);
