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

test("J-1 describeError surfaces Error.message when createSocket throws Error", () => {
	const errors: string[] = [];
	const client = new RelayConnectorClient({
		createSocket: () => {
			throw new Error("boom_relay_connect");
		},
		localRequestHandler: async () => ({ body: "", headers: {}, status: 200 }),
		localServerToken: "local-token",
		onError: (message) => {
			errors.push(message);
		},
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "t",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});

	expect(errors.length).toBe(1);
	const message = errors[0] ?? "";
	expect(message.startsWith("private_relay_connect_failed")).toBe(true);
	expect(message).toContain("boom_relay_connect");
	expect(client.getState()).toBe("error");
});

test("J-2 describeError uses just the code when createSocket throws a non-Error value", () => {
	const errors: string[] = [];
	const client = new RelayConnectorClient({
		createSocket: () => {
			// eslint-disable-next-line @typescript-eslint/no-throw-literal
			throw { opaque: true } as unknown as Error;
		},
		localRequestHandler: async () => ({ body: "", headers: {}, status: 200 }),
		localServerToken: "local-token",
		onError: (message) => {
			errors.push(message);
		},
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "t",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});

	expect(errors).toEqual(["private_relay_connect_failed"]);
	expect(client.getState()).toBe("error");
});

test("J-3 describeError embeds a non-empty string thrown from createSocket", () => {
	const errors: string[] = [];
	const client = new RelayConnectorClient({
		createSocket: () => {
			// eslint-disable-next-line @typescript-eslint/no-throw-literal
			throw "dns_resolve_failed";
		},
		localRequestHandler: async () => ({ body: "", headers: {}, status: 200 }),
		localServerToken: "local-token",
		onError: (message) => {
			errors.push(message);
		},
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "t",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});

	expect(errors).toEqual(["private_relay_connect_failed: dns_resolve_failed"]);
});

test("J-4 describeError falls back to the code alone when an empty string is thrown", () => {
	const errors: string[] = [];
	const client = new RelayConnectorClient({
		createSocket: () => {
			// eslint-disable-next-line @typescript-eslint/no-throw-literal
			throw "";
		},
		localRequestHandler: async () => ({ body: "", headers: {}, status: 200 }),
		localServerToken: "local-token",
		onError: (message) => {
			errors.push(message);
		},
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "t",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});

	expect(errors).toEqual(["private_relay_connect_failed"]);
});

test("J-5 relay error event reports onError, transitions to disconnected, and closes with 1011 relay_error", () => {
	const remoteSocket = new FakeSocket();
	const errors: string[] = [];
	const states: string[] = [];
	const client = new RelayConnectorClient({
		createSocket: () => remoteSocket as unknown as WebSocket,
		heartbeatIntervalMs: 60_000,
		localRequestHandler: async () => ({ body: "", headers: {}, status: 200 }),
		localServerToken: "local-token",
		onError: (message) => {
			errors.push(message);
		},
		onStateChange: (state) => {
			states.push(state);
		},
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "t",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});
	remoteSocket.emit("open", {} as Event);
	remoteSocket.emit("message", {
		data: JSON.stringify({ connectorId: "con_1", type: "connector_auth" }),
	} as MessageEvent);
	expect(client.getState()).toBe("connected");

	remoteSocket.emit("error", { error: new Error("pipe_broken") } as unknown as Event);

	expect(errors.some((m) => m.startsWith("private_relay_socket_error"))).toBe(true);
	expect(states).toContain("disconnected");
	expect(remoteSocket.closeCalls.some((c) => c.code === 1011 && c.reason === "relay_error")).toBe(true);
});

test("J-6 ws_close that arrives before ws_open does not leak into suppressedLocalCloseIds", () => {
	const remoteSocket = new FakeSocket();
	const localSocket = new FakeSocket();
	let count = 0;
	const client = new RelayConnectorClient({
		createSocket: () => {
			count += 1;
			return count === 1 ? (remoteSocket as unknown as WebSocket) : (localSocket as unknown as WebSocket);
		},
		heartbeatIntervalMs: 60_000,
		localRequestHandler: async () => ({ body: "", headers: {}, status: 200 }),
		localServerToken: "local-token",
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "t",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});
	remoteSocket.emit("open", {} as Event);
	remoteSocket.emit("message", {
		data: JSON.stringify({ connectorId: "con_1", type: "connector_auth" }),
	} as MessageEvent);

	// ws_close arrives BEFORE ws_open for this clientConnectionId (race).
	remoteSocket.emit("message", {
		data: JSON.stringify({
			clientConnectionId: "cli_race_1",
			code: 4000,
			reason: "race_close",
			type: "ws_close",
		}),
	} as MessageEvent);

	// Now ws_open arrives: the local socket should be created, immediately closed,
	// and NOT leave a lingering suppression entry that leaks memory.
	remoteSocket.emit("message", {
		data: JSON.stringify({ clientConnectionId: "cli_race_1", type: "ws_open" }),
	} as MessageEvent);

	// The local socket was closed synchronously in handleWsOpen with the pending close args.
	expect(localSocket.closeCalls).toEqual([{ code: 4000, reason: "race_close" }]);

	// Emitting a close AFTER handleWsOpen must NOT be suppressed since no listener was attached.
	// The close listener is never registered for this socket because handleWsOpen returned early.
	// So a subsequent synthetic close event should be a no-op (no listeners).
	localSocket.emit("close", { code: 1006, reason: "late_close" } as CloseEvent);

	// The relay must not receive a ws_close frame echoing the late close (no handler was attached).
	expect(remoteSocket.sent.filter((f) => f.includes("\"type\":\"ws_close\""))).toEqual([]);
});

test("J-7 stop() transitions to idle and marks remoteClosedByUser so close lands in idle", () => {
	const remoteSocket = new FakeSocket();
	const states: string[] = [];
	const client = new RelayConnectorClient({
		createSocket: () => remoteSocket as unknown as WebSocket,
		heartbeatIntervalMs: 60_000,
		localRequestHandler: async () => ({ body: "", headers: {}, status: 200 }),
		localServerToken: "local-token",
		onStateChange: (state) => {
			states.push(state);
		},
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "t",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});
	remoteSocket.emit("open", {} as Event);
	remoteSocket.emit("message", {
		data: JSON.stringify({ connectorId: "con_1", type: "connector_auth" }),
	} as MessageEvent);
	expect(client.getState()).toBe("connected");

	client.stop();

	expect(client.getState()).toBe("idle");
	expect(remoteSocket.closeCalls.at(-1)).toEqual({ code: 1000, reason: "client_stop" });
});

test("J-8 connect timeout fires onError, transitions to error, and closes relay with 1011 relay_connect_timeout", async () => {
	const remoteSocket = new FakeSocket();
	const errors: string[] = [];
	const states: string[] = [];
	const client = new RelayConnectorClient({
		connectTimeoutMs: 2_000, // floor enforced
		createSocket: () => remoteSocket as unknown as WebSocket,
		heartbeatIntervalMs: 60_000,
		localRequestHandler: async () => ({ body: "", headers: {}, status: 200 }),
		localServerToken: "local-token",
		onError: (message) => {
			errors.push(message);
		},
		onStateChange: (state) => {
			states.push(state);
		},
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "t",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});
	// Do NOT emit connector_auth — let the connect timer fire.
	await Bun.sleep(2_100);

	expect(errors).toContain("private_relay_connect_failed");
	expect(states).toContain("error");
	expect(remoteSocket.closeCalls.some((c) => c.code === 1011 && c.reason === "relay_connect_timeout")).toBe(true);
});

test("J-9 ws_open failure to create local socket forwards a ws_close frame with code 1011 local_socket_open_failed", () => {
	const remoteSocket = new FakeSocket();
	let count = 0;
	const errors: string[] = [];
	const client = new RelayConnectorClient({
		createSocket: () => {
			count += 1;
			if (count === 1) {
				return remoteSocket as unknown as WebSocket;
			}
			throw new Error("local_app_closed");
		},
		heartbeatIntervalMs: 60_000,
		localRequestHandler: async () => ({ body: "", headers: {}, status: 200 }),
		localServerToken: "local-token",
		onError: (message) => {
			errors.push(message);
		},
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "t",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});
	remoteSocket.emit("open", {} as Event);
	remoteSocket.emit("message", {
		data: JSON.stringify({ connectorId: "con_1", type: "connector_auth" }),
	} as MessageEvent);

	remoteSocket.emit("message", {
		data: JSON.stringify({ clientConnectionId: "cli_1", type: "ws_open" }),
	} as MessageEvent);

	const closeFrame = remoteSocket.sent.find((f) => f.includes("\"type\":\"ws_close\""));
	expect(closeFrame).toBeDefined();
	const parsed = JSON.parse(closeFrame ?? "{}") as { clientConnectionId: string; code: number; reason: string };
	expect(parsed).toEqual({
		clientConnectionId: "cli_1",
		code: 1011,
		reason: "local_socket_open_failed",
		type: "ws_close",
	} as unknown as typeof parsed);
	expect(errors.some((m) => m.startsWith("private_local_app_unavailable"))).toBe(true);
});

test("J-10 forwardToRelay no-ops when the relay socket is not in readyState 1", () => {
	const remoteSocket = new FakeSocket();
	const localSocket = new FakeSocket();
	let count = 0;
	const client = new RelayConnectorClient({
		createSocket: () => {
			count += 1;
			return count === 1 ? (remoteSocket as unknown as WebSocket) : (localSocket as unknown as WebSocket);
		},
		heartbeatIntervalMs: 60_000,
		localRequestHandler: async () => ({ body: "", headers: {}, status: 200 }),
		localServerToken: "local-token",
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "t",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});
	remoteSocket.emit("open", {} as Event);
	remoteSocket.emit("message", {
		data: JSON.stringify({ connectorId: "con_1", type: "connector_auth" }),
	} as MessageEvent);
	// Open the local socket.
	remoteSocket.emit("message", {
		data: JSON.stringify({ clientConnectionId: "cli_1", type: "ws_open" }),
	} as MessageEvent);
	localSocket.emit("open", {} as Event);

	const sentBefore = remoteSocket.sent.length;

	// Close the relay — readyState becomes 3.
	remoteSocket.emit("close", { code: 1006, reason: "gone" } as CloseEvent);

	// Any further local-socket messages must not throw and must not write to the remote socket.
	localSocket.emit("message", { data: "{\"event\":\"late\"}" } as MessageEvent);

	expect(remoteSocket.sent.length).toBe(sentBefore);
	expect(client.getState()).toBe("disconnected");
});

test("J-11 restart after error: second start() replaces attempt and reaches connected", () => {
	const sockets: FakeSocket[] = [];
	const states: string[] = [];
	const client = new RelayConnectorClient({
		createSocket: () => {
			const s = new FakeSocket();
			sockets.push(s);
			return s as unknown as WebSocket;
		},
		heartbeatIntervalMs: 60_000,
		localRequestHandler: async () => ({ body: "", headers: {}, status: 200 }),
		localServerToken: "local-token",
		onStateChange: (s) => {
			states.push(s);
		},
	});

	client.start({
		connectorId: "con_1",
		connectorToken: "t1",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});
	sockets[0]?.emit("open", {} as Event);
	sockets[0]?.emit("message", {
		data: JSON.stringify({ connectorId: "con_1", type: "connector_auth" }),
	} as MessageEvent);
	// Surface an error on attempt 1.
	sockets[0]?.emit("error", { error: new Error("transient") } as unknown as Event);
	expect(client.getState()).toBe("disconnected");

	client.start({
		connectorId: "con_1",
		connectorToken: "t2",
		localServerBaseUrl: "http://127.0.0.1:8835",
		privateBackendUrl: "http://127.0.0.1:8787",
	});
	sockets[1]?.emit("open", {} as Event);
	sockets[1]?.emit("message", {
		data: JSON.stringify({ connectorId: "con_1", type: "connector_auth" }),
	} as MessageEvent);

	expect(client.getState()).toBe("connected");
});
