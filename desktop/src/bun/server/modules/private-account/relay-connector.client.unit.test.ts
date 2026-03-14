import { expect, test } from "bun:test";

import { RelayConnectorClient } from "./relay-connector.client";

type Listener = (event: MessageEvent | CloseEvent | Event) => void;

class FakeSocket {
	public readyState = 0;
	public closeCalls: Array<{ code?: number; reason?: string }> = [];
	public readonly sent: string[] = [];
	private readonly listeners = new Map<string, Listener[]>();

	public addEventListener(type: string, listener: Listener): void {
		const current = this.listeners.get(type) ?? [];
		current.push(listener);
		this.listeners.set(type, current);
	}

	public close(code?: number, reason?: string): void {
		this.closeCalls.push({ code, reason });
		this.emit("close", { code: code ?? 1000, reason: reason ?? "closed" } as CloseEvent);
	}

	public emit(type: string, event: MessageEvent | CloseEvent | Event): void {
		if (type === "open") {
			this.readyState = 1;
		}
		if (type === "close") {
			this.readyState = 3;
		}
		for (const listener of this.listeners.get(type) ?? []) {
			listener(event);
		}
	}

	public removeEventListener(type: string, listener: Listener): void {
		this.listeners.set(
			type,
			(this.listeners.get(type) ?? []).filter((candidate) => candidate !== listener),
		);
	}

	public send(data: string): void {
		this.sent.push(data);
	}
}

test("RelayConnectorClient forwards proxy requests and websocket events", async () => {
	const remoteSocket = new FakeSocket();
	const localSocket = new FakeSocket();
	const createdUrls: string[] = [];
	const handledRequests: Array<{ method: string; path: string }> = [];
	const client = new RelayConnectorClient({
		createSocket: (url) => {
			createdUrls.push(url);
			return createdUrls.length === 1 ? (remoteSocket as unknown as WebSocket) : (localSocket as unknown as WebSocket);
		},
		heartbeatIntervalMs: 60_000,
		localRequestHandler: async (input) => {
			handledRequests.push({ method: input.method, path: input.path });
			return {
				body: JSON.stringify({ ok: true }),
				headers: { "content-type": "application/json" },
				status: 200,
			};
		},
		localServerToken: "local-token",
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "connector-token",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});

	remoteSocket.emit("open", {} as Event);
	remoteSocket.emit("message", {
		data: JSON.stringify({
			connectorId: "con_1",
			type: "connector_auth",
		}),
	} as MessageEvent);
	remoteSocket.emit("message", {
		data: JSON.stringify({
			body: JSON.stringify({ query: "status=active" }),
			headers: {},
			method: "POST",
			path: "/v1/projects?status=active",
			requestId: "req_1",
			type: "proxy_request",
		}),
	} as MessageEvent);
	remoteSocket.emit("message", {
		data: JSON.stringify({
			clientConnectionId: "cli_1",
			type: "ws_open",
		}),
	} as MessageEvent);
	localSocket.emit("open", {} as Event);
	remoteSocket.emit("message", {
		data: JSON.stringify({
			clientConnectionId: "cli_1",
			payload: "{\"event\":\"ping\"}",
			type: "ws_client_event",
		}),
	} as MessageEvent);
	localSocket.emit("message", {
		data: "{\"event\":\"pong\"}",
	} as MessageEvent);
	await Promise.resolve();

	expect(createdUrls[0]).toContain("/v1/private/connectors/socket");
	expect(createdUrls[1]).toContain("/v1/ws?token=local-token");
	expect(handledRequests).toEqual([{ method: "POST", path: "/v1/projects?status=active" }]);
	expect(localSocket.sent).toContain("{\"event\":\"ping\"}");
	expect(remoteSocket.sent.some((item) => item.includes("\"type\":\"proxy_response\""))).toBe(true);
	expect(remoteSocket.sent.some((item) => item.includes("\"type\":\"ws_server_event\""))).toBe(true);
});

test("RelayConnectorClient preserves the private backend port for secure relay sockets", () => {
	const createdUrls: string[] = [];
	const client = new RelayConnectorClient({
		createSocket: (url) => {
			createdUrls.push(url);
			return new FakeSocket() as unknown as WebSocket;
		},
		localRequestHandler: async () => ({
			body: "",
			headers: {},
			status: 200,
		}),
		localServerToken: "local-token",
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "connector-token",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "https://private.remotecode.io:8787",
	});

	expect(createdUrls[0]).toBe(
		"wss://private.remotecode.io:8787/v1/private/connectors/socket?connectorId=con_1&token=connector-token",
	);

	client.stop();
});

test("RelayConnectorClient returns a 503 proxy response when the local desktop handler fails", async () => {
	const remoteSocket = new FakeSocket();
	const client = new RelayConnectorClient({
		createSocket: () => remoteSocket as unknown as WebSocket,
		heartbeatIntervalMs: 60_000,
		localRequestHandler: async () => {
			throw new Error("private_local_app_unavailable");
		},
		localServerToken: "local-token",
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "connector-token",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});

	remoteSocket.emit("open", {} as Event);
	remoteSocket.emit("message", {
		data: JSON.stringify({
			connectorId: "con_1",
			type: "connector_auth",
		}),
	} as MessageEvent);
	remoteSocket.emit("message", {
		data: JSON.stringify({
			body: null,
			headers: {},
			method: "GET",
			path: "/v1/projects",
			requestId: "req_1",
			type: "proxy_request",
		}),
	} as MessageEvent);
	await Promise.resolve();

	const proxyResponse = remoteSocket.sent.find((entry) => entry.includes("\"type\":\"proxy_response\""));
	if (!proxyResponse) {
		throw new Error("missing_proxy_response");
	}

	expect(JSON.parse(proxyResponse)).toMatchObject({
		requestId: "req_1",
		status: 503,
		type: "proxy_response",
	});
});

test("RelayConnectorClient ignores stale socket events after a newer start replaces the relay attempt", () => {
	const remoteSockets: FakeSocket[] = [];
	const client = new RelayConnectorClient({
		createSocket: () => {
			const socket = new FakeSocket();
			remoteSockets.push(socket);
			return socket as unknown as WebSocket;
		},
		heartbeatIntervalMs: 60_000,
		localRequestHandler: async () => ({
			body: "",
			headers: {},
			status: 200,
		}),
		localServerToken: "local-token",
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "token-1",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});
	client.start({
		connectorId: "con_1",
		connectorToken: "token-2",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});

	remoteSockets[0]?.emit("close", { code: 1011, reason: "stale_attempt" } as CloseEvent);
	expect(client.getState()).toBe("connecting");

	remoteSockets[1]?.emit("open", {} as Event);
	remoteSockets[1]?.emit("message", {
		data: JSON.stringify({
			connectorId: "con_1",
			type: "connector_auth",
		}),
	} as MessageEvent);

	expect(client.getState()).toBe("connected");
});

test("RelayConnectorClient preserves client websocket payloads that arrive before ws_open", () => {
	const remoteSocket = new FakeSocket();
	const localSocket = new FakeSocket();
	let socketCreationCount = 0;
	const client = new RelayConnectorClient({
		createSocket: () => {
			socketCreationCount += 1;
			return socketCreationCount === 1
				? (remoteSocket as unknown as WebSocket)
				: (localSocket as unknown as WebSocket);
		},
		heartbeatIntervalMs: 60_000,
		localRequestHandler: async () => ({
			body: "",
			headers: {},
			status: 200,
		}),
		localServerToken: "local-token",
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "connector-token",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});

	remoteSocket.emit("open", {} as Event);
	remoteSocket.emit("message", {
		data: JSON.stringify({
			connectorId: "con_1",
			type: "connector_auth",
		}),
	} as MessageEvent);
	remoteSocket.emit("message", {
		data: JSON.stringify({
			clientConnectionId: "cli_1",
			payload: "{\"event\":\"join_workspace\"}",
			type: "ws_client_event",
		}),
	} as MessageEvent);
	remoteSocket.emit("message", {
		data: JSON.stringify({
			clientConnectionId: "cli_1",
			type: "ws_open",
		}),
	} as MessageEvent);

	expect(localSocket.sent).toEqual([]);
	localSocket.emit("open", {} as Event);

	expect(localSocket.sent).toEqual(["{\"event\":\"join_workspace\"}"]);
});

test("RelayConnectorClient closes inactive relay sockets so the desktop service can reconnect", async () => {
	const remoteSocket = new FakeSocket();
	const states: string[] = [];
	const errors: string[] = [];
	const client = new RelayConnectorClient({
		connectTimeoutMs: 50,
		createSocket: () => remoteSocket as unknown as WebSocket,
		heartbeatIntervalMs: 60_000,
		localRequestHandler: async () => ({
			body: "",
			headers: {},
			status: 200,
		}),
		localServerToken: "local-token",
		onError: (message) => {
			errors.push(message);
		},
		onStateChange: (state) => {
			states.push(state);
		},
		relayInactivityTimeoutMs: 100,
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "connector-token",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});

	remoteSocket.emit("open", {} as Event);
	remoteSocket.emit("message", {
		data: JSON.stringify({
			connectorId: "con_1",
			type: "connector_auth",
		}),
	} as MessageEvent);

	await Bun.sleep(150);

	expect(errors).toContain("private_relay_socket_error");
	expect(states).toContain("error");
	expect(states.at(-1)).toBe("disconnected");
	expect(remoteSocket.closeCalls.some((call) => call.reason === "relay_inactive")).toBe(true);
});
