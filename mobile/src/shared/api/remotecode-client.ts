import type { ApiConfig } from "./api-config-store";
import type {
	AuthVerifyResponseDTO,
	ChatDTO,
	CodexModelsCatalogDTO,
	DiscoveryInfoDTO,
	FsListResponseDTO,
	FsRootEntryDTO,
	GitBranchListDTO,
	GitCommitResultDTO,
	GitStatusDTO,
	MessageDTO,
	ProjectDTO,
	TerminalCommandDTO,
	TerminalEntryDTO,
	WorkspaceSelectionDTO,
} from "./types";

interface DeleteResponse {
	deleted: boolean;
}

interface CreateProjectResponse {
	created: boolean;
	project: ProjectDTO;
}

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

interface ListMessagesResponse {
	messages: MessageDTO[];
}

interface ListCodexModelsResponse {
	models: CodexModelsCatalogDTO["models"];
	nextCursor: string | null;
}

interface ListFsRootsResponse {
	roots: FsRootEntryDTO[];
}

interface CommitResponse {
	commit: GitCommitResultDTO;
}

interface TerminalHistoryResponse {
	commands: TerminalCommandDTO[];
	entries: TerminalEntryDTO[];
}

interface TerminalExecResponse {
	command: TerminalCommandDTO;
	entries: TerminalEntryDTO[];
}

type SelectionResponse = WorkspaceSelectionDTO;

export interface RemoteCodeClient {
	createChat: (projectId: string, title?: string) => Promise<ChatDTO>;
	createProject: (input: { name?: string; path: string }) => Promise<ProjectDTO>;
	deleteChat: (chatId: string) => Promise<DeleteResponse>;
	deleteProject: (projectId: string) => Promise<DeleteResponse>;
	execTerminalCommand: (
		chatId: string,
		input: { command: string; timeoutMs?: number },
	) => Promise<TerminalExecResponse>;
	getDiscoveryInfo: (baseUrlOverride?: string) => Promise<DiscoveryInfoDTO>;
	getProjectGitBranches: (projectId: string) => Promise<GitBranchListDTO>;
	getProjectGitStatus: (projectId: string) => Promise<GitStatusDTO>;
	getTerminalHistory: (
		chatId: string,
		options?: { cursor?: number; limit?: number },
	) => Promise<TerminalHistoryResponse>;
	getSelection: () => Promise<WorkspaceSelectionDTO>;
	listCodexModels: () => Promise<CodexModelsCatalogDTO>;
	listFsEntries: (path: string) => Promise<FsListResponseDTO>;
	listFsRoots: () => Promise<FsRootEntryDTO[]>;
	listChats: (projectId: string) => Promise<ChatDTO[]>;
	listMessages: (chatId: string) => Promise<MessageDTO[]>;
	listProjects: () => Promise<ProjectDTO[]>;
	commitProject: (
		projectId: string,
		input: { message: string; includeUnstaged?: boolean; push?: boolean },
	) => Promise<GitCommitResultDTO>;
	createProjectGitBranch: (projectId: string, name: string) => Promise<string>;
	checkoutProjectGitBranch: (projectId: string, branch: string) => Promise<string>;
	toggleFavorite: (projectId: string, isFavorite: boolean) => Promise<ProjectDTO>;
	updateSelection: (selection: WorkspaceSelectionDTO) => Promise<WorkspaceSelectionDTO>;
	verifyToken: (token: string, baseUrlOverride?: string) => Promise<AuthVerifyResponseDTO>;
}

const toNormalizedBaseUrl = (input: string): string => {
	const normalized = input.trim().replace(/\/+$/u, "");
	return normalized.length > 0 ? normalized : "http://127.0.0.1:8835";
};

const toRequestId = (): string =>
	`req-${Date.now().toString(36)}-${Math.random().toString(16).slice(2, 8)}`;

export const createRemoteCodeClient = (config: ApiConfig): RemoteCodeClient => {
	const baseUrl = toNormalizedBaseUrl(config.baseUrl);
	const token = config.token.trim();
	const clientId = `mobile-${Math.random().toString(16).slice(2, 10)}`;

	const request = async <T>(input: {
		method: "GET" | "POST" | "PATCH" | "DELETE";
		path: string;
		body?: unknown;
		baseUrlOverride?: string;
		tokenOverride?: string;
	}): Promise<T> => {
		const resolvedBaseUrl = toNormalizedBaseUrl(input.baseUrlOverride ?? baseUrl);
		const resolvedToken = (input.tokenOverride ?? token).trim();
		const response = await fetch(`${resolvedBaseUrl}/v1${input.path}`, {
			method: input.method,
			headers: {
				authorization: `Bearer ${resolvedToken}`,
				"content-type": "application/json",
				"x-remotecode-client-id": clientId,
				"x-remotecode-request-id": toRequestId(),
			},
			body: input.body === undefined ? undefined : JSON.stringify(input.body),
		});

			let payload: (Record<string, unknown> & { error?: unknown }) | null = null;
			try {
				payload = (await response.json()) as Record<string, unknown> & { error?: unknown };
			} catch {
				payload = null;
			}

		if (!response.ok) {
			const message =
				typeof payload?.error === "string" && payload.error.trim().length > 0
					? payload.error
					: response.statusText || "Request failed";
			throw new Error(message);
		}

		return payload as T;
	};

	return {
		async createChat(projectId: string, title?: string) {
			const payload = await request<CreateChatResponse>({
				method: "POST",
				path: `/projects/${projectId}/chats`,
				body: { title },
			});

			return payload.chat;
		},

		async createProject(input: { name?: string; path: string }) {
			const payload = await request<CreateProjectResponse>({
				method: "POST",
				path: "/projects",
				body: input,
			});

			return payload.project;
		},

		async deleteChat(chatId: string) {
			return await request<DeleteResponse>({
				method: "DELETE",
				path: `/chats/${chatId}`,
			});
		},

		async deleteProject(projectId: string) {
			return await request<DeleteResponse>({
				method: "DELETE",
				path: `/projects/${projectId}`,
			});
		},

		async execTerminalCommand(chatId: string, input: { command: string; timeoutMs?: number }) {
			return await request<TerminalExecResponse>({
				method: "POST",
				path: `/chats/${chatId}/terminal/exec`,
				body: input,
			});
		},

		async getDiscoveryInfo(baseUrlOverride?: string) {
			return await request<DiscoveryInfoDTO>({
				method: "GET",
				path: "/discovery",
				baseUrlOverride,
			});
		},

		async getProjectGitBranches(projectId: string) {
			return await request<GitBranchListDTO>({
				method: "GET",
				path: `/projects/${projectId}/git/branches`,
			});
		},

		async getProjectGitStatus(projectId: string) {
			return await request<GitStatusDTO>({
				method: "GET",
				path: `/projects/${projectId}/git/status`,
			});
		},

		async getTerminalHistory(chatId: string, options?: { cursor?: number; limit?: number }) {
			const query = new URLSearchParams();
			if (typeof options?.cursor === "number" && Number.isFinite(options.cursor) && options.cursor > 0) {
				query.set("cursor", String(Math.floor(options.cursor)));
			}
			if (typeof options?.limit === "number" && Number.isFinite(options.limit) && options.limit > 0) {
				query.set("limit", String(Math.floor(options.limit)));
			}
			const suffix = query.toString();
			return await request<TerminalHistoryResponse>({
				method: "GET",
				path: suffix ? `/chats/${chatId}/terminal?${suffix}` : `/chats/${chatId}/terminal`,
			});
		},

		async getSelection() {
			return await request<SelectionResponse>({
				method: "GET",
				path: "/selection",
			});
		},

		async listCodexModels() {
			const payload = await request<ListCodexModelsResponse>({
				method: "GET",
				path: "/providers/codex/models",
			});

			return {
				models: payload.models,
				nextCursor: payload.nextCursor,
			};
		},

		async listFsEntries(path: string) {
			return await request<FsListResponseDTO>({
				method: "GET",
				path: `/fs/list?path=${encodeURIComponent(path)}`,
			});
		},

		async listFsRoots() {
			const payload = await request<ListFsRootsResponse>({
				method: "GET",
				path: "/fs/roots",
			});

			return payload.roots;
		},

		async listChats(projectId: string) {
			const payload = await request<ListChatsResponse>({
				method: "GET",
				path: `/projects/${projectId}/chats`,
			});

			return payload.chats;
		},

		async listMessages(chatId: string) {
			const payload = await request<ListMessagesResponse>({
				method: "GET",
				path: `/chats/${chatId}/messages`,
			});

			return payload.messages;
		},

		async listProjects() {
			const payload = await request<ListProjectsResponse>({
				method: "GET",
				path: "/projects",
			});

			return payload.projects;
		},

		async commitProject(projectId: string, input: { message: string; includeUnstaged?: boolean; push?: boolean }) {
			const payload = await request<CommitResponse>({
				method: "POST",
				path: `/projects/${projectId}/git/commit`,
				body: input,
			});

			return payload.commit;
		},

		async createProjectGitBranch(projectId: string, name: string) {
			const payload = await request<{ branch: string }>({
				method: "POST",
				path: `/projects/${projectId}/git/branches/create`,
				body: { name },
			});

			return payload.branch;
		},

		async checkoutProjectGitBranch(projectId: string, branch: string) {
			const payload = await request<{ branch: string }>({
				method: "POST",
				path: `/projects/${projectId}/git/branches/checkout`,
				body: { branch },
			});

			return payload.branch;
		},

		async toggleFavorite(projectId: string, isFavorite: boolean) {
			const payload = await request<ProjectPatchResponse>({
				method: "PATCH",
				path: `/projects/${projectId}`,
				body: { isFavorite },
			});

			return payload.project;
		},

		async updateSelection(selection: WorkspaceSelectionDTO) {
			return await request<SelectionResponse>({
				method: "PATCH",
				path: "/selection",
				body: selection,
			});
		},

		async verifyToken(tokenValue: string, baseUrlOverride?: string) {
			return await request<AuthVerifyResponseDTO>({
				method: "POST",
				path: "/auth/verify",
				body: { token: tokenValue },
				baseUrlOverride,
				tokenOverride: tokenValue,
			});
		},
	};
};
