import assert from "node:assert/strict";
import { setTimeout as delay } from "node:timers/promises";
import { afterEach, beforeEach, describe, test } from "node:test";

import { buildRealtimeWebSocketHeaders, buildRealtimeWebSocketUrl, createRealtimeClient } from "./ws-client";

interface SentPayload {
	data: Record<string, unknown>;
	event: string;
}

interface MockSocketInstance {
	onclose: (() => void) | null;
	onerror: (() => void) | null;
	onmessage: ((event: { data: unknown }) => void) | null;
	onopen: (() => void) | null;
	openConnection: () => void;
	url: string;
	options?: { headers?: Record<string, string> };
	close: () => void;
	readyState: number;
	send: (payload: string) => void;
	sentPayloads: string[];
}

interface MockSocketConstructor {
	new(url: string): MockSocketInstance;
	CONNECTING: number;
	OPEN: number;
	CLOSING: number;
	CLOSED: number;
	instances: MockSocketInstance[];
	reset: () => void;
	prototype: MockSocketInstance;
}

const createMockWebSocket = (): MockSocketConstructor => {
	const instances: MockSocketInstance[] = [];
	const MockSocket = function MockSocketConstructorFn(
		this: MockSocketInstance,
		url: string,
		options?: { headers?: Record<string, string> },
	) {
		this.url = url;
		this.options = options;
		this.sentPayloads = [];
		this.readyState = MockSocket.CONNECTING;
		this.onopen = null;
		this.onclose = null;
		this.onerror = null;
		this.onmessage = null;
		instances.push(this);
	} as unknown as MockSocketConstructor;

	MockSocket.CONNECTING = 0;
	MockSocket.OPEN = 1;
	MockSocket.CLOSING = 2;
	MockSocket.CLOSED = 3;
	MockSocket.instances = instances;
	MockSocket.reset = () => {
		instances.length = 0;
	};

	MockSocket.prototype.send = function send(payload: string) {
		this.sentPayloads.push(payload);
	};

	MockSocket.prototype.close = function close() {
		this.readyState = MockSocket.CLOSED;
		if (this.onclose) {
			this.onclose();
		}
	};

	MockSocket.prototype.openConnection = function openConnection() {
		this.readyState = MockSocket.OPEN;
		if (this.onopen) {
			this.onopen();
		}
	};

	return MockSocket;
};

const toPayloads = (socket: MockSocketInstance): SentPayload[] => {
	return socket.sentPayloads.map((item) => JSON.parse(item) as SentPayload);
};

describe("createRealtimeClient workspace subscription resilience", () => {
	let originalWebSocket: typeof WebSocket = globalThis.WebSocket;
	let MockWebSocket: MockSocketConstructor = createMockWebSocket();

	beforeEach(() => {
		originalWebSocket = globalThis.WebSocket;
		MockWebSocket = createMockWebSocket();
		globalThis.WebSocket = MockWebSocket as unknown as typeof WebSocket;
	});

	afterEach(() => {
		globalThis.WebSocket = originalWebSocket;
		MockWebSocket.reset();
	});

	test("queues only the latest join_workspace while socket is connecting", () => {
		const realtime = createRealtimeClient({
			onEvent: () => {
				// no-op
			},
			target: {
				baseUrl: "http://127.0.0.1:8835",
				kind: "local",
				token: "token",
			},
		});

		realtime.connect();
		const socket = MockWebSocket?.instances[0];
		assert.ok(socket, "missing websocket instance");

		realtime.sendJoinWorkspace(3, "client-a");
		realtime.sendJoinWorkspace(8, "client-a");

		socket.openConnection();
		const workspaceMessages = toPayloads(socket).filter((payload) => payload.event === "join_workspace");
		assert.equal(workspaceMessages.length, 1);
		assert.equal(workspaceMessages[0]?.data.lastSeq, 8);
		assert.equal(workspaceMessages[0]?.data.clientId, "client-a");
	});

	test("re-subscribes workspace after reconnect", async () => {
		const realtime = createRealtimeClient({
			onEvent: () => {
				// no-op
			},
			target: {
				baseUrl: "http://127.0.0.1:8835",
				kind: "local",
				token: "token",
			},
		});

		realtime.connect();
		const firstSocket = MockWebSocket?.instances[0];
		assert.ok(firstSocket, "missing first websocket");
		firstSocket.openConnection();

		realtime.sendJoinWorkspace(11, "client-b");
		firstSocket.sentPayloads.length = 0;
		firstSocket.close();

		await delay(350);
		const secondSocket = MockWebSocket?.instances[1];
		assert.ok(secondSocket, "missing reconnected websocket");
		secondSocket.openConnection();

		const workspaceMessages = toPayloads(secondSocket).filter((payload) => payload.event === "join_workspace");
		assert.equal(workspaceMessages.length, 1);
		assert.equal(workspaceMessages[0]?.data.lastSeq, 11);
		assert.equal(workspaceMessages[0]?.data.clientId, "client-b");
	});

	test("sends only the latest queued join_workspace after reconnect", async () => {
		const realtime = createRealtimeClient({
			onEvent: () => {
				// no-op
			},
			target: {
				baseUrl: "http://127.0.0.1:8835",
				kind: "local",
				token: "token",
			},
		});

		realtime.connect();
		const firstSocket = MockWebSocket?.instances[0];
		assert.ok(firstSocket, "missing first websocket");
		firstSocket.openConnection();

		realtime.sendJoinWorkspace(4, "client-c");
		firstSocket.close();
		realtime.sendJoinWorkspace(6, "client-c");
		realtime.sendJoinWorkspace(15, "client-c");

		await delay(350);
		const secondSocket = MockWebSocket?.instances[1];
		assert.ok(secondSocket, "missing reconnected websocket");
		secondSocket.openConnection();

		const workspaceMessages = toPayloads(secondSocket).filter((payload) => payload.event === "join_workspace");
		assert.equal(workspaceMessages.length, 1);
		assert.equal(workspaceMessages[0]?.data.lastSeq, 15);
		assert.equal(workspaceMessages[0]?.data.clientId, "client-c");
	});

	test("builds private websocket url and headers for relay mode", () => {
		assert.equal(buildRealtimeWebSocketUrl({
			accessToken: "private-access-token",
			backendUrl: "https://private.remotecode.dev",
			connectorId: "con_1",
			kind: "private",
		}), "wss://private.remotecode.dev/v1/ws");
		assert.deepEqual(buildRealtimeWebSocketHeaders({
			accessToken: "private-access-token",
			backendUrl: "https://private.remotecode.dev",
			connectorId: "con_1",
			kind: "private",
		}), {
			authorization: "Bearer private-access-token",
			"x-remotecode-connector-id": "con_1",
		});
	});
});
