import { Elysia } from "elysia";
import { gzipSync } from "node:zlib";

import { serverConfig } from "./config";
import { AuthController } from "./modules/auth/auth.controller";
import { ChatController } from "./modules/chat/chat.controller";
import { ChatRepository } from "./modules/chat/chat.repository";
import { ChatService } from "./modules/chat/chat.service";
import { DiscoveryController } from "./modules/discovery/discovery.controller";
import { FsController } from "./modules/fs/fs.controller";
import { createFsService } from "./modules/fs/fs.service";
import { MessageController } from "./modules/message/message.controller";
import { MessageRepository } from "./modules/message/message.repository";
import { createChatTurnSnapshotRepository } from "./modules/message/chat-turn-snapshot.repository";
import { MessageService } from "./modules/message/message.service";
import { createLiveActivitySubscriptionRepository } from "./modules/live-activity/live-activity-subscription.repository";
import {
	createLiveActivityPushServiceFromEnvironment,
	createNoopLiveActivityPushService,
} from "./modules/live-activity/live-activity-push.service";
import { ProjectController } from "./modules/project/project.controller";
import { ProjectRepository } from "./modules/project/project.repository";
import { ProjectService } from "./modules/project/project.service";
import { GitController } from "./modules/git/git.controller";
import { GitService } from "./modules/git/git.service";
import { ProviderController } from "./modules/provider/provider.controller";
import { CodexModelsService } from "./modules/provider/codex-models.service";
import { createServerMetadataRepository } from "./modules/server-metadata/server-metadata.repository";
import { createServerMetadataService } from "./modules/server-metadata/server-metadata.service";
import { SelectionController } from "./modules/selection/selection.controller";
import { createSelectionRepository } from "./modules/selection/selection.repository";
import { createSelectionService } from "./modules/selection/selection.service";
import { PrivateAccountController } from "./modules/private-account/private-account.controller";
import { createPrivateAccountRepository } from "./modules/private-account/private-account.repository";
import { createPrivateAccountService } from "./modules/private-account/private-account.service";
import { TerminalController } from "./modules/terminal/terminal.controller";
import { createTerminalRepository } from "./modules/terminal/terminal.repository";
import { createTerminalService } from "./modules/terminal/terminal.service";
import { createWorkspaceEventsRepository } from "./modules/workspace-events/workspace-events.repository";
import { createWorkspaceEventsService } from "./modules/workspace-events/workspace-events.service";
import { createChatStreamEventRepository } from "./modules/ws/chat-stream-event.repository";
import { createChatStreamSnapshotRepository } from "./modules/ws/chat-stream-snapshot.repository";
import { WsController } from "./modules/ws/ws.controller";
import { WsService } from "./modules/ws/ws.service";
import { DatabaseBootstrap } from "./shared/db/db.bootstrap";
import { DatabaseClientFactory } from "./shared/db/db.client";
import { serverLogger } from "./shared/core/server-logger";

const MIN_GZIP_PAYLOAD_BYTES = 1024;

const isGzipAccepted = (request: Request): boolean => {
	const acceptEncoding = request.headers.get("accept-encoding");
	return typeof acceptEncoding === "string" && acceptEncoding.toLowerCase().includes("gzip");
};

const appendVaryValue = (current: string | null, value: string): string => {
	if (!current || current.trim().length === 0) {
		return value;
	}

	const values = current.split(",").map((item) => item.trim().toLowerCase());
	if (values.includes(value.toLowerCase())) {
		return current;
	}

	return `${current}, ${value}`;
};

const isCompressibleContentType = (contentType: string | null): boolean => {
	if (!contentType) {
		return false;
	}

	const normalized = contentType.toLowerCase();
	return normalized.startsWith("text/")
		|| normalized.includes("application/json")
		|| normalized.includes("application/javascript")
		|| normalized.includes("application/xml");
};

const readStatusCode = (value: unknown): number => {
	if (typeof value === "number" && Number.isFinite(value)) {
		return Math.floor(value);
	}

	if (typeof value === "string") {
		const parsed = Number.parseInt(value, 10);
		if (Number.isFinite(parsed)) {
			return parsed;
		}
	}

	return 200;
};

const mergeSetHeaders = (
	baseHeaders: Headers,
	setHeaders: Record<string, string | number>,
): Headers => {
	for (const [name, value] of Object.entries(setHeaders)) {
		baseHeaders.set(name, String(value));
	}

	return baseHeaders;
};

const createGzipResponse = (
	body: Uint8Array,
	input: {
		headers: Headers;
		status: number;
		statusText?: string;
	},
): Response | null => {
	if (body.byteLength < MIN_GZIP_PAYLOAD_BYTES) {
		return null;
	}

	const contentType = input.headers.get("content-type");
	if (!isCompressibleContentType(contentType)) {
		return null;
	}

	const contentEncoding = input.headers.get("content-encoding");
	if (contentEncoding && contentEncoding.trim().length > 0) {
		return null;
	}

	input.headers.set("content-encoding", "gzip");
	input.headers.set("vary", appendVaryValue(input.headers.get("vary"), "accept-encoding"));
	input.headers.delete("content-length");

	return new Response(gzipSync(body), {
		headers: input.headers,
		status: input.status,
		statusText: input.statusText,
	});
};

export const ServerBootstrap = {
	async buildServerApp(options?: {
		databasePath?: string;
		disableLiveActivityPush?: boolean;
		port?: number;
		privateBackendUrl?: string;
	}) {
		const listenPort = options?.port ?? serverConfig.port;
		const databaseClient = await DatabaseClientFactory.create(options?.databasePath);

		DatabaseBootstrap.initialize(databaseClient.sqlite);

		const projectRepository = new ProjectRepository(databaseClient.orm);
		const chatRepository = new ChatRepository(databaseClient.orm);
		const messageRepository = new MessageRepository(databaseClient.orm);
		const chatTurnSnapshotRepository = createChatTurnSnapshotRepository(databaseClient.orm);
		chatRepository.resetRuntimeActivityState();
		const workspaceSelectionRepository = createSelectionRepository(databaseClient.orm);
		const terminalRepository = createTerminalRepository(databaseClient.orm);
		const workspaceEventsRepository = createWorkspaceEventsRepository(databaseClient.orm);
		const chatStreamEventRepository = createChatStreamEventRepository(databaseClient.orm);
		const chatStreamSnapshotRepository = createChatStreamSnapshotRepository(databaseClient.orm);
		const serverMetadataRepository = createServerMetadataRepository(databaseClient.orm);
		const privateAccountRepository = createPrivateAccountRepository(serverMetadataRepository);
		const liveActivitySubscriptionRepository = createLiveActivitySubscriptionRepository(databaseClient.orm);

		const projectService = new ProjectService(projectRepository);
		const chatService = new ChatService(chatRepository, projectRepository);
		const messageService = new MessageService(
			chatRepository,
			messageRepository,
			chatStreamEventRepository,
			chatTurnSnapshotRepository,
		);
		const gitService = new GitService(projectService);
		const fsService = createFsService();
		const workspaceSelectionService = createSelectionService(workspaceSelectionRepository);
		const terminalService = createTerminalService({
			chat: chatRepository,
			project: projectRepository,
			terminal: terminalRepository,
		});
		const workspaceEventsService = createWorkspaceEventsService(workspaceEventsRepository);
		const serverMetadataService = createServerMetadataService(serverMetadataRepository, listenPort);
		const liveActivityPushService = options?.disableLiveActivityPush
			? createNoopLiveActivityPushService()
			: createLiveActivityPushServiceFromEnvironment({
				apnsAuthKeyId: serverConfig.liveActivityApnsAuthKeyId,
				apnsPrivateKeyPath: serverConfig.liveActivityApnsPrivateKeyPath,
				apnsTeamId: serverConfig.liveActivityApnsTeamId,
				apnsUseSandbox: serverConfig.liveActivityApnsUseSandbox,
				bundleIdentifier: serverConfig.liveActivityBundleIdentifier ?? "",
				firebaseProjectId: serverConfig.liveActivityFirebaseProjectId,
				serviceAccountPath: serverConfig.liveActivityServiceAccountPath,
				subscriptionStore: liveActivitySubscriptionRepository,
		});
		const privateAccountService = createPrivateAccountService(privateAccountRepository, {
			backendUrl: options?.privateBackendUrl ?? serverConfig.privateBackendUrl,
			localServerToken: serverConfig.token,
		});
		const wsService = new WsService(
			chatRepository,
			messageRepository,
			projectRepository,
			undefined,
			workspaceEventsService,
			chatStreamSnapshotRepository,
			chatStreamEventRepository,
			liveActivityPushService,
			chatTurnSnapshotRepository,
		);
		const codexModelsService = new CodexModelsService();

		const app = new Elysia()
			.mapResponse(async ({ request, responseValue, set }) => {
				if (!isGzipAccepted(request)) {
					return;
				}

				const fallbackStatus = readStatusCode(set.status);
				if (fallbackStatus === 204 || fallbackStatus === 304) {
					return;
				}

				if (responseValue instanceof Response) {
					if (responseValue.status === 204 || responseValue.status === 304) {
						return;
					}

					const body = new Uint8Array(await responseValue.clone().arrayBuffer());
					const headers = mergeSetHeaders(new Headers(responseValue.headers), set.headers);
					return createGzipResponse(body, {
						headers,
						status: responseValue.status,
						statusText: responseValue.statusText,
					}) ?? responseValue;
				}

				if (
					responseValue === null
					|| responseValue === undefined
					|| responseValue instanceof ReadableStream
					|| responseValue instanceof ArrayBuffer
					|| ArrayBuffer.isView(responseValue)
				) {
					return;
				}

				const payloadText = typeof responseValue === "string"
					? responseValue
					: JSON.stringify(responseValue);
				const headers = mergeSetHeaders(new Headers(), set.headers);
				if (!headers.has("content-type")) {
					headers.set(
						"content-type",
						typeof responseValue === "string" ? "text/plain; charset=utf-8" : "application/json; charset=utf-8",
					);
				}

				const payload = new TextEncoder().encode(payloadText);
				const compressed = createGzipResponse(payload, {
					headers,
					status: fallbackStatus,
				});
				return compressed ?? undefined;
			})
			.group("/v1", (group) =>
				group
					.use(DiscoveryController.build(serverMetadataService))
					.use(AuthController.build(serverMetadataService))
					.use(ProjectController.build(projectService, workspaceEventsService))
					.use(ChatController.build(chatService, workspaceEventsService, wsService, wsService))
					.use(MessageController.build(messageService))
					.use(GitController.build(gitService, workspaceEventsService))
					.use(ProviderController.build(codexModelsService))
					.use(SelectionController.build(workspaceSelectionService, workspaceEventsService))
					.use(PrivateAccountController.build(privateAccountService))
					.use(TerminalController.build(terminalService, workspaceEventsService))
					.use(FsController.build(fsService)),
			)
			.use(WsController.build(wsService, workspaceEventsService));

		return {
			app,
			privateAccountService,

			db: {
				close: () => {
					databaseClient.close();
				},
			},
		};
	},

	async createBackendServer(options?: {
		databasePath?: string;
		disableLiveActivityPush?: boolean;
		port?: number;
		privateBackendUrl?: string;
	}): Promise<BackendHandle> {
		const listenPort = options?.port ?? serverConfig.port;
		const bootStartedAt = Date.now();
		const handle = await ServerBootstrap.buildServerApp({
			databasePath: options?.databasePath,
			disableLiveActivityPush: options?.disableLiveActivityPush,
			port: listenPort,
			privateBackendUrl: options?.privateBackendUrl,
		});

		let serverReference: unknown;

		await new Promise<void>((resolve) => {
			handle.app.listen(
				{
					hostname: serverConfig.host,
					port: listenPort,
				},
				(server) => {
					serverReference = server;
					resolve();
				},
			);
		});

		const actualPort = (serverReference as { port?: number } | undefined)?.port ?? listenPort;
		await handle.privateAccountService.attachRuntime({
			app: handle.app,
			baseUrl: `http://127.0.0.1:${actualPort}`,
		});
		serverLogger.success("desktop-server", "HTTP server listening", {
			bindHost: serverConfig.host,
			durationMs: serverLogger.traceDurationMs(bootStartedAt),
			localBaseUrl: `http://127.0.0.1:${actualPort}`,
			privateBackendUrl: options?.privateBackendUrl ?? serverConfig.privateBackendUrl,
		});

		return {
			...handle,
			server: serverReference as { port: number },
		};
	},
};

export const buildServerApp = async (databasePath?: string) =>
	await ServerBootstrap.buildServerApp({ databasePath });

export interface BackendHandle {
	app: Awaited<ReturnType<typeof buildServerApp>>["app"];
	db: {
		close: () => void;
	};
	privateAccountService: Awaited<ReturnType<typeof buildServerApp>>["privateAccountService"];
	server: unknown;
}

export const createBackendServer = async (
	options?: {
		databasePath?: string;
		disableLiveActivityPush?: boolean;
		port?: number;
		privateBackendUrl?: string;
	},
): Promise<BackendHandle> =>
	await ServerBootstrap.createBackendServer(options);

export type ServerApp = Awaited<ReturnType<typeof buildServerApp>>["app"];
