import type {
	AssistantStreamDeltaTarget,
	AssistantStreamEvent,
	AssistantStreamItemState,
	AssistantStreamItemType,
	ClientWsEvent,
	ServerWsEvent,
} from "./types";
import type { ActiveConnectionTarget } from "./api-config-store";

export type ConnectionState = "idle" | "connecting" | "connected" | "reconnecting" | "disconnected";

interface RealtimeOptions {
	createSocket?: (url: string, options?: { headers?: Record<string, string> }) => WebSocket;
	idleTimeoutMs?: number;
	onConnectionStateChange?: (state: ConnectionState) => void;
	onEvent: (event: ServerWsEvent) => void;
	onReliableMessageError?: (input: { chatId: string; message: string; requestId: string }) => void;
	reliableQueueLimit?: number;
	reliableQueueTtlMs?: number;
	stableConnectionMs?: number;
	target: ActiveConnectionTarget;
}

interface QueuedClientEvent {
	payload: ClientWsEvent;
	queuedAt: number;
	requestId: string | null;
	state: "queued" | "sent_unacked";
}

const isReliableUserMessage = (payload: ClientWsEvent): payload is Extract<ClientWsEvent, { event: "user_message" }> =>
	payload.event === "user_message";

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

	if (
		event === "assistant_snapshot" &&
		isString(chatId) &&
		isString(data.partialText) &&
		isString(data.updatedAt)
	) {
		return {
			data: {
				chatId,
				partialText: data.partialText,
				updatedAt: data.updatedAt,
			},
			event: "assistant_snapshot",
		};
	}

	if (event === "assistant_event" && isString(chatId)) {
		const streamEvent = parseAssistantStreamEvent(data.event);
		if (!streamEvent) {
			return null;
		}
		const parsedEventId = isNumber(data.eventId) ? data.eventId : undefined;

		return {
			data: {
				chatId,
				...(parsedEventId !== undefined ? { eventId: parsedEventId } : {}),
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
				isActive: typeof data.isActive === "boolean" ? data.isActive : false,
				providerThreadId: isString(data.providerThreadId) ? data.providerThreadId : null,
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
		event === "terminal_session_snapshot" &&
		isString(chatId) &&
		isNumber(data.cols) &&
		isString(data.cwd) &&
		(data.exitCode === null || isNumber(data.exitCode)) &&
		(data.exitedAt === null || isString(data.exitedAt)) &&
		isNumber(data.rows) &&
		isNumber(data.seq) &&
		isString(data.sessionId) &&
		isString(data.shell) &&
		isString(data.snapshot) &&
		isString(data.startedAt) &&
		(data.status === "running" || data.status === "exited")
	) {
		return {
			data: {
				chatId,
				cols: data.cols,
				cwd: data.cwd,
				exitCode: data.exitCode,
				exitedAt: data.exitedAt,
				rows: data.rows,
				seq: data.seq,
				sessionId: data.sessionId,
				shell: data.shell,
				snapshot: data.snapshot,
				startedAt: data.startedAt,
				status: data.status,
			},
			event: "terminal_session_snapshot",
		};
	}

	if (
		event === "terminal_output" &&
		isString(chatId) &&
		isString(data.data) &&
		isNumber(data.seq) &&
		isString(data.sessionId)
	) {
		return {
			data: {
				chatId,
				data: data.data,
				seq: data.seq,
				sessionId: data.sessionId,
			},
			event: "terminal_output",
		};
	}

	if (
		event === "terminal_session_state" &&
		isString(chatId) &&
		isNumber(data.cols) &&
		isString(data.cwd) &&
		(data.exitCode === null || isNumber(data.exitCode)) &&
		(data.exitedAt === null || isString(data.exitedAt)) &&
		isNumber(data.rows) &&
		isNumber(data.seq) &&
		isString(data.sessionId) &&
		isString(data.shell) &&
		isString(data.startedAt) &&
		(data.status === "running" || data.status === "exited")
	) {
		return {
			data: {
				chatId,
				cols: data.cols,
				cwd: data.cwd,
				exitCode: data.exitCode,
				exitedAt: data.exitedAt,
				rows: data.rows,
				seq: data.seq,
				sessionId: data.sessionId,
				shell: data.shell,
				startedAt: data.startedAt,
				status: data.status,
			},
			event: "terminal_session_state",
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

export const buildRealtimeWebSocketUrl = (target: ActiveConnectionTarget): string => {
	const normalized = (target.kind === "local" ? target.baseUrl : target.backendUrl).replace(/\/+$/, "");
	const wsBase =
		normalized.startsWith("https://")
			? normalized.replace(/^https:\/\//, "wss://")
			: normalized.replace(/^http:\/\//, "ws://");

	if (target.kind === "private") {
		return `${wsBase}/v1/ws?accessToken=${encodeURIComponent(target.accessToken)}&connectorId=${encodeURIComponent(target.connectorId)}`;
	}

	return `${wsBase}/v1/ws?token=${encodeURIComponent(target.token)}`;
};

export const buildRealtimeWebSocketHeaders = (target: ActiveConnectionTarget): Record<string, string> | undefined => {
	if (target.kind !== "private") {
		return undefined;
	}

	return {
		authorization: `Bearer ${target.accessToken}`,
		"x-remotecode-connector-id": target.connectorId,
	};
};

export const createRealtimeClient = (options: RealtimeOptions) => {
	const reconnectBaseDelay = 300;
	const reconnectMaxDelay = 30_000;
	const reliableQueueLimit = options.reliableQueueLimit ?? 100;
	const reliableQueueTtlMs = options.reliableQueueTtlMs ?? 300_000;
	const stableConnectionMs = options.stableConnectionMs ?? 5_000;
	const idleTimeoutMs = options.idleTimeoutMs ?? 60_000;

	let socket: WebSocket | null = null;
	let reconnectAttempts = 0;
	let stopped = false;
	let reconnectTimeout: ReturnType<typeof setTimeout> | null = null;
	let stableConnectionTimer: ReturnType<typeof setTimeout> | null = null;
	let idleTimer: ReturnType<typeof setTimeout> | null = null;
	let isConnecting = false;
	let reconnectScheduled = false;
	let isConnected = false;
	let socketErrored = false;
	const activeChats = new Set<string>();
	const activeTerminalChats = new Map<string, { cols?: number; rows?: number }>();
	let activeWorkspaceSubscription: { clientId?: string; lastSeq: number } | null = null;
	const sendQueue: QueuedClientEvent[] = [];

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

	const clearStableConnectionTimer = () => {
		if (!stableConnectionTimer) {
			return;
		}

		clearTimeout(stableConnectionTimer);
		stableConnectionTimer = null;
	};

	const clearIdleTimer = () => {
		if (!idleTimer) {
			return;
		}

		clearTimeout(idleTimer);
		idleTimer = null;
	};

	const resetIdleTimer = () => {
		clearIdleTimer();
		if (stopped || idleTimeoutMs <= 0) {
			return;
		}
		idleTimer = setTimeout(() => {
			idleTimer = null;

			// No server activity for idleTimeoutMs — the socket may be dead even
			// though onclose hasn't fired. Force a reconnect cycle.
			try {
				socket?.close();
			} catch {
				// no-op
			}
		}, idleTimeoutMs);
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

		for (const queued of sendQueue) {
			if (queued.payload.event === "join_chat") {
				joinedInQueue.add(queued.payload.data.chatId);
			}
		}

		return joinedInQueue;
	};

	const getQueuedJoinTerminalChatIds = () => {
		const joinedInQueue = new Set<string>();

		for (const queued of sendQueue) {
			if (queued.payload.event === "join_terminal_session") {
				joinedInQueue.add(queued.payload.data.chatId);
			}
		}

		return joinedInQueue;
	};

	const hasQueuedWorkspaceJoin = () => {
		return sendQueue.some((queued) => queued.payload.event === "join_workspace");
	};

	const emitReliableMessageError = (queued: QueuedClientEvent, fallbackMessage: string) => {
		if (queued.payload.event !== "user_message" || !queued.requestId) {
			return;
		}

		options.onReliableMessageError?.({
			chatId: queued.payload.data.chatId,
			message: fallbackMessage,
			requestId: queued.requestId,
		});
	};

	const dropExpiredReliableMessages = () => {
		const now = Date.now();
		for (let index = sendQueue.length - 1; index >= 0; index -= 1) {
			const queued = sendQueue[index];
			if (!queued || queued.payload.event !== "user_message") {
				continue;
			}

			if (now - queued.queuedAt < reliableQueueTtlMs) {
				continue;
			}

			sendQueue.splice(index, 1);
			emitReliableMessageError(queued, "The request expired while the desktop was offline. Please resend it.");
		}
	};

	const resetUnackedReliableMessagesForRetry = () => {
		for (const queued of sendQueue) {
			if (queued.payload.event === "user_message" && queued.state === "sent_unacked") {
				queued.state = "queued";
			}
		}
	};

	const buildQueueEntry = (payload: ClientWsEvent): QueuedClientEvent => ({
		payload,
		queuedAt: Date.now(),
		requestId: payload.event === "user_message"
			? payload.data.requestId ?? null
			: null,
		state: "queued",
	});

	const enqueueMessage = (payload: ClientWsEvent) => {
		dropExpiredReliableMessages();

		if (payload.event === "join_chat") {
			const queuedJoinChatIds = getQueuedJoinChatIds();
			if (queuedJoinChatIds.has(payload.data.chatId)) {
				return;
			}
		}

		if (payload.event === "join_workspace") {
			for (let index = sendQueue.length - 1; index >= 0; index -= 1) {
				const queued = sendQueue[index];
				if (queued?.payload.event === "join_workspace") {
					sendQueue.splice(index, 1);
					break;
				}
			}
		}

		if (payload.event === "join_terminal_session") {
			for (let index = sendQueue.length - 1; index >= 0; index -= 1) {
				const queued = sendQueue[index];
				if (
					queued?.payload.event === "join_terminal_session" &&
					queued.payload.data.chatId === payload.data.chatId
				) {
					sendQueue.splice(index, 1);
				}
			}
		}

		if (isReliableUserMessage(payload)) {
			const existingIndex = sendQueue.findIndex((queued) => queued.requestId === payload.data.requestId);
			if (existingIndex !== -1) {
				sendQueue[existingIndex] = buildQueueEntry(payload);
				return;
			}
		}

		if (sendQueue.length >= reliableQueueLimit) {
			if (isReliableUserMessage(payload)) {
				emitReliableMessageError(
					buildQueueEntry(payload),
					"The pending request queue is full. Please wait for current retries to finish.",
				);
			}
			return;
		}

		sendQueue.push(buildQueueEntry(payload));
	};

	const flushQueue = () => {
		if (!socket || socket.readyState !== WebSocket.OPEN) {
			return;
		}

		dropExpiredReliableMessages();
		for (let index = 0; index < sendQueue.length;) {
			const queued = sendQueue[index];
			if (!queued) {
				index += 1;
				continue;
			}
			if (queued.payload.event === "user_message" && queued.state === "sent_unacked") {
				index += 1;
				continue;
			}

			try {
				socket.send(JSON.stringify(queued.payload));
				if (queued.payload.event === "user_message") {
					queued.state = "sent_unacked";
					index += 1;
					continue;
				}

				sendQueue.splice(index, 1);
			} catch {
				break;
			}
		}
	};

	const acknowledgeRequest = (requestId: string | null | undefined) => {
		if (!requestId) {
			return;
		}

		for (let index = sendQueue.length - 1; index >= 0; index -= 1) {
			if (sendQueue[index]?.requestId === requestId) {
				sendQueue.splice(index, 1);
			}
		}
	};

	const sendWorkspaceJoinNow = (subscription: { clientId?: string; lastSeq: number }): boolean => {
		if (!socket || socket.readyState !== WebSocket.OPEN) {
			return false;
		}

		socket.send(
			JSON.stringify({
				data: {
					lastSeq: subscription.lastSeq,
					...(subscription.clientId ? { clientId: subscription.clientId } : {}),
				},
				event: "join_workspace",
			}),
		);
		return true;
	};

	const scheduleReconnect = () => {
		if (stopped || isConnecting || reconnectScheduled) {
			return;
		}

		const exponential = Math.min(reconnectBaseDelay * 2 ** reconnectAttempts, reconnectMaxDelay);

		// Equal jitter: random in [exponential/2, exponential] to prevent
		// reconnect storms when many clients reconnect simultaneously.
		const jitter = exponential / 2 + Math.random() * (exponential / 2);
		reconnectAttempts += 1;
		reconnectScheduled = true;
		notifyState("reconnecting");

		reconnectTimeout = setTimeout(() => {
			reconnectTimeout = null;
			reconnectScheduled = false;
			connect();
		}, jitter);
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

		const url = buildRealtimeWebSocketUrl(options.target);
		const headers = buildRealtimeWebSocketHeaders(options.target);
		const socketFactory = options.createSocket
			?? ((socketUrl: string, socketOptions?: { headers?: Record<string, string> }) =>
				new (WebSocket as unknown as new(url: string, protocols?: string | string[], options?: { headers?: Record<string, string> }) => WebSocket)(socketUrl, undefined, socketOptions));
		socket = socketFactory(url, headers ? { headers } : undefined);

		socket.onopen = () => {
			isConnected = true;
			socketErrored = false;
			isConnecting = false;
			clearReconnectTimeout();

			// Don't reset reconnect attempts immediately — only after the connection
			// has stayed up long enough to be considered stable. Prevents fast-fail
			// loops from busy-looping with no backoff.
			clearStableConnectionTimer();
			stableConnectionTimer = setTimeout(() => {
				reconnectAttempts = 0;
				stableConnectionTimer = null;
			}, stableConnectionMs);
			resetIdleTimer();
			notifyState("connected");

			const queuedJoinChatIds = getQueuedJoinChatIds();
			const queuedWorkspaceJoin = hasQueuedWorkspaceJoin();
			const queuedJoinTerminalChatIds = getQueuedJoinTerminalChatIds();
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

			if (activeWorkspaceSubscription && !queuedWorkspaceJoin) {
				sendWorkspaceJoinNow(activeWorkspaceSubscription);
			}

			for (const [chatId, viewport] of activeTerminalChats.entries()) {
				if (queuedJoinTerminalChatIds.has(chatId)) {
					continue;
				}

				socket?.send(
					JSON.stringify({
						data: {
							chatId,
							...(viewport.cols ? { cols: viewport.cols } : {}),
							...(viewport.rows ? { rows: viewport.rows } : {}),
						},
						event: "join_terminal_session",
					}),
				);
			}
		};

		socket.onclose = () => {
			isConnected = false;
			isConnecting = false;
			clearStableConnectionTimer();
			clearIdleTimer();
			resetUnackedReliableMessagesForRetry();

			if (!stopped) {
				scheduleReconnect();
				return;
			}

			notifyState("disconnected");
		};

		socket.onerror = () => {
			// Mark socket as errored so that send() queues messages instead of
			// writing to a broken pipe (M-13).
			socketErrored = true;

			// Close the socket so `onclose` fires exactly once and handles reconnect.
			// This prevents a double-reconnect cycle (onerror + onclose both scheduling).
			closeSocket();
		};

		socket.onmessage = (message) => {
			resetIdleTimer();
			const payload = parseServerWsEvent(message.data);

			if (!payload) {
				return;
			}

			if (payload.event === "error" && payload.data.code === "connector_offline") {
				resetUnackedReliableMessagesForRetry();
				return;
			}

			if (payload.event === "error" && payload.data.code === "connector_reconnected") {
				flushQueue();
				return;
			}

			if (payload.event === "workspace_event") {
				acknowledgeRequest(payload.data.requestId);
			}
			options.onEvent(payload);
		};
	};

	const BACKPRESSURE_THRESHOLD_BYTES = 1_048_576;

	const isSocketBackpressured = (): boolean => {
		const bufferedAmount = (socket as { bufferedAmount?: number } | null)?.bufferedAmount;
		return typeof bufferedAmount === "number" && bufferedAmount > BACKPRESSURE_THRESHOLD_BYTES;
	};

	const send = (payload: ClientWsEvent) => {
		if (stopped) {
			return;
		}

		if (payload.event === "user_message") {
			enqueueMessage(payload);
			if (socket && socket.readyState === WebSocket.OPEN && !socketErrored && !isSocketBackpressured()) {
				flushQueue();
			}
			return;
		}

		if (!socket || socket.readyState !== WebSocket.OPEN || socketErrored || isSocketBackpressured()) {
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
			clearStableConnectionTimer();
			clearIdleTimer();
			closeSocket();
			activeChats.clear();
			activeTerminalChats.clear();
			activeWorkspaceSubscription = null;
			sendQueue.length = 0;
			reconnectAttempts = 0;
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
			const normalizedLastSeq =
				typeof lastSeq === "number" && Number.isFinite(lastSeq) && lastSeq > 0
					? Math.floor(lastSeq)
					: 0;
			activeWorkspaceSubscription = {
				lastSeq: normalizedLastSeq,
				...(clientId ? { clientId } : {}),
			};
			if (activeWorkspaceSubscription && !sendWorkspaceJoinNow(activeWorkspaceSubscription)) {
				send({
					data: {
						lastSeq: activeWorkspaceSubscription.lastSeq,
						...(activeWorkspaceSubscription.clientId
							? { clientId: activeWorkspaceSubscription.clientId }
							: {}),
					},
					event: "join_workspace",
				});
			}
		},
		sendJoinTerminalSession: (chatId: string, viewport?: { cols?: number; rows?: number }) => {
			activeTerminalChats.set(chatId, {
				cols: viewport?.cols,
				rows: viewport?.rows,
			});
			send({
				data: {
					chatId,
					...(viewport?.cols ? { cols: viewport.cols } : {}),
					...(viewport?.rows ? { rows: viewport.rows } : {}),
				},
				event: "join_terminal_session",
			});
		},
		sendLeaveTerminalSession: (chatId: string) => {
			activeTerminalChats.delete(chatId);
			send({
				data: { chatId },
				event: "leave_terminal_session",
			});
		},
		sendTerminalInput: (chatId: string, data: string) => {
			send({
				data: { chatId, data },
				event: "terminal_input",
			});
		},
		sendTerminalResize: (chatId: string, viewport: { cols: number; rows: number }) => {
			activeTerminalChats.set(chatId, viewport);
			send({
				data: {
					chatId,
					cols: viewport.cols,
					rows: viewport.rows,
				},
				event: "terminal_resize",
			});
		},
		sendTerminalSignal: (chatId: string, signal: "SIGINT" | "SIGTERM") => {
			send({
				data: { chatId, signal },
				event: "terminal_signal",
			});
		},
		sendTerminalRestart: (chatId: string, viewport?: { cols?: number; rows?: number }) => {
			activeTerminalChats.set(chatId, {
				cols: viewport?.cols,
				rows: viewport?.rows,
			});
			send({
				data: {
					chatId,
					...(viewport?.cols ? { cols: viewport.cols } : {}),
					...(viewport?.rows ? { rows: viewport.rows } : {}),
				},
				event: "terminal_restart",
			});
		},
		sendUserMessage: (
			chatId: string,
			text: string,
			options?: {
				clientId?: string;
				model?: string;
				permissionMode?: string;
				projectId?: string;
				provider?: string;
				reasoningEffort?: string;
				requestId?: string;
			},
		) => {
			const requestId = options?.requestId ?? `ws-${Date.now().toString(36)}-${Math.random().toString(16).slice(2, 10)}`;
			send({
				data: {
					chatId,
					text,
					...(options?.clientId ? { clientId: options.clientId } : {}),
					...(options?.model ? { model: options.model } : {}),
					...(options?.permissionMode ? { permissionMode: options.permissionMode } : {}),
					...(options?.projectId ? { projectId: options.projectId } : {}),
					...(options?.provider ? { provider: options.provider } : {}),
					...(options?.reasoningEffort ? { reasoningEffort: options.reasoningEffort } : {}),
					requestId,
				},
				event: "user_message",
			});
		},
		acknowledgeRequest,
	};
};
