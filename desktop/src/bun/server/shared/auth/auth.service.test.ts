import { expect, test } from "bun:test";

import { createEdenClient, createEdenWsClient } from "../../eden-client";
import { createTestServer } from "../core/test-server";

test("REST sem token retorna 401", async () => {
	const { baseUrl, cleanup } = await createTestServer();

	try {
		const unauth = createEdenClient({ baseUrl, token: "" });
		const response = await unauth.v1.projects.get();

		expect(response.status).toBe(401);
	} finally {
		await cleanup();
	}
});

test("WS sem token é rejeitado", async () => {
	const { baseUrl, cleanup } = await createTestServer();

	let socket: WebSocket | undefined;
	let closeEvent: { code: number } | undefined;
	let errorEvent = false;

	try {
		socket = new WebSocket(`${baseUrl}/v1/ws`);
		await new Promise<void>((resolve) => {
			const timeout = setTimeout(() => {
				resolve();
			}, 2000);

			socket!.addEventListener("close", (event) => {
				clearTimeout(timeout);
				closeEvent = { code: event.code };
				resolve();
			});

			socket!.addEventListener("error", () => {
				errorEvent = true;
				clearTimeout(timeout);
				resolve();
			});
		});

		if (!closeEvent && !errorEvent) {
			throw new Error("no close/error event received");
		}

		if (closeEvent) {
			expect([4401, 1002]).toContain(closeEvent.code);
		} else {
			expect(errorEvent).toBe(true);
		}
	} finally {
		socket?.close();
		await new Promise((resolve) => setTimeout(resolve, 20));
		await cleanup();
	}
});

export const canCreateWsWithoutToken = async () => {
	const { baseUrl, cleanup } = await createTestServer();

	try {
		await createEdenWsClient(createEdenClient({ baseUrl }), { token: "" });

		return false;
	} finally {
		await cleanup();
	}
};
