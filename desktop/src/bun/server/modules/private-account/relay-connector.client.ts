interface SocketLike {
	addEventListener: (type: string, listener: (event: MessageEvent | CloseEvent | Event) => void) => void;
	close: (code?: number, reason?: string) => void;
	readyState: number;
	removeEventListener: (type: string, listener: (event: MessageEvent | CloseEvent | Event) => void) => void;
	send: (data: string) => void;
}

export interface RelayConnectorOptions {
	connectTimeoutMs?: number;
	createSocket?: (url: string) => SocketLike;
	heartbeatIntervalMs?: number;
	localRequestHandler: (input: {
		body: string | null;
		headers: Record<string, string>;
		method: string;
		path: string;
	}) => Promise<{
		body: string | null;
		bodyEncoding?: "utf8" | "base64";
		headers: Record<string, string>;
		status: number;
	}>;
	localServerToken: string;
	onError?: (message: string) => void;
	onStateChange?: (state: "idle" | "connecting" | "connected" | "disconnected" | "error") => void;
	relayInactivityTimeoutMs?: number;
}

interface StartRelayInput {
	connectorId: string;
	connectorToken: string;
	localServerBaseUrl: string;
	privateBackendUrl: string;
}

interface LocalSocketState {
	isOpen: boolean;
	pendingPayloads: string[];
	socket: SocketLike;
}

interface PendingRemoteClose {
	code?: number;
	reason?: string;
}

const normalizeUrl = (value: string): string => value.trim().replace(/\/+$/u, "");
const CONNECT_TIMEOUT_FLOOR_MS = 2_000;
const RELAY_INACTIVITY_TIMEOUT_FLOOR_MS = 100;

const toWsBaseUrl = (value: string): string => {
	const normalized = normalizeUrl(value);
	if (normalized.startsWith("https://")) {
		return normalized.replace(/^https:\/\//u, "wss://");
	}

	if (normalized.startsWith("http://")) {
		return normalized.replace(/^http:\/\//u, "ws://");
	}

	return normalized;
};

const parseFrame = (value: unknown): Record<string, unknown> | null => {
	try {
		if (typeof value === "string") {
			const parsed = JSON.parse(value) as unknown;
			return typeof parsed === "object" && parsed !== null ? (parsed as Record<string, unknown>) : null;
		}

		if (value instanceof ArrayBuffer) {
			const parsed = JSON.parse(new TextDecoder().decode(value)) as unknown;
			return typeof parsed === "object" && parsed !== null ? (parsed as Record<string, unknown>) : null;
		}

		if (ArrayBuffer.isView(value)) {
			const parsed = JSON.parse(
				new TextDecoder().decode(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength)),
			) as unknown;
			return typeof parsed === "object" && parsed !== null ? (parsed as Record<string, unknown>) : null;
		}

		if (typeof value === "object" && value !== null) {
			return value as Record<string, unknown>;
		}
	} catch {
		return null;
	}

	return null;
};

const toMessageText = (value: unknown): string => {
	if (typeof value === "string") {
		return value;
	}

	if (value instanceof ArrayBuffer) {
		return new TextDecoder().decode(value);
	}

	if (ArrayBuffer.isView(value)) {
		return new TextDecoder().decode(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength));
	}

	return JSON.stringify(value);
};

export class RelayConnectorClient {
	private connectTimeoutMs: number;
	private connectTimer: ReturnType<typeof setTimeout> | null = null;
	private connectionAttemptId = 0;
	private readonly createSocket: (url: string) => SocketLike;
	private readonly heartbeatIntervalMs: number;
	private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
	private localSockets = new Map<string, LocalSocketState>();
	private pendingRemoteClosures = new Map<string, PendingRemoteClose>();
	private pendingRemotePayloads = new Map<string, string[]>();
	private localServerBaseUrl: string | null = null;
	private readonly localServerToken: string;
	private readonly localRequestHandler: RelayConnectorOptions["localRequestHandler"];
	private onError: RelayConnectorOptions["onError"];
	private onStateChange: RelayConnectorOptions["onStateChange"];
	private relayActivityTimer: ReturnType<typeof setTimeout> | null = null;
	private readonly relayInactivityTimeoutMs: number;
	private relaySocket: SocketLike | null = null;
	private remoteClosedByUser = false;
	private state: "idle" | "connecting" | "connected" | "disconnected" | "error" = "idle";
	private suppressedLocalCloseIds = new Set<string>();

	public constructor(options: RelayConnectorOptions) {
		this.createSocket = options.createSocket ?? ((url) => new WebSocket(url) as unknown as SocketLike);
		this.heartbeatIntervalMs = options.heartbeatIntervalMs ?? 2_000;
		this.connectTimeoutMs = Math.max(options.connectTimeoutMs ?? 8_000, CONNECT_TIMEOUT_FLOOR_MS);
		this.localRequestHandler = options.localRequestHandler;
		this.localServerToken = options.localServerToken;
		this.onError = options.onError;
		this.onStateChange = options.onStateChange;
		this.relayInactivityTimeoutMs = Math.max(
			options.relayInactivityTimeoutMs ?? Math.max(this.heartbeatIntervalMs * 3, 8_000),
			RELAY_INACTIVITY_TIMEOUT_FLOOR_MS,
		);
	}

	public getState(): "idle" | "connecting" | "connected" | "disconnected" | "error" {
		return this.state;
	}

	public start(input: StartRelayInput): void {
		const attemptId = this.connectionAttemptId + 1;
		this.stop();
		this.connectionAttemptId = attemptId;
		this.remoteClosedByUser = false;
		this.localServerBaseUrl = normalizeUrl(input.localServerBaseUrl);
		this.setState("connecting");

		const relayUrl = `${toWsBaseUrl(input.privateBackendUrl)}/v1/private/connectors/socket?connectorId=${encodeURIComponent(input.connectorId)}&token=${encodeURIComponent(input.connectorToken)}`;
		let socket: SocketLike;
		try {
			socket = this.createSocket(relayUrl);
		} catch {
			this.reportRelayFailure("private_relay_connect_failed");
			this.setState("error");
			return;
		}
		this.relaySocket = socket;
		this.startConnectTimeout(attemptId);

		socket.addEventListener("open", () => {
			if (!this.isCurrentRelayAttempt(socket, attemptId)) {
				return;
			}

			this.startHeartbeat();
			this.touchRelayActivity(attemptId);
		});

		socket.addEventListener("message", (event) => {
			if (!this.isCurrentRelayAttempt(socket, attemptId)) {
				return;
			}

			this.touchRelayActivity(attemptId);
			void this.handleRelayMessage(event as MessageEvent);
		});

		socket.addEventListener("close", () => {
			if (!this.isCurrentRelayAttempt(socket, attemptId)) {
				return;
			}

			this.stopHeartbeat();
			this.stopConnectTimeout();
			this.stopRelayActivityTimeout();
			this.closeAllLocalSockets();
			this.relaySocket = null;
			this.setState(this.remoteClosedByUser ? "idle" : "disconnected");
		});

		socket.addEventListener("error", () => {
			if (!this.isCurrentRelayAttempt(socket, attemptId)) {
				return;
			}

			this.reportRelayFailure("private_relay_socket_error");
			this.setState("error");
			try {
				socket.close(1011, "relay_error");
			} catch {
				// Best effort close to force a clean reconnect path.
			}
		});
	}

	public stop(): void {
		this.remoteClosedByUser = true;
		this.stopHeartbeat();
		this.stopConnectTimeout();
		this.stopRelayActivityTimeout();
		this.closeAllLocalSockets();
		if (this.relaySocket) {
			this.relaySocket.close(1000, "client_stop");
			this.relaySocket = null;
		}
		this.setState("idle");
	}

	private closeAllLocalSockets(): void {
		for (const [clientConnectionId, state] of this.localSockets) {
			this.suppressedLocalCloseIds.add(clientConnectionId);
			state.socket.close(1000, "relay_closed");
		}

		this.localSockets.clear();
		this.pendingRemoteClosures.clear();
		this.pendingRemotePayloads.clear();
		this.suppressedLocalCloseIds.clear();
	}

	private flushLocalQueue(clientConnectionId: string): void {
		const state = this.localSockets.get(clientConnectionId);
		if (!state || !state.isOpen) {
			return;
		}

		while (state.pendingPayloads.length > 0) {
			const payload = state.pendingPayloads.shift();
			if (!payload) {
				continue;
			}

			state.socket.send(payload);
		}
	}

	private forwardToRelay(frame: Record<string, unknown>): void {
		if (!this.relaySocket || this.relaySocket.readyState !== 1) {
			return;
		}

		try {
			this.relaySocket.send(JSON.stringify(frame));
		} catch {
			this.reportRelayFailure("private_relay_socket_error");
		}
	}

	private async handleProxyRequest(frame: Record<string, unknown>): Promise<void> {
		const requestId = typeof frame.requestId === "string" ? frame.requestId : "";
		const method = typeof frame.method === "string" ? frame.method : "GET";
		const path = typeof frame.path === "string" ? frame.path : "/";
		const body = typeof frame.body === "string" ? frame.body : null;
		const headers =
			typeof frame.headers === "object" && frame.headers !== null
				? Object.fromEntries(
					Object.entries(frame.headers as Record<string, unknown>).filter((entry): entry is [string, string] =>
						typeof entry[1] === "string"
					),
				)
				: {};

		try {
			const response = await this.localRequestHandler({
				body,
				headers,
				method,
				path,
			});

			this.forwardToRelay({
				body: response.body,
				...(response.bodyEncoding ? { bodyEncoding: response.bodyEncoding } : {}),
				headers: response.headers,
				requestId,
				status: response.status,
				type: "proxy_response",
			});
		} catch (error) {
			this.reportRelayFailure("private_local_app_unavailable");
			this.forwardToRelay({
				body: JSON.stringify({
					error: error instanceof Error && error.message.trim().length > 0
						? error.message
						: "private_local_app_unavailable",
				}),
				headers: {
					"content-type": "application/json",
				},
				requestId,
				status: 503,
				type: "proxy_response",
			});
		}
	}

	private handleWsClientEvent(frame: Record<string, unknown>): void {
		const clientConnectionId = typeof frame.clientConnectionId === "string" ? frame.clientConnectionId : "";
		const payload = typeof frame.payload === "string" ? frame.payload : "";
		if (!clientConnectionId || payload.length === 0) {
			return;
		}

		const state = this.localSockets.get(clientConnectionId);
		if (!state) {
			const queuedPayloads = this.pendingRemotePayloads.get(clientConnectionId) ?? [];
			queuedPayloads.push(payload);
			this.pendingRemotePayloads.set(clientConnectionId, queuedPayloads.slice(-50));
			return;
		}

		if (!state.isOpen) {
			state.pendingPayloads.push(payload);
			return;
		}

		state.socket.send(payload);
	}

	private handleWsClose(frame: Record<string, unknown>): void {
		const clientConnectionId = typeof frame.clientConnectionId === "string" ? frame.clientConnectionId : "";
		if (!clientConnectionId) {
			return;
		}

		const socketState = this.localSockets.get(clientConnectionId);
		if (!socketState) {
			this.pendingRemoteClosures.set(clientConnectionId, {
				code: typeof frame.code === "number" ? frame.code : 1000,
				reason: typeof frame.reason === "string" ? frame.reason : "remote_close",
			});
			this.pendingRemotePayloads.delete(clientConnectionId);
			return;
		}

		this.suppressedLocalCloseIds.add(clientConnectionId);
		socketState.socket.close(
			typeof frame.code === "number" ? frame.code : 1000,
			typeof frame.reason === "string" ? frame.reason : "remote_close",
		);
		this.localSockets.delete(clientConnectionId);
	}

	private handleWsOpen(frame: Record<string, unknown>): void {
		const clientConnectionId = typeof frame.clientConnectionId === "string" ? frame.clientConnectionId : "";
		if (!clientConnectionId || !this.localServerBaseUrl) {
			return;
		}

		let socket: SocketLike;
		try {
			socket = this.createSocket(
				`${toWsBaseUrl(this.localServerBaseUrl)}/v1/ws?token=${encodeURIComponent(this.localServerToken)}`,
			);
		} catch {
			this.reportRelayFailure("private_local_app_unavailable");
			this.forwardToRelay({
				clientConnectionId,
				code: 1011,
				reason: "local_socket_open_failed",
				type: "ws_close",
			});
			return;
		}
		const state: LocalSocketState = {
			isOpen: false,
			pendingPayloads: this.pendingRemotePayloads.get(clientConnectionId) ?? [],
			socket,
		};
		this.pendingRemotePayloads.delete(clientConnectionId);
		this.localSockets.set(clientConnectionId, state);

		const pendingClose = this.pendingRemoteClosures.get(clientConnectionId);
		if (pendingClose) {
			this.pendingRemoteClosures.delete(clientConnectionId);
			this.suppressedLocalCloseIds.add(clientConnectionId);
			socket.close(pendingClose.code, pendingClose.reason);
			this.localSockets.delete(clientConnectionId);
			return;
		}

		socket.addEventListener("open", () => {
			state.isOpen = true;
			this.flushLocalQueue(clientConnectionId);
		});

		socket.addEventListener("message", (event) => {
			this.forwardToRelay({
				clientConnectionId,
				payload: toMessageText((event as MessageEvent).data),
				type: "ws_server_event",
			});
		});

		socket.addEventListener("close", (event) => {
			this.localSockets.delete(clientConnectionId);
			if (this.suppressedLocalCloseIds.has(clientConnectionId)) {
				this.suppressedLocalCloseIds.delete(clientConnectionId);
				return;
			}

			this.forwardToRelay({
				clientConnectionId,
				code: (event as CloseEvent).code,
				reason: (event as CloseEvent).reason,
				type: "ws_close",
			});
		});
	}

	private async handleRelayMessage(event: MessageEvent): Promise<void> {
		const frame = parseFrame(event.data);
		if (!frame || typeof frame.type !== "string") {
			return;
		}

		switch (frame.type) {
			case "connector_auth": {
				this.stopConnectTimeout();
				this.setState("connected");
				return;
			}
			case "heartbeat": {
				return;
			}
			case "proxy_request": {
				await this.handleProxyRequest(frame);
				return;
			}
			case "ws_client_event": {
				this.handleWsClientEvent(frame);
				return;
			}
			case "ws_close": {
				this.handleWsClose(frame);
				return;
			}
			case "ws_open": {
				this.handleWsOpen(frame);
				return;
			}
			default: {
				return;
			}
		}
	}

	private setState(value: "idle" | "connecting" | "connected" | "disconnected" | "error"): void {
		this.state = value;
		this.onStateChange?.(value);
	}

	private isCurrentRelayAttempt(socket: SocketLike, attemptId: number): boolean {
		return this.connectionAttemptId === attemptId && this.relaySocket === socket;
	}

	private reportRelayFailure(message: string): void {
		this.onError?.(message);
	}

	private startConnectTimeout(attemptId: number): void {
		this.stopConnectTimeout();
		this.connectTimer = setTimeout(() => {
			if (this.connectionAttemptId !== attemptId) {
				return;
			}

			this.reportRelayFailure("private_relay_connect_failed");
			this.setState("error");
			this.relaySocket?.close(1011, "relay_connect_timeout");
		}, this.connectTimeoutMs);
		this.connectTimer.unref?.();
	}

	private stopConnectTimeout(): void {
		if (!this.connectTimer) {
			return;
		}

		clearTimeout(this.connectTimer);
		this.connectTimer = null;
	}

	private touchRelayActivity(attemptId: number): void {
		if (this.connectionAttemptId !== attemptId) {
			return;
		}

		this.stopRelayActivityTimeout();
		this.relayActivityTimer = setTimeout(() => {
			if (this.connectionAttemptId !== attemptId) {
				return;
			}

			this.reportRelayFailure("private_relay_socket_error");
			this.setState("error");
			this.relaySocket?.close(1011, "relay_inactive");
		}, this.relayInactivityTimeoutMs);
		this.relayActivityTimer.unref?.();
	}

	private stopRelayActivityTimeout(): void {
		if (!this.relayActivityTimer) {
			return;
		}

		clearTimeout(this.relayActivityTimer);
		this.relayActivityTimer = null;
	}

	private startHeartbeat(): void {
		this.stopHeartbeat();
		this.heartbeatTimer = setInterval(() => {
			this.forwardToRelay({
				sentAt: new Date().toISOString(),
				type: "heartbeat",
			});
		}, this.heartbeatIntervalMs);
		this.heartbeatTimer.unref?.();
	}

	private stopHeartbeat(): void {
		if (!this.heartbeatTimer) {
			return;
		}

		clearInterval(this.heartbeatTimer);
		this.heartbeatTimer = null;
	}
}

export const createRelayConnectorClient = (options: RelayConnectorOptions) =>
	new RelayConnectorClient(options);
