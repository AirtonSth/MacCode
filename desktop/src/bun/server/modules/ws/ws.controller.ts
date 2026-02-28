import { Elysia, t } from "elysia";

import { serverConfig } from "../../config";
import { resolveWsToken } from "../../shared/auth/auth.service";
import type { ClientWsEvent, ServerWsEvent } from "../../types";
import type { WsService } from "./ws.model";

type BroadcastSocket = WsLike & {
	send: (message: unknown) => void;
};

interface WsLike {
	data: {
		request: Request;
	};
}

export class WsController {
	private readonly subscriptions = new Map<string, Set<BroadcastSocket>>();

	constructor(private readonly service: WsService) {}

	static build(service: WsService) {
		return new WsController(service).build();
	}

	private joinChat(chatId: string, socket: BroadcastSocket) {
		const previous = this.subscriptions.get(chatId);

		if (previous) {
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
				return candidate as ClientWsEvent;
			}
		}

		return null;
	}

	build() {
		return new Elysia({ name: "ws-controller" }).ws("/v1/ws", {
			body: t.Union([
				t.Object({
					data: t.Object({
						chatId: t.String(),
					}),

					event: t.Literal("join_chat"),
				}),
				t.Object({
					data: t.Object({
						chatId: t.String(),
						text: t.String(),
					}),

					event: t.Literal("user_message"),
				}),
			]),

			close: (ws) => {
				this.leaveSocket(ws as BroadcastSocket);
			},

			message: (ws, message) => {
				void (async () => {
					const payload = WsController.parseEventPayload(message as unknown);

					if (!payload?.data.chatId) {
						(ws as BroadcastSocket).send(
							{
								data: {
									code: "bad_payload",
									message: "invalid websocket message format",
								},
								event: "error",
							},
						);

						return;
					}

					if (payload.event === "join_chat") {
						const chat = await this.service.getChatById(payload.data.chatId);

						if (!chat) {
							(ws as BroadcastSocket).send(
								{
									data: {
										code: "chat_not_found",
										message: "chat not found",
										chatId: payload.data.chatId,
									},
									event: "error",
								},
							);

							return;
						}

						this.joinChat(payload.data.chatId, ws as BroadcastSocket);

						return;
					}

					if (payload.event === "user_message") {
						const text = payload.data.text.trim();

						if (!text) {
							(ws as BroadcastSocket).send(
								{
									data: {
										code: "invalid_text",
										message: "message text is required",
										chatId: payload.data.chatId,
									},
									event: "error",
								},
							);

							return;
						}

						this.joinChat(payload.data.chatId, ws as BroadcastSocket);
						await this.service.startUserMessage({
							chatId: payload.data.chatId,
							emit: (event) => {
								this.broadcastToChat(payload.data.chatId, event);
							},
							text,
						});

						return;
					}

					(ws as BroadcastSocket).send(
						{
							data: {
								code: "bad_event",
								message: "unsupported event",
							},
							event: "error",
						},
					);
				})();
			},

			open: (ws) => {
				const token = resolveWsToken(ws.data.request);

				if (!token || token !== serverConfig.token) {
					ws.close(1008, "unauthorized");
				}
			},
		});
	}
}

export const createWsController = (service: WsService) => WsController.build(service);
