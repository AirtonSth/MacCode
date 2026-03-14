/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import { createRealtimeClient } from "./ws-client";

test("createRealtimeClient opens the private relay websocket with query auth and connector headers", () => {
	const openedSockets: { options?: { headers?: Record<string, string> }; url: string }[] = [];
	const fakeSocket = {
		close: () => undefined,
		onclose: null as null | (() => void),
		onerror: null as null | (() => void),
		onmessage: null as null | ((event: { data: unknown }) => void),
		onopen: null as null | (() => void),
		readyState: 0,
		send: () => undefined,
	} as unknown as WebSocket;

	const realtime = createRealtimeClient({
		createSocket: (url, options) => {
			openedSockets.push({ options, url });
			return fakeSocket;
		},
		onEvent: () => {
			// no-op
		},
		target: {
			accessToken: "private-access-token",
			backendUrl: "https://private.remotecode.io:8787",
			connectorId: "con_1",
			kind: "private",
		},
	});

	realtime.connect();

	expect(openedSockets).toEqual([
		{
			options: {
				headers: {
					authorization: "Bearer private-access-token",
					"x-remotecode-connector-id": "con_1",
				},
			},
			url: "wss://private.remotecode.io:8787/v1/ws?accessToken=private-access-token&connectorId=con_1",
		},
	]);
});
