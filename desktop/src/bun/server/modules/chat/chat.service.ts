import type { ChatContextDTO, ChatDTO, ProjectSummaryDTO, ThreadSummaryDTO } from "../../types";
import type { ProjectRepository } from "../project/project.repository";
import type { ChatRepository } from "./chat.repository";

export interface ChatServiceContract {
	createChat: (projectId: string, title: string) => Promise<ChatDTO | null>;
	getChatContext: (chatId: string) => Promise<ChatContextDTO | null>;
	getChatById: (chatId: string) => Promise<ChatDTO | null>;
	listByProjectId: (projectId: string) => Promise<ChatDTO[] | null>;
	listThreadSummariesByProjectId: (projectId: string) => Promise<ThreadSummaryDTO[] | null>;
	updateChat: (
		chatId: string,
		update: Partial<Pick<ChatDTO, "status" | "diffAdded" | "diffRemoved">>,
	) => Promise<ChatDTO | null>;
	deleteChat: (id: string) => Promise<boolean>;
}

export class ChatService implements ChatServiceContract {
	constructor(
		private readonly chatRepository: ChatRepository,
		private readonly projectRepository: ProjectRepository,
	) {}

	async getChatById(chatId: string): Promise<ChatDTO | null> {
		return this.chatRepository.findChatById(chatId);
	}

	async getChatContext(chatId: string): Promise<ChatContextDTO | null> {
		const chat = await this.chatRepository.findChatById(chatId);
		if (!chat) {
			return null;
		}

		const project = await this.projectRepository.findProjectById(chat.projectId);
		if (!project) {
			return null;
		}

		const projectSummary: ProjectSummaryDTO = {
			id: project.id,
			name: project.name,
			path: project.path,
		};

		return {
			chat,
			project: projectSummary,
		};
	}

async createChat(projectId: string, title: string): Promise<ChatDTO | null> {
		const project = await this.projectRepository.findProjectById(projectId);

		if (!project) {
			return null;
		}

		return this.chatRepository.createChat(projectId, title);
	}

	

	async listByProjectId(projectId: string): Promise<ChatDTO[] | null> {
		const project = await this.projectRepository.findProjectById(projectId);

		if (!project) {
			return null;
		}

		return this.chatRepository.getChatsByProjectId(projectId);
	}

	async listThreadSummariesByProjectId(projectId: string): Promise<ThreadSummaryDTO[] | null> {
		const project = await this.projectRepository.findProjectById(projectId);

		if (!project) {
			return null;
		}

		return this.chatRepository.getThreadSummariesByProjectId(projectId);
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

	async deleteChat(id: string): Promise<boolean> {
		return this.chatRepository.deleteChat(id);
	}
}

export const createChatService = (repositories: {
	chat: ChatRepository;
	project: ProjectRepository;
}) => new ChatService(repositories.chat, repositories.project);
