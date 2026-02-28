import type { ChatDTO } from "../../types";
import type { ProjectRepository } from "../project/project.repository";
import type { ChatRepository } from "./chat.repository";

export interface ChatServiceContract {
	createChat: (projectId: string, title: string) => Promise<ChatDTO | null>;
	getChatById: (chatId: string) => Promise<ChatDTO | null>;
	listByProjectId: (projectId: string) => Promise<ChatDTO[] | null>;
	updateChat: (
		chatId: string,
		update: Partial<Pick<ChatDTO, "status" | "diffAdded" | "diffRemoved">>,
	) => Promise<ChatDTO | null>;
}

export class ChatService implements ChatServiceContract {
	constructor(
		private readonly chatRepository: ChatRepository,
		private readonly projectRepository: ProjectRepository,
	) {}

	async createChat(projectId: string, title: string): Promise<ChatDTO | null> {
		const project = await this.projectRepository.findProjectById(projectId);

		if (!project) {
			return null;
		}

		return this.chatRepository.createChat(projectId, title);
	}

	getChatById(chatId: string): Promise<ChatDTO | null> {
		return Promise.resolve(this.chatRepository.findChatById(chatId));
	}

	async listByProjectId(projectId: string): Promise<ChatDTO[] | null> {
		const project = await this.projectRepository.findProjectById(projectId);

		if (!project) {
			return null;
		}

		return this.chatRepository.getChatsByProjectId(projectId);
	}

	async updateChat(chatId: string, update: Partial<Pick<ChatDTO, "status" | "diffAdded" | "diffRemoved">>): Promise<ChatDTO | null> {
		const current = await this.chatRepository.findChatById(chatId);

		if (!current) {
			return null;
		}

		const merged = {
			diffAdded: update.diffAdded ?? current.diffAdded,
			diffRemoved: update.diffRemoved ?? current.diffRemoved,
			status: update.status ?? current.status,
		};

		return this.chatRepository.updateChat(chatId, merged);
	}
}

export const createChatService = (repositories: {
	chat: ChatRepository;
	project: ProjectRepository;
}) => new ChatService(repositories.chat, repositories.project);
