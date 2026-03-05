import { type CSSProperties, type PointerEvent as ReactPointerEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { motion, useReducedMotion } from "framer-motion";
import {
	Folder,
	FolderSearch,
	FolderOpen,
	Loader2,
	MessageSquareText,
	PanelLeft,
	SquareTerminal,
	Trash2,
} from "lucide-react";

import { Electroview } from "electrobun/view";
import { Button } from "../components/ui/button";
import { ScrollArea } from "../components/ui/scroll-area";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "../components/ui/tooltip";
import { MessageComposer } from "../features/composer/ui/MessageComposer";
import { ConversationPanel } from "../features/conversation/ui/ConversationPanel";
import { GitQuickControl } from "../features/git/ui/GitQuickControl";
import { useProjectGit } from "../features/git/model/useProjectGit";
import { useThreadTerminalSession } from "../features/terminal/model/useThreadTerminalSession";
import { ThreadTerminalPanel } from "../features/terminal/ui/ThreadTerminalPanel";
import {
	type ChatDTO,
	type MessageDTO,
	type ProjectDTO,
	type StreamTurnState,
	useWorkspaceStore,
} from "../features/workspace/model/useWorkspaceStore";
import { sendWorkspaceMessage } from "../features/workspace/model/send-message";
import { cn } from "../lib/utils";
import type { AssistantStreamEvent, AssistantStreamItemState, AssistantStreamItemType } from "../../shared/assistant-stream-event";
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
import { RemoteCodeApi, RemoteCodeApiError } from "../shared/api/remotecode-http";
import {
	RemoteCodeRealtime,
	type ConnectionState,
	type ServerWsEvent,
} from "../shared/realtime/remotecode-ws";

const FALLBACK_TIMESTAMP = "1970-01-01T00:00:00.000Z";

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
	projectId,
	title: "New thread",
	provider: "fake",
	status: "pending",
	diffAdded: 0,
	diffRemoved: 0,
	updatedAt: new Date().toISOString(),
});

const toProjectDtoFromWorkspaceSummary = (workspace: {
	id: string;
	name: string;
	path: string;
}): ProjectDTO => ({
	id: workspace.id,
	name: workspace.name,
	path: workspace.path,
	isFavorite: false,
	createdAt: FALLBACK_TIMESTAMP,
	updatedAt: FALLBACK_TIMESTAMP,
});

const toChatDtoFromThreadSummary = (
	thread: { id: string; isActive: boolean; title: string; updatedAt: string },
	projectId: string,
): ChatDTO => ({
	id: thread.id,
	isActive: thread.isActive,
	projectId,
	title: thread.title,
	provider: "codex",
	status: thread.isActive ? "running" : "pending",
	diffAdded: 0,
	diffRemoved: 0,
	updatedAt: thread.updatedAt,
});
const SIDEBAR_MAX_VISIBLE_THREADS = 3;

const createStreamTurnState = (turnId: string): StreamTurnState => ({
	turnId,
	status: "running",
	itemsById: {},
	itemOrder: [],
	startedAtMs: Date.now(),
	finishedAtMs: null,
});

const createStreamItem = (itemId: string, itemType: AssistantStreamItemType) => ({
	id: itemId,
	type: itemType,
	state: "running" as AssistantStreamItemState,
	summary: "",
	body: "",
	output: "",
	startedAtMs: Date.now(),
	finishedAtMs: null as number | null,
	expandedByUser: false,
	isExpanded: true,
});

const replayAssistantEventsIntoTurns = (events: AssistantStreamEvent[]): StreamTurnState[] => {
	const turnIdsInOrder: string[] = [];
	const turnsById = new Map<string, StreamTurnState>();

	for (const event of events) {
		const currentTurn = turnsById.get(event.turnId) ?? createStreamTurnState(event.turnId);
		if (!turnsById.has(event.turnId)) {
			turnIdsInOrder.push(event.turnId);
		}

		const nextTurn: StreamTurnState = {
			...currentTurn,
			itemsById: { ...currentTurn.itemsById },
			itemOrder: [...currentTurn.itemOrder],
		};
		const existingItem = "itemId" in event ? nextTurn.itemsById[event.itemId] : undefined;
		const inferredItemType: AssistantStreamItemType =
			"itemType" in event
				? event.itemType
				: event.type === "item_delta" && event.target === "output"
					? "tool"
					: existingItem?.type ?? "reasoning";
		const getItem = (itemId: string) => {
			const candidate = nextTurn.itemsById[itemId] ?? createStreamItem(itemId, inferredItemType);
			if (!nextTurn.itemOrder.includes(itemId)) {
				nextTurn.itemOrder.push(itemId);
			}
			return candidate;
		};

		switch (event.type) {
			case "turn_started":
				break;
			case "turn_completed":
				nextTurn.status = nextTurn.status === "failed" ? "failed" : "completed";
				nextTurn.finishedAtMs = nextTurn.finishedAtMs ?? Date.now();
				break;
			case "item_started": {
				const item = getItem(event.itemId);
				item.type = event.itemType;
				item.state = event.state ?? "running";
				if (event.summary !== undefined) {
					item.summary = event.summary;
				}
				nextTurn.itemsById[event.itemId] = item;
				break;
			}
			case "item_delta": {
				const item = getItem(event.itemId);
				if (event.target === "summary") {
					item.summary = `${item.summary}${event.delta}`;
				}
				if (event.target === "body") {
					item.body = `${item.body}${event.delta}`;
				}
				if (event.target === "output") {
					item.output = `${item.output}${event.delta}`;
				}
				nextTurn.itemsById[event.itemId] = item;
				break;
			}
			case "item_state": {
				const item = getItem(event.itemId);
				item.state = event.state;
				if (event.summary !== undefined) {
					item.summary = event.summary;
				}
				if (event.state === "failed" || event.state === "cancelled") {
					nextTurn.status = "failed";
				}
				nextTurn.itemsById[event.itemId] = item;
				break;
			}
			case "item_completed": {
				const item = getItem(event.itemId);
				item.state = event.state ?? (item.state === "failed" || item.state === "cancelled" ? item.state : "completed");
				item.finishedAtMs = item.finishedAtMs ?? Date.now();
				if (event.summary !== undefined) {
					item.summary = event.summary;
				}
				if (item.state === "failed" || item.state === "cancelled") {
					nextTurn.status = "failed";
				}
				nextTurn.itemsById[event.itemId] = item;
				break;
			}
		}

		turnsById.set(event.turnId, nextTurn);
	}

	return turnIdsInOrder.map((turnId) => turnsById.get(turnId)).filter((turn): turn is StreamTurnState => Boolean(turn));
};

const clampSidebarWidth = (width: number): number => {
	const bounded = Number.isFinite(width) ? width : DEFAULT_SIDEBAR_WIDTH;
	return Math.min(SIDEBAR_WIDTH_MAX, Math.max(SIDEBAR_WIDTH_MIN, Math.round(bounded)));
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

const App = (): JSX.Element => {
	const { dispatch, state } = useWorkspaceStore();
	const shouldReduceMotion = useReducedMotion();
	const wsRef = useRef<ReturnType<(typeof RemoteCodeRealtime)["createClient"]> | null>(null);
	const selectedChatIdRef = useRef<string | null>(null);
	const selectedProjectIdRef = useRef<string | null>(null);
	const persistedSelectedChatIdRef = useRef<string | null>(null);
	const isCreatingChatRef = useRef<boolean>(false);
	const sidebarWidthRef = useRef<number>(DEFAULT_SIDEBAR_WIDTH);
	const isSidebarResizingRef = useRef<boolean>(false);
	const sidebarResizeStartXRef = useRef<number>(0);
	const sidebarResizeStartWidthRef = useRef<number>(DEFAULT_SIDEBAR_WIDTH);
	const terminalOpenByChatRef = useRef<Record<string, boolean>>({});
	const workspaceClientIdRef = useRef<string>(resolveWebSocketClientId());
	const lastWorkspaceSeqRef = useRef<number>(0);
	const pendingSendChatIdsRef = useRef<Set<string>>(new Set());
	const projectsLoadInFlightRef = useRef<Promise<void> | null>(null);
	const projectsLoadQueuedRef = useRef<boolean>(false);
	const chatsLoadInFlightRef = useRef<Map<string, Promise<void>>>(new Map());
	const chatsLoadQueuedRef = useRef<Map<string, string | null>>(new Map());
	const messagesLoadInFlightRef = useRef<Map<string, Promise<void>>>(new Map());
	const messagesLoadQueuedRef = useRef<Set<string>>(new Set());
	const chatContextLoadInFlightRef = useRef<Map<string, Promise<void>>>(new Map());
	const [stoppingByChat, setStoppingByChat] = useState<Record<string, boolean>>({});

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

	const selectedChat = useMemo(
		() => state.chats.find((chat) => chat.id === state.selectedChatId) ?? null,
		[state.chats, state.selectedChatId],
	);
	const draftThreadChat = useMemo(
		() => (state.selectedProjectId ? createDraftThreadChat(state.selectedProjectId) : null),
		[state.selectedProjectId],
	);
	const activeThreadChat = selectedChat ?? draftThreadChat;

	const selectedChatId = state.selectedChatId;
	const streamingText = selectedChatId
		? state.streamingByChat[selectedChatId] ?? ""
		: "";
	const streamingTurn: StreamTurnState | null = selectedChatId
		? state.streamTurnsByChat[selectedChatId] ?? null
		: null;
	const streamHistoryTurns: StreamTurnState[] = selectedChatId
		? state.streamHistoryByChat[selectedChatId] ?? []
		: [];
	const selectedChatSending = selectedChatId
		? Boolean(state.sendingByChat[selectedChatId])
		: false;
	const selectedChatStopping = selectedChatId ? Boolean(stoppingByChat[selectedChatId]) : false;
	const isChatActive = useCallback(
		(chatId: string): boolean => {
			const chat = state.chats.find((item) => item.id === chatId);
			return Boolean(
				chat?.isActive ||
				state.sendingByChat[chatId] ||
				state.streamingActiveByChat[chatId],
			);
		},
		[state.chats, state.sendingByChat, state.streamingActiveByChat],
	);
	const isSelectedThreadWorking = activeThreadChat ? isChatActive(activeThreadChat.id) : false;

	const [isOpeningProject, setIsOpeningProject] = useState(false);
	const [expandedProjectThreads, setExpandedProjectThreads] = useState<Record<string, boolean>>({});
	const [projectThreadsOpen, setProjectThreadsOpen] = useState<Record<string, boolean>>({});
	const [openingProjectId, setOpeningProjectId] = useState<string | null>(null);
	const [openingThreadId, setOpeningThreadId] = useState<string | null>(null);
	const [sidebarWidth, setSidebarWidth] = useState<number>(() => {
		if (typeof window === "undefined") {
			return DEFAULT_SIDEBAR_WIDTH;
		}

		return parseSidebarWidth(window.localStorage.getItem(SIDEBAR_WIDTH_STORAGE_KEY));
	});
	const [isSidebarVisible, setIsSidebarVisible] = useState<boolean>(true);
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
	const permissionModeRef = useRef<CodexPermissionMode>(permissionMode);
	const selectedModelRef = useRef<string | null>(selectedModel);
	const selectedReasoningEffortRef = useRef<CodexReasoningEffort | null>(selectedReasoningEffort);

	const selectedModelDescriptor = useMemo(
		() => getModelDescriptorByName(availableModels, selectedModel),
		[availableModels, selectedModel],
	);
	const availableReasoningEfforts = useMemo(
		() => selectedModelDescriptor?.supportedReasoningEfforts.map((item) => item.reasoningEffort) ?? [],
		[selectedModelDescriptor],
	);

	useEffect(() => {
		sidebarWidthRef.current = sidebarWidth;
	}, [sidebarWidth]);

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
		setSidebarWidth(nextWidth);
	}, []);

	const startSidebarResize = useCallback((event: ReactPointerEvent<HTMLButtonElement>) => {
		event.preventDefault();
		if (event.button !== 0 || !event.isPrimary || typeof window === "undefined") {
			return;
		}

		isSidebarResizingRef.current = true;
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
			stopSidebarResize();
		},
		[stopSidebarResize],
	);

	useEffect(() => () => {
		document.body.classList.remove("select-none");
		document.body.classList.remove("cursor-ew-resize");
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

	const loadMessagesForChatCore = useCallback(
		async (chatId: string | null) => {
			if (!chatId) {
				dispatch({ payload: [], type: "SET_MESSAGES" });
				dispatch({ payload: false, type: "SET_MESSAGES_LOADING" });
				return;
			}

			dispatch({ payload: true, type: "SET_MESSAGES_LOADING" });
			try {
				const messages = await api.listMessages(chatId);
				let afterId = 0;
				const streamEvents: AssistantStreamEvent[] = [];
				let lastEventId = 0;
				while (true) {
					const page = await api.listChatStreamEvents(chatId, {
						afterId,
						limit: 500,
					});
					for (const entry of page.events) {
						streamEvents.push(entry.event);
						lastEventId = Math.max(lastEventId, entry.id);
					}

					if (!page.hasMore || page.nextAfterId === null) {
						break;
					}

					afterId = page.nextAfterId;
				}

					if (selectedChatIdRef.current === chatId) {
						dispatch({ payload: messages, type: "SET_MESSAGES" });
					}
					dispatch({
						payload: {
							chatId,
							turns: replayAssistantEventsIntoTurns(streamEvents),
							lastEventId,
						},
						type: "SET_STREAM_HISTORY",
					});
					clearRestErrors();
				} catch (error) {
					if (formatApiErrorCode(error) === "HTTP_404") {
						if (selectedChatIdRef.current === chatId) {
							dispatch({ payload: [], type: "SET_MESSAGES" });
						}
					dispatch({
						payload: {
							chatId,
							lastEventId: 0,
							turns: [],
						},
						type: "SET_STREAM_HISTORY",
					});
					clearRestErrors();
					return;
				}
				addError(
					formatApiErrorMessage(error, "Unable to fetch messages from chat"),
					"rest",
					formatApiErrorCode(error),
				);
			} finally {
				if (selectedChatIdRef.current === chatId) {
					dispatch({ payload: false, type: "SET_MESSAGES_LOADING" });
				}
			}
		},
			[addError, api, clearRestErrors, dispatch, formatApiErrorCode, formatApiErrorMessage],
	);

	const loadMessagesForChat = useCallback(
		async (chatId: string | null) => {
			if (!chatId) {
				await loadMessagesForChatCore(chatId);
				return;
			}

			const inFlight = messagesLoadInFlightRef.current.get(chatId);
			if (inFlight) {
				messagesLoadQueuedRef.current.add(chatId);
				await inFlight;
				return;
			}

			const task = (async () => {
				do {
					messagesLoadQueuedRef.current.delete(chatId);
					await loadMessagesForChatCore(chatId);
				} while (messagesLoadQueuedRef.current.has(chatId));
			})().finally(() => {
				messagesLoadInFlightRef.current.delete(chatId);
				messagesLoadQueuedRef.current.delete(chatId);
			});

			messagesLoadInFlightRef.current.set(chatId, task);
			await task;
		},
		[loadMessagesForChatCore],
	);

	const syncFinalMessagesAfterDone = useCallback(
		async (chatId: string) => {
			const maxAttempts = 5;
			const retryDelayMs = 250;
			const trySyncMessages = async (attempt: number): Promise<void> => {
				if (selectedChatIdRef.current !== chatId) {
					return;
				}

				try {
					const latestMessages = await api.listMessages(chatId);
					if (selectedChatIdRef.current !== chatId) {
						return;
					}

					dispatch({ payload: latestMessages, type: "SET_MESSAGES" });
					clearRestErrors();
					if (latestMessages.at(-1)?.role === "assistant") {
						return;
					}
				} catch {
					// Keep retrying until maxAttempts.
				}

				if (attempt >= maxAttempts) {
					if (selectedChatIdRef.current === chatId) {
						await loadMessagesForChat(chatId);
					}
					return;
				}

				setTimeout(() => {
					void trySyncMessages(attempt + 1);
				}, retryDelayMs);
			};

			await trySyncMessages(1);
		},
		[api, clearRestErrors, dispatch, loadMessagesForChat],
	);

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
							title: context.chat.title,
							status: context.chat.status,
							diffAdded: context.chat.diffAdded,
							diffRemoved: context.chat.diffRemoved,
							updatedAt: context.chat.updatedAt,
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

	const loadCodexModels = useCallback(async () => {
		try {
			const catalog = await api.listCodexModels();
			setAvailableModels(catalog.models);
			clearRestErrors();
		} catch (error) {
			addError(
				formatApiErrorMessage(error, "Unable to load codex models"),
				"rest",
				formatApiErrorCode(error),
			);
		} finally {
			setHasLoadedCodexModels(true);
		}
	}, [addError, api, clearRestErrors, formatApiErrorCode, formatApiErrorMessage]);

	const handleWsEvent = useCallback(
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
					dispatch({
						payload: {
							chatId: event.data.chatId,
							delta: event.data.delta,
						},
						type: "APPEND_STREAMING",
					});
					clearChatSending(event.data.chatId);
					break;
				case "assistant_snapshot":
					dispatch({
						payload: {
							chatId: event.data.chatId,
							text: event.data.partialText,
						},
						type: "SET_STREAMING_SNAPSHOT",
					});
					break;
				case "assistant_event":
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
						dispatch({
							payload: { chatId: event.data.chatId },
							type: "CLEAR_STREAMING",
						});
						if (selectedChatIdRef.current === event.data.chatId) {
							await syncFinalMessagesAfterDone(event.data.chatId);
							void refreshProjectGit();
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
						dispatch({
							payload: { chatId: event.data.chatId },
							type: "CLEAR_STREAMING",
						});
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

					switch (envelope.type) {
						case "project_created":
						case "project_updated":
							if (isSelfWorkspaceEvent) {
								break;
							}
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
							if (!isSelfWorkspaceEvent) {
								await loadProjects();
							}
							break;
						case "chat_created":
						case "chat_deleted": {
							if (isSelfWorkspaceEvent) {
								break;
							}
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
							if (isSelfWorkspaceEvent || chatId === selectedChatIdRef.current) {
								break;
							}

							const diffAdded = payload?.diffAdded;
							const diffRemoved = payload?.diffRemoved;
							const isActive = payload?.isActive;
							const status = payload?.status;
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
							if (isSelfWorkspaceEvent) {
								break;
							}
							if (isMessagePayload(messagePayload)) {
								if (messagePayload.chatId === selectedChatIdRef.current) {
									dispatch({
										payload: messagePayload,
										type: "APPEND_MESSAGE",
									});
								}
								break;
							}
							if (chatId && chatId === selectedChatIdRef.current) {
								await loadMessagesForChat(chatId);
							}
							break;
						case "selection_updated":
							if (!isSelfWorkspaceEvent) {
								await loadProjects();
							}
							break;
						case "git_updated":
							if (isSelfWorkspaceEvent) {
								break;
							}
							if (projectId && projectId === selectedProjectIdRef.current) {
								void refreshProjectGit();
							}
							break;
						case "terminal_command_started":
						case "terminal_entry_appended":
						case "terminal_command_finished":
							if (isSelfWorkspaceEvent) {
								break;
							}
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
			dispatch,
			loadChatsForProject,
			loadMessagesForChat,
			loadProjects,
			refreshProjectGit,
			syncFinalMessagesAfterDone,
			syncTerminalHistory,
		],
	);

	const handleWsState = useCallback(
			(connectionState: ConnectionState) => {
				dispatch({ payload: connectionState, type: "SET_CONNECTION_STATE" });
				if (connectionState === "connected") {
					wsRef.current?.sendJoinWorkspace(lastWorkspaceSeqRef.current, workspaceClientIdRef.current);
					if (selectedChatIdRef.current) {
						wsRef.current?.sendJoinChat(selectedChatIdRef.current);
					}
				}
			},
			[dispatch],
	);

	const handleBootstrap = useCallback(() => {
		dispatch({
			payload: { baseUrl, token },
			type: "BOOTSTRAP_CONFIG",
		});
		return Promise.all([loadProjects(), loadCodexModels()]);
	}, [baseUrl, dispatch, loadCodexModels, loadProjects, token]);

	useEffect(() => {
		void handleBootstrap();
	}, [handleBootstrap]);

	useEffect(() => {
		void loadChatsForProject(state.selectedProjectId, persistedSelectedChatIdRef.current);
	}, [loadChatsForProject, state.selectedProjectId]);

	useEffect(() => {
		void loadMessagesForChat(state.selectedChatId);
	}, [loadMessagesForChat, state.selectedChatId]);

	useEffect(() => {
		void loadChatContext(state.selectedChatId);
	}, [loadChatContext, state.selectedChatId]);

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
			if (terminalOpenByChatRef.current[state.selectedChatId]) {
				void syncTerminalHistory(state.selectedChatId);
			}
		}
	}, [state.connectionState, state.selectedChatId, syncTerminalHistory]);

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

			dispatch({ payload: true, type: "SET_CREATING_CHAT" });
			try {
				const chat = await api.createChat(state.selectedProjectId, title);
				dispatch({ payload: chat, type: "UPSERT_CHAT" });
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

	const handleSendMessage = useCallback(
		async (text: string) => {
			if (selectedChat?.isActive) {
				addError("This thread is currently running. Wait until it finishes.", "ws", "chat_running");
				return;
			}

			const result = await sendWorkspaceMessage({
				createChatId: async () => {
					const chat = await handleCreateChat("New thread");
					return chat?.id ?? null;
				},
				createTimestamp: () => new Date().toISOString(),
				generateMessageId: () => crypto.randomUUID(),
				hasOpenWebSocket: Boolean(wsRef.current),
				onAppendMessage: (message) => {
					dispatch({
						payload: message,
						type: "APPEND_MESSAGE",
					});
				},
				onClearStreaming: (chatId) => {
					dispatch({
						payload: { chatId: chatId ?? null },
						type: "RESET_STREAMING",
					});
				},
					onCreateMessageError: addError,
					onSendUserMessage: (chatId, messageText) => {
						dispatch({
							payload: {
								id: chatId,
								isActive: true,
								status: "running",
								updatedAt: new Date().toISOString(),
							},
							type: "UPDATE_CHAT",
						});
						const requestId =
							typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
								? crypto.randomUUID()
								: `ws-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;
						wsRef.current?.sendUserMessage(
							chatId,
							messageText,
							state.selectedProjectId ?? undefined,
							permissionMode,
							selectedModel ?? undefined,
							selectedReasoningEffort ?? undefined,
							workspaceClientIdRef.current,
							requestId,
						);
					},
				onSetSending: (chatId, sending) => {
					dispatch({
						payload: {
							chatId,
							sending,
						},
						type: "SET_CHAT_SENDING",
					});
				},
				selectedChatId: state.selectedChatId,
				selectedChatExists: Boolean(selectedChat),
				selectedChatProvider: selectedChat?.provider ?? null,
				selectedProjectId: state.selectedProjectId,
				text,
			});

			if (result.sent && result.chatId) {
				pendingSendChatIdsRef.current.add(result.chatId);
				return;
			}

			if (result.chatId) {
				pendingSendChatIdsRef.current.delete(result.chatId);
			}
		},
		[
			addError,
			dispatch,
			handleCreateChat,
			permissionMode,
			selectedModel,
			selectedReasoningEffort,
			selectedChat?.status,
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
						dispatch({
							payload: { chatId: result.chat.id },
							type: "CLEAR_STREAMING",
						});
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
		[addError, api, dispatch, formatApiErrorCode, formatApiErrorMessage],
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

	const handleSetStreamItemExpanded = useCallback(
		(itemId: string, expanded: boolean, byUser: boolean) => {
			const chatId = selectedChatIdRef.current;
			if (!chatId) {
				return;
			}

			dispatch({
				payload: {
					chatId,
					itemId,
					expanded,
					byUser,
				},
				type: "SET_STREAM_ITEM_EXPANDED",
			});
		},
		[dispatch],
	);

	const handleSetStreamItemState = useCallback(
		(itemId: string, stateValue: "running" | "preview" | "collapsed" | "completed" | "failed" | "cancelled") => {
			const chatId = selectedChatIdRef.current;
			if (!chatId) {
				return;
			}

			dispatch({
				payload: {
					chatId,
					itemId,
					state: stateValue,
				},
				type: "SET_STREAM_ITEM_STATE",
			});
		},
		[dispatch],
	);

	const handleSelectProject = useCallback(
		async (projectId: string) => {
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

			dispatch({ payload: null, type: "SET_SELECTED_CHAT" });
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
		if (!openingThreadId) {
			return;
		}

		if (state.selectedChatId !== openingThreadId) {
			return;
		}

		if (state.messagesLoading) {
			return;
		}

		setOpeningThreadId(null);
	}, [openingThreadId, state.messagesLoading, state.selectedChatId]);

	const handleDeleteProject = useCallback(
		async (projectId: string) => {
			try {
				const deletionResult = await api.deleteProject(projectId);
				if (!deletionResult.deleted) {
					throw new Error("Unable to delete workspace");
				}
				if (state.selectedProjectId === projectId) {
					await persistWorkspaceSelection(null, null);
				}

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
			<div className="relative h-full w-full overflow-hidden">
				<div className="pointer-events-none absolute inset-0 bg-[radial-gradient(circle_at_48%_84%,rgba(55,150,255,0.22),transparent_44%)]" />
				<motion.div
						style={{ "--desktop-sidebar-width": `${sidebarWidth}px` } as CSSProperties}
						animate={shouldReduceMotion ? undefined : { opacity: 1, y: 0 }}
						className={cn(
							"grid h-full w-full min-h-0 overflow-hidden rounded-b-[14px] border-x border-b border-white/5 bg-[#0d0f14]/88 backdrop-blur-xl",
							isSidebarVisible
								? "grid-cols-[var(--desktop-sidebar-width)_8px_minmax(0,1fr)] max-[920px]:grid-cols-1 max-[920px]:grid-rows-[minmax(280px,42vh)_minmax(0,1fr)]"
								: "grid-cols-[minmax(0,1fr)]",
							)}
							initial={shouldReduceMotion ? undefined : { opacity: 0, y: 12 }}
							transition={{ duration: 0.32, ease: "easeOut" }}
						>
						<span className="noise-mask" />

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
															void handleCreateChat("New thread");
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
												<p className="px-2 py-1.5 text-[11px] text-slate-400">Loading workspaces...</p>
											) : state.projects.length === 0 ? (
												<p className="rounded-md border border-dashed border-white/10 px-2.5 py-3 text-[11px] text-slate-400">
													No workspaces yet. Open a project folder to begin.
												</p>
											) : (
												state.projects.map((project) => {
													const isSelectedProject = project.id === state.selectedProjectId;
													const isThreadListOpen = isSelectedProject ? projectThreadsOpen[project.id] !== false : false;
													const isThreadListExpanded = Boolean(expandedProjectThreads[project.id]);
													const hasMoreThreads =
														isThreadListOpen &&
														isSelectedProject &&
														state.chats.length > SIDEBAR_MAX_VISIBLE_THREADS &&
														!isThreadListExpanded;
													const visibleChats =
														isThreadListOpen && isThreadListExpanded
														? state.chats
														: state.chats.slice(0, SIDEBAR_MAX_VISIBLE_THREADS);
													return (
														<motion.section
															className="px-1 py-0.5 transition-colors duration-150"
															key={project.id}
															layout={!shouldReduceMotion}
														>
																<div
																	aria-label={`Select ${project.name}`}
																	className="group flex min-w-0 cursor-pointer items-center gap-1.5 rounded-md px-1.5 py-1 transition hover:text-slate-100"
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
																	{project.id === openingProjectId ? (
																		<Loader2 className="h-3.5 w-3.5 shrink-0 animate-spin text-sky-300" />
																	) : (
																		<Folder className="h-3.5 w-3.5 shrink-0 text-slate-400/90" />
																	)}
																	<span className="min-w-0">
																		<span
																			className="block truncate text-[13px] font-medium text-slate-100"
																			title={formatProjectMeta(project.path)}
																			>
																				{project.name}
																			</span>
																		</span>
																<Tooltip>
																	<TooltipTrigger asChild>
																		<Button
																			aria-label={`Delete ${project.name}`}
																			className="h-6 w-6 shrink-0 text-rose-300/80 opacity-0 transition-opacity hover:text-rose-100 group-hover:opacity-100 focus-visible:opacity-100"
																			onClick={(event) => {
																				event.stopPropagation();
																				void handleDeleteProject(project.id);
																			}}
																			size="icon"
																			type="button"
																			variant="ghost"
																		>
																			<Trash2 className="h-4 w-4" />
																		</Button>
																	</TooltipTrigger>
																	<TooltipContent>Delete workspace</TooltipContent>
																</Tooltip>
															</div>

															{isSelectedProject && isThreadListOpen ? (
																<ul className="ml-3 mt-1.5 space-y-0.5 border-l border-white/8 pl-2.5">
																	{state.chatsLoading ? (
																		<li className="px-1.5 py-1 text-[11px] text-slate-400">Loading threads...</li>
																	) : state.chats.length === 0 ? (
																		<li className="px-1.5 py-1 text-[11px] text-slate-400">No threads yet.</li>
																	) : (
																		<>
													{visibleChats.map((chat) => (
																					<motion.li key={chat.id} className="w-full" layout={!shouldReduceMotion}>
																					<div
                                                                                        aria-label={`Open ${chat.title}`}
                                                                                        className={cn(
                                                                                            "group relative grid w-full min-h-[2rem] grid-cols-[minmax(0,1fr)_auto] items-center gap-2 rounded-md px-1.5 py-1.5 text-left text-[13px] transition duration-150",
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
																							<span className={cn("inline-flex min-w-0 items-center gap-1.5", state.selectedChatId === chat.id ? "self-center" : "")}>
                                                                                                <span className="truncate leading-5">{chat.title}</span>
																								{isChatActive(chat.id) ? (
																									<span className="inline-flex items-center gap-1 rounded-full border border-sky-300/25 bg-sky-400/10 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-[0.06em] text-sky-100">
																										<Loader2 className="h-2.5 w-2.5 animate-spin" />
																										Active
																									</span>
																								) : null}
                                                                                            </span>
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
																			))}
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
								</aside>

								<button
									aria-label="Resize sidebar"
									className={cn(
										"z-20 h-full cursor-ew-resize touch-none p-0 transition-colors duration-150 hover:bg-white/[0.04] max-[920px]:hidden",
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
															{activeThreadChat?.title ?? "New thread"}
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
														hasRestError={state.errors.some((error) => error.source === "rest")}
														isWorking={isSelectedThreadWorking}
														loading={state.messagesLoading}
														messages={state.messages}
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
									selectedModel={selectedModel}
									selectedReasoningEffort={selectedReasoningEffort}
									sending={selectedChatSending}
									stopping={selectedChatStopping}
								/>
												</div>
											</div>

											{isTerminalOpen && state.selectedChatId ? (
												<div className="shrink-0 border-t border-white/10">
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
												</div>
											) : null}
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

export default App;
