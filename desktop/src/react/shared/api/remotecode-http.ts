export interface ApiConfig {
	baseUrl: string;
	token: string;
}

export interface ProjectDTO {
	id: string;
	name: string;
	path: string;
	isFavorite: boolean;
	createdAt: string;
	updatedAt: string;
}

export interface ChatDTO {
	id: string;
	projectId: string;
	provider: "fake" | "codex";
	title: string;
	status: "pending" | "running" | "completed" | "failed";
	diffAdded: number;
	diffRemoved: number;
	updatedAt: string;
}

export interface MessageDTO {
	id: string;
	chatId: string;
	role: "user" | "assistant";
	content: string;
	createdAt: string;
}

export interface WorkspaceSelection {
	selectedProjectId: string | null;
	selectedChatId: string | null;
}

export class RemoteCodeApiError extends Error {
	constructor(
		public readonly status: number,
		public readonly code: string,
		public readonly payload: unknown,
		message: string,
	) {
		super(message);
		this.name = "RemoteCodeApiError";
	}
}

interface RestListProjectsResponse {
	projects: ProjectDTO[];
}

interface RestCreateProjectResponse {
	created: boolean;
	project: ProjectDTO;
}

interface RestProjectPatchResponse {
	project: ProjectDTO;
}

interface RestListChatsResponse {
	chats: ChatDTO[];
}

interface RestCreateChatResponse {
	chat: ChatDTO;
}

interface RestListMessagesResponse {
	messages: MessageDTO[];
}

interface RestWorkspaceSelectionResponse {
	selectedProjectId: string | null;
	selectedChatId: string | null;
}

interface RestDeleteResponse {
	deleted: boolean;
}

interface RequestInput {
	method: "GET" | "POST" | "PATCH" | "DELETE";
	path: string;
	body?: unknown;
}

const isObject = (value: unknown): value is Record<string, unknown> =>
	typeof value === "object" && value !== null;

const toErrorText = (body: unknown, fallback: string): string => {
	if (!isObject(body)) {
		return fallback;
	}

	const errorValue = body.error;

	if (typeof errorValue === "string" && errorValue.trim().length > 0) {
		return errorValue;
	}

	return fallback;
};

const parsePath = (path: string): string => (path.startsWith("/") ? path : `/${path}`);

const cleanBaseUrl = (rawUrl: string): string => {
	const withoutTrailingSlash = rawUrl.replace(/\/+$/, "");
	return withoutTrailingSlash || "http://127.0.0.1:3001";
};

const readBody = async (response: Response): Promise<unknown> => {
	try {
		return await response.json();
	} catch {
		return null;
	}
};

const unpackResponse = <T>(body: unknown): T => {
	if (isObject(body) && isObject(body.data)) {
		return body.data as T;
	}

	return body as T;
};

const createRequestError = async (response: Response): Promise<RemoteCodeApiError> => {
	const body = await readBody(response);
	const payload = isObject(body) ? body : null;
	const status = response.status;
	const message = toErrorText(payload, response.statusText || "request failed");
	const code = `${status}`;

	return new RemoteCodeApiError(status, code, payload, message);
};

export const RemoteCodeApi = {
	createClient(config?: Partial<ApiConfig>) {
		const baseUrl = cleanBaseUrl(
			config?.baseUrl?.trim() || (import.meta.env.VITE_REMOTECODE_SERVER_URL || "http://127.0.0.1:3001").trim(),
		);
		const token = config?.token?.trim() || (import.meta.env.VITE_REMOTECODE_LOCAL_TOKEN || "local-dev-token").trim();

		const request = async <T>(input: RequestInput): Promise<T> => {
			const url = `${baseUrl}/v1${parsePath(input.path)}`;
			const response = await fetch(url, {
				body: input.body === undefined ? undefined : JSON.stringify(input.body),
				headers: {
					authorization: `Bearer ${token}`,
					"content-type": "application/json",
				},
				method: input.method,
			});

			if (!response.ok) {
				throw await createRequestError(response);
			}

			const body = await readBody(response);
			return unpackResponse<T>(body);
		};

		return {
			listProjects: async (): Promise<ProjectDTO[]> => {
				const payload = await request<RestListProjectsResponse>({
					method: "GET",
					path: "/projects",
				});

				return payload.projects;
			},

			createProject: async (input: { name?: string; path: string }): Promise<ProjectDTO> => {
				const payload = await request<RestCreateProjectResponse>({
					body: input,
					method: "POST",
					path: "/projects",
				});

				return payload.project;
			},

			toggleFavorite: async (id: string, isFavorite: boolean): Promise<ProjectDTO> => {
				const payload = await request<RestProjectPatchResponse>({
					body: { isFavorite },
					method: "PATCH",
					path: `/projects/${id}`,
				});

				return payload.project;
			},

			listChats: async (projectId: string): Promise<ChatDTO[]> => {
				const payload = await request<RestListChatsResponse>({
					method: "GET",
					path: `/projects/${projectId}/chats`,
				});

				return payload.chats;
			},

			createChat: async (projectId: string, title?: string): Promise<ChatDTO> => {
				const payload = await request<RestCreateChatResponse>({
					body: { title },
					method: "POST",
					path: `/projects/${projectId}/chats`,
				});

				return payload.chat;
			},

			listMessages: async (chatId: string): Promise<MessageDTO[]> => {
				const payload = await request<RestListMessagesResponse>({
					method: "GET",
					path: `/chats/${chatId}/messages`,
				});

				return payload.messages;
			},

			getWorkspaceSelection: async (): Promise<WorkspaceSelection> => {
				return await request<RestWorkspaceSelectionResponse>({
					method: "GET",
					path: "/selection",
				});
			},

			updateWorkspaceSelection: async (
				input: { selectedProjectId: string | null; selectedChatId: string | null },
			): Promise<WorkspaceSelection> => {
				const payload = await request<RestWorkspaceSelectionResponse>({
					body: input,
					method: "PATCH",
					path: "/selection",
				});

				return payload;
			},

			deleteProject: async (id: string): Promise<RestDeleteResponse> => {
				return await request<RestDeleteResponse>({
					method: "DELETE",
					path: `/projects/${id}`,
				});
			},

			deleteChat: async (id: string): Promise<RestDeleteResponse> => {
				return await request<RestDeleteResponse>({
					method: "DELETE",
					path: `/chats/${id}`,
				});
			},
		};
	},
};
