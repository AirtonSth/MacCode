/* eslint-disable import/no-unresolved */
import { expect, test } from "bun:test";

import { createRemoteCodeClient } from "./remotecode-client";

interface BunServerLike {
	port: number;
	stop: (closeActiveConnections?: boolean) => void;
}

test("createRemoteCodeClient reaches a private proxied endpoint with connector routing", async () => {
	const server = Bun.serve({
		fetch: (request) => {
			return new Response(JSON.stringify({
				projects: [
					{
						connectorId: request.headers.get("x-remotecode-connector-id"),
						createdAt: new Date().toISOString(),
						id: "project-1",
						isFavorite: false,
						name: "Workspace 1",
						path: "/tmp/workspace-1",
						updatedAt: new Date().toISOString(),
					},
				],
			}), {
				headers: {
					"content-type": "application/json",
				},
			});
		},
		port: 0,
	}) as BunServerLike;

	try {
		const port = String(server.port ?? 0);
		const baseUrl = `http://127.0.0.1:${port}`;
		const client = createRemoteCodeClient({
			activeTarget: {
				accessToken: "private-access-token",
				backendUrl: baseUrl,
				connectorId: "con_1",
				kind: "private",
			},
			baseUrl,
			token: "private-access-token",
		});

		const projects = await client.listProjects();
		expect(projects[0]?.name).toBe("Workspace 1");
	} finally {
		server.stop(true);
	}
});
