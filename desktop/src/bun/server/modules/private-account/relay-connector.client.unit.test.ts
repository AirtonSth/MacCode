import { expect, test } from "bun:test";

import { RelayConnectorClient } from "./relay-connector.client";

type Listener = (event: MessageEvent | CloseEvent | Event) => void;

class FakeSocket {
	public readyState = 0;
	public readonly sent: string[] = [];
	private readonly listeners = new Map<string, Listener[]>();

	public addEventListener(type: string, listener: Listener): void {
		const current = this.listeners.get(type) ?? [];
		current.push(listener);
		this.listeners.set(type, current);
	}

	public close(): void {
		this.emit("close", { code: 1000, reason: "closed" } as CloseEvent);
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
