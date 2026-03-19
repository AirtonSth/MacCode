import { QueryClient, QueryClientProvider, useQuery, useQueryClient } from "@tanstack/react-query";
import { type CSSProperties, type PointerEvent as ReactPointerEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import {
	Folder,
	FolderSearch,
	FolderOpen,
	Loader2,
	MoreHorizontal,
	MessageSquareText,
	PanelLeft,
	Plus,
	SquareTerminal,
	Trash2,
	Zap,
} from "lucide-react";

import { Electroview } from "electrobun/view";
import { Button } from "../components/ui/button";
import { ScrollArea } from "../components/ui/scroll-area";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "../components/ui/tooltip";
import { MessageComposer } from "../features/composer/ui/MessageComposer";
import { ConversationPanel } from "../features/conversation/ui/ConversationPanel";
import { GitQuickControl } from "../features/git/ui/GitQuickControl";
import { useProjectGit } from "../features/git/model/useProjectGit";
import { PrivateAccountSidebarFooter } from "../features/private-account/ui/private-account-sidebar-footer";
import { useThreadTerminalSession } from "../features/terminal/model/useThreadTerminalSession";
import { ThreadTerminalPanel } from "../features/terminal/ui/ThreadTerminalPanel";
import {
	type ChatDTO,
	type MessageDTO,
	type ProjectDTO,
	type StreamTurnState,
	createEmptyMessageWindow,
	getTransientChatStateCounts,
	sortChatsByUpdatedAtDesc,
	useWorkspaceStore,
} from "../features/workspace/model/useWorkspaceStore";
import {
	DEFAULT_DRAFT_THREAD_TITLE,
	deriveThreadTitleFromMessage,
	isPlaceholderThreadTitle,
} from "../features/workspace/model/send-message";
import { MESSAGE_PAGE_SIZE, appendMessageToMessagePage } from "../features/workspace/model/message-page-utils";
import { queryKeys } from "../features/workspace/model/query-keys";
import {
	applyAssistantEventToTurn,
	mapChatTurnsToStreamTurns,
	setStreamItemExpanded as updateStreamItemExpanded,
	setStreamItemState as updateStreamItemState,
} from "../features/workspace/model/stream-turn-state";
import { useMessagesQuery } from "../features/workspace/model/use-messages-query";
import { useAppUpdate } from "../features/app-update/model/useAppUpdate";
import { UpdateBanner } from "../features/app-update/ui/UpdateBanner";
import { cn } from "../lib/utils";
import { showThreadCompletionDesktopNotification } from "./thread-completion-notification";
import type { AssistantStreamEvent } from "../../shared/assistant-stream-event";
import {
	DEFAULT_CODEX_PERMISSION_MODE,
	parseCodexPermissionMode,
	type CodexPermissionMode,
} from "../../shared/codex-permission-mode";
import {
	parseCodexReasoningEffort,
	type CodexModelDescriptor,
	type CodexReasoningEffort,
} from "../../shared/codex-model-config";
import {
	RemoteCodeApi,
	RemoteCodeApiError,
	type MessagePageDTO,
} from "../shared/api/remotecode-http";
import {
	RemoteCodeRealtime,
	type ConnectionState,
	type ServerWsEvent,
} from "../shared/realtime/remotecode-ws";
import { fetchModelsForProvider, shouldLockProviderSelection } from "./provider-change";

const FALLBACK_TIMESTAMP = "1970-01-01T00:00:00.000Z";
const createDesktopQueryClient = (): QueryClient => new QueryClient({
	defaultOptions: {
		queries: {
			refetchOnWindowFocus: false,
			retry: 1,
		},
	},
});

const formatRelativeTime = (dateString: string): string => {
	const timestamp = new Date(dateString).getTime();
	if (Number.isNaN(timestamp)) {
		return "now";
	}

	const difference = Math.max(0, Date.now() - timestamp);
	if (difference < 60_000) {
		return "now";
	}

	const minutes = Math.floor(difference / 60_000);
	if (minutes < 60) {
		return `${minutes}m`;
	}

	const hours = Math.floor(minutes / 60);
	if (hours < 24) {
		return `${hours}h`;
	}

	const days = Math.floor(hours / 24);
	return `${days}d`;
};

const formatProjectMeta = (absolutePath: string): string => {
	const cleanPath = absolutePath.trim().replace(/\\/g, "/").replace(/\/+$/u, "");
	const segments = cleanPath.split("/").filter(Boolean);
	if (segments.length < 2) {
		return "local";
	}

	return segments[segments.length - 2];
};

const normalizeProjectPath = (projectPath: string): string => {
	return projectPath.trim().replace(/^["']+|["']+$/gu, "");
};

const extractSelectedProjectPath = (candidates: unknown): string | null => {
	if (typeof candidates === "string") {
		const normalized = normalizeProjectPath(candidates);
		return normalized.length > 0 ? normalized : null;
	}

	if (candidates && typeof candidates === "object" && !Array.isArray(candidates)) {
		const nestedPaths = (candidates as { paths?: unknown[] }).paths;
		if (Array.isArray(nestedPaths) && nestedPaths.length > 0 && typeof nestedPaths[0] === "string") {
			const normalized = normalizeProjectPath(nestedPaths[0]);
			return normalized.length > 0 ? normalized : null;
		}
	}

	if (!Array.isArray(candidates) || candidates.length === 0) {
		return null;
	}

	const first = candidates[0];
	if (typeof first !== "string") {
		if (first && typeof first === "object" && "paths" in first) {
			const nestedPaths = (first as { paths?: unknown[] }).paths;
			if (Array.isArray(nestedPaths) && nestedPaths.length > 0 && typeof nestedPaths[0] === "string") {
				const normalized = normalizeProjectPath(nestedPaths[0] as string);
				return normalized.length > 0 ? normalized : null;
			}
		}

		return null;
	}

	const normalized = normalizeProjectPath(first);
	return normalized.length > 0 ? normalized : null;
};

const getFolderFallbackName = (projectPath: string): string => {
	const normalizedPath = projectPath.replace(/\\/g, "/").replace(/\/+$/u, "");
	const segments = normalizedPath.split("/").filter(Boolean);
	return segments[segments.length - 1] ?? "Project";
};

const OPEN_PROJECT_RPC_TIMEOUT_MS = 120_000;
const SIDEBAR_WIDTH_STORAGE_KEY = "remotecode-desktop-sidebar-width";
const PERMISSION_MODE_STORAGE_KEY = "remotecode:permission-mode";
const MODEL_STORAGE_KEY = "remotecode:model";
const REASONING_EFFORT_STORAGE_KEY = "remotecode:reasoning-effort";
const PROVIDER_STORAGE_KEY = "remotecode:provider";

type SelectedProvider = "codex" | "claude";

const isValidProvider = (value: unknown): value is SelectedProvider =>
	value === "codex" || value === "claude";
const WS_CLIENT_ID_STORAGE_KEY = "remotecode:ws-client-id";
const DEFAULT_SIDEBAR_WIDTH = 272;
const SIDEBAR_WIDTH_MIN = 208;
const SIDEBAR_WIDTH_MAX = 560;

const electrobunView = (() => {
	try {
		return new Electroview({
			rpc: Electroview.defineRPC({
				maxRequestTime: OPEN_PROJECT_RPC_TIMEOUT_MS,
				handlers: {
					messages: {},
					requests: {},
				},
			}),
		});
	} catch {
		return null;
	}
})();

const createDraftThreadChat = (projectId: string): ChatDTO => ({
	id: `draft-thread-${projectId}`,
	isActive: false,
	lastReadAt: null,
	projectId,
	title: DEFAULT_DRAFT_THREAD_TITLE,
	provider: "fake",
	providerThreadId: null,
	status: "pending",
	diffAdded: 0,
	diffRemoved: 0,
	finishedAt: null,
	hasUnreadFinished: false,
	updatedAt: new Date().toISOString(),
});

const toProjectDtoFromWorkspaceSummary = (workspace: {
	id: string;
	name: string;
	path: string;
	unreadFinishedThreadCount?: number;
}): ProjectDTO => ({
	id: workspace.id,
	name: workspace.name,
	path: workspace.path,
	isFavorite: false,
	createdAt: FALLBACK_TIMESTAMP,
	unreadFinishedThreadCount: workspace.unreadFinishedThreadCount ?? 0,
	updatedAt: FALLBACK_TIMESTAMP,
});

const toChatDtoFromThreadSummary = (
	thread: { hasUnreadFinished?: boolean; id: string; isActive: boolean; title: string; updatedAt: string },
	projectId: string,
): ChatDTO => ({
	id: thread.id,
	isActive: thread.isActive,
	lastReadAt: null,
	projectId,
	title: thread.title,
	provider: "codex",
	providerThreadId: null,
	status: thread.isActive ? "running" : "pending",
	diffAdded: 0,
	diffRemoved: 0,
	finishedAt: null,
	hasUnreadFinished: thread.hasUnreadFinished ?? false,
	updatedAt: thread.updatedAt,
});
const SIDEBAR_MAX_VISIBLE_THREADS = 3;

const getThreadStatusTooltip = (chat: Pick<ChatDTO, "hasUnreadFinished" | "isActive">): string | null => {
	if (chat.isActive) {
		return "Active thread";
	}

	if (chat.hasUnreadFinished) {
		return "Unread finished thread";
	}

	return null;
};

const clampSidebarWidth = (width: number): number => {
	const bounded = Number.isFinite(width) ? width : DEFAULT_SIDEBAR_WIDTH;
	return Math.min(SIDEBAR_WIDTH_MAX, Math.max(SIDEBAR_WIDTH_MIN, Math.round(bounded)));
};

const renderStatsState = {
	counts: {} as Record<string, number>,
};

const bumpRenderStat = (name: string): void => {
	renderStatsState.counts[name] = (renderStatsState.counts[name] ?? 0) + 1;
};

const parseSidebarWidth = (value: string | null): number => {
	const parsed = Number.parseInt(value ?? "", 10);
	if (Number.isNaN(parsed)) {
		return DEFAULT_SIDEBAR_WIDTH;
	}

	return clampSidebarWidth(parsed);
};

const resolveSelectedModel = (
	models: CodexModelDescriptor[],
	preferredModel: string | null,
): string | null => {
	if (models.length === 0) {
		return null;
	}

	if (preferredModel && models.some((item) => item.model === preferredModel)) {
		return preferredModel;
	}

	const defaultModel = models.find((item) => item.isDefault);
	return defaultModel?.model ?? models[0]?.model ?? null;
};

const getModelDescriptorByName = (
	models: CodexModelDescriptor[],
	modelName: string | null,
): CodexModelDescriptor | null => {
	if (!modelName) {
		return null;
	}

	return models.find((item) => item.model === modelName) ?? null;
};

const resolveSelectedReasoningEffort = (
	model: CodexModelDescriptor | null,
	preferredEffort: CodexReasoningEffort | null,
): CodexReasoningEffort | null => {
	if (!model) {
		return null;
	}

	const supported = model.supportedReasoningEfforts.map((item) => item.reasoningEffort);
	if (supported.length === 0) {
		return null;
	}

	if (preferredEffort && supported.includes(preferredEffort)) {
		return preferredEffort;
	}

	if (supported.includes(model.defaultReasoningEffort)) {
		return model.defaultReasoningEffort;
	}

	return supported[0] ?? null;
};

const resolveWebSocketClientId = (): string => {
	if (typeof window === "undefined") {
		return `desktop-${Date.now()}`;
	}

	try {
		const stored = window.localStorage.getItem(WS_CLIENT_ID_STORAGE_KEY)?.trim();
		if (stored) {
			return stored;
		}

		const created = typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
			? crypto.randomUUID()
			: `desktop-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;
		window.localStorage.setItem(WS_CLIENT_ID_STORAGE_KEY, created);
		return created;
	} catch {
		return `desktop-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;
	}
};

const isRecord = (value: unknown): value is Record<string, unknown> => {
	return typeof value === "object" && value !== null && !Array.isArray(value);
};

const isChatStatus = (value: unknown): value is ChatDTO["status"] => {
	return value === "pending" || value === "running" || value === "completed" || value === "failed";
};

const isProjectPayload = (value: unknown): value is ProjectDTO => {
	if (!isRecord(value)) {
		return false;
	}

	return (
		typeof value.id === "string" &&
		typeof value.name === "string" &&
		typeof value.path === "string" &&
		typeof value.isFavorite === "boolean" &&
		typeof value.createdAt === "string" &&
		typeof value.updatedAt === "string"
	);
};

const isMessagePayload = (value: unknown): value is MessageDTO => {
	if (!isRecord(value)) {
		return false;
	}

	return (
		typeof value.id === "string" &&
		typeof value.chatId === "string" &&
		(value.role === "user" || value.role === "assistant") &&
		typeof value.content === "string" &&
		typeof value.createdAt === "string"
	);
};

const AppContent = (): JSX.Element => {
	bumpRenderStat("app-root");
	const queryClient = useQueryClient();
	const { dispatch, state } = useWorkspaceStore();
	const shouldReduceMotion = useReducedMotion();
	const wsRef = useRef<ReturnType<(typeof RemoteCodeRealtime)["createClient"]> | null>(null);
	const selectedChatIdRef = useRef<string | null>(null);
	const selectedProjectIdRef = useRef<string | null>(null);
	const persistedSelectedChatIdRef = useRef<string | null>(null);
	const isCreatingChatRef = useRef<boolean>(false);
	const sidebarWidthRef = useRef<number>(DEFAULT_SIDEBAR_WIDTH);
	const isSidebarResizingRef = useRef<boolean>(false);
	const errorAutoDismissTimersRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());
	const sidebarResizeStartXRef = useRef<number>(0);
	const sidebarResizeStartWidthRef = useRef<number>(DEFAULT_SIDEBAR_WIDTH);
	const terminalOpenByChatRef = useRef<Record<string, boolean>>({});
	const workspaceClientIdRef = useRef<string>(resolveWebSocketClientId());
	const lastWorkspaceSeqRef = useRef<number>(0);
	const pendingSendChatIdsRef = useRef<Set<string>>(new Set());
	const activeChatIdsRef = useRef<Set<string>>(new Set());
	const previousActiveChatIdsRef = useRef<Set<string>>(new Set());
	const bootstrapDoneRef = useRef<boolean>(false);
	const skipPostBootstrapChatsLoadRef = useRef<boolean>(false);
	const projectsLoadInFlightRef = useRef<Promise<void> | null>(null);
	const projectsLoadQueuedRef = useRef<boolean>(false);
	const chatsLoadInFlightRef = useRef<Map<string, Promise<void>>>(new Map());
	const chatsLoadQueuedRef = useRef<Map<string, string | null>>(new Map());
	const chatContextLoadInFlightRef = useRef<Map<string, Promise<void>>>(new Map());
	const workspaceMenuRef = useRef<HTMLDivElement | null>(null);
	const layoutShellRef = useRef<HTMLDivElement | null>(null);
	const [stoppingByChat, setStoppingByChat] = useState<Record<string, boolean>>({});
	const [messageWindowModeByChat, setMessageWindowModeByChat] = useState<Record<string, "latest" | "older">>({});
	const [latestDirtyByChat, setLatestDirtyByChat] = useState<Record<string, boolean>>({});
	const [streamingTextByChat, setStreamingTextByChat] = useState<Record<string, string>>({});
	const messageWindowModeByChatRef = useRef<Record<string, "latest" | "older">>({});
	const streamingTextByChatRef = useRef<Record<string, string>>({});
	const lastAssistantEventIdByChatRef = useRef<Record<string, number>>({});

	const baseUrl = useMemo(() => {
		return (import.meta.env.VITE_REMOTECODE_SERVER_URL || "http://127.0.0.1:8835").trim();
	}, []);

	const token = useMemo(() => {
		return (import.meta.env.VITE_REMOTECODE_LOCAL_TOKEN || "remotecode.io-token").trim();
	}, []);

	const api = useMemo(() => RemoteCodeApi.createClient({ baseUrl, token }), [baseUrl, token]);

	const selectedProject = useMemo(
		() => state.projects.find((project) => project.id === state.selectedProjectId) ?? null,
		[state.projects, state.selectedProjectId],
	);
	const projectChatsCacheRef = useRef<Record<string, ChatDTO[]>>({});

	const selectedChatFromState = useMemo(
		() => state.chats.find((chat) => chat.id === state.selectedChatId) ?? null,
		[state.chats, state.selectedChatId],
	);
	const cachedSelectedChat = useMemo(() => {
		if (!state.selectedChatId || !state.selectedProjectId) {
			return null;
		}

		if (selectedChatFromState) {
			return selectedChatFromState;
		}

		return projectChatsCacheRef.current[state.selectedProjectId]?.find((chat) => chat.id === state.selectedChatId) ?? null;
	}, [selectedChatFromState, state.selectedChatId, state.selectedProjectId]);
	const selectedChat = selectedChatFromState ?? cachedSelectedChat;
	const selectedChatProvider =
		selectedChat?.provider === "codex" || selectedChat?.provider === "claude"
			? selectedChat.provider
			: null;
	const selectedChatProviderThreadId = selectedChat?.providerThreadId?.trim() || null;
	const draftThreadChat = useMemo(
		() => (state.selectedProjectId ? createDraftThreadChat(state.selectedProjectId) : null),
		[state.selectedProjectId],
	);
	const activeThreadChat = selectedChat ?? draftThreadChat;

	const selectedChatId = state.selectedChatId;
	const messagesQuery = useMessagesQuery(api, selectedChatId, {
		enabled: Boolean(selectedChatId),
	});
	const streamTurnQuery = useQuery<StreamTurnState | null>({
		gcTime: Number.POSITIVE_INFINITY,
		initialData: null,
		queryFn: async () => null,
		queryKey: queryKeys.streamTurn(selectedChatId),
		staleTime: Number.POSITIVE_INFINITY,
	});
	const messageWindowMode = selectedChatId ? messageWindowModeByChat[selectedChatId] ?? "latest" : "latest";
	const hasOlderMessages = messagesQuery.hasOlderMessages;
	const latestMessageWindowDirty = selectedChatId ? latestDirtyByChat[selectedChatId] ?? false : false;
	const visibleMessages = messagesQuery.messages;
	const streamingText = selectedChatId ? streamingTextByChat[selectedChatId] ?? "" : "";
	const streamingTurn = streamTurnQuery.data ?? null;
	const streamHistoryTurns = useMemo(
		() => mapChatTurnsToStreamTurns(messagesQuery.page.turns ?? []),
		[messagesQuery.page.turns],
	);
	const hasSelectedMessageWindowContent =
		messagesQuery.page.messages.length > 0 || messagesQuery.page.turns.length > 0;
	const hasSelectedStreamingContent =
		streamingText.trim().length > 0 || streamHistoryTurns.length > 0 || streamingTurn !== null;
	const isProviderSelectionLocked = shouldLockProviderSelection({
		hasStreamingText: streamingText.trim().length > 0,
		hasStreamingTurn: streamingTurn !== null,
		messageCount: messagesQuery.page.messages.length,
		providerThreadId: selectedChatProviderThreadId,
		turnCount: messagesQuery.page.turns.length,
	});
	const isConversationPendingHydration =
		selectedChatId !== null
		&& messagesQuery.isPlaceholderData
		&& !hasSelectedMessageWindowContent
		&& !hasSelectedStreamingContent;
	const isConversationLoading =
		isConversationPendingHydration
		|| (
			selectedChatId !== null &&
			(messagesQuery.isPending || messagesQuery.fetchStatus === "fetching")
			&& !messagesQuery.isPlaceholderData
			&& !hasSelectedMessageWindowContent
			&& !hasSelectedStreamingContent
		);
	const selectedChatSending = selectedChatId
		? Boolean(state.sendingByChat[selectedChatId])
		: false;
	const selectedChatStopping = selectedChatId ? Boolean(stoppingByChat[selectedChatId]) : false;
	useEffect(() => {
		const debugGlobal = globalThis as typeof globalThis & {
			__RC_TRANSIENT_CHAT_STATE__?: {
				getCounts: () => ReturnType<typeof getTransientChatStateCounts>;
			};
			__RC_RENDER_STATS__?: {
				getCounts: () => Record<string, number>;
				reset: () => void;
			};
		};
		debugGlobal.__RC_TRANSIENT_CHAT_STATE__ = {
			getCounts: () => getTransientChatStateCounts(state),
		};
		debugGlobal.__RC_RENDER_STATS__ = {
			getCounts: () => ({ ...renderStatsState.counts }),
			reset: () => {
				renderStatsState.counts = {};
			},
		};

		return () => {
			delete debugGlobal.__RC_TRANSIENT_CHAT_STATE__;
			delete debugGlobal.__RC_RENDER_STATS__;
		};
	}, [state]);

	const isChatActive = useCallback(
		(chatId: string): boolean => activeChatIdsRef.current.has(chatId),
		[],
	);
	const isSelectedThreadWorking = activeThreadChat
		? Boolean(
			activeThreadChat.isActive
			|| state.sendingByChat[activeThreadChat.id]
			|| state.streamingActiveByChat[activeThreadChat.id]
			|| isChatActive(activeThreadChat.id),
		)
		: false;

	const activeChats = useMemo(
		() => state.chats.filter((chat) => chat.isActive),
		[state.chats],
	);

	const [isOpeningProject, setIsOpeningProject] = useState(false);
	const [expandedProjectThreads, setExpandedProjectThreads] = useState<Record<string, boolean>>({});
	const [projectThreadsOpen, setProjectThreadsOpen] = useState<Record<string, boolean>>({});
	const [openingProjectId, setOpeningProjectId] = useState<string | null>(null);
	const [visibleOpeningProjectId, setVisibleOpeningProjectId] = useState<string | null>(null);
	const [openingThreadId, setOpeningThreadId] = useState<string | null>(null);
	const [openWorkspaceMenuProjectId, setOpenWorkspaceMenuProjectId] = useState<string | null>(null);
	const [isActiveThreadsOpen, setIsActiveThreadsOpen] = useState(false);
	const activeThreadsMenuRef = useRef<HTMLDivElement | null>(null);
	const [sidebarWidth, setSidebarWidth] = useState<number>(() => {
		if (typeof window === "undefined") {
			return DEFAULT_SIDEBAR_WIDTH;
		}

		return parseSidebarWidth(window.localStorage.getItem(SIDEBAR_WIDTH_STORAGE_KEY));
	});
	const [isSidebarVisible, setIsSidebarVisible] = useState<boolean>(true);
	const [isSidebarResizing, setIsSidebarResizing] = useState(false);
	const [permissionMode, setPermissionMode] = useState<CodexPermissionMode>(() => {
		if (typeof window === "undefined") {
			return DEFAULT_CODEX_PERMISSION_MODE;
		}

		return (
			parseCodexPermissionMode(window.localStorage.getItem(PERMISSION_MODE_STORAGE_KEY)) ??
			DEFAULT_CODEX_PERMISSION_MODE
		);
	});
	const [availableModels, setAvailableModels] = useState<CodexModelDescriptor[]>([]);
	const [hasLoadedCodexModels, setHasLoadedCodexModels] = useState(false);
	const [selectedModel, setSelectedModel] = useState<string | null>(() => {
		if (typeof window === "undefined") {
			return null;
		}

		const savedModel = window.localStorage.getItem(MODEL_STORAGE_KEY);
		return typeof savedModel === "string" && savedModel.trim().length > 0 ? savedModel.trim() : null;
	});
	const [selectedReasoningEffort, setSelectedReasoningEffort] = useState<CodexReasoningEffort | null>(() => {
		if (typeof window === "undefined") {
			return null;
		}

		return parseCodexReasoningEffort(window.localStorage.getItem(REASONING_EFFORT_STORAGE_KEY));
	});
	const [selectedProvider, setSelectedProvider] = useState<SelectedProvider>(() => {
		if (typeof window === "undefined") {
			return "codex";
		}

		const stored = window.localStorage.getItem(PROVIDER_STORAGE_KEY);
		return isValidProvider(stored) ? stored : "codex";
	});
	const permissionModeRef = useRef<CodexPermissionMode>(permissionMode);
	const selectedModelRef = useRef<string | null>(selectedModel);
	const selectedReasoningEffortRef = useRef<CodexReasoningEffort | null>(selectedReasoningEffort);
	const selectedProviderRef = useRef<SelectedProvider>(selectedProvider);

	const appUpdate = useAppUpdate({
		electrobunRpc: electrobunView ? { request: electrobunView.rpc.request } : null,
	});

	const selectedModelDescriptor = useMemo(
		() => getModelDescriptorByName(availableModels, selectedModel),
		[availableModels, selectedModel],
	);
	const availableReasoningEfforts = useMemo(
		() => selectedModelDescriptor?.supportedReasoningEfforts.map((item) => item.reasoningEffort) ?? [],
		[selectedModelDescriptor],
	);
	const sidebarResizeBound = sidebarWidth <= SIDEBAR_WIDTH_MIN
		? "min"
		: sidebarWidth >= SIDEBAR_WIDTH_MAX
			? "max"
			: null;

	useEffect(() => {
		sidebarWidthRef.current = sidebarWidth;
		layoutShellRef.current?.style.setProperty("--desktop-sidebar-width", `${sidebarWidth}px`);
	}, [sidebarWidth]);

	const applySidebarWidth = useCallback((width: number) => {
		sidebarWidthRef.current = width;
		layoutShellRef.current?.style.setProperty("--desktop-sidebar-width", `${width}px`);
	}, []);

	useEffect(() => {
		if (!openWorkspaceMenuProjectId || typeof window === "undefined") {
			return;
		}

		const handlePointerDown = (event: PointerEvent) => {
			if (!workspaceMenuRef.current) {
				return;
			}

			if (!(event.target instanceof Node)) {
				return;
			}

			if (!workspaceMenuRef.current.contains(event.target)) {
				setOpenWorkspaceMenuProjectId(null);
			}
		};

		window.addEventListener("pointerdown", handlePointerDown);
		return () => {
			window.removeEventListener("pointerdown", handlePointerDown);
		};
	}, [openWorkspaceMenuProjectId]);

	useEffect(() => {
		if (!openWorkspaceMenuProjectId) {
			return;
		}

		if (!state.projects.some((project) => project.id === openWorkspaceMenuProjectId)) {
			setOpenWorkspaceMenuProjectId(null);
		}
	}, [openWorkspaceMenuProjectId, state.projects]);

	useEffect(() => {
		if (!isActiveThreadsOpen || typeof window === "undefined") {
			return;
		}

		const handlePointerDown = (event: PointerEvent) => {
			if (!activeThreadsMenuRef.current) {
				return;
			}

			if (!(event.target instanceof Node)) {
				return;
			}

			if (!activeThreadsMenuRef.current.contains(event.target)) {
				setIsActiveThreadsOpen(false);
			}
		};

		window.addEventListener("pointerdown", handlePointerDown);
		return () => {
			window.removeEventListener("pointerdown", handlePointerDown);
		};
	}, [isActiveThreadsOpen]);

	useEffect(() => {
		permissionModeRef.current = permissionMode;
	}, [permissionMode]);

	useEffect(() => {
		selectedModelRef.current = selectedModel;
	}, [selectedModel]);

	useEffect(() => {
		selectedReasoningEffortRef.current = selectedReasoningEffort;
	}, [selectedReasoningEffort]);

	useEffect(() => {
		selectedProviderRef.current = selectedProvider;
	}, [selectedProvider]);

	const lastProviderSyncChatIdRef = useRef<string | null>(null);
	useEffect(() => {
		if (!isProviderSelectionLocked || !selectedChatProvider) {
			return;
		}
		// Only sync provider when switching to a different chat, not when the user explicitly changes provider.
		if (lastProviderSyncChatIdRef.current === selectedChatId) {
			return;
		}
		lastProviderSyncChatIdRef.current = selectedChatId;

		if (selectedProvider === selectedChatProvider) {
			return;
		}

		setSelectedProvider(selectedChatProvider);
		if (typeof window !== "undefined") {
			window.localStorage.setItem(PROVIDER_STORAGE_KEY, selectedChatProvider);
		}
		void fetchModelsForProvider(selectedChatProvider, api, {
			setAvailableModels,
			setHasLoadedCodexModels,
			setSelectedModel,
			setSelectedReasoningEffort,
		});
	}, [api, isProviderSelectionLocked, selectedChatId, selectedChatProvider, selectedProvider]);

	useEffect(() => {
		messageWindowModeByChatRef.current = messageWindowModeByChat;
	}, [messageWindowModeByChat]);

	useEffect(() => {
		streamingTextByChatRef.current = streamingTextByChat;
	}, [streamingTextByChat]);

	useEffect(() => {
		dispatch({ payload: isConversationLoading, type: "SET_MESSAGE_WINDOW_LOADING" });
	}, [dispatch, isConversationLoading]);

	useEffect(() => {
		const nextActiveChatIds = new Set<string>();
		for (const chat of state.chats) {
			if (chat.isActive) {
				nextActiveChatIds.add(chat.id);
			}
		}
		for (const [chatId, sending] of Object.entries(state.sendingByChat)) {
			if (sending) {
				nextActiveChatIds.add(chatId);
			}
		}
		for (const [chatId, streamingActive] of Object.entries(state.streamingActiveByChat)) {
			if (streamingActive) {
				nextActiveChatIds.add(chatId);
			}
		}
		activeChatIdsRef.current = nextActiveChatIds;
	}, [state.chats, state.sendingByChat, state.streamingActiveByChat]);

	useEffect(() => {
		const previousActiveChatIds = previousActiveChatIdsRef.current;
		const currentActiveChatIds = new Set(activeChatIdsRef.current);

		for (const chat of state.chats) {
			if (!previousActiveChatIds.has(chat.id) || currentActiveChatIds.has(chat.id)) {
				continue;
			}
			if (chat.status !== "completed" && chat.status !== "failed") {
				continue;
			}

			void showThreadCompletionDesktopNotification(chat);
		}

		previousActiveChatIdsRef.current = currentActiveChatIds;
	}, [state.chats, state.sendingByChat, state.streamingActiveByChat]);

	useEffect(() => {
		if (typeof window === "undefined") {
			return;
		}

		try {
			window.localStorage.setItem(PERMISSION_MODE_STORAGE_KEY, permissionMode);
		} catch {
			// Ignore storage failures in restricted environments
		}
	}, [permissionMode]);

	useEffect(() => {
		if (typeof window === "undefined") {
			return;
		}

		try {
			if (!selectedModel) {
				window.localStorage.removeItem(MODEL_STORAGE_KEY);
				return;
			}

			window.localStorage.setItem(MODEL_STORAGE_KEY, selectedModel);
		} catch {
			// Ignore storage failures in restricted environments
		}
	}, [selectedModel]);

	useEffect(() => {
		if (typeof window === "undefined") {
			return;
		}

		try {
			if (!selectedReasoningEffort) {
				window.localStorage.removeItem(REASONING_EFFORT_STORAGE_KEY);
				return;
			}

			window.localStorage.setItem(REASONING_EFFORT_STORAGE_KEY, selectedReasoningEffort);
		} catch {
			// Ignore storage failures in restricted environments
		}
	}, [selectedReasoningEffort]);

	useEffect(() => {
		if (!hasLoadedCodexModels || availableModels.length === 0) {
			return;
		}

		const resolvedModel = resolveSelectedModel(availableModels, selectedModel);
		if (resolvedModel !== selectedModel) {
			setSelectedModel(resolvedModel);
			return;
		}

		const resolvedEffort = resolveSelectedReasoningEffort(
			getModelDescriptorByName(availableModels, resolvedModel),
			selectedReasoningEffort,
		);
		if (resolvedEffort !== selectedReasoningEffort) {
			setSelectedReasoningEffort(resolvedEffort);
		}
	}, [availableModels, hasLoadedCodexModels, selectedModel, selectedReasoningEffort]);

	const persistSidebarWidth = useCallback((width: number) => {
		if (typeof window === "undefined") {
			return;
		}

		try {
			window.localStorage.setItem(SIDEBAR_WIDTH_STORAGE_KEY, String(width));
		} catch {
			// Ignore storage failures in restricted environments
		}
	}, []);

	const stopSidebarResize = useCallback(() => {
		if (!isSidebarResizingRef.current) {
			return;
		}

		isSidebarResizingRef.current = false;
		setIsSidebarResizing(false);
		document.body.classList.remove("select-none");
		document.body.classList.remove("cursor-ew-resize");
		persistSidebarWidth(sidebarWidthRef.current);
	}, [persistSidebarWidth]);

	const handleSidebarResizePointerMove = useCallback((event: ReactPointerEvent<HTMLButtonElement>) => {
		if (!isSidebarResizingRef.current) {
			return;
		}

		const nextWidth = clampSidebarWidth(
			sidebarResizeStartWidthRef.current + (event.clientX - sidebarResizeStartXRef.current),
		);
		applySidebarWidth(nextWidth);
	}, [applySidebarWidth]);

	const startSidebarResize = useCallback((event: ReactPointerEvent<HTMLButtonElement>) => {
		event.preventDefault();
		if (event.button !== 0 || !event.isPrimary || typeof window === "undefined") {
			return;
		}

		isSidebarResizingRef.current = true;
		setIsSidebarResizing(true);
		sidebarResizeStartXRef.current = event.clientX;
		sidebarResizeStartWidthRef.current = sidebarWidthRef.current;
		document.body.classList.add("select-none");
		document.body.classList.add("cursor-ew-resize");
		event.currentTarget.setPointerCapture(event.pointerId);
	}, []);

	const handleSidebarResizePointerUp = useCallback(
		(event: ReactPointerEvent<HTMLButtonElement>) => {
			if (event.currentTarget.hasPointerCapture(event.pointerId)) {
				event.currentTarget.releasePointerCapture(event.pointerId);
			}
			setSidebarWidth(sidebarWidthRef.current);
			stopSidebarResize();
		},
		[stopSidebarResize],
	);

	useEffect(() => () => {
		document.body.classList.remove("select-none");
		document.body.classList.remove("cursor-ew-resize");
	}, []);

	useEffect(() => {
		const timers = errorAutoDismissTimersRef.current;

		for (const error of state.errors) {
			if (timers.has(error.id)) {
				continue;
			}

			timers.set(error.id, setTimeout(() => {
				timers.delete(error.id);
				dispatch({ payload: error.id, type: "REMOVE_ERROR" });
			}, 6_000));
		}

		for (const [errorId, timer] of timers) {
			if (state.errors.some((error) => error.id === errorId)) {
				continue;
			}

			clearTimeout(timer);
			timers.delete(errorId);
		}
	}, [dispatch, state.errors]);

	useEffect(() => {
		return () => {
			for (const timer of errorAutoDismissTimersRef.current.values()) {
				clearTimeout(timer);
			}
			errorAutoDismissTimersRef.current.clear();
		};
	}, []);

	useEffect(() => {
		selectedChatIdRef.current = state.selectedChatId;
	}, [state.selectedChatId]);

	useEffect(() => {
		selectedProjectIdRef.current = state.selectedProjectId;
	}, [state.selectedProjectId]);

	useEffect(() => {
		isCreatingChatRef.current = state.isCreatingChat;
	}, [state.isCreatingChat]);

	const addError = useCallback(
		(message: string, source: "rest" | "ws", code = "unknown") => {
			dispatch({
				type: "ADD_ERROR",
				payload: { code, message, source },
			});
		},
		[dispatch],
	);

	const clearRestErrors = useCallback(() => {
		dispatch({ type: "CLEAR_ERRORS_BY_SOURCE", payload: "rest" });
	}, [dispatch]);

	const formatApiErrorCode = useCallback((error: unknown) => {
		return error instanceof RemoteCodeApiError ? `HTTP_${error.status}` : "NETWORK";
	}, []);

	const formatApiErrorMessage = useCallback((error: unknown, fallback: string) => {
		return error instanceof Error ? error.message : fallback;
	}, []);

	const {
		state: projectGitState,
		checkoutBranch,
		createBranch,
		refresh: refreshProjectGit,
	} = useProjectGit({
		projectId: state.selectedProjectId,
		api,
		onError: (message) => {
			addError(message, "rest", "git_error");
		},
	});

	const {
		state: terminalState,
		setOpen: setTerminalOpen,
		syncHistory: syncTerminalHistory,
		runCommand: runTerminalCommand,
	} = useThreadTerminalSession({
		execCommand: async (chatId, input) => {
			return await api.execTerminalCommand(chatId, input);
		},
		historyLimit: 1_000,
		getHistory: async (chatId, options) => {
			return await api.getTerminalHistory(chatId, options);
		},
		onError: (message) => {
			addError(message, "rest", "terminal_error");
		},
	});

	useEffect(() => {
		const openByChat: Record<string, boolean> = {};
		for (const [chatId, chatState] of Object.entries(terminalState.chats)) {
			openByChat[chatId] = chatState.isOpen;
		}

		terminalOpenByChatRef.current = openByChat;
	}, [terminalState.chats]);

	const persistWorkspaceSelection = useCallback(
		async (
			selectedProjectId: string | null,
			selectedChatId: string | null,
			overrides?: {
				permissionMode?: CodexPermissionMode;
				selectedModel?: string | null;
				selectedReasoningEffort?: CodexReasoningEffort | null;
			},
		) => {
			try {
					await api.updateWorkspaceSelection({
						selectedChatId,
						selectedProjectId,
						permissionMode: overrides?.permissionMode ?? permissionModeRef.current,
						selectedModel: overrides?.selectedModel ?? selectedModelRef.current,
						selectedReasoningEffort:
							overrides?.selectedReasoningEffort ?? selectedReasoningEffortRef.current,
					});
					clearRestErrors();
				} catch (error) {
					addError(
						formatApiErrorMessage(error, "Unable to persist selection"),
						"rest",
						formatApiErrorCode(error),
					);
				}
			},
			[addError, api, clearRestErrors, formatApiErrorCode, formatApiErrorMessage],
		);

	const isViewingLatestMessages = useCallback(
		(chatId: string): boolean =>
			selectedChatIdRef.current === chatId &&
			(messageWindowModeByChatRef.current[chatId] ?? "latest") === "latest",
		[],
	);

	const markLatestMessagesDirty = useCallback((chatId: string) => {
		setLatestDirtyByChat((current) => current[chatId] ? current : {
			...current,
			[chatId]: true,
		});
	}, []);

	const clearStreamingStateForChat = useCallback((chatId: string) => {
		queryClient.setQueryData<StreamTurnState | null>(queryKeys.streamTurn(chatId), null);
		setStreamingTextByChat((current) => (
			current[chatId] === undefined
				? current
				: {
					...current,
					[chatId]: "",
				}
		));
		dispatch({
			payload: { chatId },
			type: "CLEAR_STREAMING",
		});
		dispatch({
			payload: { chatId },
			type: "CLEAR_STREAM_TURN",
		});
	}, [dispatch, queryClient]);

	const loadLatestMessagesForChat = useCallback(
		async (chatId: string) => {
			try {
				const latestPage = await api.listMessagesPage(chatId, {
					limit: MESSAGE_PAGE_SIZE,
				});
				queryClient.setQueryData(queryKeys.messages(chatId), latestPage);
				setMessageWindowModeByChat((current) => ({
					...current,
					[chatId]: "latest",
				}));
				setLatestDirtyByChat((current) => ({
					...current,
					[chatId]: false,
				}));
				clearRestErrors();
			} catch (error) {
				if (formatApiErrorCode(error) === "HTTP_404") {
					queryClient.setQueryData<MessagePageDTO>(queryKeys.messages(chatId), {
						hasMore: false,
						messages: [],
						nextBeforeMessageId: null,
						turns: [],
					});
					setMessageWindowModeByChat((current) => ({
						...current,
						[chatId]: "latest",
					}));
					setLatestDirtyByChat((current) => ({
						...current,
						[chatId]: false,
					}));
					clearRestErrors();
					return;
				}
				addError(
					formatApiErrorMessage(error, "Unable to fetch messages from chat"),
					"rest",
					formatApiErrorCode(error),
				);
			}
		},
		[addError, api, clearRestErrors, formatApiErrorCode, formatApiErrorMessage, queryClient],
	);

	const loadOlderMessagesForChat = useCallback(
		async (chatId: string, beforeMessageId: string) => {
			try {
				const olderPage = await api.listMessagesPage(chatId, {
					beforeMessageId,
					limit: MESSAGE_PAGE_SIZE,
				});
				queryClient.setQueryData(queryKeys.messages(chatId), olderPage);
				setMessageWindowModeByChat((current) => ({
					...current,
					[chatId]: "older",
				}));
				queryClient.setQueryData<StreamTurnState | null>(queryKeys.streamTurn(chatId), null);
				setStreamingTextByChat((current) => ({
					...current,
					[chatId]: "",
				}));
				clearRestErrors();
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to fetch older messages"),
					"rest",
					formatApiErrorCode(error),
				);
			}
		},
		[addError, api, clearRestErrors, formatApiErrorCode, formatApiErrorMessage, queryClient],
	);

	const syncMissedAssistantEventsForChat = useCallback(
		async (chatId: string) => {
			if (!isViewingLatestMessages(chatId)) {
				markLatestMessagesDirty(chatId);
				return;
			}

			const collectEvents = async (
				afterId: number,
				accumulator: Array<{ event: AssistantStreamEvent; id: number }>,
			): Promise<Array<{ event: AssistantStreamEvent; id: number }>> => {
				const page = await api.listChatStreamEvents(chatId, {
					afterId,
					limit: 500,
				});
				const nextEvents = [
					...accumulator,
					...page.events.map((entry) => ({
						event: entry.event,
						id: entry.id,
					})),
				];

				if (!page.hasMore || page.nextAfterId === null) {
					return nextEvents;
				}

				return await collectEvents(page.nextAfterId, nextEvents);
			};

			const lastKnownEventId = lastAssistantEventIdByChatRef.current[chatId] ?? 0;
			try {
				const events = await collectEvents(lastKnownEventId, []);
				if (events.length === 0) {
					return;
				}

				let latestTurn = queryClient.getQueryData<StreamTurnState | null>(queryKeys.streamTurn(chatId)) ?? null;
				let appliedAnyEvent = false;
				for (const entry of events) {
					const lastAppliedEventId = lastAssistantEventIdByChatRef.current[chatId] ?? 0;
					if (entry.id <= lastAppliedEventId) {
						continue;
					}

					latestTurn = applyAssistantEventToTurn(latestTurn, entry.event);
					lastAssistantEventIdByChatRef.current[chatId] = entry.id;
					appliedAnyEvent = true;
				}

				if (!appliedAnyEvent) {
					return;
				}

				queryClient.setQueryData<StreamTurnState | null>(
					queryKeys.streamTurn(chatId),
					latestTurn,
				);
			} catch {
				void queryClient.invalidateQueries({ queryKey: queryKeys.messages(chatId) });
			}
		},
		[api, isViewingLatestMessages, markLatestMessagesDirty, queryClient],
	);

	const syncFinalMessagesAfterDone = useCallback(
		async (chatId: string) => {
			const maxAttempts = 5;
			const retryDelayMs = 250;
			const trySyncMessages = async (attempt: number): Promise<void> => {
				if (!isViewingLatestMessages(chatId)) {
					setStreamingTextByChat((current) => ({
						...current,
						[chatId]: "",
					}));
					markLatestMessagesDirty(chatId);
					return;
				}

				try {
					const latestPage = await api.listMessagesPage(chatId, {
						limit: MESSAGE_PAGE_SIZE,
					});
					if (latestPage.messages.at(-1)?.role === "assistant") {
						queryClient.setQueryData<MessagePageDTO>(queryKeys.messages(chatId), latestPage);
						setMessageWindowModeByChat((current) => ({
							...current,
							[chatId]: "latest",
						}));
						setStreamingTextByChat((current) => ({
							...current,
							[chatId]: "",
						}));
						setLatestDirtyByChat((current) => ({
							...current,
							[chatId]: false,
						}));
						clearRestErrors();
						return;
					}
				} catch {
					// Keep retrying until maxAttempts.
				}

				if (attempt >= maxAttempts) {
					setStreamingTextByChat((current) => ({
						...current,
						[chatId]: "",
					}));
					if (isViewingLatestMessages(chatId)) {
						void queryClient.invalidateQueries({ queryKey: queryKeys.messages(chatId) });
					} else {
						markLatestMessagesDirty(chatId);
					}
					return;
				}

				setTimeout(() => {
					void trySyncMessages(attempt + 1);
				}, retryDelayMs);
			};

			await trySyncMessages(1);
		},
		[api, clearRestErrors, isViewingLatestMessages, markLatestMessagesDirty, queryClient],
	);

	useEffect(() => {
		if (!selectedChatId) {
			return;
		}

		dispatch({
			payload: {
				chatId: selectedChatId,
				lastEventId: lastAssistantEventIdByChatRef.current[selectedChatId] ?? 0,
				turns: messagesQuery.isPlaceholderData ? [] : streamHistoryTurns,
			},
			type: "SET_STREAM_HISTORY",
		});
	}, [dispatch, messagesQuery.isPlaceholderData, selectedChatId, streamHistoryTurns]);

	useEffect(() => {
		if (!selectedChatId) {
			return;
		}

		lastAssistantEventIdByChatRef.current[selectedChatId] = 0;
		queryClient.setQueryData<StreamTurnState | null>(
			queryKeys.streamTurn(selectedChatId),
			null,
		);

		if (activeChatIdsRef.current.has(selectedChatId) && isViewingLatestMessages(selectedChatId)) {
			void syncMissedAssistantEventsForChat(selectedChatId);
		}
	}, [
		isViewingLatestMessages,
		messagesQuery.page.turns,
		queryClient,
		selectedChatId,
		syncMissedAssistantEventsForChat,
	]);

		const loadChatsForProjectCore = useCallback(
			async (projectId: string | null, preferredChatId: string | null = null) => {
			if (!projectId) {
				dispatch({ payload: [], type: "SET_CHATS" });
				dispatch({ payload: null, type: "SET_SELECTED_CHAT" });
				dispatch({ payload: false, type: "SET_CHATS_LOADING" });
				return;
			}

			if (selectedProjectIdRef.current !== projectId) {
				dispatch({ payload: null, type: "SET_SELECTED_CHAT" });
			}

				dispatch({ payload: true, type: "SET_CHATS_LOADING" });
				try {
						const chats = (await api.listThreadSummaries(projectId)).map((chat) =>
							toChatDtoFromThreadSummary(chat, projectId),
						);
						if (selectedProjectIdRef.current !== projectId) {
							return;
						}
						clearRestErrors();

					const hasPreferredChat = preferredChatId ? chats.some((chat) => chat.id === preferredChatId) : false;
					const nextSelectedChatId = hasPreferredChat ? preferredChatId : chats[0]?.id ?? null;

				dispatch({ payload: chats, type: "SET_CHATS" });
				if (hasPreferredChat) {
					dispatch({ payload: preferredChatId, type: "SET_SELECTED_CHAT" });
				}

				if (
					selectedProjectIdRef.current !== projectId ||
					selectedChatIdRef.current !== nextSelectedChatId
				) {
					await persistWorkspaceSelection(projectId, nextSelectedChatId);
				}
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to load chats for project"),
					"rest",
					formatApiErrorCode(error),
				);
				if (selectedProjectIdRef.current === projectId) {
					dispatch({ payload: [], type: "SET_CHATS" });
				}
			} finally {
				if (selectedProjectIdRef.current === projectId) {
					dispatch({ payload: false, type: "SET_CHATS_LOADING" });
					persistedSelectedChatIdRef.current = null;
				}
			}
		},
			[addError, api, clearRestErrors, dispatch, formatApiErrorCode, formatApiErrorMessage, persistWorkspaceSelection],
		);

	const loadChatsForProject = useCallback(
		async (projectId: string | null, preferredChatId: string | null = null) => {
			if (!projectId) {
				await loadChatsForProjectCore(projectId, preferredChatId);
				return;
			}

			const inFlight = chatsLoadInFlightRef.current.get(projectId);
			if (inFlight) {
				const queuedPreferred = chatsLoadQueuedRef.current.get(projectId);
				if (preferredChatId !== null) {
					chatsLoadQueuedRef.current.set(projectId, preferredChatId);
				} else if (queuedPreferred === undefined) {
					chatsLoadQueuedRef.current.set(projectId, null);
				}
				await inFlight;
				return;
			}

			let nextPreferredChatId = preferredChatId;
			const task = (async () => {
				while (true) {
					chatsLoadQueuedRef.current.delete(projectId);
					await loadChatsForProjectCore(projectId, nextPreferredChatId);
					const queuedPreferred = chatsLoadQueuedRef.current.get(projectId);
					if (queuedPreferred === undefined) {
						break;
					}
					nextPreferredChatId = queuedPreferred;
				}
			})().finally(() => {
				chatsLoadInFlightRef.current.delete(projectId);
				chatsLoadQueuedRef.current.delete(projectId);
			});

			chatsLoadInFlightRef.current.set(projectId, task);
			await task;
		},
		[loadChatsForProjectCore],
	);

	const loadChatContext = useCallback(
		async (chatId: string | null) => {
			if (!chatId) {
				return;
			}

			const inFlight = chatContextLoadInFlightRef.current.get(chatId);
			if (inFlight) {
				await inFlight;
				return;
			}

			const task = (async () => {
				try {
					const context = await api.getChatContext(chatId);
					if (selectedChatIdRef.current !== chatId) {
						return;
					}

						dispatch({
							payload: {
								id: context.chat.id,
								projectId: context.chat.projectId,
								provider: context.chat.provider,
								providerThreadId: context.chat.providerThreadId ?? null,
								isActive: context.chat.isActive,
								title: context.chat.title,
								status: context.chat.status,
								diffAdded: context.chat.diffAdded,
								diffRemoved: context.chat.diffRemoved,
								finishedAt: context.chat.finishedAt,
								hasUnreadFinished: context.chat.hasUnreadFinished,
								updatedAt: context.chat.updatedAt,
								lastReadAt: context.chat.lastReadAt,
							},
							type: "UPDATE_CHAT",
						});
						clearRestErrors();
					} catch (error) {
						if (formatApiErrorCode(error) === "HTTP_404") {
							return;
						}
					addError(
						formatApiErrorMessage(error, "Unable to fetch chat context"),
						"rest",
						formatApiErrorCode(error),
					);
				}
			})().finally(() => {
				chatContextLoadInFlightRef.current.delete(chatId);
			});

			chatContextLoadInFlightRef.current.set(chatId, task);
			await task;
		},
		[addError, api, clearRestErrors, dispatch, formatApiErrorCode, formatApiErrorMessage],
	);

		const loadProjectsCore = useCallback(async () => {
			dispatch({ payload: true, type: "SET_PROJECTS_LOADING" });
			try {
				const [projects, selection] = await Promise.all([
					api.listWorkspaceSummaries().then((workspaces) =>
						workspaces.map(toProjectDtoFromWorkspaceSummary),
					),
					api.getWorkspaceSelection().catch(() => ({
						selectedChatId: null,
						selectedProjectId: null,
					permissionMode: DEFAULT_CODEX_PERMISSION_MODE,
					selectedModel: null,
					selectedReasoningEffort: null,
				})),
			]);
			const hasSelection = selection.selectedProjectId
				? projects.some((project) => project.id === selection.selectedProjectId)
				: false;
			const selectedProjectId = hasSelection ? selection.selectedProjectId : projects[0]?.id ?? null;
			const selectedChatId = hasSelection ? selection.selectedChatId : null;
			const nextPermissionMode =
				parseCodexPermissionMode(selection.permissionMode) ?? DEFAULT_CODEX_PERMISSION_MODE;
			const nextSelectedModel =
				typeof selection.selectedModel === "string" && selection.selectedModel.trim().length > 0
					? selection.selectedModel.trim()
					: null;
			const nextSelectedReasoningEffort =
				parseCodexReasoningEffort(selection.selectedReasoningEffort) ?? null;

			persistedSelectedChatIdRef.current = selectedChatId;
			dispatch({ payload: projects, type: "SET_PROJECTS" });
			dispatch({ payload: selectedProjectId, type: "SET_SELECTED_PROJECT" });
			setPermissionMode(nextPermissionMode);
			setSelectedModel(nextSelectedModel);
			setSelectedReasoningEffort(nextSelectedReasoningEffort);
			clearRestErrors();

			if (
				selection.selectedProjectId !== selectedProjectId ||
				selection.selectedChatId !== selectedChatId ||
				selection.permissionMode !== nextPermissionMode ||
				(selection.selectedModel ?? null) !== nextSelectedModel ||
				(selection.selectedReasoningEffort ?? null) !== nextSelectedReasoningEffort
			) {
				await persistWorkspaceSelection(selectedProjectId, selectedChatId, {
					permissionMode: nextPermissionMode,
					selectedModel: nextSelectedModel,
					selectedReasoningEffort: nextSelectedReasoningEffort,
				});
			}
		} catch (error) {
			addError(
				formatApiErrorMessage(error, "Unable to load projects"),
				"rest",
				formatApiErrorCode(error),
			);
		} finally {
			dispatch({ payload: false, type: "SET_PROJECTS_LOADING" });
		}
	}, [
		addError,
		api,
		clearRestErrors,
		dispatch,
		formatApiErrorCode,
		formatApiErrorMessage,
		persistWorkspaceSelection,
	]);

	const loadProjects = useCallback(async () => {
		const inFlight = projectsLoadInFlightRef.current;
		if (inFlight) {
			projectsLoadQueuedRef.current = true;
			await inFlight;
			return;
		}

		const task = (async () => {
			do {
				projectsLoadQueuedRef.current = false;
				await loadProjectsCore();
			} while (projectsLoadQueuedRef.current);
		})().finally(() => {
			projectsLoadInFlightRef.current = null;
			projectsLoadQueuedRef.current = false;
		});

		projectsLoadInFlightRef.current = task;
		await task;
	}, [loadProjectsCore]);

	const refreshProjectThreadCache = useCallback(
		async (projectId: string | null) => {
			if (!projectId) {
				return;
			}

			if (selectedProjectIdRef.current === projectId) {
				await loadChatsForProject(projectId, selectedChatIdRef.current);
				return;
			}

			const threadSummaries = await api.listThreadSummaries(projectId);
			projectChatsCacheRef.current[projectId] = sortChatsByUpdatedAtDesc(
				threadSummaries.map((chat) => toChatDtoFromThreadSummary(chat, projectId)),
			);
		},
		[api, loadChatsForProject],
	);

	const refreshUnreadThreadState = useCallback(
		async (projectId: string | null) => {
			await Promise.all([
				loadProjects(),
				refreshProjectThreadCache(projectId),
			]);
		},
		[loadProjects, refreshProjectThreadCache],
	);

	const loadCodexModels = useCallback(async () => {
		try {
			const provider = selectedProviderRef.current;
			const catalog = provider === "claude"
				? await api.listClaudeModels()
				: await api.listCodexModels();
			setAvailableModels(catalog.models);
			clearRestErrors();
		} catch (error) {
			addError(
				formatApiErrorMessage(error, "Unable to load models"),
				"rest",
				formatApiErrorCode(error),
			);
		} finally {
			setHasLoadedCodexModels(true);
		}
	}, [addError, api, clearRestErrors, formatApiErrorCode, formatApiErrorMessage]);

	const handleWsEventImpl = useCallback(
		async (event: ServerWsEvent) => {
			const clearChatSending = (chatId: string) => {
				if (!pendingSendChatIdsRef.current.has(chatId)) {
					return;
				}

				pendingSendChatIdsRef.current.delete(chatId);
				dispatch({
					payload: {
						chatId,
						sending: false,
					},
					type: "SET_CHAT_SENDING",
				});
			};

				switch (event.event) {
					case "assistant_delta":
						if (selectedChatIdRef.current !== event.data.chatId) {
							clearChatSending(event.data.chatId);
							break;
						}
						if (!isViewingLatestMessages(event.data.chatId)) {
							markLatestMessagesDirty(event.data.chatId);
							clearChatSending(event.data.chatId);
							break;
						}
						setStreamingTextByChat((current) => ({
							...current,
							[event.data.chatId]: `${current[event.data.chatId] ?? ""}${event.data.delta}`,
						}));
						dispatch({
							payload: {
								chatId: event.data.chatId,
								text: `${streamingTextByChatRef.current[event.data.chatId] ?? ""}${event.data.delta}`,
							},
							type: "SET_STREAMING_SNAPSHOT",
						});
						clearChatSending(event.data.chatId);
						break;
					case "assistant_snapshot":
						if (selectedChatIdRef.current !== event.data.chatId) {
							break;
						}
						if (!isViewingLatestMessages(event.data.chatId)) {
							markLatestMessagesDirty(event.data.chatId);
							break;
						}
						setStreamingTextByChat((current) => ({
							...current,
							[event.data.chatId]: event.data.partialText,
						}));
						dispatch({
							payload: {
								chatId: event.data.chatId,
								text: event.data.partialText,
							},
							type: "SET_STREAMING_SNAPSHOT",
						});
						break;
					case "assistant_event":
						if (selectedChatIdRef.current !== event.data.chatId) {
							clearChatSending(event.data.chatId);
							break;
						}
						if (!isViewingLatestMessages(event.data.chatId)) {
							markLatestMessagesDirty(event.data.chatId);
							clearChatSending(event.data.chatId);
							break;
						}
						if (
							typeof event.data.eventId === "number" &&
							event.data.eventId <= (lastAssistantEventIdByChatRef.current[event.data.chatId] ?? 0)
						) {
							break;
						}
						if (typeof event.data.eventId === "number") {
							lastAssistantEventIdByChatRef.current[event.data.chatId] = event.data.eventId;
						}
						queryClient.setQueryData<StreamTurnState | null>(
							queryKeys.streamTurn(event.data.chatId),
							(current) => applyAssistantEventToTurn(current ?? null, event.data.event),
						);
						dispatch({
							payload: {
								chatId: event.data.chatId,
								eventId: event.data.eventId,
								event: event.data.event,
							},
							type: "APPLY_ASSISTANT_EVENT",
						});
						clearChatSending(event.data.chatId);
						break;
					case "assistant_done":
						queryClient.setQueryData<StreamTurnState | null>(
							queryKeys.streamTurn(event.data.chatId),
							null,
						);
						dispatch({
							payload: { chatId: event.data.chatId },
							type: "CLEAR_STREAM_TURN",
						});
						if (selectedChatIdRef.current === event.data.chatId) {
							await syncFinalMessagesAfterDone(event.data.chatId);
							void refreshProjectGit();
						} else {
							setStreamingTextByChat((current) => ({
								...current,
								[event.data.chatId]: "",
							}));
						}
						clearChatSending(event.data.chatId);
						break;
				case "chat_updated":
					dispatch({
						payload: {
							diffAdded: event.data.diffAdded,
							diffRemoved: event.data.diffRemoved,
							id: event.data.chatId,
							isActive: event.data.isActive,
							providerThreadId: event.data.providerThreadId ?? null,
							status: event.data.status,
							updatedAt: event.data.updatedAt,
						},
						type: "UPDATE_CHAT",
					});
						if (event.data.status !== "running") {
							clearChatSending(event.data.chatId);
						}
						if (
							selectedChatIdRef.current === event.data.chatId &&
							(event.data.status === "completed" || event.data.status === "failed")
						) {
							void refreshProjectGit();
						}
						break;
				case "error":
						addError(event.data.message, "ws", event.data.code);
						if (event.data.chatId) {
							clearStreamingStateForChat(event.data.chatId);
							clearChatSending(event.data.chatId);
						}
						break;
				case "workspace_event": {
					const envelope = event.data;
					lastWorkspaceSeqRef.current = Math.max(lastWorkspaceSeqRef.current, envelope.seq);
					const isSelfWorkspaceEvent =
						envelope.originClientId !== null &&
						envelope.originClientId === workspaceClientIdRef.current;

					const payload = isRecord(envelope.payload) ? envelope.payload : null;
					const payloadChat = isRecord(payload?.chat) ? payload.chat : null;
					const payloadMessage = isRecord(payload?.message) ? payload.message : null;
					const payloadCommand = isRecord(payload?.command) ? payload.command : null;
					const chatId =
						typeof payload?.chatId === "string"
							? payload.chatId
							: typeof payloadChat?.id === "string"
								? payloadChat.id
								: typeof payloadMessage?.chatId === "string"
									? payloadMessage.chatId
									: typeof payloadCommand?.chatId === "string"
										? payloadCommand.chatId
										: null;
					const projectId =
						typeof payload?.projectId === "string"
							? payload.projectId
							: typeof payloadChat?.projectId === "string"
								? payloadChat.projectId
								: null;
					const projectPayload = payload?.project;
					const messagePayload = payload?.message;
					const shouldIgnoreWorkspaceEvent = isSelfWorkspaceEvent && envelope.type !== "message_created";

					if (shouldIgnoreWorkspaceEvent) {
						break;
					}

					switch (envelope.type) {
						case "project_created":
						case "project_updated":
							if (isProjectPayload(projectPayload)) {
								dispatch({
									payload: projectPayload,
									type: "UPSERT_PROJECT",
								});
								break;
							}
							await loadProjects();
							break;
						case "project_deleted":
							await loadProjects();
							break;
						case "chat_created":
						case "chat_deleted": {
							const preferredChatId =
								envelope.type === "chat_created" && isCreatingChatRef.current && chatId
									? chatId
									: selectedChatIdRef.current;
							const selectedProjectId = selectedProjectIdRef.current;
							if (projectId && selectedProjectId && projectId !== selectedProjectId) {
								break;
							}
							if (selectedProjectId) {
								await loadChatsForProject(selectedProjectId, preferredChatId);
							}
							break;
						}
						case "chat_updated": {
							const status = payload?.status;
							if (status === "completed" || status === "failed") {
								await refreshUnreadThreadState(projectId);
							}

							if (chatId === selectedChatIdRef.current) {
								break;
							}

							const diffAdded = payload?.diffAdded;
							const diffRemoved = payload?.diffRemoved;
							const isActive = payload?.isActive;
							const title = payload?.title;
							const updatedAt = payload?.updatedAt;

							if (
								chatId &&
								typeof diffAdded === "number" &&
								typeof diffRemoved === "number" &&
								typeof isActive === "boolean" &&
								isChatStatus(status) &&
								typeof updatedAt === "string"
							) {
								dispatch({
									payload: {
										diffAdded,
										diffRemoved,
										id: chatId,
										isActive,
										status,
										...(typeof title === "string" ? { title } : {}),
										updatedAt,
									},
									type: "UPDATE_CHAT",
								});
								break;
							}

							if (chatId && typeof title === "string" && typeof updatedAt === "string") {
								dispatch({
									payload: {
										id: chatId,
										title,
										updatedAt,
									},
									type: "UPDATE_CHAT",
								});
								break;
							}

							if (selectedProjectIdRef.current && (!projectId || projectId === selectedProjectIdRef.current)) {
								await loadChatsForProject(selectedProjectIdRef.current, selectedChatIdRef.current);
						}
							break;
						}
						case "message_created":
							if (isMessagePayload(messagePayload)) {
								if (messagePayload.chatId === selectedChatIdRef.current) {
									if (isViewingLatestMessages(messagePayload.chatId)) {
										queryClient.setQueryData<MessagePageDTO>(
											queryKeys.messages(messagePayload.chatId),
											(current) => appendMessageToMessagePage(current, messagePayload),
										);
									} else {
										markLatestMessagesDirty(messagePayload.chatId);
									}
								}
								break;
							}
							if (chatId && chatId === selectedChatIdRef.current) {
								if (isViewingLatestMessages(chatId)) {
									await loadLatestMessagesForChat(chatId);
								} else {
									markLatestMessagesDirty(chatId);
								}
							}
							break;
						case "selection_updated":
							break;
						case "git_updated":
							if (projectId && projectId === selectedProjectIdRef.current) {
								void refreshProjectGit();
							}
							break;
						case "terminal_command_started":
						case "terminal_entry_appended":
						case "terminal_command_finished":
							if (
								chatId &&
								chatId === selectedChatIdRef.current &&
								terminalOpenByChatRef.current[chatId]
							) {
								await syncTerminalHistory(chatId);
							}
							break;
					}

					break;
				}
			}
		},
		[
			addError,
			clearStreamingStateForChat,
			dispatch,
			isViewingLatestMessages,
			loadChatsForProject,
			loadLatestMessagesForChat,
			loadProjects,
			markLatestMessagesDirty,
			queryClient,
			refreshUnreadThreadState,
			refreshProjectGit,
			syncFinalMessagesAfterDone,
			syncTerminalHistory,
		],
	);

	const handleWsEventRef = useRef(handleWsEventImpl);
	handleWsEventRef.current = handleWsEventImpl;

	const handleWsEvent = useCallback(
		(event: ServerWsEvent) => {
			void handleWsEventRef.current(event);
		},
		[],
	);

	const handleWsStateImpl = useCallback(
			(connectionState: ConnectionState) => {
				dispatch({ payload: connectionState, type: "SET_CONNECTION_STATE" });
				if (connectionState === "connected") {
					wsRef.current?.sendJoinWorkspace(lastWorkspaceSeqRef.current, workspaceClientIdRef.current);
					if (selectedChatIdRef.current) {
						wsRef.current?.sendJoinChat(selectedChatIdRef.current);
						if (activeChatIdsRef.current.has(selectedChatIdRef.current)) {
							void syncMissedAssistantEventsForChat(selectedChatIdRef.current);
						}
					}
				}
			},
			[dispatch, syncMissedAssistantEventsForChat],
		);

	const handleWsStateRef = useRef(handleWsStateImpl);
	handleWsStateRef.current = handleWsStateImpl;

	const handleWsState = useCallback(
		(connectionState: ConnectionState) => {
			handleWsStateRef.current(connectionState);
		},
		[],
	);

	const handleBootstrap = useCallback(async () => {
		dispatch({
			payload: { baseUrl, token },
			type: "BOOTSTRAP_CONFIG",
		});

		try {
			const [projects, selection] = await Promise.all([
				api.listWorkspaceSummaries().then((workspaces) =>
					workspaces.map(toProjectDtoFromWorkspaceSummary),
				),
				api.getWorkspaceSelection().catch(() => ({
					selectedChatId: null,
					selectedProjectId: null,
					permissionMode: DEFAULT_CODEX_PERMISSION_MODE,
					selectedModel: null,
					selectedReasoningEffort: null,
				})),
			]);

			const hasProjectSelection = selection.selectedProjectId
				? projects.some((project) => project.id === selection.selectedProjectId)
				: false;
			const selectedProjectId = hasProjectSelection
				? selection.selectedProjectId
				: projects[0]?.id ?? null;
			const preferredChatId = hasProjectSelection ? selection.selectedChatId : null;
			const nextPermissionMode =
				parseCodexPermissionMode(selection.permissionMode) ?? DEFAULT_CODEX_PERMISSION_MODE;
			const nextSelectedModel =
				typeof selection.selectedModel === "string" && selection.selectedModel.trim().length > 0
					? selection.selectedModel.trim()
					: null;
			const nextSelectedReasoningEffort =
				parseCodexReasoningEffort(selection.selectedReasoningEffort) ?? null;

			let chats: ChatDTO[] = [];
			if (selectedProjectId) {
				try {
					chats = sortChatsByUpdatedAtDesc(
						(await api.listThreadSummaries(selectedProjectId)).map((chat) =>
							toChatDtoFromThreadSummary(chat, selectedProjectId),
						),
					);
				} catch {
					// chats remain empty on failure — non-fatal
				}
			}

			const hasPreferredChat = preferredChatId
				? chats.some((chat) => chat.id === preferredChatId)
				: false;
			const selectedChatId = hasPreferredChat
				? preferredChatId
				: chats[0]?.id ?? null;
			const messageWindow = createEmptyMessageWindow(selectedChatId);

			persistedSelectedChatIdRef.current = preferredChatId;
			selectedProjectIdRef.current = selectedProjectId;
			selectedChatIdRef.current = selectedChatId;
			skipPostBootstrapChatsLoadRef.current = selectedProjectId !== null;

			dispatch({
				payload: {
					projects,
					selectedProjectId,
					chats,
					selectedChatId,
					messageWindow,
				},
				type: "BOOTSTRAP_COMPLETE",
			});

			setPermissionMode(nextPermissionMode);
			setSelectedModel(nextSelectedModel);
			setSelectedReasoningEffort(nextSelectedReasoningEffort);
			clearRestErrors();

			if (
				selection.selectedProjectId !== selectedProjectId ||
				selection.selectedChatId !== selectedChatId ||
				selection.permissionMode !== nextPermissionMode ||
				(selection.selectedModel ?? null) !== nextSelectedModel ||
				(selection.selectedReasoningEffort ?? null) !== nextSelectedReasoningEffort
			) {
				await persistWorkspaceSelection(selectedProjectId, selectedChatId, {
					permissionMode: nextPermissionMode,
					selectedModel: nextSelectedModel,
					selectedReasoningEffort: nextSelectedReasoningEffort,
				});
			}
		} catch (error) {
			addError(
				formatApiErrorMessage(error, "Unable to load projects"),
				"rest",
				formatApiErrorCode(error),
			);
			dispatch({ payload: false, type: "SET_PROJECTS_LOADING" });
			dispatch({ payload: false, type: "SET_CHATS_LOADING" });
			dispatch({ payload: false, type: "SET_MESSAGE_WINDOW_LOADING" });
		} finally {
			bootstrapDoneRef.current = true;
		}
	}, [
		addError,
		api,
		baseUrl,
		clearRestErrors,
		dispatch,
		formatApiErrorCode,
		formatApiErrorMessage,
		persistWorkspaceSelection,
		token,
	]);

	useEffect(() => {
		void Promise.all([handleBootstrap(), loadCodexModels()]);
	}, [handleBootstrap, loadCodexModels]);

	useEffect(() => {
		if (!bootstrapDoneRef.current) {
			return;
		}
		if (skipPostBootstrapChatsLoadRef.current) {
			skipPostBootstrapChatsLoadRef.current = false;
			return;
		}
		void loadChatsForProject(state.selectedProjectId, persistedSelectedChatIdRef.current);
	}, [loadChatsForProject, state.selectedProjectId]);

	useEffect(() => {
		if (state.selectedProjectId && !state.chatsLoading) {
			projectChatsCacheRef.current[state.selectedProjectId] = state.chats;
		}
	}, [state.selectedProjectId, state.chats, state.chatsLoading]);

	useEffect(() => {
		if (!bootstrapDoneRef.current) {
			return;
		}
		void loadChatContext(state.selectedChatId);
	}, [loadChatContext, state.selectedChatId]);

	const lastMarkedReadSignatureRef = useRef<string | null>(null);
	const selectedChatReadSignature = state.selectedChatId
		? `${state.selectedChatId}:${activeThreadChat?.status ?? "missing"}:${activeThreadChat?.updatedAt ?? "none"}`
		: null;

	useEffect(() => {
		if (!bootstrapDoneRef.current || !state.selectedChatId || !state.selectedProjectId) {
			lastMarkedReadSignatureRef.current = null;
			return;
		}

		if (lastMarkedReadSignatureRef.current === selectedChatReadSignature) {
			return;
		}

		const selectedChatId = state.selectedChatId;
		lastMarkedReadSignatureRef.current = selectedChatReadSignature;

		void (async () => {
			try {
				const chat = await api.markChatRead(selectedChatId);
				dispatch({
					payload: {
						finishedAt: chat.finishedAt,
						hasUnreadFinished: chat.hasUnreadFinished,
						id: chat.id,
						lastReadAt: chat.lastReadAt,
					},
					type: "UPDATE_CHAT",
				});
				await refreshUnreadThreadState(chat.projectId);
			} catch {
				// Keep read-sync best-effort to avoid surfacing noisy errors while navigating.
			}
		})();
	}, [
		api,
		dispatch,
		refreshUnreadThreadState,
		selectedChatReadSignature,
		state.selectedChatId,
		state.selectedProjectId,
	]);

	useEffect(() => {
		const client = RemoteCodeRealtime.createClient({
			baseUrl,
			onConnectionStateChange: handleWsState,
			onEvent: (event) => {
				handleWsEvent(event);
			},
			token,
		});

		wsRef.current = client;
		client.connect();

		return () => {
			client.disconnect();
		};
	}, [baseUrl, handleWsEvent, handleWsState, token]);

	useEffect(() => {
		if (state.connectionState === "connected" && state.selectedChatId) {
			wsRef.current?.sendJoinChat(state.selectedChatId);
			if (activeChatIdsRef.current.has(state.selectedChatId) && isViewingLatestMessages(state.selectedChatId)) {
				void syncMissedAssistantEventsForChat(state.selectedChatId);
			}
			if (terminalOpenByChatRef.current[state.selectedChatId]) {
				void syncTerminalHistory(state.selectedChatId);
			}
		}
	}, [
		isViewingLatestMessages,
		state.connectionState,
		state.selectedChatId,
		syncMissedAssistantEventsForChat,
		syncTerminalHistory,
	]);

	const handleCreateProject = useCallback(
		async (input: { name?: string; path: string }) => {
			dispatch({ payload: true, type: "SET_CREATING_PROJECT" });
			try {
				const project = await api.createProject(input);
				dispatch({ payload: project, type: "UPSERT_PROJECT" });
				dispatch({ payload: project.id, type: "SET_SELECTED_PROJECT" });
				await persistWorkspaceSelection(project.id, null);
				clearRestErrors();
				return project;
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to create project"),
					"rest",
					formatApiErrorCode(error),
				);
				return null;
			} finally {
				dispatch({ payload: false, type: "SET_CREATING_PROJECT" });
			}
		},
		[addError, api, clearRestErrors, dispatch, formatApiErrorCode, formatApiErrorMessage, persistWorkspaceSelection],
	);

	const handleCreateChat = useCallback(
		async (title: string) => {
			if (!state.selectedProjectId) {
				addError("Select a project before creating a chat", "rest", "missing_project");
				return null;
			}

			setProjectThreadsOpen((current) => ({ ...current, [state.selectedProjectId!]: true }));
			setExpandedProjectThreads((current) => ({ ...current, [state.selectedProjectId!]: true }));
			dispatch({ payload: true, type: "SET_CREATING_CHAT" });
			try {
				const chat = await api.createChat(state.selectedProjectId, title, selectedProviderRef.current);
				dispatch({ payload: chat, type: "UPSERT_CHAT" });
				dispatch({ payload: chat.id, type: "SET_SELECTED_CHAT" });
				selectedProjectIdRef.current = state.selectedProjectId;
				selectedChatIdRef.current = chat.id;
				persistedSelectedChatIdRef.current = chat.id;
				await persistWorkspaceSelection(state.selectedProjectId, chat.id);
				clearRestErrors();
				return chat;
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to create chat"),
					"rest",
					formatApiErrorCode(error),
				);
				return null;
			} finally {
				dispatch({ payload: false, type: "SET_CREATING_CHAT" });
			}
		},
			[
				addError,
				api,
				clearRestErrors,
				dispatch,
				formatApiErrorCode,
				formatApiErrorMessage,
				persistWorkspaceSelection,
				state.selectedProjectId,
			],
		);

	const handleCreateChatForProject = useCallback(
		async (projectId: string) => {
			if (projectId !== selectedProjectIdRef.current) {
				dispatch({ payload: null, type: "SET_SELECTED_CHAT" });
				dispatch({ payload: projectId, type: "SET_SELECTED_PROJECT" });
				selectedProjectIdRef.current = projectId;
				selectedChatIdRef.current = null;
				persistedSelectedChatIdRef.current = null;
				setProjectThreadsOpen((current) => ({ ...current, [projectId]: true }));
			}
			setProjectThreadsOpen((current) => ({ ...current, [projectId]: true }));
			setExpandedProjectThreads((current) => ({ ...current, [projectId]: true }));

			dispatch({ payload: true, type: "SET_CREATING_CHAT" });
			try {
				const chat = await api.createChat(projectId, DEFAULT_DRAFT_THREAD_TITLE, selectedProviderRef.current);
				dispatch({ payload: chat, type: "UPSERT_CHAT" });
				selectedProjectIdRef.current = projectId;
				selectedChatIdRef.current = chat.id;
				persistedSelectedChatIdRef.current = chat.id;
				await persistWorkspaceSelection(projectId, chat.id);
				clearRestErrors();
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to create chat"),
					"rest",
					formatApiErrorCode(error),
				);
			} finally {
				dispatch({ payload: false, type: "SET_CREATING_CHAT" });
			}
		},
		[
			addError,
			api,
			clearRestErrors,
			dispatch,
			formatApiErrorCode,
			formatApiErrorMessage,
			persistWorkspaceSelection,
		],
	);

	const syncThreadTitleFromMessage = useCallback(
		async (chatId: string, currentTitle: string | null | undefined, text: string) => {
			if (!isPlaceholderThreadTitle(currentTitle)) {
				return;
			}

			const nextTitle = deriveThreadTitleFromMessage(text);
			dispatch({
				payload: {
					id: chatId,
					title: nextTitle,
				},
				type: "UPDATE_CHAT",
			});

			try {
				const updatedChat = await api.updateChat(chatId, { title: nextTitle });
				dispatch({ payload: updatedChat, type: "UPSERT_CHAT" });
				clearRestErrors();
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to rename thread"),
					"rest",
					formatApiErrorCode(error),
				);
			}
		},
		[addError, api, clearRestErrors, dispatch, formatApiErrorCode, formatApiErrorMessage],
	);

	const handleSendMessage = useCallback(
		async (text: string) => {
			if (selectedChat?.isActive) {
				addError("This thread is currently running. Wait until it finishes.", "ws", "chat_running");
				return;
			}

			if (!state.selectedProjectId) {
				addError("Select a project before sending a message", "rest", "missing_project");
				return;
			}

			if (state.selectedChatId && messageWindowMode !== "latest") {
				await loadLatestMessagesForChat(state.selectedChatId);
			}

			const selectedChatHasNoMessages = messagesQuery.messages.length === 0;
			const needsReplacementChat =
				Boolean(selectedChat) &&
				selectedChatHasNoMessages &&
				isPlaceholderThreadTitle(selectedChat?.title);
			const needsFallbackChat = !needsReplacementChat && !selectedChat;
			const tempChatId = needsFallbackChat
				? `temp-chat-${Date.now()}`
				: (selectedChat?.id ?? null);
			const optimisticChatId = tempChatId ?? `temp-chat-${Date.now()}`;
			const nextMessage: MessageDTO = {
				chatId: optimisticChatId,
				content: text,
				createdAt: new Date().toISOString(),
				id: crypto.randomUUID(),
				role: "user",
			};

			queryClient.setQueryData<MessagePageDTO>(
				queryKeys.messages(optimisticChatId),
				(current) => appendMessageToMessagePage(current, nextMessage),
			);
			setMessageWindowModeByChat((current) => ({
				...current,
				[optimisticChatId]: "latest",
			}));
			setLatestDirtyByChat((current) => ({
				...current,
				[optimisticChatId]: false,
			}));
			clearRestErrors();

			const replacementChat = needsReplacementChat
				? await handleCreateChat(deriveThreadTitleFromMessage(text))
				: null;
			const placeholderChatIdToDelete =
				replacementChat && selectedChat ? selectedChat.id : null;
			const fallbackChat = needsFallbackChat
				? await handleCreateChat(deriveThreadTitleFromMessage(text))
				: null;
			const activeChatId =
				replacementChat?.id ??
				selectedChat?.id ??
				fallbackChat?.id ??
				null;

			if (!activeChatId) {
				queryClient.removeQueries({ queryKey: queryKeys.messages(optimisticChatId) });
				return;
			}

			if (optimisticChatId !== activeChatId) {
				const optimisticData = queryClient.getQueryData<MessagePageDTO>(
					queryKeys.messages(optimisticChatId),
				);
				if (optimisticData) {
					queryClient.setQueryData<MessagePageDTO>(
						queryKeys.messages(activeChatId),
						{
							...optimisticData,
							messages: optimisticData.messages.map((message) => ({
								...message,
								chatId: activeChatId,
							})),
						},
					);
					queryClient.removeQueries({ queryKey: queryKeys.messages(optimisticChatId) });
				}
				nextMessage.chatId = activeChatId;
			}

			if (state.selectedChatId !== activeChatId) {
				dispatch({ payload: activeChatId, type: "SET_SELECTED_CHAT" });
				selectedChatIdRef.current = activeChatId;
				persistedSelectedChatIdRef.current = activeChatId;
				await persistWorkspaceSelection(state.selectedProjectId, activeChatId);
			}

			queryClient.setQueryData<StreamTurnState | null>(
				queryKeys.streamTurn(activeChatId),
				null,
			);
			setStreamingTextByChat((current) => ({
				...current,
				[activeChatId]: "",
			}));
			dispatch({
				payload: {
					chatId: activeChatId,
					sending: true,
				},
				type: "SET_CHAT_SENDING",
			});
			dispatch({
				payload: {
					id: activeChatId,
					isActive: true,
					status: "running",
					updatedAt: nextMessage.createdAt,
				},
				type: "UPDATE_CHAT",
			});

			if (!wsRef.current) {
				addError("WebSocket client is not ready", "ws", "not_ready");
				dispatch({
					payload: {
						chatId: activeChatId,
						sending: false,
					},
					type: "SET_CHAT_SENDING",
				});
				return;
			}

			const currentThreadTitle = replacementChat?.title ?? selectedChat?.title ?? fallbackChat?.title ?? null;
			await syncThreadTitleFromMessage(activeChatId, currentThreadTitle, text);
			pendingSendChatIdsRef.current.add(activeChatId);
			wsRef.current.sendJoinChat(activeChatId);
			const requestId = crypto.randomUUID();
			wsRef.current.sendUserMessage(
				activeChatId,
				text,
				state.selectedProjectId ?? undefined,
				permissionMode,
				selectedModel ?? undefined,
				selectedReasoningEffort ?? undefined,
				workspaceClientIdRef.current,
				requestId,
				selectedProvider ?? undefined,
			);

			if (placeholderChatIdToDelete) {
				try {
					await api.deleteChat(placeholderChatIdToDelete);
				} catch {
					// Ignore placeholder cleanup failure.
				}
			}
		},
			[
				addError,
				api,
				clearRestErrors,
				dispatch,
				handleCreateChat,
				loadLatestMessagesForChat,
				messageWindowMode,
				messagesQuery.messages.length,
				permissionMode,
				persistWorkspaceSelection,
				queryClient,
				syncThreadTitleFromMessage,
				selectedModel,
				selectedChatProvider,
				selectedChatProviderThreadId,
				selectedProvider,
				selectedReasoningEffort,
				selectedChat,
				selectedChat?.provider,
				state.selectedChatId,
				state.selectedProjectId,
		],
	);

	const handleForceStop = useCallback(
		async () => {
			const chatId = selectedChatIdRef.current;
			if (!chatId) {
				return;
			}

			setStoppingByChat((current) => ({
				...current,
				[chatId]: true,
			}));

			try {
				const result = await api.stopChat(chatId);
				if (result.chat) {
					dispatch({
						payload: {
							diffAdded: result.chat.diffAdded,
							diffRemoved: result.chat.diffRemoved,
							id: result.chat.id,
							isActive: result.chat.isActive,
							providerThreadId: result.chat.providerThreadId ?? null,
							status: result.chat.status,
							updatedAt: result.chat.updatedAt,
						},
						type: "UPDATE_CHAT",
					});

					if (!result.chat.isActive) {
						pendingSendChatIdsRef.current.delete(result.chat.id);
						dispatch({
							payload: {
								chatId: result.chat.id,
								sending: false,
							},
							type: "SET_CHAT_SENDING",
						});
						clearStreamingStateForChat(result.chat.id);
					}
				}

				if (!result.stopped) {
					addError("This thread is no longer running.", "rest", "chat_not_running");
				}
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to force stop thread"),
					"rest",
					formatApiErrorCode(error),
				);
			} finally {
				setStoppingByChat((current) => {
					if (!current[chatId]) {
						return current;
					}

					const next = { ...current };
					delete next[chatId];
					return next;
				});
			}
		},
		[addError, api, clearStreamingStateForChat, dispatch, formatApiErrorCode, formatApiErrorMessage],
	);

	const persistCurrentSelectionPreferences = useCallback(
		(overrides: {
			permissionMode?: CodexPermissionMode;
			selectedModel?: string | null;
			selectedReasoningEffort?: CodexReasoningEffort | null;
		}) => {
			const selectedProjectId = selectedProjectIdRef.current;
			const selectedChatId = selectedProjectId ? selectedChatIdRef.current : null;
			void persistWorkspaceSelection(
				selectedProjectId,
				selectedChatId,
				overrides,
			);
		},
		[persistWorkspaceSelection],
	);

	const handlePermissionModeChange = useCallback(
		(mode: CodexPermissionMode) => {
			setPermissionMode(mode);
			persistCurrentSelectionPreferences({
				permissionMode: mode,
			});
		},
		[persistCurrentSelectionPreferences],
	);

	const handleModelChange = useCallback(
		(nextModel: string) => {
			const nextModelDescriptor = getModelDescriptorByName(availableModels, nextModel);
			const nextReasoningEffort = resolveSelectedReasoningEffort(
				nextModelDescriptor,
				selectedReasoningEffortRef.current,
			);
			setSelectedModel(nextModel);
			setSelectedReasoningEffort(nextReasoningEffort);
			persistCurrentSelectionPreferences({
				selectedModel: nextModel,
				selectedReasoningEffort: nextReasoningEffort,
			});
		},
		[availableModels, persistCurrentSelectionPreferences],
	);

	const handleReasoningEffortChange = useCallback(
		(effort: CodexReasoningEffort) => {
			setSelectedReasoningEffort(effort);
			persistCurrentSelectionPreferences({
				selectedReasoningEffort: effort,
			});
		},
		[persistCurrentSelectionPreferences],
	);

	const handleProviderChange = useCallback(
		(provider: SelectedProvider) => {
			if (isProviderSelectionLocked) {
				return;
			}

			setSelectedProvider(provider);
			if (typeof window !== "undefined") {
				window.localStorage.setItem(PROVIDER_STORAGE_KEY, provider);
			}
			// Keep previous provider's models visible until new ones load (D-14).
			void fetchModelsForProvider(provider, api, {
				setAvailableModels,
				setHasLoadedCodexModels,
				setSelectedModel,
				setSelectedReasoningEffort,
			});
		},
		[api, isProviderSelectionLocked],
	);

	const handleSetStreamItemExpanded = useCallback(
		(itemId: string, expanded: boolean, byUser: boolean) => {
			const chatId = selectedChatIdRef.current;
			if (!chatId) {
				return;
			}

			queryClient.setQueryData<StreamTurnState | null>(
				queryKeys.streamTurn(chatId),
				(current) => (
					current
						? updateStreamItemExpanded(current, itemId, {
							expanded,
							byUser,
						})
						: current ?? null
				),
			);
			queryClient.setQueryData<MessagePageDTO>(
				queryKeys.messages(chatId),
				(current) => (
					current
						? {
							...current,
							turns: current.turns.map((turn) => (
								turn.itemsById[itemId]
									? updateStreamItemExpanded(turn as StreamTurnState, itemId, {
										expanded,
										byUser,
									})
									: turn
							)),
						}
						: current
				),
			);
		},
		[queryClient],
	);

	const handleSetStreamItemState = useCallback(
		(itemId: string, stateValue: "running" | "preview" | "collapsed" | "completed" | "failed" | "cancelled") => {
			const chatId = selectedChatIdRef.current;
			if (!chatId) {
				return;
			}

			queryClient.setQueryData<StreamTurnState | null>(
				queryKeys.streamTurn(chatId),
				(current) => (current ? updateStreamItemState(current, itemId, stateValue) : current ?? null),
			);
			queryClient.setQueryData<MessagePageDTO>(
				queryKeys.messages(chatId),
				(current) => (
					current
						? {
							...current,
							turns: current.turns.map((turn) => (
								turn.itemsById[itemId]
									? updateStreamItemState(turn as StreamTurnState, itemId, stateValue)
									: turn
							)),
						}
						: current
				),
			);
		},
		[queryClient],
	);

	const handleSelectProject = useCallback(
		async (projectId: string) => {
			setOpenWorkspaceMenuProjectId(null);
			if (projectId === state.selectedProjectId) {
				setProjectThreadsOpen((current) => ({
					...current,
					[projectId]: !(current[projectId] ?? true),
				}));
				return;
			}

			setProjectThreadsOpen((current) => ({
				...current,
				[projectId]: true,
			}));

			dispatch({ payload: projectId, type: "SET_SELECTED_PROJECT" });
			selectedProjectIdRef.current = projectId;
			selectedChatIdRef.current = null;
			persistedSelectedChatIdRef.current = null;
			setOpeningProjectId(projectId);
			setOpeningThreadId(null);
			await persistWorkspaceSelection(projectId, null);
		},
		[dispatch, persistWorkspaceSelection, state.selectedProjectId],
	);

	const handleSelectChat = useCallback(
		async (chatId: string) => {
			if (chatId === state.selectedChatId) {
				return;
			}

			setOpeningThreadId(chatId);
			dispatch({ payload: chatId, type: "SET_SELECTED_CHAT" });
			selectedChatIdRef.current = chatId;
			persistedSelectedChatIdRef.current = chatId;
			await persistWorkspaceSelection(state.selectedProjectId, chatId);
		},
		[dispatch, persistWorkspaceSelection, state.selectedChatId, state.selectedProjectId],
	);

	const handleLoadOlderMessages = useCallback(async () => {
		const chatId = selectedChatIdRef.current;
		const beforeMessageId = messagesQuery.page.nextBeforeMessageId;
		if (
			!chatId ||
			!beforeMessageId ||
			!messagesQuery.hasOlderMessages ||
			messagesQuery.isLoadingOlderMessages
		) {
			return;
		}

		await loadOlderMessagesForChat(chatId, beforeMessageId);
	}, [
		loadOlderMessagesForChat,
		messagesQuery.hasOlderMessages,
		messagesQuery.isLoadingOlderMessages,
		messagesQuery.page.nextBeforeMessageId,
	]);

	const handleLoadLatestMessages = useCallback(async () => {
		const chatId = selectedChatIdRef.current;
		if (!chatId || messagesQuery.isLoadingLatestMessages) {
			return;
		}

		await loadLatestMessagesForChat(chatId);
	}, [loadLatestMessagesForChat, messagesQuery.isLoadingLatestMessages]);

	useEffect(() => {
		if (!openingProjectId) {
			return;
		}

		if (state.selectedProjectId !== openingProjectId) {
			return;
		}

		if (state.chatsLoading) {
			return;
		}

		setOpeningProjectId(null);
	}, [openingProjectId, state.chatsLoading, state.selectedProjectId]);

	useEffect(() => {
		if (!openingProjectId) {
			setVisibleOpeningProjectId(null);
			return;
		}
		const timer = setTimeout(() => {
			setVisibleOpeningProjectId(openingProjectId);
		}, 150);
		return () => clearTimeout(timer);
	}, [openingProjectId]);

	useEffect(() => {
		if (!openingThreadId) {
			return;
		}

		if (state.selectedChatId !== openingThreadId) {
			return;
		}

		const selectedWindowReady =
			state.selectedChatId === openingThreadId &&
			!messagesQuery.isPlaceholderData &&
			messagesQuery.fetchStatus !== "fetching";
		if (!selectedWindowReady) {
			return;
		}

		setOpeningThreadId(null);
	}, [messagesQuery.fetchStatus, messagesQuery.isPlaceholderData, openingThreadId, state.selectedChatId]);

	const handleDeleteProject = useCallback(
		async (projectId: string) => {
			setOpenWorkspaceMenuProjectId(null);
			try {
				const deletionResult = await api.deleteProject(projectId);
				if (!deletionResult.deleted) {
					throw new Error("Unable to delete workspace");
				}
				if (state.selectedProjectId === projectId) {
					await persistWorkspaceSelection(null, null);
				}

				delete projectChatsCacheRef.current[projectId];
				await loadProjects();
				clearRestErrors();
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to delete workspace"),
					"rest",
					formatApiErrorCode(error),
				);
			}
		},
		[
			addError,
			api,
			clearRestErrors,
			formatApiErrorCode,
			formatApiErrorMessage,
			loadProjects,
			persistWorkspaceSelection,
			state.selectedProjectId,
		],
	);

	const handleRenameProject = useCallback(
		async (project: Pick<ProjectDTO, "id" | "name">) => {
			setOpenWorkspaceMenuProjectId(null);
			if (typeof window === "undefined") {
				return;
			}

			const nextNameInput = window.prompt("Rename workspace", project.name);
			if (nextNameInput === null) {
				return;
			}

			const nextName = nextNameInput.trim();
			if (nextName.length === 0) {
				addError("Workspace name cannot be empty", "rest", "invalid_workspace_name");
				return;
			}

			if (nextName === project.name) {
				return;
			}

			try {
				const updatedProject = await api.updateProject(project.id, { name: nextName });
				dispatch({
					payload: updatedProject,
					type: "UPSERT_PROJECT",
				});
				clearRestErrors();
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to rename workspace"),
					"rest",
					formatApiErrorCode(error),
				);
			}
		},
		[
			addError,
			api,
			clearRestErrors,
			dispatch,
			formatApiErrorCode,
			formatApiErrorMessage,
		],
	);

	const handleClearProjectThreads = useCallback(
		async (projectId: string) => {
			setOpenWorkspaceMenuProjectId(null);
			const normalizedProjectId = projectId.trim();
			if (normalizedProjectId.length === 0) {
				return;
			}

			let deleteAllThreadsFailed = false;
			let deletionError: unknown = null;
			try {
				const threads = await api.listThreadSummaries(normalizedProjectId);
				for (const thread of threads) {
					try {
						await api.deleteChat(thread.id);
					} catch (error) {
						if (formatApiErrorCode(error) !== "HTTP_404") {
							deleteAllThreadsFailed = true;
							deletionError = error;
						}
					}
				}

				projectChatsCacheRef.current[normalizedProjectId] = [];
				if (state.selectedProjectId === normalizedProjectId) {
					await loadChatsForProject(normalizedProjectId, null);
				}
				clearRestErrors();
			} catch (error) {
				deleteAllThreadsFailed = true;
				deletionError = error;
			}

			if (deleteAllThreadsFailed) {
				addError(
					formatApiErrorMessage(deletionError, "Unable to clear workspace threads"),
					"rest",
					formatApiErrorCode(deletionError),
				);
			}
		},
		[
			addError,
			api,
			clearRestErrors,
			formatApiErrorCode,
			formatApiErrorMessage,
			loadChatsForProject,
			state.selectedProjectId,
		],
	);

	const handleDeleteChat = useCallback(
		async (chatId: string) => {
			try {
				const deletionResult = await api.deleteChat(chatId);
				if (!deletionResult.deleted) {
					throw new Error("Unable to delete thread");
				}
			} catch (error) {
				if (formatApiErrorCode(error) !== "HTTP_404") {
					addError(
						formatApiErrorMessage(error, "Unable to delete thread"),
						"rest",
						formatApiErrorCode(error),
					);
					return;
				}
			}

			const preferredChatId = state.selectedChatId === chatId ? null : state.selectedChatId;
			const remainingChats = state.chats.filter((chat) => chat.id !== chatId);
			const hasPreferredChat = preferredChatId
				? remainingChats.some((chat) => chat.id === preferredChatId)
				: false;
			const nextSelectedChatId = hasPreferredChat ? preferredChatId : remainingChats[0]?.id ?? null;

			dispatch({
				payload: { chatId, nextSelectedChatId },
				type: "REMOVE_CHAT",
			});

			if (state.selectedProjectId) {
				await loadChatsForProject(state.selectedProjectId, nextSelectedChatId);
			}
			clearRestErrors();
		},
		[
			addError,
			api,
			dispatch,
			clearRestErrors,
			formatApiErrorCode,
			formatApiErrorMessage,
			loadChatsForProject,
			state.chats,
			state.selectedChatId,
			state.selectedProjectId,
		],
	);

	const handleShowMoreThreads = useCallback((projectId: string) => {
		setExpandedProjectThreads((current) => ({
			...current,
			[projectId]: true,
		}));
	}, []);

	const handleToggleWorkspaceMenu = useCallback((projectId: string) => {
		setOpenWorkspaceMenuProjectId((current) => (current === projectId ? null : projectId));
	}, []);

	const handleOpenProject = useCallback(async () => {
		setIsOpeningProject(true);
		try {
			if (!electrobunView) {
				addError("Native file dialog is unavailable", "rest", "native_rpc_unavailable");
				return;
			}

			const selectedPaths = await electrobunView.rpc.request.openProjectDirectory();
			const selectedPath = extractSelectedProjectPath(selectedPaths);
			if (!selectedPath) {
				return;
			}

			await handleCreateProject({
				name: getFolderFallbackName(selectedPath),
				path: selectedPath,
			});
		} catch (error) {
			addError(
				error instanceof Error ? error.message : "Unable to open native folder picker",
				"rest",
				"open_folder_error",
			);
		} finally {
			setIsOpeningProject(false);
		}
	}, [addError, handleCreateProject]);

	const handlePickComposerContextPaths = useCallback(async (): Promise<unknown> => {
		if (!electrobunView) {
			return [];
		}

		try {
			return await electrobunView.rpc.request.openContextPaths();
		} catch (error) {
			addError(
				error instanceof Error ? error.message : "Unable to open native context picker",
				"rest",
				"open_context_picker_error",
			);
			return [];
		}
	}, [addError]);

	const handleOpenProjectInFinder = useCallback(async () => {
		if (!selectedProject?.path) {
			addError("No project selected", "rest", "missing_project_path");
			return;
		}

		if (!electrobunView) {
			addError("Native finder action is unavailable", "rest", "native_rpc_unavailable");
			return;
		}

		try {
			await electrobunView.rpc.request.showProjectInFinder(selectedProject.path);
		} catch (error) {
			addError(
				error instanceof Error ? error.message : "Unable to open project in finder",
				"rest",
				"open_in_finder_error",
			);
		}
	}, [addError, electrobunView, selectedProject?.path]);

	const handleOpenExternalUrl = useCallback(async (url: string) => {
		if (!electrobunView) {
			globalThis.open(url, "_blank", "noopener,noreferrer");
			return;
		}

		try {
			await electrobunView.rpc.request.openExternalUrl(url);
		} catch (error) {
			addError(
				error instanceof Error ? error.message : "Unable to open external link",
				"rest",
				"open_external_url_error",
			);
		}
	}, [addError]);

	const handleToggleTerminal = useCallback(() => {
		if (!state.selectedChatId) {
			return;
		}

		const nextOpen = !Boolean(terminalOpenByChatRef.current[state.selectedChatId]);
		setTerminalOpen(state.selectedChatId, nextOpen);
		if (nextOpen) {
			void syncTerminalHistory(state.selectedChatId);
		}
	}, [setTerminalOpen, state.selectedChatId, syncTerminalHistory]);

	const handleTerminalRun = useCallback(
		async (command: string) => {
			if (!state.selectedChatId) {
				return;
			}

			await runTerminalCommand(state.selectedChatId, command);
		},
		[runTerminalCommand, state.selectedChatId],
	);

	const isThreadFocusMode = Boolean(activeThreadChat && state.selectedProjectId);
	const selectedThreadTerminal = state.selectedChatId
		? terminalState.chats[state.selectedChatId] ?? null
		: null;
	const isTerminalOpen = Boolean(selectedThreadTerminal?.isOpen);
	const sidebarToggleLabel = isSidebarVisible ? "Hide sidebar" : "Show sidebar";
	const threadPanelBgClass = isThreadFocusMode ? "bg-[#13161b]" : "bg-slate-950/35";
	return (
				<TooltipProvider delayDuration={120}>
			<div className="relative flex h-full w-full flex-col overflow-hidden">
				{appUpdate.hasUpdate && !appUpdate.dismissed ? (
					<UpdateBanner
						latestVersion={appUpdate.latestVersion}
						onDismiss={appUpdate.dismiss}
						onDownload={() => { void appUpdate.openRelease(); }}
					/>
				) : null}
				<div className="pointer-events-none absolute inset-0 bg-[radial-gradient(circle_at_48%_84%,rgba(55,150,255,0.22),transparent_44%)]" />
				<motion.div
						ref={layoutShellRef}
						style={{ "--desktop-sidebar-width": `${sidebarWidth}px` } as CSSProperties}
						animate={shouldReduceMotion ? undefined : { opacity: 1, y: 0 }}
						className={cn(
							"grid min-h-0 w-full flex-1 overflow-hidden rounded-b-[14px] border-x border-b border-white/5 bg-[#0d0f14]/88 backdrop-blur-xl",
							isSidebarVisible
								? "grid-cols-[var(--desktop-sidebar-width)_8px_minmax(0,1fr)] max-[920px]:grid-cols-1 max-[920px]:grid-rows-[minmax(280px,42vh)_minmax(0,1fr)]"
								: "grid-cols-[minmax(0,1fr)]",
							)}
							initial={shouldReduceMotion ? undefined : { opacity: 0.8, y: 4 }}
							transition={{ duration: 0.1, ease: "easeOut" }}
						>
						<span className="noise-mask" />
						{isSidebarResizing ? (
							<div
								className="pointer-events-none absolute inset-0 z-20 bg-slate-950/12 backdrop-blur-[1px]"
								data-testid="sidebar-resize-overlay"
							/>
						) : null}

									{isSidebarVisible ? (
							<>
									<aside
										className="codex-sidebar relative z-10 flex min-h-0 flex-col overflow-hidden rounded-bl-2xl px-2 py-2 max-[920px]:rounded-none"
										style={{
											background: "linear-gradient(180deg, #131722 0%, #1a1b29 34%, #2a1a31 68%, #2b1d25 100%)",
											borderRadius: "0 0 0 16px",
											boxShadow: "inset 0 1px 0 rgba(255, 255, 255, 0.06), 0 18px 38px rgba(0, 0, 0, 0.35)",
										}}
									>
									<div className="relative flex items-center justify-between px-1.5 pb-2 pt-1">
										<h2 className="text-[19px] font-medium tracking-[-0.01em] text-slate-300/95">Threads</h2>
										<div className="relative z-10 flex items-center gap-0.5">
											<Tooltip>
												<TooltipTrigger asChild>
														<Button
															aria-label="Create thread"
														className="h-7 w-7 text-slate-300 hover:bg-white/[0.06] hover:text-slate-100"
															disabled={!state.selectedProjectId}
															onClick={() => {
																void handleCreateChat(DEFAULT_DRAFT_THREAD_TITLE);
															}}
														size="icon"
														type="button"
														variant="ghost"
													>
														<MessageSquareText className="h-3.5 w-3.5" />
													</Button>
												</TooltipTrigger>
												<TooltipContent>Create thread</TooltipContent>
											</Tooltip>
											<Tooltip>
												<TooltipTrigger asChild>
													<Button
														aria-label="Open project folder"
														className="h-7 w-7 text-slate-300 hover:bg-white/[0.06] hover:text-slate-100"
														disabled={isOpeningProject}
														onClick={() => {
															void handleOpenProject();
														}}
														size="icon"
														type="button"
														variant="ghost"
													>
														<FolderOpen className="h-3.5 w-3.5" />
													</Button>
												</TooltipTrigger>
												<TooltipContent>Open project folder</TooltipContent>
											</Tooltip>
										</div>
									</div>

									<ScrollArea className="mt-1 min-h-0 flex-1 pr-0.5">
										<div className="space-y-1 pb-1">
											{state.projectsLoading ? (
												<div className="space-y-3 px-2 py-1.5">
													<div className="flex items-center gap-2">
														<div className="skeleton-pulse-sync h-3.5 w-3.5 shrink-0 rounded bg-slate-600/40" />
														<div className="skeleton-pulse-sync h-3 w-24 rounded bg-slate-600/40" />
													</div>
													<div className="ml-5 space-y-2">
														<div className="skeleton-pulse-sync h-2.5 w-32 rounded bg-slate-700/30" />
														<div className="skeleton-pulse-sync h-2.5 w-28 rounded bg-slate-700/30" />
														<div className="skeleton-pulse-sync h-2.5 w-36 rounded bg-slate-700/30" />
													</div>
													<div className="flex items-center gap-2">
														<div className="skeleton-pulse-sync h-3.5 w-3.5 shrink-0 rounded bg-slate-600/40" />
														<div className="skeleton-pulse-sync h-3 w-20 rounded bg-slate-600/40" />
													</div>
												</div>
											) : state.projects.length === 0 ? (
												<p className="rounded-md border border-dashed border-white/10 px-2.5 py-3 text-[11px] text-slate-400">
													No workspaces yet. Open a project folder to begin.
												</p>
											) : (
												state.projects.map((project) => {
													const isSelectedProject = project.id === state.selectedProjectId;
													const isThreadListOpen = isSelectedProject
														? projectThreadsOpen[project.id] !== false
														: Boolean(projectThreadsOpen[project.id]);
													const isThreadListExpanded = Boolean(expandedProjectThreads[project.id]);
													const projectChats = isSelectedProject
														? state.chats
														: (projectChatsCacheRef.current[project.id] ?? []);
													const hasMoreThreads =
														isThreadListOpen &&
														projectChats.length > SIDEBAR_MAX_VISIBLE_THREADS &&
														!isThreadListExpanded;
													const visibleChats =
														isThreadListOpen && isThreadListExpanded
														? projectChats
														: projectChats.slice(0, SIDEBAR_MAX_VISIBLE_THREADS);
													return (
													<motion.section
														className="px-1 py-0.5 transition-colors duration-150"
														key={project.id}
														layout={!shouldReduceMotion}
													>
																<div
																	aria-label={`Select ${project.name}`}
																	className="group grid min-w-0 cursor-pointer grid-cols-[minmax(0,1fr)_auto] items-center gap-1.5 rounded-md px-1.5 py-1 transition hover:text-slate-100"
																onClick={() => {
																	void handleSelectProject(project.id);
																}}
																onKeyDown={(event) => {
																	if (event.key === "Enter" || event.key === " ") {
																		event.preventDefault();
																		void handleSelectProject(project.id);
																	}
																}}
																role="button"
																tabIndex={0}
																>
																	<span className="inline-flex min-w-0 items-center gap-1.5">
																		{project.id === visibleOpeningProjectId ? (
																			<Loader2 className="h-3.5 w-3.5 shrink-0 animate-spin text-sky-300" />
																		) : (
																			<Folder className="h-3.5 w-3.5 shrink-0 text-slate-400/90" />
																		)}
																		<span className="min-w-0 flex flex-1 items-center gap-1.5">
																			<span
																				className="block truncate text-[13px] font-medium text-slate-100"
																				title={formatProjectMeta(project.path)}
																			>
																				{project.name}
																			</span>
																			{(project.unreadFinishedThreadCount ?? 0) > 0 ? (
																				<span className="inline-flex h-5 min-w-5 shrink-0 items-center justify-center rounded-full border border-emerald-300/30 bg-emerald-400/12 px-1.5 text-[10px] font-semibold text-emerald-100">
																					{project.unreadFinishedThreadCount ?? 0}
																				</span>
																			) : null}
																		</span>
																	</span>
																<div
																	className="relative ml-auto flex min-h-[1.25rem] min-w-[3rem] items-center justify-end gap-0.5"
																	ref={(node) => {
																		if (openWorkspaceMenuProjectId === project.id) {
																			workspaceMenuRef.current = node;
																		}
																	}}
																>
																	<Tooltip>
																		<TooltipTrigger asChild>
																			<Button
																				aria-label={`New thread in ${project.name}`}
																				className={cn(
																					"pointer-events-none z-10 flex h-6 w-6 items-center justify-center rounded-md border border-transparent text-slate-300 opacity-0 transition-opacity hover:border-white/15 hover:text-slate-100 group-hover:opacity-100 group-hover:pointer-events-auto focus-visible:opacity-100 focus-visible:pointer-events-auto",
																				)}
																				onClick={(event) => {
																					event.stopPropagation();
																					void handleCreateChatForProject(project.id);
																				}}
																				size="icon"
																				type="button"
																				variant="ghost"
																			>
																				<Plus className="h-3.5 w-3.5" />
																			</Button>
																		</TooltipTrigger>
																		<TooltipContent>New thread</TooltipContent>
																	</Tooltip>
																	<Tooltip>
																		<TooltipTrigger asChild>
																			<Button
																				aria-label={`Workspace options for ${project.name}`}
																				className={cn(
																					"pointer-events-none z-10 flex h-6 w-6 items-center justify-center rounded-md border border-transparent text-slate-300 opacity-0 transition-opacity hover:border-white/15 hover:text-slate-100 group-hover:opacity-100 group-hover:pointer-events-auto focus-visible:opacity-100 focus-visible:pointer-events-auto",
																					openWorkspaceMenuProjectId === project.id
																						? "opacity-100 pointer-events-auto"
																						: "",
																				)}
																				onClick={(event) => {
																					event.stopPropagation();
																					handleToggleWorkspaceMenu(project.id);
																				}}
																				size="icon"
																				type="button"
																				variant="ghost"
																			>
																				<MoreHorizontal className="h-4 w-4" />
																			</Button>
																		</TooltipTrigger>
																		<TooltipContent>Workspace options</TooltipContent>
																	</Tooltip>
																	{openWorkspaceMenuProjectId === project.id ? (
																		<div className="absolute right-0 top-[calc(100%+4px)] z-30 min-w-[9.25rem] overflow-hidden rounded-md border border-white/15 bg-[#1a1f2a] py-1 shadow-[0_14px_30px_rgba(0,0,0,0.5)]">
													<button
														className="flex w-full items-center px-3 py-1.5 text-left text-[12px] text-rose-100 transition hover:bg-rose-500/12 hover:text-rose-50"
														onClick={(event) => {
															event.stopPropagation();
															void handleClearProjectThreads(project.id);
														}}
														type="button"
													>
														Clear all threads
													</button>
													<button
														className="flex w-full items-center px-3 py-1.5 text-left text-[12px] text-slate-200 transition hover:bg-white/[0.06] hover:text-slate-100"
														onClick={(event) => {
															event.stopPropagation();
															void handleRenameProject(project);
														}}
														type="button"
													>
														Rename workspace
													</button>
																			<button
																				className="flex w-full items-center px-3 py-1.5 text-left text-[12px] text-rose-200 transition hover:bg-rose-500/12 hover:text-rose-100"
																				onClick={(event) => {
																					event.stopPropagation();
																					void handleDeleteProject(project.id);
																				}}
																				type="button"
																			>
																				Delete workspace
																			</button>
																		</div>
																	) : null}
																</div>
															</div>

															{isThreadListOpen ? (
																<ul className="ml-3 mt-1.5 space-y-0.5 border-l border-white/8 pl-2.5">
																	{isSelectedProject && state.chatsLoading ? (
																		<li className="px-1.5 py-1 text-[11px] text-slate-400">Loading threads...</li>
																	) : projectChats.length === 0 ? (
																		<li className="px-1.5 py-1 text-[11px] text-slate-400">No threads yet.</li>
																	) : (
																		<>
													{visibleChats.map((chat) => {
														const isThreadActive = isChatActive(chat.id);
														const threadStatusTooltip = getThreadStatusTooltip({
															hasUnreadFinished: chat.hasUnreadFinished,
															isActive: isThreadActive,
														});

														return (
																					<motion.li key={chat.id} className="w-full" layout={!shouldReduceMotion}>
																					<div
                                                                                        aria-label={`Open ${chat.title}`}
                                                                                        className={cn(
                                                                                            "group relative grid w-full min-h-[2.25rem] grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-2 rounded-md px-1.5 py-1.5 text-left text-[13px] transition duration-150",
																							state.selectedChatId === chat.id
																								? "bg-white/[0.07] text-slate-100"
																								: "text-slate-300 hover:bg-white/[0.03] hover:text-slate-100",
																						)}
                                                                                            onClick={() => {
                                                                                                 void handleSelectChat(chat.id);
                                                                                            }}
                                                                                            onKeyDown={(event) => {
                                                                                                 if (event.key === "Enter" || event.key === " ") {
                                                                                                      event.preventDefault();
                                                                                                      void handleSelectChat(chat.id);
                                                                                                 }
                                                                                            }}
                                                                                            role="button"
                                                                                            tabIndex={0}
                                                                                        >
																							<span className="flex h-5 w-5 items-center justify-center">
																								{threadStatusTooltip ? (
																									<Tooltip>
																										<TooltipTrigger asChild>
																											<span
																												aria-label={threadStatusTooltip}
																												className={cn(
																													"inline-flex h-5 w-5 items-center justify-center rounded-full border transition-colors",
																													isThreadActive
																														? "border-sky-300/30 bg-sky-400/12 text-sky-100"
																														: "border-emerald-300/30 bg-emerald-400/12 text-emerald-100",
																												)}
																											>
																												{isThreadActive ? (
																													<Loader2 className="h-2.5 w-2.5 animate-spin" />
																												) : (
																													<span className="h-2 w-2 rounded-full bg-current" />
																												)}
																											</span>
																										</TooltipTrigger>
																										<TooltipContent>{threadStatusTooltip}</TooltipContent>
																									</Tooltip>
																								) : (
																									<span aria-hidden="true" className="h-5 w-5" />
																								)}
																							</span>
																							<span className="min-w-0 truncate leading-5">{chat.title}</span>
																				<div className="relative ml-auto flex min-h-[1.25rem] min-w-[3rem] justify-end">
																							{chat.id === openingThreadId ? (
																								<Loader2 className="h-3.5 w-3.5 shrink-0 animate-spin text-slate-300" />
																							) : null}
																							<span className="pr-1.5 text-[11px] text-slate-500 transition-opacity duration-150 group-hover:opacity-0">
																							{formatRelativeTime(chat.updatedAt)}
																							</span>
																							<Tooltip>
                                                                                                <TooltipTrigger asChild>
                                                                                                    <Button
                                                                                                        aria-label={`Delete ${chat.title}`}
                                                                                                        className="absolute right-0 top-1/2 z-10 flex h-6 w-6 -translate-y-1/2 items-center justify-center rounded-md border border-transparent text-rose-300/80 opacity-0 transition-opacity hover:border-rose-100/20 hover:text-rose-100 group-hover:opacity-100 group-hover:pointer-events-auto focus-visible:opacity-100 focus-visible:pointer-events-auto pointer-events-none"
                                                                                                        onClick={(event) => {
                                                                                                            event.stopPropagation();
                                                                                                            void handleDeleteChat(chat.id);
                                                                                                        }}
                                                                                                        size="icon"
                                                                                                        type="button"
                                                                                                        variant="ghost"
                                                                                                    >
                                                                                                        <Trash2 className="h-4 w-4" />
                                                                                                    </Button>
                                                                                                </TooltipTrigger>
                                                                                                <TooltipContent>Delete thread</TooltipContent>
                                                                                            </Tooltip>
                                                                                        </div>
                                                                                        </div>
																				</motion.li>
																			);
																		})}
																			{hasMoreThreads ? (
																				<li className="px-1">
																					<Button
																						aria-label="Show more threads"
																						className="h-7 px-1.5 text-[11px] text-slate-300 hover:text-slate-100"
																						onClick={() => {
																							handleShowMoreThreads(project.id);
																						}}
																						size="sm"
																						type="button"
																						variant="ghost"
																					>
																						Show More
																						</Button>
																				</li>
																			) : null}
																		</>
																	)}
																</ul>
															) : null}
														</motion.section>
													);
												})
											)}
										</div>
									</ScrollArea>
								{activeChats.length > 0 ? (
									<div className="relative px-2 pb-1.5 pt-1" ref={activeThreadsMenuRef}>
										<button
											className="flex w-full items-center gap-2 rounded-lg border border-white/8 bg-white/[0.04] px-2.5 py-2 text-left transition hover:bg-white/[0.07]"
											onClick={() => {
												setIsActiveThreadsOpen((current) => !current);
											}}
											type="button"
										>
											<span className="flex h-5 w-5 shrink-0 items-center justify-center rounded-md bg-sky-500/15">
												<Zap className="h-3 w-3 text-sky-300" />
											</span>
											<span className="min-w-0 flex-1 truncate text-[12px] font-medium text-slate-200">
												{activeChats.length === 1
													? "1 active thread"
													: `${activeChats.length} active threads`}
											</span>
											<Loader2 className="h-3 w-3 shrink-0 animate-spin text-sky-300/70" />
										</button>
										{isActiveThreadsOpen ? (
											<div className="absolute bottom-[calc(100%+4px)] left-2 right-2 z-30 overflow-hidden rounded-lg border border-white/15 bg-[#1a1f2a] py-1 shadow-[0_14px_30px_rgba(0,0,0,0.5)]">
												<div className="px-3 py-1.5 text-[10px] font-medium uppercase tracking-[0.08em] text-slate-400">
													Active Threads
												</div>
												{activeChats.map((chat) => (
													<button
														className={cn(
															"flex w-full items-center gap-2 px-3 py-2 text-left text-[12px] transition hover:bg-white/[0.06]",
															state.selectedChatId === chat.id
																? "bg-white/[0.05] text-slate-100"
																: "text-slate-200",
														)}
														key={chat.id}
														onClick={() => {
															void handleSelectChat(chat.id);
															setIsActiveThreadsOpen(false);
														}}
														type="button"
													>
														<Loader2 className="h-3 w-3 shrink-0 animate-spin text-sky-300" />
														<span className="min-w-0 flex-1 truncate">{chat.title}</span>
													</button>
												))}
											</div>
										) : null}
									</div>
								) : null}
								<PrivateAccountSidebarFooter openExternalUrl={handleOpenExternalUrl} />
								</aside>

								<button
									aria-label="Resize sidebar"
									className={cn(
										"z-20 h-full cursor-ew-resize touch-none p-0 transition-colors duration-150 max-[920px]:hidden",
										isSidebarResizing ? "bg-white/[0.08]" : "hover:bg-white/[0.04]",
										sidebarResizeBound === "min" ? "bg-amber-300/10" : "",
										sidebarResizeBound === "max" ? "bg-sky-300/10" : "",
										threadPanelBgClass,
									)}
									onPointerCancel={stopSidebarResize}
									onPointerDown={startSidebarResize}
									onPointerMove={handleSidebarResizePointerMove}
									onPointerUp={handleSidebarResizePointerUp}
									type="button"
								/>
							</>
						) : null}

									<main
										className={cn(
											"relative z-10 flex min-h-0 flex-col",
											threadPanelBgClass,
											isThreadFocusMode && isSidebarVisible ? "shadow-[-20px_0_38px_rgba(4,7,14,0.42)]" : "",
										)}
									>
									{state.selectedProjectId ? (
										<section className="flex h-full min-h-0 flex-1 flex-col overflow-y-auto overflow-x-hidden">
											<header className="relative flex h-10 items-center justify-between gap-2 px-4">
												<div className="relative z-10 flex min-w-0 items-center gap-2">
													<Tooltip>
														<TooltipTrigger asChild>
															<Button
																aria-label={sidebarToggleLabel}
																className="h-7 w-7 shrink-0 text-slate-300 hover:bg-white/[0.06] hover:text-slate-100"
																onClick={() => {
																	setIsSidebarVisible((current) => !current);
																}}
																size="icon"
																type="button"
																variant="ghost"
															>
																<PanelLeft className="h-4 w-4" />
															</Button>
														</TooltipTrigger>
														<TooltipContent>{sidebarToggleLabel}</TooltipContent>
													</Tooltip>
													<div className="min-w-0">
														<h2 className="truncate text-sm font-semibold text-slate-100">
															{activeThreadChat?.title ?? DEFAULT_DRAFT_THREAD_TITLE}
														</h2>
													</div>
												</div>
												<div className="relative z-10 flex items-center gap-1.5">
													<Tooltip>
														<TooltipTrigger asChild>
															<Button
																aria-label={isTerminalOpen ? "Hide terminal" : "Show terminal"}
																className={cn(
																	"rounded-lg h-8 w-8 gap-1.5 bg-transparent transition-colors hover:bg-sky-400/10 hover:text-sky-100 active:bg-sky-400/10 active:text-sky-100 focus-visible:bg-sky-400/10 focus-visible:text-sky-100",
																	isTerminalOpen
																		? "bg-sky-400/10 text-sky-100"
																		: "text-slate-200",
																)}
																onClick={handleToggleTerminal}
																size="icon"
																type="button"
																variant="ghost"
															>
																<SquareTerminal className="h-4 w-4" />
																<span className="sr-only">
																	{isTerminalOpen ? "Hide terminal" : "Show terminal"}
																</span>
															</Button>
														</TooltipTrigger>
														<TooltipContent>
															{isTerminalOpen ? "Hide terminal" : "Show terminal"}
														</TooltipContent>
													</Tooltip>
													<Tooltip>
														<TooltipTrigger asChild>
															<Button
																aria-label="Open project in Finder"
																className="rounded-lg h-8 w-8 gap-1.5 bg-transparent text-slate-200 transition-colors hover:bg-sky-400/10 hover:text-sky-100 active:bg-sky-400/10 active:text-sky-100 focus-visible:bg-sky-400/10 focus-visible:text-sky-100 disabled:text-slate-500 disabled:hover:bg-transparent"
																disabled={!selectedProject?.path || !electrobunView}
																onClick={() => {
																	void handleOpenProjectInFinder();
																}}
																size="icon"
																type="button"
																variant="ghost"
															>
																<FolderSearch className="h-4 w-4" />
															</Button>
														</TooltipTrigger>
														<TooltipContent>Open in Finder</TooltipContent>
													</Tooltip>
													<div className="flex items-center rounded-lg border border-white/[0.06] bg-white/[0.03]">
														{(["plan", "default", "full"] as const).map((mode) => {
															const isActive = permissionMode === mode;
															const dotColor =
																mode === "full"
																	? "#F97316"
																	: mode === "plan"
																		? "#1D4ED8"
																		: "#94A3B8";
															const label =
																mode === "full"
																	? "Bypass Permissions"
																	: mode === "plan"
																		? "Plan Mode"
																		: "Default";
															const tooltip =
																mode === "full"
																	? "Bypasses all approvals and sandbox. Use with caution."
																	: mode === "plan"
																		? "Read-only. The agent can only read files and plan changes."
																		: "The agent can write to the workspace but asks for approval.";
															return (
																<Tooltip key={mode}>
																	<TooltipTrigger asChild>
																		<button
																			aria-label={`Permission: ${label}`}
																			className={cn(
																				"flex items-center gap-1.5 px-2 py-1 text-[11px] font-medium leading-4 transition-colors first:rounded-l-[7px] last:rounded-r-[7px]",
																				isActive
																					? "bg-white/[0.08] text-slate-100"
																					: "text-slate-400 hover:text-slate-200",
																			)}
																			onClick={() => {
																				handlePermissionModeChange(mode);
																			}}
																			type="button"
																		>
																			<span
																				className="block h-2 w-2 shrink-0 rounded-full"
																				style={{ backgroundColor: dotColor }}
																			/>
																			{label}
																		</button>
																	</TooltipTrigger>
																	<TooltipContent>{tooltip}</TooltipContent>
																</Tooltip>
															);
														})}
													</div>
													<GitQuickControl
														className="relative"
														client={api}
														disabled={
															!selectedProject?.id || projectGitState.status?.isRepo === false || projectGitState.loading
														}
														project={selectedProject}
														onCommitted={() => {
															void refreshProjectGit();
														}}
													/>
												</div>
											</header>

											<div className="relative min-h-0 flex-1 overflow-hidden">
													<ConversationPanel
														chat={activeThreadChat}
														focusMode
														hasOlderMessages={hasOlderMessages}
														hasRestError={state.errors.some((error) => error.source === "rest")}
														isWorking={isSelectedThreadWorking}
														isLatestDirty={latestMessageWindowDirty}
														loading={isConversationLoading}
														messageWindowMode={messageWindowMode}
														messages={visibleMessages}
														onLoadLatestMessages={handleLoadLatestMessages}
														onLoadOlderMessages={handleLoadOlderMessages}
														onSetStreamItemExpanded={handleSetStreamItemExpanded}
														onSetStreamItemState={handleSetStreamItemState}
														streamHistoryTurns={streamHistoryTurns}
														streamingTurn={streamingTurn}
														streamingText={streamingText}
													/>
											</div>

											<div className="shrink-0 px-3 pb-4 pt-3 sm:px-6">
												<div className="mx-auto w-full max-w-3xl">
													<MessageComposer
														availableModels={availableModels}
														availableReasoningEfforts={availableReasoningEfforts}
														gitBranches={
															projectGitState.status?.isRepo === true
																? projectGitState.branches
																: []
														}
														gitCurrentBranch={
															projectGitState.status?.isRepo === true
																? projectGitState.status.currentBranch
																: null
														}
														gitChangedFiles={projectGitState.status?.changedFiles ?? 0}
														gitAdded={projectGitState.status?.added ?? 0}
														gitRemoved={projectGitState.status?.removed ?? 0}
														chatStatus={isSelectedThreadWorking ? "running" : activeThreadChat?.status ?? null}
														disabled={!state.selectedProjectId}
														focusMode
														isGitLoading={projectGitState.loading}
														isGitRepository={
															selectedProject ? projectGitState.status?.isRepo ?? null : false
														}
														modelsLoading={!hasLoadedCodexModels}
														onCheckoutBranch={checkoutBranch}
														onCreateBranch={createBranch}
														onModelChange={handleModelChange}
														onPickContextPaths={
															electrobunView ? handlePickComposerContextPaths : undefined
														}
														onPermissionModeChange={handlePermissionModeChange}
														onReasoningEffortChange={handleReasoningEffortChange}
														onForceStop={handleForceStop}
														onSend={handleSendMessage}
														permissionMode={permissionMode}
														providerLocked={isProviderSelectionLocked}
														selectedModel={selectedModel}
														selectedProvider={selectedProvider}
														onProviderChange={handleProviderChange}
														selectedReasoningEffort={selectedReasoningEffort}
														sending={selectedChatSending}
														stopping={selectedChatStopping}
													/>
												</div>
											</div>

											<AnimatePresence initial={false}>
												{isTerminalOpen && state.selectedChatId ? (
													<motion.div
														animate={{ height: "auto" }}
														className="shrink-0 overflow-hidden border-t border-white/10"
														exit={{ height: 0 }}
														initial={{ height: 0 }}
														key="terminal-panel"
														transition={
															shouldReduceMotion
																? { duration: 0 }
																: { duration: 0.3, ease: [0.4, 0, 0.2, 1] }
														}
													>
														<div className="h-[42vh] min-h-[220px]">
															<ThreadTerminalPanel
																chatId={state.selectedChatId}
																className="h-full rounded-none border-0"
																error={selectedThreadTerminal?.error ?? null}
																isExecuting={Boolean(selectedThreadTerminal?.isExecuting)}
																isLoading={Boolean(selectedThreadTerminal?.isLoading)}
																items={selectedThreadTerminal?.items ?? []}
																key={state.selectedChatId}
																onRun={(command) => {
																	void handleTerminalRun(command);
																}}
															/>
														</div>
													</motion.div>
												) : null}
											</AnimatePresence>
										</section>
									) : (
							<motion.div
								animate={shouldReduceMotion ? undefined : { opacity: 1, y: 0 }}
								className="grid flex-1 place-items-center px-6 py-12"
								initial={shouldReduceMotion ? undefined : { opacity: 0, y: 10 }}
								transition={{ duration: 0.28 }}
							>
								<section className="grid gap-6 text-center">
									<div>
										<h2 className="text-[clamp(2.1rem,8vw,3.2rem)] font-semibold tracking-tight text-slate-100">
											Let&apos;s build
										</h2>
										<p className="mt-1 text-[clamp(1rem,3vw,2rem)] text-slate-300">remotecode.io</p>
									</div>
									<Button
										className="mx-auto gap-2 rounded-xl border border-white/15 bg-white/[0.05] px-6 py-2.5 text-slate-200 hover:bg-white/[0.09]"
										disabled={isOpeningProject}
										onClick={() => {
											void handleOpenProject();
										}}
										type="button"
									>
										<FolderOpen className="h-4 w-4 text-sky-300" />
										{isOpeningProject ? "Opening workspace..." : "Open workspace"}
									</Button>
								</section>
							</motion.div>
						)}
					</main>
				</motion.div>
			</div>
		</TooltipProvider>
	);
};

const App = (): JSX.Element => {
	const [queryClient] = useState(createDesktopQueryClient);

	return (
		<QueryClientProvider client={queryClient}>
			<AppContent />
		</QueryClientProvider>
	);
};

export default App;
