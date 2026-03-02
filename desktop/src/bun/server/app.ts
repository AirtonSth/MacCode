import { Elysia } from "elysia";

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
import { MessageService } from "./modules/message/message.service";
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
import { TerminalController } from "./modules/terminal/terminal.controller";
import { createTerminalRepository } from "./modules/terminal/terminal.repository";
import { createTerminalService } from "./modules/terminal/terminal.service";
import { createWorkspaceEventsRepository } from "./modules/workspace-events/workspace-events.repository";
import { createWorkspaceEventsService } from "./modules/workspace-events/workspace-events.service";
import { WsController } from "./modules/ws/ws.controller";
import { WsService } from "./modules/ws/ws.service";
import { DatabaseBootstrap } from "./shared/db/db.bootstrap";
import { DatabaseClientFactory } from "./shared/db/db.client";

export const ServerBootstrap = {
	async buildServerApp(options?: { databasePath?: string; port?: number }) {
		const listenPort = options?.port ?? serverConfig.port;
		const databaseClient = await DatabaseClientFactory.create(options?.databasePath);

		DatabaseBootstrap.initialize(databaseClient.sqlite);

		const projectRepository = new ProjectRepository(databaseClient.orm);
		const chatRepository = new ChatRepository(databaseClient.orm);
		const messageRepository = new MessageRepository(databaseClient.orm);
		const workspaceSelectionRepository = createSelectionRepository(databaseClient.orm);
		const terminalRepository = createTerminalRepository(databaseClient.orm);
		const workspaceEventsRepository = createWorkspaceEventsRepository(databaseClient.orm);
		const serverMetadataRepository = createServerMetadataRepository(databaseClient.orm);

		const projectService = new ProjectService(projectRepository);
		const chatService = new ChatService(chatRepository, projectRepository);
		const messageService = new MessageService(chatRepository, messageRepository);
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
		const wsService = new WsService(
			chatRepository,
			messageRepository,
			projectRepository,
			undefined,
			workspaceEventsService,
		);
		const codexModelsService = new CodexModelsService();

		const app = new Elysia()
			.group("/v1", (group) =>
				group
					.use(DiscoveryController.build(serverMetadataService))
					.use(AuthController.build(serverMetadataService))
					.use(ProjectController.build(projectService, workspaceEventsService))
					.use(ChatController.build(chatService, workspaceEventsService))
					.use(MessageController.build(messageService))
					.use(GitController.build(gitService, workspaceEventsService))
					.use(ProviderController.build(codexModelsService))
					.use(SelectionController.build(workspaceSelectionService, workspaceEventsService))
					.use(TerminalController.build(terminalService, workspaceEventsService))
					.use(FsController.build(fsService)),
			)
			.use(WsController.build(wsService, workspaceEventsService));

		return {
			app,

			db: {
				close: () => {
					databaseClient.close();
				},
			},
		};
	},

	async createBackendServer(options?: { databasePath?: string; port?: number }): Promise<BackendHandle> {
		const listenPort = options?.port ?? serverConfig.port;
		const handle = await ServerBootstrap.buildServerApp({
			databasePath: options?.databasePath,
			port: listenPort,
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
	server: unknown;
}

export const createBackendServer = async (options?: { databasePath?: string; port?: number }): Promise<BackendHandle> =>
	await ServerBootstrap.createBackendServer(options);

export type ServerApp = Awaited<ReturnType<typeof buildServerApp>>["app"];
