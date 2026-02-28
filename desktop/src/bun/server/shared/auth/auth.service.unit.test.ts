import { expect, test } from "bun:test";

import { AuthService } from "./auth.service";

test("readHeaderToken remove prefixo Bearer quando presente", () => {
	const request = new Request("http://localhost/v1/projects", {
		headers: {
			Authorization: "Bearer abc123",
		},
	});

	expect(AuthService.readHeaderToken(request)).toBe("abc123");
});

test("readQueryToken lê token da query para ws", () => {
	const request = new Request("http://localhost/v1/ws?token=ws-token");

	expect(AuthService.readQueryToken(request)).toBe("ws-token");
});

test("isWebSocketRoute detecta endpoint de websocket", () => {
	const request = new Request("http://localhost/v1/ws?token=abc");

	expect(AuthService.isWebSocketRoute(request)).toBe(true);
});

test("resolveWsToken combina header e query", () => {
	const headerRequest = new Request("http://localhost/v1/ws", {
		headers: {
			Authorization: "ws-header",
		},
	});
	const queryRequest = new Request("http://localhost/v1/ws?token=ws-query");

	expect(AuthService.resolveWsToken(headerRequest)).toBe("ws-header");
	expect(AuthService.resolveWsToken(queryRequest)).toBe("ws-query");
});
