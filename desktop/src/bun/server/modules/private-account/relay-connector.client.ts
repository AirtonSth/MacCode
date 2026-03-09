interface SocketLike {
	addEventListener: (type: string, listener: (event: MessageEvent | CloseEvent | Event) => void) => void;
	close: (code?: number, reason?: string) => void;
	readyState: number;
	removeEventListener: (type: string, listener: (event: MessageEvent | CloseEvent | Event) => void) => void;
	send: (data: string) => void;
}

interface RelayConnectorOptions {
	createSocket?: (url: string) => SocketLike;
	heartbeatIntervalMs?: number;
	localRequestHandler: (input: {
		body: string | null;
		headers: Record<string, string>;
		method: string;
		path: string;
	}) => Promise<{
		body: string | null;
		headers: Record<string, string>;
		status: number;
	}>;
	localServerToken: string;
	onError?: (message: string) => void;
	onStateChange?: (state: "idle" | "connecting" | "connected" | "disconnected" | "error") => void;
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

const normalizeUrl = (value: string): string => value.trim().replace(/\/+$/u, "");

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
	private readonly createSocket: (url: string) => SocketLike;
	private readonly heartbeatIntervalMs: number;
	private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
	private localSockets = new Map<string, LocalSocketState>();
	private localServerBaseUrl: string | null = null;
	private readonly localServerToken: string;
	private readonly localRequestHandler: RelayConnectorOptions["localRequestHandler"];
	private onError: RelayConnectorOptions["onError"];
	private onStateChange: RelayConnectorOptions["onStateChange"];
	private relaySocket: SocketLike | null = null;
	private remoteClosedByUser = false;
	private state: "idle" | "connecting" | "connected" | "disconnected" | "error" = "idle";
	private suppressedLocalCloseIds = new Set<string>();

	public constructor(options: RelayConnectorOptions) {
		this.createSocket = options.createSocket ?? ((url) => new WebSocket(url) as unknown as SocketLike);
		this.heartbeatIntervalMs = options.heartbeatIntervalMs ?? 2_000;
		this.localRequestHandler = options.localRequestHandler;
		this.localServerToken = options.localServerToken;
		this.onError = options.onError;
		this.onStateChange = options.onStateChange;
	}

	public getState(): "idle" | "connecting" | "connected" | "disconnected" | "error" {
		return this.state;
	}

	public start(input: StartRelayInput): void {
		this.stop();
		this.remoteClosedByUser = false;
		this.localServerBaseUrl = normalizeUrl(input.localServerBaseUrl);
		this.setState("connecting");

		const relayUrl = `${toWsBaseUrl(input.privateBackendUrl)}/v1/private/connectors/socket?connectorId=${encodeURIComponent(input.connectorId)}&token=${encodeURIComponent(input.connectorToken)}`;
		const socket = this.createSocket(relayUrl);
		this.relaySocket = socket;

		socket.addEventListener("open", () => {
			this.startHeartbeat();
		});

		socket.addEventListener("message", (event) => {
			void this.handleRelayMessage(event as MessageEvent);
		});

		socket.addEventListener("close", () => {
			this.stopHeartbeat();
			this.closeAllLocalSockets();
			this.setState(this.remoteClosedByUser ? "idle" : "disconnected");
		});

		socket.addEventListener("error", () => {
			this.setState("error");
			this.onError?.("private_relay_socket_error");
		});
	}

	public stop(): void {
		this.remoteClosedByUser = true;
		this.stopHeartbeat();
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
		this.relaySocket?.send(JSON.stringify(frame));
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

		const response = await this.localRequestHandler({
			body,
			headers,
			method,
			path,
		});

		this.forwardToRelay({
			body: response.body,
			headers: response.headers,
			requestId,
			status: response.status,
			type: "proxy_response",
		});
	}

	private handleWsClientEvent(frame: Record<string, unknown>): void {
		const clientConnectionId = typeof frame.clientConnectionId === "string" ? frame.clientConnectionId : "";
		const payload = typeof frame.payload === "string" ? frame.payload : "";
		if (!clientConnectionId || payload.length === 0) {
			return;
		}

		const state = this.localSockets.get(clientConnectionId);
		if (!state) {
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

		const socket = this.createSocket(
			`${toWsBaseUrl(this.localServerBaseUrl)}/v1/ws?token=${encodeURIComponent(this.localServerToken)}`,
		);
		const state: LocalSocketState = {
			isOpen: false,
			pendingPayloads: [],
			socket,
		};
		this.localSockets.set(clientConnectionId, state);

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

