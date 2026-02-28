import { Elysia } from "elysia";

import { serverConfig } from "./config";
import { createChatController } from "./modules/chat/chat.controller";
import { createChatRepository } from "./modules/chat/chat.repository";
import { createChatService } from "./modules/chat/chat.service";
import { createMessageController } from "./modules/message/message.controller";
import { createMessageRepository } from "./modules/message/message.repository";
import { createMessageService } from "./modules/message/message.service";
import { createProjectController } from "./modules/project/project.controller";
import { createProjectRepository } from "./modules/project/project.repository";
import { createProjectService } from "./modules/project/project.service";
import { createWsController } from "./modules/ws/ws.controller";
import { createWsService } from "./modules/ws/ws.service";
import { initializeDatabaseSchema } from "./shared/db/db.bootstrap";
import { createDatabaseClient } from "./shared/db/db.client";

export const buildServerApp = async (databasePath?: string) => {
	const databaseClient = await createDatabaseClient(databasePath);

	initializeDatabaseSchema(databaseClient.sqlite);

	const projectRepository = createProjectRepository(databaseClient.orm);
	const chatRepository = createChatRepository(databaseClient.orm);
	const messageRepository = createMessageRepository(databaseClient.orm);

	const projectService = createProjectService(projectRepository);
	const chatService = createChatService({
		chat: chatRepository,
		project: projectRepository,
	});
	const messageService = createMessageService({
		chat: chatRepository,
		message: messageRepository,
	});
	const wsService = createWsService({
		chat: chatRepository,
		message: messageRepository,
	});

	const app = new Elysia()
		.group("/v1", (group) =>
			group
				.use(createProjectController(projectService))
				.use(createChatController(chatService))
				.use(createMessageController(messageService)),
		)
		.use(createWsController(wsService));

	return {
		app,

		db: {
			close: databaseClient.close,
		},
	};
};

export interface BackendHandle {
	app: Awaited<ReturnType<typeof buildServerApp>>["app"];
	db: {
		close: () => void;
	};
	server: unknown;
}

export const createBackendServer = async (options?: {
	databasePath?: string;
	port?: number;
}): Promise<BackendHandle> => {
	const port = options?.port;
	const handle = await buildServerApp(options?.databasePath);

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
		server: serverReference,
	};
};

export type ServerApp = Awaited<ReturnType<typeof buildServerApp>>["app"];
