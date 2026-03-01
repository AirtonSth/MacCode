import {
	createEdenClient,
	type EdenApiResult,
	type ApiError,
	toEdenApiResult,
} from "@remotecode/contracts";

import type { ApiConfig } from "./api-config-store";
import type { ChatDTO, MessageDTO, ProjectDTO, WorkspaceSelectionDTO } from "./types";

interface ListProjectsResponse {
	projects: ProjectDTO[];
}

interface ProjectPatchResponse {
	project: ProjectDTO;
}

interface ListChatsResponse {
	chats: ChatDTO[];
}

interface CreateChatResponse {
	chat: ChatDTO;
}

interface DeleteResponse {
	deleted: boolean;
}

interface ListMessagesResponse {
	messages: MessageDTO[];
}

type SelectionResponse = WorkspaceSelectionDTO;

const toTypedResult = <T>(response: unknown): EdenApiResult<T> =>
	toEdenApiResult<T>(response as { data?: unknown; error?: unknown; status?: number });

export interface RemoteCodeClient {
	createChat: (projectId: string, title?: string) => Promise<ChatDTO>;
	deleteChat: (chatId: string) => Promise<DeleteResponse>;
	getSelection: () => Promise<WorkspaceSelectionDTO>;
	listChats: (projectId: string) => Promise<ChatDTO[]>;
	listMessages: (chatId: string) => Promise<MessageDTO[]>;
	listProjects: () => Promise<ProjectDTO[]>;
	toggleFavorite: (projectId: string, isFavorite: boolean) => Promise<ProjectDTO>;
	updateSelection: (selection: WorkspaceSelectionDTO) => Promise<WorkspaceSelectionDTO>;
}

const assertData = <T>(result: EdenApiResult<T>): T => {
	if (result.data) {
		return result.data;
	}

	const fallback: ApiError = {
		code: "NETWORK",
		message: "Request failed",
		payload: null,
		status: result.status,
	};

	throw result.error ?? fallback;
};

export const createRemoteCodeClient = (config: ApiConfig): RemoteCodeClient => {
	const client = createEdenClient(config);

	return {
		async createChat(projectId: string, title?: string) {
			const response = await client.v1.projects({ id: projectId }).chats.post({ title });
			const result = toTypedResult<CreateChatResponse>(response);
			const payload = assertData(result);

			return payload.chat;
		},

		async deleteChat(chatId: string) {
			const response = await client.v1.chats({ id: chatId }).delete();
			const result = toTypedResult<DeleteResponse>(response);
			return assertData(result);
		},

		async getSelection() {
			const response = await client.v1.selection.get();
			const result = toTypedResult<SelectionResponse>(response);
			return assertData(result);
		},

		async listChats(projectId: string) {
			const response = await client.v1.projects({ id: projectId }).chats.get();
			const result = toTypedResult<ListChatsResponse>(response);
			const payload = assertData(result);

			return payload.chats;
		},

		async listMessages(chatId: string) {
			const response = await client.v1.chats({ id: chatId }).messages.get();
			const result = toTypedResult<ListMessagesResponse>(response);
			const payload = assertData(result);

			return payload.messages;
		},

		async listProjects() {
			const response = await client.v1.projects.get();
			const result = toTypedResult<ListProjectsResponse>(response);
			const payload = assertData(result);

			return payload.projects;
		},

		async toggleFavorite(projectId: string, isFavorite: boolean) {
			const response = await client.v1.projects({ id: projectId }).patch({ isFavorite });
			const result = toTypedResult<ProjectPatchResponse>(response);
			const payload = assertData(result);

			return payload.project;
		},

		async updateSelection(selection: WorkspaceSelectionDTO) {
			const response = await client.v1.selection.patch(selection);
			const result = toTypedResult<SelectionResponse>(response);
			return assertData(result);
		},
	};
};
