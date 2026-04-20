import assert from "node:assert/strict";
import { setTimeout as delay } from "node:timers/promises";
import { afterEach, beforeEach, describe, test } from "node:test";

import { createRealtimeClient } from "./ws-client";

interface MockSocketInstance {
	bufferedAmount: number;
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
		this.bufferedAmount = 0;
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

describe("createRealtimeClient hardening", () => {
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

	test("I-1 idleTimeoutMs <= 0 disables the idle watchdog", async () => {
		const realtime = createRealtimeClient({
			idleTimeoutMs: 0,
			onEvent: () => undefined,
			target: { baseUrl: "http://127.0.0.1:8835", kind: "local", token: "t" },
		});

		realtime.connect();
		const socket = MockWebSocket.instances[0];
		assert.ok(socket);
		socket.openConnection();

		await delay(120);

		assert.equal(socket.readyState, MockWebSocket.OPEN, "socket should still be open");
		assert.equal(MockWebSocket.instances.length, 1, "no reconnect should have been triggered");

		realtime.disconnect();
	});

	test("I-2 idleTimeoutMs > 0 closes the socket after no inbound activity", async () => {
		const realtime = createRealtimeClient({
			idleTimeoutMs: 40,
			onEvent: () => undefined,
			target: { baseUrl: "http://127.0.0.1:8835", kind: "local", token: "t" },
		});

		realtime.connect();
		const first = MockWebSocket.instances[0];
		assert.ok(first);
		first.openConnection();

		await delay(120);

		assert.equal(first.readyState, MockWebSocket.CLOSED, "first socket should be closed by idle watchdog");

		realtime.disconnect();
	});

	test("I-3 reliableQueueLimit overflow emits onReliableMessageError for reliable user_message", () => {
		const errors: { chatId: string; message: string; requestId: string }[] = [];
		const realtime = createRealtimeClient({
			onEvent: () => undefined,
			onReliableMessageError: (input) => {
				errors.push(input);
			},
			reliableQueueLimit: 1,
			target: { baseUrl: "http://127.0.0.1:8835", kind: "local", token: "t" },
		});

		// Do not open the socket — all sends go to the queue.
		realtime.connect();

		realtime.sendUserMessage("c1", "hello", { requestId: "req_1" });
		realtime.sendUserMessage("c1", "world", { requestId: "req_2" });

		assert.equal(errors.length, 1);
		assert.equal(errors[0]?.requestId, "req_2");
		assert.match(errors[0]?.message ?? "", /queue is full/i);

		realtime.disconnect();
	});

	test("I-4 reliable user_message dedupes by requestId instead of growing the queue", () => {
		const realtime = createRealtimeClient({
			onEvent: () => undefined,
			reliableQueueLimit: 5,
			target: { baseUrl: "http://127.0.0.1:8835", kind: "local", token: "t" },
		});

		// Don't open socket yet — let them queue.
		realtime.connect();
		const socket = MockWebSocket.instances[0];
		assert.ok(socket);

		realtime.sendUserMessage("c1", "first", { requestId: "req_1" });
		realtime.sendUserMessage("c1", "second", { requestId: "req_1" });
		realtime.sendUserMessage("c1", "third", { requestId: "req_1" });

		socket.openConnection();

		const userMessages = socket.sentPayloads
			.map((p) => JSON.parse(p) as { event: string; data?: { text?: string } })
			.filter((p) => p.event === "user_message");
		assert.equal(userMessages.length, 1, "deduped by requestId");
		assert.equal(userMessages[0]?.data?.text, "third");

		realtime.disconnect();
	});

	test("I-5 reliableQueueTtlMs drops expired user_messages and emits onReliableMessageError", async () => {
		const errors: { chatId: string; message: string; requestId: string }[] = [];
		const realtime = createRealtimeClient({
			onEvent: () => undefined,
			onReliableMessageError: (input) => {
				errors.push(input);
			},
			reliableQueueTtlMs: 30,
			target: { baseUrl: "http://127.0.0.1:8835", kind: "local", token: "t" },
		});

		realtime.connect();
		const socket = MockWebSocket.instances[0];
		assert.ok(socket);

		realtime.sendUserMessage("c1", "expires", { requestId: "req_1" });

		// Wait past TTL, then trigger dropExpiredReliableMessages via any send.
		await delay(60);
		realtime.sendUserMessage("c1", "fresh", { requestId: "req_2" });

		// Now open — req_1 must be gone, req_2 should flush.
		socket.openConnection();
		const userMessages = socket.sentPayloads
			.map((p) => JSON.parse(p) as { event: string; data?: { requestId?: string } })
			.filter((p) => p.event === "user_message");

		assert.equal(userMessages.length, 1);
		assert.equal(userMessages[0]?.data?.requestId, "req_2");
		assert.equal(errors.length, 1);
		assert.equal(errors[0]?.requestId, "req_1");
		assert.match(errors[0]?.message ?? "", /expired/i);

		realtime.disconnect();
	});

	test("I-6 backpressure: user_message queues when bufferedAmount > 1MB", () => {
		const realtime = createRealtimeClient({
			onEvent: () => undefined,
			target: { baseUrl: "http://127.0.0.1:8835", kind: "local", token: "t" },
		});

		realtime.connect();
		const socket = MockWebSocket.instances[0];
		assert.ok(socket);
		socket.openConnection();

		socket.bufferedAmount = 1_048_577; // just over 1MB
		realtime.sendUserMessage("c1", "hi", { requestId: "req_1" });

		const userMessages = socket.sentPayloads.filter((p) => p.includes("\"user_message\""));
		assert.equal(userMessages.length, 0, "must not write when backpressured");

		// Draining: bufferedAmount drops, a server event resets idle timer and... only a
		// direct flush re-attempts; a new send will re-flush though.
		socket.bufferedAmount = 0;
		realtime.sendUserMessage("c1", "later", { requestId: "req_2" });

		const afterDrain = socket.sentPayloads.filter((p) => p.includes("\"user_message\""));
		assert.equal(afterDrain.length, 2, "both reliable user_messages flush after drain");

		realtime.disconnect();
	});

	test("I-7 backpressure threshold is strict '>': exactly 1MB still sends", () => {
		const realtime = createRealtimeClient({
			onEvent: () => undefined,
			target: { baseUrl: "http://127.0.0.1:8835", kind: "local", token: "t" },
		});

		realtime.connect();
		const socket = MockWebSocket.instances[0];
		assert.ok(socket);
		socket.openConnection();

		socket.bufferedAmount = 1_048_576; // exactly the threshold — not "over"
		realtime.sendUserMessage("c1", "boundary", { requestId: "req_1" });

		const userMessages = socket.sentPayloads.filter((p) => p.includes("\"user_message\""));
		assert.equal(userMessages.length, 1, "sends at exactly the threshold (strict >)");

		realtime.disconnect();
	});

	test("I-8 onerror marks the socket errored so sends queue until reconnect completes", async () => {
		const realtime = createRealtimeClient({
			onEvent: () => undefined,
			target: { baseUrl: "http://127.0.0.1:8835", kind: "local", token: "t" },
		});

		realtime.connect();
		const first = MockWebSocket.instances[0];
		assert.ok(first);
		first.openConnection();

		// Fire onerror: ws-client marks socketErrored, then calls close() → onclose → reconnect scheduled.
		first.onerror?.();

		// After error and close, subsequent sends must enqueue (first socket is CLOSED, and socketErrored
		// would have prevented immediate write even before close ran).
		realtime.sendUserMessage("c1", "after-error", { requestId: "req_1" });

		// Wait for scheduled reconnect (base 300 + jitter → worst case ~300ms).
		await delay(700);

		const second = MockWebSocket.instances[1];
		assert.ok(second, "reconnect should have been scheduled after onerror");
		second.openConnection();

		const userMessages = second.sentPayloads.filter((p) => p.includes("\"user_message\""));
		assert.equal(userMessages.length, 1, "queued message flushes on the new socket");

		realtime.disconnect();
	});

	test("I-9 disconnect() clears queue, stops reconnect, and does not create new sockets", async () => {
		const realtime = createRealtimeClient({
			onEvent: () => undefined,
			target: { baseUrl: "http://127.0.0.1:8835", kind: "local", token: "t" },
		});

		realtime.connect();
		const first = MockWebSocket.instances[0];
		assert.ok(first);
		first.openConnection();

		// Drop the connection to schedule a reconnect, then disconnect before it fires.
		first.close();
		realtime.disconnect();

		await delay(700);

		assert.equal(MockWebSocket.instances.length, 1, "disconnect must cancel pending reconnect");

		// A send after disconnect is a no-op (nothing queued; no socket to create).
		realtime.sendUserMessage("c1", "ignored", { requestId: "req_after" });
		assert.equal(MockWebSocket.instances.length, 1, "send after disconnect stays no-op");
	});

	test("I-10 onerror does NOT double-schedule a reconnect alongside onclose", async () => {
		const realtime = createRealtimeClient({
			onEvent: () => undefined,
			target: { baseUrl: "http://127.0.0.1:8835", kind: "local", token: "t" },
		});

		realtime.connect();
		const first = MockWebSocket.instances[0];
		assert.ok(first);
		first.openConnection();

		// onerror path: marks errored + calls closeSocket() which fires onclose → scheduleReconnect once.
		first.onerror?.();

		await delay(700);

		assert.equal(MockWebSocket.instances.length, 2, "exactly one reconnect should have been created");

		realtime.disconnect();
	});
});
