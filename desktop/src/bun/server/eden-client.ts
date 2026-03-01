import { treaty } from "@elysiajs/eden";

import type { ServerApp } from "./app";
import { serverConfig } from "./config";

const create = (options?: { baseUrl?: string; token?: string }) => {
	const baseUrl = options?.baseUrl ?? `https://127.0.0.1:${serverConfig.port}`;
	const token = options?.token ?? serverConfig.token;

	return treaty<ServerApp>(baseUrl, {
		headers: {
			authorization: `Bearer ${token}`,
		},
		});
};

type EdenClient = ReturnType<typeof create>;

const createWsClient = async (client: EdenClient, options?: { token?: string }) => {
	const token = options?.token ?? serverConfig.token;
	const socket = client.v1.ws.subscribe({ query: { token } });

	return await new Promise<typeof socket>((resolve, reject) => {
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
};

export const EdenClientFactory = {
	create,
	createWsClient,
};

export const createEdenClient = (options?: { baseUrl?: string; token?: string }) =>
	EdenClientFactory.create(options);

export const createEdenWsClient = async (
	client: ReturnType<typeof createEdenClient>,
	options?: { token?: string },
) => await EdenClientFactory.createWsClient(client, options);
