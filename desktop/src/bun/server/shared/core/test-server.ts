import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { type BackendHandle, createBackendServer } from "../../app";
import { createEdenClient } from "../../eden-client";

export interface RunningServer {
	backend: BackendHandle;
	baseUrl: string;
	databasePath: string;
	cleanup: () => Promise<void>;
	client: ReturnType<typeof createEdenClient>;
}

interface CreateTestServerOptions {
	disableLiveActivityPush?: boolean;
}

const toPort = (server: unknown): number => {
	if (!server || typeof server !== "object") {
		return 3001;
	}

	return (server as { port?: number }).port ?? 3001;
};

export const TestServerFactory = {
	async create(options?: CreateTestServerOptions): Promise<RunningServer> {
		const root = mkdtempSync(join(tmpdir(), "remotecode-tests-"));
		const databasePath = join(root, "remodecode.sqlite");
		const backend = await createBackendServer({
			databasePath,
			disableLiveActivityPush: options?.disableLiveActivityPush,
			port: 0,
		});

		const port = toPort(backend.server);
		const baseUrl = `http://127.0.0.1:${port}`;
		const client = createEdenClient({ baseUrl });

		return {
			backend,
			baseUrl,
			databasePath,

			cleanup: async () => {
				await backend.app.stop(true);
				await backend.db.close();
				rmSync(root, { force: true, recursive: true });
			},

			client,
		};
	},
};

export const createTestServer = async (options?: CreateTestServerOptions): Promise<RunningServer> =>
	await TestServerFactory.create(options);
