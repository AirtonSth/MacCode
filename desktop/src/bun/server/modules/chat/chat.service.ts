import type { ChatDTO } from "../../types";
import type { ProjectRepository } from "../project/project.repository";
import type { ChatRepository } from "./chat.repository";

export interface ChatService {
	createChat: (projectId: string, title: string) => Promise<ChatDTO | null>;
	getChatById: (chatId: string) => Promise<ChatDTO | null>;
	listByProjectId: (projectId: string) => Promise<ChatDTO[] | null>;
	updateChat: (
		chatId: string,
		update: Partial<Pick<ChatDTO, "status" | "diffAdded" | "diffRemoved">>,
	) => Promise<ChatDTO | null>;
}

export const createChatService = (repositories: {
	chat: ChatRepository;
	project: ProjectRepository;
}): ChatService => ({
		createChat: async (projectId, title) => {
			const project = await repositories.project.findProjectById(projectId);

			if (!project) {
				return null;
			}

			return repositories.chat.createChat(projectId, title);
		},

		getChatById: async (chatId) => repositories.chat.findChatById(chatId),

		listByProjectId: async (projectId) => {
			const project = await repositories.project.findProjectById(projectId);

			if (!project) {
				return null;
			}

			return repositories.chat.getChatsByProjectId(projectId);
		},

		updateChat: async (chatId, update) => {
			const current = await repositories.chat.findChatById(chatId);

			if (!current) {
				return null;
			}

			const merged = {
				diffAdded: update.diffAdded ?? current.diffAdded,
				diffRemoved: update.diffRemoved ?? current.diffRemoved,
				status: update.status ?? current.status,
			};

			return repositories.chat.updateChat(chatId, merged);
		},
	});
