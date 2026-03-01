import { Elysia } from "elysia";

import { serverConfig } from "./config";
import { ChatController } from "./modules/chat/chat.controller";
import { ChatRepository } from "./modules/chat/chat.repository";
import { ChatService } from "./modules/chat/chat.service";
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
import { SelectionController } from "./modules/selection/selection.controller";
import { createSelectionRepository } from "./modules/selection/selection.repository";
import { createSelectionService } from "./modules/selection/selection.service";
import { TerminalController } from "./modules/terminal/terminal.controller";
import { createTerminalRepository } from "./modules/terminal/terminal.repository";
import { createTerminalService } from "./modules/terminal/terminal.service";
import { WsController } from "./modules/ws/ws.controller";
import { WsService } from "./modules/ws/ws.service";
import { DatabaseBootstrap } from "./shared/db/db.bootstrap";
import { DatabaseClientFactory } from "./shared/db/db.client";

export const ServerBootstrap = {
	async buildServerApp(databasePath?: string) {
		const databaseClient = await DatabaseClientFactory.create(databasePath);

		DatabaseBootstrap.initialize(databaseClient.sqlite);

		const projectRepository = new ProjectRepository(databaseClient.orm);
		const chatRepository = new ChatRepository(databaseClient.orm);
		const messageRepository = new MessageRepository(databaseClient.orm);
		const workspaceSelectionRepository = createSelectionRepository(databaseClient.orm);
		const terminalRepository = createTerminalRepository(databaseClient.orm);

		const projectService = new ProjectService(projectRepository);
		const chatService = new ChatService(chatRepository, projectRepository);
		const messageService = new MessageService(chatRepository, messageRepository);
		const gitService = new GitService(projectService);
		const workspaceSelectionService = createSelectionService(workspaceSelectionRepository);
		const terminalService = createTerminalService({
			chat: chatRepository,
			project: projectRepository,
			terminal: terminalRepository,
		});
		const wsService = new WsService(chatRepository, messageRepository, projectRepository);
		const codexModelsService = new CodexModelsService();

		const app = new Elysia()
			.group("/v1", (group) =>
				group
					.use(ProjectController.build(projectService))
					.use(ChatController.build(chatService))
					.use(MessageController.build(messageService))
					.use(GitController.build(gitService))
					.use(ProviderController.build(codexModelsService))
					.use(SelectionController.build(workspaceSelectionService))
					.use(TerminalController.build(terminalService)),
			)
			.use(WsController.build(wsService));

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
		const port = options?.port;
		const handle = await ServerBootstrap.buildServerApp(options?.databasePath);

		let serverReference: unknown;

		const listenPort = port ?? serverConfig.port;

		await new Promise<void>((resolve) => {
			handle.app.listen(listenPort, (server) => {
				serverReference = server;
				resolve();
			});
		});

		return {
			...handle,
			server: serverReference as { port: number },
		};
	},
};

export const buildServerApp = async (databasePath?: string) => await ServerBootstrap.buildServerApp(databasePath);

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
