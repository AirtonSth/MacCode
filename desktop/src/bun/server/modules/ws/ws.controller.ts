import { Elysia, t } from "elysia";

import { serverConfig } from "../../config";
import { resolveWsToken } from "../../shared/auth/auth.service";
import type { ClientWsEvent, ServerWsEvent } from "../../types";
import type { WsService } from "./ws.model";
import { createClientErrorEvent } from "./ws.service";

interface BroadcastSocket extends WsLike {
	send: (message: unknown) => void;
}

interface WsLike {
	data: {
		request: Request;
	};
}

const parseEventPayload = (message: unknown): ClientWsEvent | null => {
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
		return parseEventPayload(new TextDecoder().decode(message));
	}

	if (message instanceof Uint8Array) {
		return parseEventPayload(new TextDecoder().decode(message));
	}

	if (typeof message === "object") {
		const candidate = message as { data?: unknown; event?: unknown; };

		if (typeof candidate.event === "string" && candidate.data && typeof candidate.data === "object") {
			return candidate as ClientWsEvent;
		}
	}

	return null;
};

export const createWsController = (service: WsService) => {
	const subscriptions = new Map<string, Set<BroadcastSocket>>();

	const joinChat = (chatId: string, socket: BroadcastSocket) => {
		const previous = subscriptions.get(chatId);

		if (previous) {
			previous.add(socket);

			return;
		}

		subscriptions.set(chatId, new Set([socket]));
	};

	const leaveSocket = (socket: BroadcastSocket) => {
		for (const [chatId, sockets] of subscriptions.entries()) {
			if (!sockets.delete(socket)) {
				continue;
			}

			if (sockets.size === 0) {
				subscriptions.delete(chatId);
			}
		}
	};

	const broadcastToChat = (chatId: string, event: ServerWsEvent) => {
		const targets = subscriptions.get(chatId);

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
	};

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
			leaveSocket(ws as BroadcastSocket);
		},

		message: (ws, message) => {
			void (async () => {
				const payload = parseEventPayload(message as unknown);

				if (!payload?.data.chatId) {
					(ws as BroadcastSocket).send(
						createClientErrorEvent("bad_payload", "invalid websocket message format"),
					);

					return;
				}

				if (payload.event === "join_chat") {
					const chat = await service.getChatById(payload.data.chatId);

					if (!chat) {
						(ws as BroadcastSocket).send(
							createClientErrorEvent("chat_not_found", "chat not found", payload.data.chatId),
						);

						return;
					}

					joinChat(payload.data.chatId, ws as BroadcastSocket);

					return;
				}

				if (payload.event === "user_message") {
					const text = payload.data.text.trim();

					if (!text) {
						(ws as BroadcastSocket).send(
							createClientErrorEvent(
								"invalid_text",
								"message text is required",
								payload.data.chatId,
							),
						);

						return;
					}

					joinChat(payload.data.chatId, ws as BroadcastSocket);
					await service.startUserMessage({
						chatId: payload.data.chatId,
						emit: (event) => { broadcastToChat(payload.data.chatId, event); },
						text,
					});

					return;
				}

				(ws as BroadcastSocket).send(createClientErrorEvent("bad_event", "unsupported event"));
			})();
		},

		open: (ws) => {
			const token = resolveWsToken(ws.data.request);

			if (!token || token !== serverConfig.token) {
				ws.close(1008, "unauthorized");
				
			}
		},
	});
};
