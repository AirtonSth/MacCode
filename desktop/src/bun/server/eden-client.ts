import { treaty } from "@elysiajs/eden";

import type { ServerApp } from "./app";
import { serverConfig } from "./config";

export class EdenClientFactory {
	static create(options?: { baseUrl?: string; token?: string }) {
		const baseUrl = options?.baseUrl ?? `https://127.0.0.1:${serverConfig.port}`;
		const token = options?.token ?? serverConfig.token;

		return treaty<ServerApp>(baseUrl, {
			headers: {
				authorization: `Bearer ${token}`,
			},
		});
	}

	static async createWsClient(
		client: ReturnType<typeof EdenClientFactory.create>,
		options?: { token?: string },
	) {
		const token = options?.token ?? serverConfig.token;
		const socket = client.v1.ws.subscribe({ query: { token } });

		return await new Promise<(typeof socket)>((resolve, reject) => {
			if (socket.ws.readyState === 1) {
				resolve(socket);

				return;
			}

			socket.ws.addEventListener("open", () => {
				resolve(socket);
			});
			socket.ws.addEventListener("close", () => {
				reject(new Error("websocket was closed before open"));
			});
			socket.ws.addEventListener("error", () => {
				reject(new Error("failed to open websocket"));
			});
		});
	}
}

export const createEdenClient = (options?: { baseUrl?: string; token?: string }) =>
	EdenClientFactory.create(options);

export const createEdenWsClient = async (
	client: ReturnType<typeof createEdenClient>,
	options?: { token?: string },
) => EdenClientFactory.createWsClient(client, options);
