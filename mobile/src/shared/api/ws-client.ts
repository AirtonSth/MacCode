import type {
	AssistantStreamDeltaTarget,
	AssistantStreamEvent,
	AssistantStreamItemState,
	AssistantStreamItemType,
	ClientWsEvent,
	ServerWsEvent,
} from "./types";

export type ConnectionState = "idle" | "connecting" | "connected" | "reconnecting" | "disconnected";

interface RealtimeOptions {
	baseUrl: string;
	onConnectionStateChange?: (state: ConnectionState) => void;
	onEvent: (event: ServerWsEvent) => void;
	token: string;
}

const isObject = (value: unknown): value is Record<string, unknown> =>
	typeof value === "object" && value !== null;

const isString = (value: unknown): value is string => typeof value === "string";

const isNumber = (value: unknown): value is number => typeof value === "number";

const streamItemTypeValues = ["reasoning", "tool", "plan", "assistant_message"] as const;
const streamItemStateValues = [
	"running",
	"preview",
	"collapsed",
	"completed",
	"failed",
	"cancelled",
] as const;
const streamDeltaTargetValues = ["summary", "body", "output"] as const;

const isStreamItemType = (value: unknown): value is AssistantStreamItemType =>
	isString(value) && streamItemTypeValues.includes(value as AssistantStreamItemType);

const isStreamItemState = (value: unknown): value is AssistantStreamItemState =>
	isString(value) && streamItemStateValues.includes(value as AssistantStreamItemState);

const isStreamDeltaTarget = (value: unknown): value is AssistantStreamDeltaTarget =>
	isString(value) && streamDeltaTargetValues.includes(value as AssistantStreamDeltaTarget);

const parseAssistantStreamEvent = (value: unknown): AssistantStreamEvent | null => {
	if (!isObject(value) || !isString(value.type)) {
		return null;
	}

	if (value.type === "turn_started" && isString(value.turnId)) {
		return {
			type: "turn_started",
			turnId: value.turnId,
		};
	}

	if (
		value.type === "item_started" &&
		isString(value.turnId) &&
		isString(value.itemId) &&
		isStreamItemType(value.itemType)
	) {
		return {
			type: "item_started",
			turnId: value.turnId,
			itemId: value.itemId,
			itemType: value.itemType,
			state: isStreamItemState(value.state) ? value.state : undefined,
			summary: isString(value.summary) ? value.summary : undefined,
		};
	}

	if (
		value.type === "item_delta" &&
		isString(value.turnId) &&
		isString(value.itemId) &&
		isStreamDeltaTarget(value.target) &&
		isString(value.delta)
	) {
		return {
			type: "item_delta",
			turnId: value.turnId,
			itemId: value.itemId,
			target: value.target,
			delta: value.delta,
		};
	}

	if (
		value.type === "item_state" &&
		isString(value.turnId) &&
		isString(value.itemId) &&
		isStreamItemState(value.state)
	) {
		return {
			type: "item_state",
			turnId: value.turnId,
			itemId: value.itemId,
			state: value.state,
			summary: isString(value.summary) ? value.summary : undefined,
		};
	}

	if (value.type === "item_completed" && isString(value.turnId) && isString(value.itemId)) {
		return {
			type: "item_completed",
			turnId: value.turnId,
			itemId: value.itemId,
			state: isStreamItemState(value.state) ? value.state : undefined,
			summary: isString(value.summary) ? value.summary : undefined,
		};
	}

	if (value.type === "turn_completed" && isString(value.turnId)) {
		return {
			type: "turn_completed",
			turnId: value.turnId,
		};
	}

	return null;
};

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
	const isChatStatus = (value: unknown): value is "pending" | "running" | "completed" | "failed" =>
		isString(value) && statusValues.includes(value as "pending" | "running" | "completed" | "failed");

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

	if (event === "assistant_event" && isString(chatId)) {
		const streamEvent = parseAssistantStreamEvent(data.event);
		if (!streamEvent) {
			return null;
		}

		return {
			data: {
				chatId,
				event: streamEvent,
			},
			event: "assistant_event",
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

	if (
		event === "workspace_event" &&
		isNumber(data.seq) &&
		isString(data.ts) &&
		isString(data.type) &&
		("payload" in data) &&
		(isString(data.originClientId) || data.originClientId === null || data.originClientId === undefined) &&
		(isString(data.requestId) || data.requestId === null || data.requestId === undefined)
	) {
		return {
			data: {
				seq: data.seq,
				ts: data.ts,
				type: data.type,
				payload: data.payload ?? null,
				originClientId: isString(data.originClientId) ? data.originClientId : null,
				requestId: isString(data.requestId) ? data.requestId : null,
			},
			event: "workspace_event",
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

export const createRealtimeClient = (options: RealtimeOptions) => {
	const reconnectBaseDelay = 300;
	const reconnectMaxDelay = 4_000;

	let socket: WebSocket | null = null;
	let reconnectAttempts = 0;
	let stopped = false;
	let reconnectTimeout: ReturnType<typeof setTimeout> | null = null;
	let isConnecting = false;
	let reconnectScheduled = false;
	let isConnected = false;
	const activeChats = new Set<string>();
	const sendQueue: ClientWsEvent[] = [];

	const notifyState = (state: ConnectionState) => {
		options.onConnectionStateChange?.(state);
	};

	const clearReconnectTimeout = () => {
		if (!reconnectTimeout) {
			return;
		}

		clearTimeout(reconnectTimeout);
		reconnectTimeout = null;
		reconnectScheduled = false;
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

		if (sendQueue.length >= 50) {
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

		socket.onopen = () => {
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

				socket?.send(
					JSON.stringify({
						data: {
							chatId,
						},
						event: "join_chat",
					}),
				);
			}
		};

		socket.onclose = () => {
			isConnected = false;
			isConnecting = false;

			if (!stopped) {
				scheduleReconnect();
				return;
			}

			notifyState("disconnected");
		};

		socket.onerror = () => {
			notifyState("reconnecting");
			scheduleReconnect();
		};

		socket.onmessage = (message) => {
			const payload = parseServerWsEvent(message.data);

			if (!payload) {
				return;
			}

			options.onEvent(payload);
		};
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
			clearReconnectTimeout();
			closeSocket();
			notifyState("disconnected");
		},
		getIsConnected: () => isConnected && socket?.readyState === WebSocket.OPEN,
		sendJoinChat: (chatId: string) => {
			activeChats.add(chatId);
			send({
				data: { chatId },
				event: "join_chat",
			});
		},
		sendJoinWorkspace: (lastSeq = 0, clientId?: string) => {
			send({
				data: {
					lastSeq,
					...(clientId ? { clientId } : {}),
				},
				event: "join_workspace",
			});
		},
		sendUserMessage: (
			chatId: string,
			text: string,
			options?: {
				clientId?: string;
				model?: string;
				permissionMode?: string;
				reasoningEffort?: string;
				requestId?: string;
			},
		) => {
			send({
				data: {
					chatId,
					text,
					...(options?.clientId ? { clientId: options.clientId } : {}),
					...(options?.model ? { model: options.model } : {}),
					...(options?.permissionMode ? { permissionMode: options.permissionMode } : {}),
					...(options?.reasoningEffort ? { reasoningEffort: options.reasoningEffort } : {}),
					...(options?.requestId ? { requestId: options.requestId } : {}),
				},
				event: "user_message",
			});
		},
	};
};
