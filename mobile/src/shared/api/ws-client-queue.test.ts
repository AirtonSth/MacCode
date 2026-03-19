/* eslint-disable import/no-unresolved */
/* eslint-disable promise/avoid-new */
import { describe, expect, test } from "bun:test";

import { createRealtimeClient } from "./ws-client";

/**
 * [M-13] Messages sent between a WS error and reconnection must be queued.
 * [M-33] Queue overflow must fail explicitly once the reliable queue is full.
 */

interface FakeSocket {
	close: () => void;
	onclose: (() => void) | null;
	onerror: (() => void) | null;
	onmessage: ((event: { data: unknown }) => void) | null;
	onopen: (() => void) | null;
	readyState: number;
	send: (data: string) => void;
	sentPayloads: string[];
}

function createFakeSocketFactory() {
	const instances: FakeSocket[] = [];

	const factory = (url: string) => {
		void url;
		const sock: FakeSocket = {
			close() {
				if (this.readyState === 3) {
					return;
				}
				this.readyState = 3;
				this.onclose?.();
			},
			onclose: null,
			onerror: null,
			onmessage: null,
			onopen: null,
			readyState: 0,
			send(data: string) {
				this.sentPayloads.push(data);
			},
			sentPayloads: [],
		};
		instances.push(sock);
		return sock as unknown as WebSocket;
	};

	return { factory, instances };
}

describe("[M-13] socketErrored flag queues messages on error", () => {
	test("send after onerror queues the message instead of calling socket.send", async () => {
		const { factory, instances } = createFakeSocketFactory();

		const client = createRealtimeClient({
			createSocket: factory,
			onEvent: () => {
				// no-op
			},
			target: {
				baseUrl: "http://127.0.0.1:8835",
				kind: "local",
				token: "tok",
			},
		});

		client.connect();
		const first = instances[0];
		expect(first).toBeDefined();

		// Simulate open
		first.readyState = 1;
		first.onopen?.();

		// Record payloads before error
		const payloadsBefore = first.sentPayloads.length;

		// Trigger error — sets socketErrored = true then closes
		first.onerror?.();

		// Send a message while in errored state — should be queued, not sent
		client.sendUserMessage("chat-abc", "hello from errored state");

		// The old socket should not have received any new payloads
		expect(first.sentPayloads.length).toBe(payloadsBefore);

		// Wait for reconnect
		await new Promise((resolve) => {
			setTimeout(resolve, 500);
		});

		const second = instances[1];
		expect(second).toBeDefined();
		second.readyState = 1;
		second.onopen?.();

		// The queued user message should have been flushed to the new socket
		const userMessages = second.sentPayloads
			.map((raw) => JSON.parse(raw) as { data: { chatId?: string; text?: string }; event: string })
			.filter((msg) => msg.event === "user_message" && msg.data.chatId === "chat-abc");

		expect(userMessages.length).toBe(1);
		expect(userMessages[0].data.text).toBe("hello from errored state");
	});

	test("socketErrored flag is cleared on successful reconnection", async () => {
		const { factory, instances } = createFakeSocketFactory();

		const client = createRealtimeClient({
			createSocket: factory,
			onEvent: () => {
				// no-op
			},
			target: {
				baseUrl: "http://127.0.0.1:8835",
				kind: "local",
				token: "tok",
			},
		});

		client.connect();
		const first = instances[0];
		expect(first).toBeDefined();
		first.readyState = 1;
		first.onopen?.();

		// Trigger error
		first.onerror?.();

		// Wait for reconnect
		await new Promise((resolve) => {
			setTimeout(resolve, 500);
		});

		const second = instances[1];
		expect(second).toBeDefined();
		second.readyState = 1;
		second.onopen?.();

		// Send after reconnect should go directly (not queued)
		second.sentPayloads.length = 0;
		client.sendUserMessage("chat-xyz", "post-reconnect msg");

		const directMessages = second.sentPayloads
			.map((raw) => JSON.parse(raw) as { data: { chatId?: string }; event: string })
			.filter((msg) => msg.event === "user_message");

		expect(directMessages.length).toBe(1);
	});

	test("workspace ack removes a reliable user message from the resend queue", () => {
		const { factory, instances } = createFakeSocketFactory();

		const client = createRealtimeClient({
			createSocket: factory,
			onEvent: () => {
				// no-op
			},
			target: {
				baseUrl: "http://127.0.0.1:8835",
				kind: "local",
				token: "tok",
			},
		});

		client.connect();
		const socket = instances[0];
		expect(socket).toBeDefined();
		socket.readyState = 1;
		socket.onopen?.();

		client.sendUserMessage("chat-ack", "hello", {
			requestId: "req-ack",
		});
		expect(socket.sentPayloads.length).toBe(1);

		socket.onmessage?.({
			data: JSON.stringify({
				data: {
					originClientId: null,
					payload: {
						message: {
							chatId: "chat-ack",
							content: "hello",
							createdAt: new Date().toISOString(),
							id: "msg-1",
							role: "user",
						},
					},
					requestId: "req-ack",
					seq: 1,
					ts: new Date().toISOString(),
					type: "message_created",
				},
				event: "workspace_event",
			}),
		});

		client.sendJoinChat("chat-ack");
		const userMessages = socket.sentPayloads
			.map((raw) => JSON.parse(raw) as { data: { chatId?: string; requestId?: string }; event: string })
			.filter((msg) => msg.event === "user_message" && msg.data.requestId === "req-ack");

		expect(userMessages.length).toBe(1);
	});
});

describe("[M-33] Reliable queue bounds", () => {
	test("queue limit is 100", async () => {
		const { factory, instances } = createFakeSocketFactory();

		const client = createRealtimeClient({
			createSocket: factory,
			onEvent: () => {
				// no-op
			},
			target: {
				baseUrl: "http://127.0.0.1:8835",
				kind: "local",
				token: "tok",
			},
		});

		client.connect();

		// Do NOT open the socket — messages will be queued
		const sock = instances[0];
		expect(sock).toBeDefined();

		// Fill the queue well beyond old limit of 50
		for (let i = 0; i < 150; i += 1) {
			client.sendUserMessage(`chat-${i}`, `msg-${i}`);
		}

		// Now open — only the first 100 should flush because the queue is capped.
		sock.readyState = 1;
		sock.onopen?.();

		const flushed = sock.sentPayloads.length;
		expect(flushed).toBe(100);
	});

	test("subscription messages still flush when the reliable queue is full", () => {
		const { factory, instances } = createFakeSocketFactory();

		const client = createRealtimeClient({
			createSocket: factory,
			onEvent: () => {
				// no-op
			},
			target: {
				baseUrl: "http://127.0.0.1:8835",
				kind: "local",
				token: "tok",
			},
		});

		client.connect();
		const sock = instances[0];
		expect(sock).toBeDefined();

		// Socket stays connecting — messages go to queue

		// Add a join_chat first
		client.sendJoinChat("critical-chat");

		// Fill the queue beyond capacity with user messages.
		for (let i = 0; i < 150; i += 1) {
			client.sendUserMessage(`chat-${i}`, `msg-${i}`);
		}

		// Open the socket and check that join_chat survived
		sock.readyState = 1;
		sock.onopen?.();

		const flushedPayloads = sock.sentPayloads
			.map((raw) => JSON.parse(raw) as { data: { chatId?: string }; event: string });

		const joinMessages = flushedPayloads.filter(
			(msg) => msg.event === "join_chat" && msg.data.chatId === "critical-chat",
		);

		// The join_chat message must still be present (not evicted)
		expect(joinMessages.length).toBeGreaterThanOrEqual(1);
	});
});
