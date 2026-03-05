import type { CodexModelsCatalog, CodexReasoningEffort } from "../../../shared/codex-model-config";
import type { CodexPermissionMode } from "../../../shared/codex-permission-mode";
import type { AssistantStreamEvent } from "../../../shared/assistant-stream-event";

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

export interface WorkspaceSummaryDTO {
	id: string;
	name: string;
	path: string;
}

export interface ChatDTO {
	id: string;
	isActive: boolean;
	projectId: string;
	provider: "fake" | "codex";
	title: string;
	status: "pending" | "running" | "completed" | "failed";
	diffAdded: number;
	diffRemoved: number;
	updatedAt: string;
}

export interface ThreadSummaryDTO {
	id: string;
	isActive: boolean;
	title: string;
	updatedAt: string;
}

export interface ActiveThreadSummaryDTO {
	id: string;
	projectId: string;
	projectName: string;
	title: string;
	updatedAt: string;
}

export interface ProjectSummaryDTO {
	id: string;
	name: string;
	path: string;
}

export interface ChatContextDTO {
	chat: ChatDTO;
	project: ProjectSummaryDTO;
}

export interface MessageDTO {
	id: string;
	chatId: string;
	role: "user" | "assistant";
	content: string;
	createdAt: string;
}

export interface ChatStreamEventDTO {
	id: number;
	chatId: string;
	createdAt: string;
	event: AssistantStreamEvent;
}

export interface ChatStreamEventsResponseDTO {
	events: ChatStreamEventDTO[];
	hasMore: boolean;
	nextAfterId: number | null;
}

export interface WorkspaceSelection {
	selectedProjectId: string | null;
	selectedChatId: string | null;
	permissionMode: CodexPermissionMode;
	selectedModel: string | null;
	selectedReasoningEffort: CodexReasoningEffort | null;
}

export interface DiscoveryInfoDTO {
	serverId: string;
	hostname: string;
	port: number;
	version: string;
	authMode: "token_lan";
	capabilitiesVersion: string;
}

export interface AuthVerifyResponseDTO {
	ok: boolean;
	server: DiscoveryInfoDTO;
}

export interface FsRootEntryDTO {
	id: string;
	label: string;
	path: string;
}

export interface FsEntryDTO {
	name: string;
	path: string;
	type: "directory" | "file";
}

export interface FsListResponseDTO {
	path: string;
	parentPath: string | null;
	entries: FsEntryDTO[];
}

export interface TerminalCommandDTO {
	id: string;
	chatId: string;
	command: string;
	cwd: string;
	shell: string;
	status: "running" | "completed" | "failed" | "timeout";
	exitCode: number | null;
	durationMs: number | null;
	startedAt: string;
	finishedAt: string | null;
}

export interface TerminalEntryDTO {
	id: number;
	commandId: string;
	chatId: string;
	stream: "stdout" | "stderr";
	data: string;
	createdAt: string;
}

export interface TerminalHistoryDTO {
	commands: TerminalCommandDTO[];
	entries: TerminalEntryDTO[];
}

export interface TerminalExecDTO {
	command: TerminalCommandDTO;
	entries: TerminalEntryDTO[];
}

export interface GitStatusDTO {
	isRepo: boolean;
	currentBranch: string | null;
	ahead: number;
	behind: number;
	changedFiles: number;
	stagedFiles: number;
	unstagedFiles: number;
	untrackedFiles: number;
	conflictedFiles: number;
	isDetachedHead: boolean;
	added: number;
	removed: number;
}

export type GitBranchDTO = string;

export interface GitBranchListDTO {
	currentBranch: string | null;
	branches: string[];
}

export interface CheckoutProjectGitBranchRequestDTO {
	branch: string;
}

export interface CreateProjectGitBranchRequestDTO {
	name: string;
}

export interface CommitProjectRequestDTO {
	message: string;
	includeUnstaged?: boolean;
	push?: boolean;
}

interface RestProjectGitCheckoutResponse {
	switched: boolean;
	branch: GitBranchDTO;
}

interface RestProjectGitCreateBranchResponse {
	created: boolean;
	branch: GitBranchDTO;
}

interface RestProjectGitCommitResponse {
	commit: {
		branch: string | null;
		commitHash: string | null;
		commitMessage: string;
		pushed: boolean;
		pushedWithUpstream: boolean;
	};
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

interface RestListWorkspaceSummariesResponse {
	workspaces: WorkspaceSummaryDTO[];
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

interface RestListThreadSummariesResponse {
	threads: ThreadSummaryDTO[];
}

interface RestListActiveThreadsResponse {
	threads: ActiveThreadSummaryDTO[];
}

interface RestCreateChatResponse {
	chat: ChatDTO;
}

type RestChatContextResponse = ChatContextDTO;

interface RestListMessagesResponse {
	messages: MessageDTO[];
}

interface RestListChatStreamEventsResponse {
	events: ChatStreamEventDTO[];
	hasMore: boolean;
	nextAfterId: number | null;
}

interface RestWorkspaceSelectionResponse {
	selectedProjectId: string | null;
	selectedChatId: string | null;
	permissionMode: CodexPermissionMode;
	selectedModel: string | null;
	selectedReasoningEffort: CodexReasoningEffort | null;
}

interface RestDeleteResponse {
	deleted: boolean;
}

export interface StopChatResponseDTO {
	chat: ChatDTO | null;
	state: "not_running" | "stale_cleared" | "stopping";
	stopped: boolean;
}

interface RestFsRootsResponse {
	roots: FsRootEntryDTO[];
}

interface RestTerminalHistoryResponse {
	commands: TerminalCommandDTO[];
	entries: TerminalEntryDTO[];
}

interface RestTerminalExecResponse {
	command: TerminalCommandDTO;
	entries: TerminalEntryDTO[];
}

type RestCodexModelsResponse = CodexModelsCatalog;

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
	return withoutTrailingSlash || "http://127.0.0.1:8835";
};

const CLIENT_ID_STORAGE_KEY = "remotecode:http-client-id";

const resolveHttpClientId = (): string => {
	if (typeof window === "undefined") {
		return `desktop-http-${Date.now()}`;
	}

	try {
		const stored = window.localStorage.getItem(CLIENT_ID_STORAGE_KEY)?.trim();
		if (stored) {
			return stored;
		}

		const created = typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
			? crypto.randomUUID()
			: `desktop-http-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;
		window.localStorage.setItem(CLIENT_ID_STORAGE_KEY, created);
		return created;
	} catch {
		return `desktop-http-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;
	}
};

const isMutatingMethod = (method: RequestInput["method"]): boolean =>
	method === "POST" || method === "PATCH" || method === "DELETE";

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
			config?.baseUrl?.trim() || (import.meta.env.VITE_REMOTECODE_SERVER_URL || "http://127.0.0.1:8835").trim(),
		);
		const token = config?.token?.trim() || (import.meta.env.VITE_REMOTECODE_LOCAL_TOKEN || "remotecode.io-token").trim();
		const clientId = resolveHttpClientId();

		const request = async <T>(input: RequestInput): Promise<T> => {
			const url = `${baseUrl}/v1${parsePath(input.path)}`;
			const requestId = isMutatingMethod(input.method)
				? (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
						? crypto.randomUUID()
						: `req-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`)
				: null;

			const response = await fetch(url, {
				body: input.body === undefined ? undefined : JSON.stringify(input.body),
				headers: {
					authorization: `Bearer ${token}`,
					"content-type": "application/json",
					"x-remotecode-client-id": clientId,
					...(requestId ? { "x-remotecode-request-id": requestId } : {}),
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

				listWorkspaceSummaries: async (): Promise<WorkspaceSummaryDTO[]> => {
					const payload = await request<RestListWorkspaceSummariesResponse>({
						method: "GET",
						path: "/projects/workspaces",
					});

					return payload.workspaces;
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

				listThreadSummaries: async (projectId: string): Promise<ThreadSummaryDTO[]> => {
					const payload = await request<RestListThreadSummariesResponse>({
						method: "GET",
						path: `/projects/${projectId}/threads`,
					});

					return payload.threads;
				},

				listActiveThreads: async (): Promise<ActiveThreadSummaryDTO[]> => {
					const payload = await request<RestListActiveThreadsResponse>({
						method: "GET",
						path: "/threads/active/runtime",
					});

					return payload.threads;
				},

				createChat: async (projectId: string, title?: string): Promise<ChatDTO> => {
					const payload = await request<RestCreateChatResponse>({
						body: { title },
						method: "POST",
						path: `/projects/${projectId}/chats`,
					});

					return payload.chat;
				},

				getChatContext: async (chatId: string): Promise<ChatContextDTO> => {
					return await request<RestChatContextResponse>({
						method: "GET",
						path: `/chats/${chatId}/context`,
					});
				},

			listCodexModels: async (): Promise<CodexModelsCatalog> => {
				return await request<RestCodexModelsResponse>({
					method: "GET",
					path: "/providers/codex/models",
				});
			},

			listMessages: async (chatId: string): Promise<MessageDTO[]> => {
				const payload = await request<RestListMessagesResponse>({
					method: "GET",
					path: `/chats/${chatId}/messages`,
				});

				return payload.messages;
			},

			listChatStreamEvents: async (
				chatId: string,
				options?: { afterId?: number; limit?: number },
			): Promise<ChatStreamEventsResponseDTO> => {
				const query = new URLSearchParams();
				if (typeof options?.afterId === "number" && Number.isFinite(options.afterId) && options.afterId > 0) {
					query.set("afterId", String(Math.floor(options.afterId)));
				}
				if (typeof options?.limit === "number" && Number.isFinite(options.limit) && options.limit > 0) {
					query.set("limit", String(Math.floor(options.limit)));
				}
				const suffix = query.toString();
				return await request<RestListChatStreamEventsResponse>({
					method: "GET",
					path: suffix ? `/chats/${chatId}/stream-events?${suffix}` : `/chats/${chatId}/stream-events`,
				});
			},

			getWorkspaceSelection: async (): Promise<WorkspaceSelection> => {
				return await request<RestWorkspaceSelectionResponse>({
					method: "GET",
					path: "/selection",
				});
			},

				updateWorkspaceSelection: async (
					input: {
						selectedProjectId: string | null;
						selectedChatId: string | null;
						permissionMode?: CodexPermissionMode;
						selectedModel?: string | null;
						selectedReasoningEffort?: CodexReasoningEffort | null;
					},
				): Promise<WorkspaceSelection> => {
					const payload = await request<RestWorkspaceSelectionResponse>({
						body: input,
					method: "PATCH",
					path: "/selection",
				});

				return payload;
			},

			getDiscoveryInfo: async (): Promise<DiscoveryInfoDTO> => {
				return await request<DiscoveryInfoDTO>({
					method: "GET",
					path: "/discovery",
				});
			},

			verifyToken: async (tokenInput: string): Promise<AuthVerifyResponseDTO> => {
				return await request<AuthVerifyResponseDTO>({
					body: { token: tokenInput.trim() },
					method: "POST",
					path: "/auth/verify",
				});
			},

			listFsRoots: async (): Promise<FsRootEntryDTO[]> => {
				const payload = await request<RestFsRootsResponse>({
					method: "GET",
					path: "/fs/roots",
				});

				return payload.roots;
			},

			listFsEntries: async (path: string): Promise<FsListResponseDTO> => {
				const encodedPath = encodeURIComponent(path);
				return await request<FsListResponseDTO>({
					method: "GET",
					path: `/fs/list?path=${encodedPath}`,
				});
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

			stopChat: async (id: string): Promise<StopChatResponseDTO> => {
				return await request<StopChatResponseDTO>({
					method: "POST",
					path: `/chats/${id}/stop`,
				});
			},

			getTerminalHistory: async (
				chatId: string,
				options?: { cursor?: number; limit?: number },
			): Promise<TerminalHistoryDTO> => {
				const query = new URLSearchParams();
				if (typeof options?.cursor === "number" && Number.isFinite(options.cursor) && options.cursor > 0) {
					query.set("cursor", String(Math.floor(options.cursor)));
				}
				if (typeof options?.limit === "number" && Number.isFinite(options.limit) && options.limit > 0) {
					query.set("limit", String(Math.floor(options.limit)));
				}

				const suffix = query.toString();
				const path = suffix ? `/chats/${chatId}/terminal?${suffix}` : `/chats/${chatId}/terminal`;

				return await request<RestTerminalHistoryResponse>({
					method: "GET",
					path,
				});
			},

			execTerminalCommand: async (
				chatId: string,
				input: { command: string; timeoutMs?: number },
			): Promise<TerminalExecDTO> => {
				return await request<RestTerminalExecResponse>({
					body: input,
					method: "POST",
					path: `/chats/${chatId}/terminal/exec`,
				});
			},

			getProjectGitStatus: async (projectId: string): Promise<GitStatusDTO> => {
				return await request<GitStatusDTO>({
					method: "GET",
					path: `/projects/${projectId}/git/status`,
				});
			},

			getProjectGitBranches: async (projectId: string): Promise<GitBranchListDTO> => {
				return await request<GitBranchListDTO>({
					method: "GET",
					path: `/projects/${projectId}/git/branches`,
				});
			},

			checkoutProjectGitBranch: async (projectId: string, branch: string): Promise<RestProjectGitCheckoutResponse> => {
				return await request<RestProjectGitCheckoutResponse>({
					body: { branch },
					method: "POST",
					path: `/projects/${projectId}/git/branches/checkout`,
				});
			},

			createProjectGitBranch: async (projectId: string, name: string): Promise<RestProjectGitCreateBranchResponse> => {
				return await request<RestProjectGitCreateBranchResponse>({
					body: { name },
					method: "POST",
					path: `/projects/${projectId}/git/branches/create`,
				});
			},

			commitProject: async (
				projectId: string,
				input: CommitProjectRequestDTO,
			): Promise<RestProjectGitCommitResponse> => {
				return await request<RestProjectGitCommitResponse>({
					body: input,
					method: "POST",
					path: `/projects/${projectId}/git/commit`,
				});
			},
		};
	},
};
