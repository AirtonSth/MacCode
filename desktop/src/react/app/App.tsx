import { type CSSProperties, type PointerEvent as ReactPointerEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import {
	AlertTriangle,
	Folder,
	FolderOpen,
	MessageSquareText,
	PanelLeft,
	RefreshCcw,
	SquareTerminal,
	Sparkles,
	Star,
	Trash2,
	X,
} from "lucide-react";

import { Electroview } from "electrobun/view";
import { Badge } from "../components/ui/badge";
import { Button } from "../components/ui/button";
import { ScrollArea } from "../components/ui/scroll-area";
import { Separator } from "../components/ui/separator";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "../components/ui/tooltip";
import { MessageComposer } from "../features/composer/ui/MessageComposer";
import { ConversationPanel } from "../features/conversation/ui/ConversationPanel";
import { useThreadTerminalSession } from "../features/terminal/model/useThreadTerminalSession";
import { ThreadTerminalPanel } from "../features/terminal/ui/ThreadTerminalPanel";
import { useWorkspaceStore } from "../features/workspace/model/useWorkspaceStore";
import { sendWorkspaceMessage } from "../features/workspace/model/send-message";
import { cn } from "../lib/utils";
import { RemoteCodeApi, RemoteCodeApiError } from "../shared/api/remotecode-http";
import {
	RemoteCodeRealtime,
	type ConnectionState,
	type ServerWsEvent,
} from "../shared/realtime/remotecode-ws";

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

const getConnectionPillClass = (connectionState: ConnectionState): string => {
	switch (connectionState) {
		case "connected":
			return "border-emerald-300/30 bg-emerald-400/10 text-emerald-100";
		case "connecting":
		case "reconnecting":
			return "border-amber-300/30 bg-amber-400/10 text-amber-100";
		case "disconnected":
			return "border-rose-300/30 bg-rose-400/10 text-rose-100";
		default:
			return "border-slate-300/20 bg-slate-400/10 text-slate-200";
	}
};

const OPEN_PROJECT_RPC_TIMEOUT_MS = 120_000;
const SIDEBAR_WIDTH_STORAGE_KEY = "remotecode-desktop-sidebar-width";
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

const SUGGESTION_CARDS = [
	"Build a classic Snake game in this repo.",
	"Create a one-page PDF that summarizes this app.",
	"Create a plan to improve the backend architecture.",
];

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

const App = (): JSX.Element => {
	const { dispatch, state } = useWorkspaceStore();
	const shouldReduceMotion = useReducedMotion();
	const wsRef = useRef<ReturnType<(typeof RemoteCodeRealtime)["createClient"]> | null>(null);
	const selectedChatIdRef = useRef<string | null>(null);
	const persistedSelectedChatIdRef = useRef<string | null>(null);
	const sidebarWidthRef = useRef<number>(DEFAULT_SIDEBAR_WIDTH);
	const isSidebarResizingRef = useRef<boolean>(false);
	const sidebarResizeStartXRef = useRef<number>(0);
	const sidebarResizeStartWidthRef = useRef<number>(DEFAULT_SIDEBAR_WIDTH);
	const terminalOpenByChatRef = useRef<Record<string, boolean>>({});

	const baseUrl = useMemo(() => {
		return (import.meta.env.VITE_REMOTECODE_SERVER_URL || "http://127.0.0.1:3001").trim();
	}, []);

	const token = useMemo(() => {
		return (import.meta.env.VITE_REMOTECODE_LOCAL_TOKEN || "local-dev-token").trim();
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

	const streamingText = selectedChatIdRef.current
		? state.streamingByChat[selectedChatIdRef.current] ?? ""
		: "";

	const [isOpeningProject, setIsOpeningProject] = useState(false);
	const [sidebarWidth, setSidebarWidth] = useState<number>(() => {
		if (typeof window === "undefined") {
			return DEFAULT_SIDEBAR_WIDTH;
		}

		return parseSidebarWidth(window.localStorage.getItem(SIDEBAR_WIDTH_STORAGE_KEY));
	});
	const [isSidebarVisible, setIsSidebarVisible] = useState<boolean>(true);

	useEffect(() => {
		sidebarWidthRef.current = sidebarWidth;
	}, [sidebarWidth]);

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

	const addError = useCallback(
		(message: string, source: "rest" | "ws", code = "unknown") => {
			dispatch({
				type: "ADD_ERROR",
				payload: { code, message, source },
			});
		},
		[dispatch],
	);

	const formatApiErrorCode = useCallback((error: unknown) => {
		return error instanceof RemoteCodeApiError ? `HTTP_${error.status}` : "NETWORK";
	}, []);

	const formatApiErrorMessage = useCallback((error: unknown, fallback: string) => {
		return error instanceof Error ? error.message : fallback;
	}, []);

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
		async (selectedProjectId: string | null, selectedChatId: string | null) => {
			try {
				await api.updateWorkspaceSelection({
					selectedChatId,
					selectedProjectId,
				});
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to persist selection"),
					"rest",
					formatApiErrorCode(error),
				);
			}
		},
		[addError, api, formatApiErrorCode, formatApiErrorMessage],
	);

	const loadMessagesForChat = useCallback(
		async (chatId: string | null) => {
			if (!chatId) {
				dispatch({ payload: [], type: "SET_MESSAGES" });
				dispatch({ payload: false, type: "SET_MESSAGES_LOADING" });
				return;
			}

			dispatch({ payload: true, type: "SET_MESSAGES_LOADING" });
			try {
				const messages = await api.listMessages(chatId);
				dispatch({ payload: messages, type: "SET_MESSAGES" });
			} catch (error) {
				if (formatApiErrorCode(error) === "HTTP_404") {
					dispatch({ payload: [], type: "SET_MESSAGES" });
					return;
				}
				addError(
					formatApiErrorMessage(error, "Unable to fetch messages from chat"),
					"rest",
					formatApiErrorCode(error),
				);
			} finally {
				dispatch({ payload: false, type: "SET_MESSAGES_LOADING" });
			}
		},
		[addError, api, dispatch, formatApiErrorCode, formatApiErrorMessage],
	);

	const loadChatsForProject = useCallback(
		async (projectId: string | null, preferredChatId: string | null = null) => {
			if (!projectId) {
				dispatch({ payload: [], type: "SET_CHATS" });
				dispatch({ payload: null, type: "SET_SELECTED_CHAT" });
				dispatch({ payload: false, type: "SET_CHATS_LOADING" });
				return;
			}

			dispatch({ payload: null, type: "SET_SELECTED_CHAT" });
			dispatch({ payload: true, type: "SET_CHATS_LOADING" });
			try {
				const chats = await api.listChats(projectId);
				const hasPreferredChat = preferredChatId ? chats.some((chat) => chat.id === preferredChatId) : false;
				const selectedChatId = hasPreferredChat ? preferredChatId : chats[0]?.id ?? null;

				dispatch({ payload: chats, type: "SET_CHATS" });
				if (hasPreferredChat) {
					dispatch({ payload: preferredChatId, type: "SET_SELECTED_CHAT" });
				}
				await persistWorkspaceSelection(projectId, selectedChatId);
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to load chats for project"),
					"rest",
					formatApiErrorCode(error),
				);
				dispatch({ payload: [], type: "SET_CHATS" });
			} finally {
				dispatch({ payload: false, type: "SET_CHATS_LOADING" });
				persistedSelectedChatIdRef.current = null;
			}
		},
		[addError, api, dispatch, formatApiErrorCode, formatApiErrorMessage, persistWorkspaceSelection],
	);

	const loadProjects = useCallback(async () => {
		dispatch({ payload: true, type: "SET_PROJECTS_LOADING" });
		try {
			const [projects, selection] = await Promise.all([
				api.listProjects(),
				api.getWorkspaceSelection().catch(() => ({ selectedChatId: null, selectedProjectId: null })),
			]);
			const hasSelection = selection.selectedProjectId
				? projects.some((project) => project.id === selection.selectedProjectId)
				: false;
			const selectedProjectId = hasSelection ? selection.selectedProjectId : projects[0]?.id ?? null;
			const selectedChatId = hasSelection ? selection.selectedChatId : null;

			persistedSelectedChatIdRef.current = selectedChatId;
			dispatch({ payload: projects, type: "SET_PROJECTS" });
			dispatch({ payload: selectedProjectId, type: "SET_SELECTED_PROJECT" });

			if (
				selection.selectedProjectId !== selectedProjectId ||
				selection.selectedChatId !== selectedChatId
			) {
				await persistWorkspaceSelection(selectedProjectId, selectedChatId);
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
	}, [addError, api, dispatch, formatApiErrorCode, formatApiErrorMessage, persistWorkspaceSelection]);

	const handleWsEvent = useCallback(
		async (event: ServerWsEvent) => {
			switch (event.event) {
				case "assistant_delta":
					dispatch({
						payload: {
							chatId: event.data.chatId,
							delta: event.data.delta,
						},
						type: "APPEND_STREAMING",
					});
					if (selectedChatIdRef.current === event.data.chatId) {
						dispatch({
							payload: false,
							type: "SET_SENDING_MESSAGE",
						});
					}
					break;
				case "assistant_done":
					dispatch({
						payload: { chatId: event.data.chatId },
						type: "CLEAR_STREAMING",
					});
					if (selectedChatIdRef.current === event.data.chatId) {
						await loadMessagesForChat(event.data.chatId);
					}
					dispatch({
						payload: false,
						type: "SET_SENDING_MESSAGE",
					});
					break;
				case "chat_updated":
					dispatch({
						payload: {
							diffAdded: event.data.diffAdded,
							diffRemoved: event.data.diffRemoved,
							id: event.data.chatId,
							status: event.data.status,
							updatedAt: event.data.updatedAt,
						},
						type: "UPDATE_CHAT",
					});
					break;
				case "error":
					addError(event.data.message, "ws", event.data.code);
					if (event.data.chatId) {
						dispatch({
							payload: { chatId: event.data.chatId },
							type: "CLEAR_STREAMING",
						});
						if (selectedChatIdRef.current === event.data.chatId) {
							dispatch({
								payload: false,
								type: "SET_SENDING_MESSAGE",
							});
						}
					}
					break;
			}
		},
		[addError, dispatch, loadMessagesForChat],
	);

	const handleWsState = useCallback(
		(connectionState: ConnectionState) => {
			dispatch({ payload: connectionState, type: "SET_CONNECTION_STATE" });
			if (connectionState === "connected" && selectedChatIdRef.current) {
				wsRef.current?.sendJoinChat(selectedChatIdRef.current);
				void loadMessagesForChat(selectedChatIdRef.current);
			}
		},
		[dispatch, loadMessagesForChat],
	);

	const handleBootstrap = useCallback(() => {
		dispatch({
			payload: { baseUrl, token },
			type: "BOOTSTRAP_CONFIG",
		});
		return loadProjects();
	}, [baseUrl, dispatch, loadProjects, token]);

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
		[addError, api, dispatch, formatApiErrorCode, formatApiErrorMessage, persistWorkspaceSelection],
	);

	const handleToggleFavorite = useCallback(
		async (projectId: string, isFavorite: boolean) => {
			dispatch({ payload: { id: projectId, isFavorite }, type: "TOGGLE_FAVORITE" });
			try {
				const project = await api.toggleFavorite(projectId, isFavorite);
				dispatch({ payload: project, type: "UPSERT_PROJECT" });
			} catch (error) {
				addError(
					formatApiErrorMessage(error, "Unable to update project"),
					"rest",
					formatApiErrorCode(error),
				);
			}
		},
		[addError, api, dispatch, formatApiErrorCode, formatApiErrorMessage],
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
				await persistWorkspaceSelection(state.selectedProjectId, chat.id);
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
		[addError, api, dispatch, formatApiErrorCode, formatApiErrorMessage, persistWorkspaceSelection, state.selectedProjectId],
	);

	const handleSendMessage = useCallback(
		async (text: string) => {
			await sendWorkspaceMessage({
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
						payload: { chatId },
						type: "CLEAR_STREAMING",
					});
				},
				onCreateMessageError: addError,
				onSendUserMessage: (chatId, messageText) => {
					wsRef.current?.sendUserMessage(chatId, messageText);
				},
				onSetSending: (sending) => {
					dispatch({
						payload: sending,
						type: "SET_SENDING_MESSAGE",
					});
				},
				selectedChatId: state.selectedChatId,
				selectedChatProvider: selectedChat?.provider ?? null,
				selectedProjectId: state.selectedProjectId,
				text,
			});
		},
		[
			addError,
			dispatch,
			handleCreateChat,
			selectedChat?.provider,
			state.selectedChatId,
			state.selectedProjectId,
		],
	);

	const handleSelectProject = useCallback(
		async (projectId: string) => {
			if (projectId === state.selectedProjectId) {
				return;
			}

			dispatch({ payload: null, type: "SET_SELECTED_CHAT" });
			dispatch({ payload: projectId, type: "SET_SELECTED_PROJECT" });
			persistedSelectedChatIdRef.current = null;
			await persistWorkspaceSelection(projectId, null);
		},
		[dispatch, persistWorkspaceSelection, state.selectedProjectId],
	);

	const handleSelectChat = useCallback(
		async (chatId: string) => {
			if (chatId === state.selectedChatId) {
				return;
			}

			dispatch({ payload: chatId, type: "SET_SELECTED_CHAT" });
			persistedSelectedChatIdRef.current = chatId;
			await persistWorkspaceSelection(state.selectedProjectId, chatId);
		},
		[dispatch, persistWorkspaceSelection, state.selectedChatId, state.selectedProjectId],
	);

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
		},
		[
			addError,
			api,
			dispatch,
			formatApiErrorCode,
			formatApiErrorMessage,
			loadChatsForProject,
			state.chats,
			state.selectedChatId,
			state.selectedProjectId,
		],
	);

	const clearAllErrors = useCallback(() => {
		dispatch({ type: "CLEAR_ERRORS" });
	}, [dispatch]);

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

	const connectionMessage = useMemo(() => {
		switch (state.connectionState) {
			case "connected":
				return "Connected";
			case "connecting":
				return "Connecting...";
			case "reconnecting":
				return "Reconnecting...";
			case "disconnected":
				return "Disconnected";
			default:
				return "Idle";
		}
	}, [state.connectionState]);
	const hasProjects = state.projects.length > 0;
	const isThreadFocusMode = Boolean(state.selectedChatId);
	const selectedThreadTerminal = state.selectedChatId
		? terminalState.chats[state.selectedChatId] ?? null
		: null;
	const isTerminalOpen = Boolean(selectedThreadTerminal?.isOpen);
	const sidebarToggleLabel = isSidebarVisible ? "Hide sidebar" : "Show sidebar";

	return (
				<TooltipProvider delayDuration={120}>
			<div className="relative h-full w-full overflow-hidden">
				<div className="pointer-events-none absolute inset-0 bg-[radial-gradient(circle_at_48%_84%,rgba(55,150,255,0.22),transparent_44%)]" />
				<motion.div
						style={{ "--desktop-sidebar-width": `${sidebarWidth}px` } as CSSProperties}
						animate={shouldReduceMotion ? undefined : { opacity: 1, y: 0 }}
							className={cn(
								"grid h-full w-full min-h-0 border border-white/5 bg-[#0d0f14]/88 backdrop-blur-xl",
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
								<aside className="codex-sidebar relative z-10 flex min-h-0 flex-col border-r border-sidebar-border/70 bg-[#101319]/92 px-2 py-2 backdrop-blur-xl max-[920px]:border-b max-[920px]:border-r-0">
									<div className="flex items-center justify-between px-1.5 pb-2 pt-1">
										<h2 className="text-[23px] font-medium tracking-[-0.01em] text-slate-300/95">Threads</h2>
										<div className="flex items-center gap-0.5">
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
												<p className="px-2 py-1.5 text-[12px] text-slate-400">Loading workspaces...</p>
											) : state.projects.length === 0 ? (
												<p className="rounded-md border border-dashed border-white/10 bg-white/[0.01] px-2.5 py-3 text-[12px] text-slate-400">
													No workspaces yet. Open a project folder to begin.
												</p>
											) : (
												state.projects.map((project) => {
													const isSelectedProject = project.id === state.selectedProjectId;
													return (
														<motion.section
															className={cn(
																"rounded-lg px-1 py-0.5 transition-colors duration-150",
																isSelectedProject ? "bg-white/[0.03]" : "hover:bg-white/[0.02]",
															)}
															key={project.id}
															layout={!shouldReduceMotion}
														>
															<div className="group flex items-center gap-1.5">
																<button
																	aria-label={`Select ${project.name}`}
																	className="flex min-w-0 flex-1 items-center gap-2 rounded-md border border-transparent px-1.5 py-1 text-left transition hover:border-white/10 hover:bg-white/[0.02]"
																	onClick={() => {
																		void handleSelectProject(project.id);
																	}}
																	type="button"
																>
																	<Folder className="h-3.5 w-3.5 shrink-0 text-slate-400/90" />
																	<span className="min-w-0">
																		<span
																			className="block truncate text-[15px] font-medium text-slate-100"
																			title={formatProjectMeta(project.path)}
																		>
																			{project.name}
																		</span>
																	</span>
																</button>
																<Tooltip>
																	<TooltipTrigger asChild>
																		<Button
																			aria-label={
																				project.isFavorite
																					? "Remove from favorites"
																					: "Add to favorites"
																			}
																			className="h-6 w-6 shrink-0 opacity-0 transition-opacity group-hover:opacity-100 focus-visible:opacity-100"
																			onClick={() => {
																				void handleToggleFavorite(project.id, !project.isFavorite);
																			}}
																			size="icon"
																			type="button"
																			variant="ghost"
																		>
																			<Star
																				className={cn(
																					"h-4 w-4",
																					project.isFavorite
																						? "fill-amber-300 text-amber-300"
																						: "text-slate-500",
																				)}
																			/>
																		</Button>
																	</TooltipTrigger>
																	<TooltipContent>
																		{project.isFavorite ? "Remove favorite" : "Mark as favorite"}
																	</TooltipContent>
																</Tooltip>
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

															{isSelectedProject ? (
																<ul className="ml-3 mt-1.5 space-y-0.5 border-l border-white/8 pl-2.5">
																	{state.chatsLoading ? (
																		<li className="px-1.5 py-1 text-[12px] text-slate-400">Loading threads...</li>
																	) : state.chats.length === 0 ? (
																		<li className="px-1.5 py-1 text-[12px] text-slate-400">No threads yet.</li>
																	) : (
																		state.chats.map((chat) => (
																			<motion.li key={chat.id} layout={!shouldReduceMotion}>
																				<div
																					className={cn(
																						"group flex items-center gap-2 rounded-md border border-transparent px-1.5 py-1.5 text-left text-[14px] transition duration-150",
																						state.selectedChatId === chat.id
																							? "bg-white/[0.07] text-slate-100"
																							: "text-slate-300 hover:bg-white/[0.04]",
																					)}
																				>
																					<button
																						aria-label={`Open ${chat.title}`}
																						className="inline-flex min-w-0 flex-1 items-center"
																						onClick={() => {
																							void handleSelectChat(chat.id);
																						}}
																						type="button"
																					>
																						<span className="truncate leading-5">{chat.title}</span>
																					</button>
																					<span className="shrink-0 text-[12px] text-slate-500">
																						{formatRelativeTime(chat.updatedAt)}
																					</span>
																					<Tooltip>
																						<TooltipTrigger asChild>
																							<Button
																								aria-label={`Delete ${chat.title}`}
																								className="h-6 w-6 shrink-0 text-rose-300/80 opacity-0 transition-opacity hover:text-rose-100 group-hover:opacity-100 focus-visible:opacity-100"
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
																			</motion.li>
																		))
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
									className="z-20 h-full cursor-ew-resize touch-none bg-transparent p-0 transition-colors duration-150 hover:bg-white/[0.04] max-[920px]:hidden"
									onPointerCancel={stopSidebarResize}
									onPointerDown={startSidebarResize}
									onPointerMove={handleSidebarResizePointerMove}
									onPointerUp={handleSidebarResizePointerUp}
									type="button"
								/>
							</>
						) : null}

					<main className={cn("relative z-10 flex min-h-0 flex-col", isThreadFocusMode ? "bg-transparent" : "bg-slate-950/35")}>
						{hasProjects ? (
								isThreadFocusMode ? (
									<section className="flex h-full min-h-0 flex-1 flex-col overflow-y-auto overflow-x-hidden">
										<header className="flex h-14 items-center justify-between gap-3 border-b border-white/10 px-4">
											<div className="flex min-w-0 items-center gap-2">
												<Tooltip>
													<TooltipTrigger asChild>
														<Button
															aria-label={sidebarToggleLabel}
															className="h-8 w-8 shrink-0 text-slate-300 hover:bg-white/[0.06] hover:text-slate-100"
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
													<p className="text-[11px] font-semibold uppercase tracking-[0.18em] text-slate-400">Thread</p>
													<h2 className="truncate text-sm font-semibold text-slate-100">
														{selectedChat?.title ?? "No thread selected"}
													</h2>
												</div>
											</div>
											<Button
											className={cn(
												"gap-2",
												isTerminalOpen
													? "border-sky-300/30 bg-sky-400/10 text-sky-100 hover:bg-sky-400/20"
													: "border-white/10 text-slate-200 hover:bg-white/[0.06]",
											)}
											onClick={handleToggleTerminal}
											type="button"
											variant="outline"
										>
											<SquareTerminal className="h-4 w-4" />
											<span className="sr-only">{isTerminalOpen ? "Hide terminal" : "Show terminal"}</span>
										</Button>
									</header>

										<div className="relative min-h-0 flex-1 overflow-hidden">
											<ConversationPanel
												chat={selectedChat}
												focusMode
												hasRestError={state.errors.some((error) => error.source === "rest")}
												loading={state.messagesLoading}
												messages={state.messages}
												streamingText={streamingText}
											/>
										</div>

									<div className="shrink-0 border-t border-white/10 bg-slate-950/35 px-3 pb-4 pt-3 sm:px-6">
										<div className="mx-auto w-full max-w-3xl">
											<MessageComposer
												chatStatus={selectedChat?.status ?? null}
												disabled={!state.selectedProjectId}
												focusMode
												onSend={handleSendMessage}
												sending={state.isSendingMessage}
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
								<>
										<header className="flex h-16 items-center justify-between gap-3 border-b border-white/10 px-4 lg:px-5">
											<div className="flex min-w-0 items-center gap-2">
												<Tooltip>
													<TooltipTrigger asChild>
														<Button
															aria-label={sidebarToggleLabel}
															className="h-8 w-8 shrink-0 text-slate-300 hover:bg-white/[0.06] hover:text-slate-100"
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
													<p className="text-[11px] font-semibold uppercase tracking-[0.18em] text-slate-400">
														Workspace
													</p>
													<h1 className="truncate text-sm font-semibold text-slate-100">
														{selectedChat ? selectedChat.title : "New thread"}
													</h1>
												</div>
											</div>
											<div className="flex shrink-0 items-center gap-2">
											<Tooltip>
												<TooltipTrigger asChild>
													<Button
														disabled={isOpeningProject}
														onClick={() => {
															void handleOpenProject();
														}}
														size="icon"
														type="button"
														variant="outline"
													>
														<FolderOpen className="h-4 w-4" />
													</Button>
												</TooltipTrigger>
												<TooltipContent>Open folder</TooltipContent>
											</Tooltip>
											<Tooltip>
												<TooltipTrigger asChild>
													<Button
														onClick={() => {
															void loadProjects();
														}}
														size="icon"
														type="button"
														variant="outline"
													>
														<RefreshCcw className="h-4 w-4" />
													</Button>
												</TooltipTrigger>
												<TooltipContent>Reload</TooltipContent>
											</Tooltip>
											{state.errors.length > 0 ? (
												<Tooltip>
													<TooltipTrigger asChild>
														<Button onClick={clearAllErrors} size="icon" type="button" variant="destructive">
															<AlertTriangle className="h-4 w-4" />
														</Button>
													</TooltipTrigger>
													<TooltipContent>Clear {state.errors.length} errors</TooltipContent>
												</Tooltip>
											) : null}
											<Badge className={getConnectionPillClass(state.connectionState)} variant="outline">
												{connectionMessage}
											</Badge>
										</div>
									</header>

									<section className="flex min-h-0 flex-1 flex-col gap-3 p-3 lg:p-4">
										<AnimatePresence initial={false}>
											{state.errors.length > 0 ? (
												<motion.div
													animate={{ opacity: 1, y: 0 }}
													className="space-y-2"
													exit={{ opacity: 0, y: -8 }}
													initial={{ opacity: 0, y: -8 }}
												>
													{state.errors.map((error) => (
														<motion.article
															className="flex items-start gap-3 rounded-2xl border border-rose-300/30 bg-rose-500/10 px-3 py-2.5 text-xs text-rose-100"
															key={error.id}
															layout={!shouldReduceMotion}
														>
															<AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
															<div className="min-w-0 flex-1">
																<p className="truncate font-semibold">{error.code}</p>
																<p className="truncate">{error.message}</p>
															</div>
															<Button
																aria-label={`Dismiss ${error.message}`}
																className="h-7 w-7 rounded-lg"
																onClick={() => {
																	dispatch({ payload: error.id, type: "REMOVE_ERROR" });
																}}
																size="icon"
																type="button"
																variant="ghost"
															>
																<X className="h-3.5 w-3.5" />
															</Button>
														</motion.article>
													))}
												</motion.div>
											) : null}
										</AnimatePresence>

										<div className="relative min-h-0 flex-1">
											{state.selectedChatId ? (
												<ConversationPanel
													chat={selectedChat}
													hasRestError={state.errors.some((error) => error.source === "rest")}
													loading={state.messagesLoading}
													messages={state.messages}
													streamingText={streamingText}
												/>
											) : (
												<motion.div
													animate={shouldReduceMotion ? undefined : { opacity: 1, y: 0 }}
													className="grid h-full place-items-center rounded-[28px] border border-white/10 bg-slate-950/45 p-6 text-center backdrop-blur-2xl"
													initial={shouldReduceMotion ? undefined : { opacity: 0, y: 10 }}
													transition={{ duration: 0.28 }}
												>
													<div>
														<div className="mx-auto mb-3 grid h-12 w-12 place-items-center rounded-2xl border border-white/20 bg-white/[0.04]">
															<Sparkles className="h-5 w-5 text-sky-200" />
														</div>
														<h2 className="text-[clamp(1.4rem,2.5vw,2.2rem)] font-bold text-slate-100">
															Let&apos;s build
														</h2>
														<p className="mt-1 text-[clamp(1rem,1.9vw,1.3rem)] text-slate-400">
															{selectedProject?.name ?? "remotecode.io"}
														</p>
													</div>
												</motion.div>
											)}
										</div>

										<div className="space-y-3">
											<div className="grid gap-2 md:grid-cols-3">
												{SUGGESTION_CARDS.map((card) => (
													<button
														className="group cursor-pointer rounded-2xl border border-white/10 bg-white/[0.03] px-3 py-3 text-left text-sm text-slate-300 transition hover:border-white/20 hover:bg-white/[0.06]"
														key={card}
														type="button"
													>
														<span className="mb-2 inline-flex h-6 w-6 items-center justify-center rounded-lg border border-white/15 bg-white/[0.03]">
															<Sparkles className="h-3.5 w-3.5 text-slate-300/80 group-hover:text-sky-200" />
														</span>
														<span className="block leading-5">{card}</span>
													</button>
												))}
											</div>

											<MessageComposer
												chatStatus={selectedChat?.status ?? null}
												disabled={!state.selectedProjectId}
												onSend={handleSendMessage}
												sending={state.isSendingMessage}
											/>

											<Separator />

											<div className="flex flex-wrap items-center gap-3 text-xs text-slate-400">
												<span className="inline-flex items-center gap-1.5">
													<span
														className={cn(
															"h-1.5 w-1.5 rounded-full",
															state.connectionState === "connected"
																? "bg-emerald-300"
																: state.connectionState === "disconnected"
																	? "bg-rose-300"
																	: "bg-amber-300",
														)}
													/>
													Local
												</span>
												<span>{connectionMessage}</span>
												<span>{selectedProject?.name ?? "No workspace selected"}</span>
											</div>
										</div>
									</section>
								</>
							)
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
