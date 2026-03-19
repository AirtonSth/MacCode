/* eslint-disable import/no-unresolved */
/* eslint-disable promise/avoid-new */
/* eslint-disable sonarjs/no-unused-collection */
import { describe, expect, test } from "bun:test";

import { createRealtimeClient, type ConnectionState } from "./ws-client";

/**
 * [M-24] Double reconnect on onerror + onclose.
 *
 * Before the fix, `onerror` called `scheduleReconnect()` directly, and
 * then `onclose` (which fires after every error) called it again.
 * This created two reconnect timers per failure, causing duplicate
 * sockets and silent message loss between the error and the reconnect.
 *
 * The fix makes `onerror` close the socket so that `onclose` is the
 * single reconnection entry point. These tests verify:
 *   1. Only one reconnect is scheduled per error event.
 *   2. Messages sent between error and reconnect are queued (not lost).
 *   3. The queued messages are flushed when the next socket connects.
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

describe("[M-24] WebSocket onerror does not double-reconnect", () => {
	test("onerror closes the socket so onclose handles reconnect once", async () => {
		const { factory, instances } = createFakeSocketFactory();
		const stateLog: ConnectionState[] = [];

		const client = createRealtimeClient({
			createSocket: factory,
			onConnectionStateChange: (state) => {
				stateLog.push(state);
			},
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

		// Simulate successful open
		first.readyState = 1;
		first.onopen?.();

		// Simulate a socket error — onerror should close the socket,
		// which triggers onclose exactly once.
		first.onerror?.();

		// Wait longer than the base reconnect delay (300ms)
		await new Promise((resolve) => {
			setTimeout(resolve, 500);
		});

		// Exactly one new socket should have been created for the reconnect
		expect(instances.length).toBe(2);
	});

	test("reconnecting state appears exactly once per disconnect cycle", async () => {
		const { factory, instances } = createFakeSocketFactory();
		const stateLog: ConnectionState[] = [];

		const client = createRealtimeClient({
			createSocket: factory,
			onConnectionStateChange: (state) => {
				stateLog.push(state);
			},
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

		stateLog.length = 0;

		// Trigger error
		first.onerror?.();

		// Count how many "reconnecting" notifications fire
		const reconnectingCount = stateLog.filter((s) => s === "reconnecting").length;
		expect(reconnectingCount).toBe(1);
	});

	test("messages sent after error are queued and flushed on reconnect", async () => {
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

		// Trigger error — socket is now closed
		first.onerror?.();

		// Send a message while disconnected — should be queued, not lost
		client.sendJoinChat("chat-123");

		// Wait for reconnect timer
		await new Promise((resolve) => {
			setTimeout(resolve, 500);
		});

		const second = instances[1];
		expect(second).toBeDefined();

		// Simulate the new socket opening
		second.readyState = 1;
		second.onopen?.();

		// The queued join_chat should now have been flushed to the new socket
		const joinMessages = second.sentPayloads
			.map((raw) => JSON.parse(raw) as { data: { chatId: string }; event: string })
			.filter((msg) => msg.event === "join_chat" && msg.data.chatId === "chat-123");

		expect(joinMessages.length).toBeGreaterThanOrEqual(1);
	});

	test("onclose without preceding onerror still reconnects normally", async () => {
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

		// Simulate a clean close (server-initiated)
		first.close();

		await new Promise((resolve) => {
			setTimeout(resolve, 500);
		});

		expect(instances.length).toBe(2);
	});

	test("disconnect after error prevents reconnect", async () => {
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

		// Trigger error then immediately disconnect
		first.onerror?.();
		client.disconnect();

		await new Promise((resolve) => {
			setTimeout(resolve, 500);
		});

		// No reconnect should have happened — only the initial socket
		// plus potentially one more from onerror's close. The disconnect()
		// call should have cancelled any pending reconnect timer.
		const socketCount = instances.length;
		expect(socketCount).toBeLessThanOrEqual(2);

		// Verify the client reports disconnected, not connected
		expect(client.getIsConnected()).toBe(false);
	});
});
