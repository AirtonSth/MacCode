import type { CodexPermissionMode } from "../../../shared/codex-permission-mode";

export type ConnectionState = "idle" | "connecting" | "connected" | "reconnecting" | "disconnected";

export type WsConnectionEvent = (state: ConnectionState) => void;

export interface ClientJoinEvent {
	data: {
		chatId: string;
	};
	event: "join_chat";
}

export interface ClientMessageEvent {
	data: {
		chatId: string;
		text: string;
		permissionMode?: CodexPermissionMode;
	};
	event: "user_message";
}

export type ClientWsEvent = ClientJoinEvent | ClientMessageEvent;

export interface AssistantDeltaEvent {
	data: {
		chatId: string;
		delta: string;
	};
	event: "assistant_delta";
}

export interface AssistantDoneEvent {
	data: {
		chatId: string;
	};
	event: "assistant_done";
}

export interface ChatUpdatedEvent {
	data: {
		chatId: string;
		diffAdded: number;
		diffRemoved: number;
		status: "pending" | "running" | "completed" | "failed";
		updatedAt: string;
	};
	event: "chat_updated";
}

export interface ErrorEvent {
	data: {
		chatId?: string;
		code: string;
		message: string;
	};
	event: "error";
}

export type ServerWsEvent = AssistantDeltaEvent | AssistantDoneEvent | ChatUpdatedEvent | ErrorEvent;

const isObject = (value: unknown): value is Record<string, unknown> =>
	typeof value === "object" && value !== null;

const isString = (value: unknown): value is string => typeof value === "string";

const isNumber = (value: unknown): value is number => typeof value === "number";

const parseJsonString = (raw: string): unknown => {
	try {
		return JSON.parse(raw);
	} catch {
		return null;
	}
};

const toObjectMessage = (raw: unknown): unknown => {
	if (isString(raw)) {
		return parseJsonString(raw);
	}

	if (raw instanceof ArrayBuffer) {
		const text = new TextDecoder().decode(raw);
		return parseJsonString(text);
	}

	if (ArrayBuffer.isView(raw)) {
		const chunk = new Uint8Array(raw.buffer, raw.byteOffset, raw.byteLength);
		const text = new TextDecoder().decode(chunk);
		return parseJsonString(text);
	}

	return raw;
};

export const parseServerWsEvent = (raw: unknown): ServerWsEvent | null => {
	const candidate = toObjectMessage(raw);

	if (!isObject(candidate)) {
		return null;
	}

	const event = candidate.event;
	const data = candidate.data;

	const statusValues = ["pending", "running", "completed", "failed"] as const;
	const isChatStatus = (value: unknown): value is ChatUpdatedEvent["data"]["status"] =>
		isString(value) && statusValues.includes(value as ChatUpdatedEvent["data"]["status"]);

	if (!isString(event) || !isObject(data)) {
		return null;
	}

	const chatId = data.chatId;

	if (event === "assistant_delta") {
		const delta = data.delta;

		if (isString(delta) && isString(chatId)) {
			return {
				data: {
					chatId,
					delta,
				},
				event: "assistant_delta",
			};
		}
	}

	if (event === "assistant_done" && isString(chatId)) {
		return {
			data: {
				chatId,
			},
			event: "assistant_done",
		};
	}

	if (
		event === "chat_updated" &&
		isString(chatId) &&
		isNumber(data.diffAdded) &&
		isNumber(data.diffRemoved) &&
		isChatStatus(data.status) &&
		isString(data.updatedAt)
	) {
		return {
			data: {
				chatId,
				diffAdded: data.diffAdded,
				diffRemoved: data.diffRemoved,
				status: data.status,
				updatedAt: data.updatedAt,
			},
			event: "chat_updated",
		};
	}

	if (event === "error" && isString(data.code) && isString(data.message)) {
		return {
			data: {
				chatId: isString(chatId) ? chatId : undefined,
				code: data.code,
				message: data.message,
			},
			event: "error",
		};
	}

	return null;
};

const buildWsUrl = (baseUrl: string, token: string): string => {
	const normalized = baseUrl.replace(/\/+$/, "");
	const wsBase =
		normalized.startsWith("https://")
			? normalized.replace(/^https:\/\//, "wss://")
			: normalized.replace(/^http:\/\//, "ws://");

	return `${wsBase}/v1/ws?token=${encodeURIComponent(token)}`;
};

interface RemoteCodeRealtimeOptions {
	baseUrl: string;
	token: string;
	onEvent: (event: ServerWsEvent) => void;
	onConnectionStateChange?: (state: ConnectionState) => void;
}

export const RemoteCodeRealtime = {
	createClient: (options: RemoteCodeRealtimeOptions) => {
		const reconnectBaseDelay = 300;
		const reconnectMaxDelay = 4000;

		let socket: WebSocket | null = null;
		let reconnectAttempts = 0;
		let stopped = false;
		let reconnectTimeout: ReturnType<typeof setTimeout> | null = null;
		let isConnecting = false;
		let reconnectScheduled = false;
		let isConnected = false;
		const activeChats = new Set<string>();
		const sendQueue: ClientWsEvent[] = [];

		const isQueueFull = () => sendQueue.length >= 50;

		const clearReconnectTimeout = () => {
			if (!reconnectTimeout) {
				return;
			}

			clearTimeout(reconnectTimeout);
			reconnectTimeout = null;
			reconnectScheduled = false;
		};

		const getQueuedJoinChatIds = () => {
			const joinedInQueue = new Set<string>();

			for (const event of sendQueue) {
				if (event.event === "join_chat") {
					joinedInQueue.add(event.data.chatId);
				}
			}

			return joinedInQueue;
		};

		const enqueueMessage = (payload: ClientWsEvent) => {
			if (payload.event === "join_chat") {
				const queuedJoinChatIds = getQueuedJoinChatIds();
				if (queuedJoinChatIds.has(payload.data.chatId)) {
					return;
				}
			}

			if (isQueueFull()) {
				sendQueue.shift();
			}

			sendQueue.push(payload);
		};

		const flushQueue = () => {
			if (!socket || socket.readyState !== WebSocket.OPEN) {
				return;
			}

			while (sendQueue.length > 0) {
				const payload = sendQueue.shift();
				if (!payload) {
					continue;
				}

				try {
					socket.send(JSON.stringify(payload));
				} catch {
					sendQueue.unshift(payload);
					break;
				}
			}
		};

		const notifyState = (state: ConnectionState) => {
			options.onConnectionStateChange?.(state);
		};

		const closeSocket = () => {
			if (!socket) {
				return;
			}

			try {
				socket.close();
			} catch {
				// no-op
			}
		};

		const scheduleReconnect = () => {
			if (stopped || isConnecting || reconnectScheduled) {
				return;
			}

			const delay = Math.min(reconnectBaseDelay * 2 ** reconnectAttempts, reconnectMaxDelay);
			reconnectAttempts += 1;
			reconnectScheduled = true;
			notifyState("reconnecting");

			reconnectTimeout = setTimeout(() => {
				reconnectTimeout = null;
				reconnectScheduled = false;
				connect();
			}, delay);
		};

		const connect = () => {
			if (stopped || isConnecting) {
				return;
			}

			if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) {
				return;
			}

			isConnecting = true;
			clearReconnectTimeout();
			notifyState("connecting");
			closeSocket();

			socket = new WebSocket(buildWsUrl(options.baseUrl, options.token));

			socket.addEventListener("open", () => {
				isConnected = true;
				reconnectAttempts = 0;
				isConnecting = false;
				clearReconnectTimeout();
				notifyState("connected");

				const queuedJoinChatIds = getQueuedJoinChatIds();
				flushQueue();
				for (const chatId of activeChats) {
					if (queuedJoinChatIds.has(chatId)) {
						continue;
					}
					socket?.send(JSON.stringify({ data: { chatId }, event: "join_chat" }));
				}
			});

			socket.addEventListener("close", () => {
				isConnected = false;
				isConnecting = false;

				if (!stopped) {
					scheduleReconnect();
				} else {
					notifyState("disconnected");
				}
			});

			socket.addEventListener("error", () => {
				notifyState("reconnecting");
				scheduleReconnect();
			});

			socket.addEventListener("message", (message) => {
				const payload = parseServerWsEvent(message.data);
				if (!payload) {
					return;
				}
				options.onEvent(payload);
			});
		};

		const send = (payload: ClientWsEvent) => {
			if (stopped) {
				return;
			}

			if (!socket || socket.readyState !== WebSocket.OPEN) {
				enqueueMessage(payload);
				return;
			}

			socket.send(JSON.stringify(payload));
		};

		return {
			connect,
			disconnect: () => {
				stopped = true;
				if (reconnectTimeout) {
					clearTimeout(reconnectTimeout);
				}

				closeSocket();
				notifyState("disconnected");
			},

			sendJoinChat(chatId: string) {
				activeChats.add(chatId);
				send({ data: { chatId }, event: "join_chat" });
			},

			sendUserMessage(chatId: string, text: string, permissionMode?: CodexPermissionMode) {
				send({
					data: {
						chatId,
						text,
						...(permissionMode ? { permissionMode } : {}),
					},
					event: "user_message",
				});
			},

			getIsConnected() {
				return isConnected && socket?.readyState === WebSocket.OPEN;
			},
		};
	},
};
